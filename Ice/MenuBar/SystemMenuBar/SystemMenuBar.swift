//
//  SystemMenuBar.swift
//  Ice
//

import Cocoa

/// A namespace for behavior that applies when the system manages the layout
/// of menu bar items.
///
/// Starting with macOS 27, menu bar items are no longer backed by individual
/// windows. The system lays them out itself, and moves items that don't fit
/// into its own overflow menu. Ice's techniques for hiding and arranging items
/// conflict with this, so they're disabled, and Ice only provides the Ice Bar,
/// which lists the items of other apps using the accessibility API.
enum SystemMenuBar {
    /// A Boolean value that indicates whether the system manages the layout
    /// of menu bar items.
    static let isManagedBySystem = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    /// The maximum time to wait for a single accessibility request.
    private static let messagingTimeout: Float = 0.2

    /// Returns the menu bar items of all running apps other than Ice and the
    /// system, ordered as they appear in the menu bar.
    static func fetchItems() async -> [SystemMenuBarItem] {
        await Task.detached(priority: .userInitiated) {
            makeItems()
        }.value
    }

    private static func makeItems() -> [SystemMenuBarItem] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var items = [SystemMenuBarItem]()
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard
                pid != currentPID,
                pid > 0,
                !app.isTerminated,
                !(app.bundleIdentifier?.hasPrefix("com.apple.") ?? false)
            else {
                continue
            }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, messagingTimeout)
            guard
                let extrasMenuBar: AXUIElement = copyAttribute("AXExtrasMenuBar", of: application),
                let children: [AXUIElement] = copyAttribute(kAXChildrenAttribute, of: extrasMenuBar)
            else {
                continue
            }
            for (index, child) in children.enumerated() {
                let title: String? = copyAttribute(kAXTitleAttribute, of: child)
                let description: String? = copyAttribute(kAXDescriptionAttribute, of: child)
                items.append(
                    SystemMenuBarItem(
                        id: "\(pid)-\(index)",
                        element: child,
                        application: app,
                        label: [title, description].compactMap { $0 }.first { !$0.isEmpty },
                        minX: position(of: child)?.x ?? .greatestFiniteMagnitude
                    )
                )
            }
        }
        return items.sorted { $0.minX < $1.minX }
    }

    /// Returns the position of the given accessibility element.
    private static func position(of element: AXUIElement) -> CGPoint? {
        guard let value: AXValue = copyAttribute(kAXPositionAttribute, of: element) else {
            return nil
        }
        var position = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &position) else {
            return nil
        }
        return position
    }

    /// Returns the value of an attribute of an accessibility element.
    private static func copyAttribute<T>(_ attribute: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value
        else {
            return nil
        }
        // AXUIElement and AXValue are CoreFoundation types, which can't be
        // conditionally cast, so compare their type identifiers instead.
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
        } else if T.self == AXValue.self {
            guard CFGetTypeID(value) == AXValueGetTypeID() else {
                return nil
            }
        }
        return value as? T
    }
}

// MARK: - SystemMenuBarItem

/// A menu bar item of another app, accessed using the accessibility API.
struct SystemMenuBarItem: Identifiable {
    let id: String

    /// The item's accessibility element.
    let element: AXUIElement

    /// The app that owns the item.
    let application: NSRunningApplication

    /// The item's accessibility title or description.
    let label: String?

    /// The item's horizontal position in the menu bar.
    let minX: CGFloat

    /// A name for the item that is suited for display to the user.
    var displayName: String {
        let appName = application.localizedName ?? application.bundleIdentifier ?? String(localized: "Unknown")
        guard let label, label != appName else {
            return appName
        }
        return "\(appName) – \(label)"
    }

    /// The icon of the app that owns the item.
    var icon: NSImage? {
        application.icon
    }

    /// Opens the item's menu.
    func press() {
        Task.detached(priority: .userInitiated) {
            if AXUIElementPerformAction(element, kAXPressAction as CFString) != .success {
                _ = AXUIElementPerformAction(element, "AXShowMenu" as CFString)
            }
        }
    }
}
