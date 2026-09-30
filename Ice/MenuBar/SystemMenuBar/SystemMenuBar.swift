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

    /// A lock that protects the cached item frames.
    private static let lock = NSLock()

    /// The frames of all menu bar items, including the system's and Ice's,
    /// specified in screen coordinates with a top-left origin.
    private static var cachedItemFrames = [CGRect]()

    /// A Boolean value that indicates whether the cached item frames are
    /// being refreshed.
    private static var isRefreshingItemFrames = false

    /// The date the cached item frames were last refreshed.
    private static var lastItemFramesRefreshDate = Date.distantPast

    /// Returns the menu bar items of all running apps other than Ice and the
    /// system, ordered as they appear in the menu bar.
    static func fetchItems() async -> [SystemMenuBarItem] {
        await Task.detached(priority: .userInitiated) {
            SystemMenuBar.makeItems(includeSystemItems: false)
        }.value
    }

    /// Returns a Boolean value that indicates whether the given point, specified
    /// in screen coordinates with a top-left origin, is inside a menu bar item.
    ///
    /// The frames of the menu bar items are cached and refreshed in the background
    /// at most twice per second, so the result may briefly be out of date.
    static func isPointInsideMenuBarItem(_ point: CGPoint) -> Bool {
        refreshItemFramesIfNeeded()
        return lock.withLock {
            cachedItemFrames.contains { $0.contains(point) }
        }
    }

    /// Refreshes the cached item frames in the background, if they're out of date.
    static func refreshItemFramesIfNeeded() {
        let shouldRefresh = lock.withLock {
            guard
                isManagedBySystem,
                !isRefreshingItemFrames,
                Date.now.timeIntervalSince(lastItemFramesRefreshDate) >= 0.5
            else {
                return false
            }
            isRefreshingItemFrames = true
            return true
        }
        guard shouldRefresh else {
            return
        }
        Task.detached(priority: .utility) {
            let frames = SystemMenuBar.makeItems(includeSystemItems: true).compactMap(\.frame)
            SystemMenuBar.lock.withLock {
                SystemMenuBar.cachedItemFrames = frames
                SystemMenuBar.lastItemFramesRefreshDate = .now
                SystemMenuBar.isRefreshingItemFrames = false
            }
        }
    }

    private static func makeItems(includeSystemItems: Bool) -> [SystemMenuBarItem] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var items = [SystemMenuBarItem]()
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard
                pid > 0,
                !app.isTerminated
            else {
                continue
            }
            if !includeSystemItems {
                guard
                    pid != currentPID,
                    !(app.bundleIdentifier?.hasPrefix("com.apple.") ?? false)
                else {
                    continue
                }
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
                        frame: frame(of: child)
                    )
                )
            }
        }
        return items.sorted { ($0.frame?.minX ?? .greatestFiniteMagnitude) < ($1.frame?.minX ?? .greatestFiniteMagnitude) }
    }

    /// Returns the frame of the given accessibility element.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue: AXValue = copyAttribute(kAXPositionAttribute, of: element),
            let sizeValue: AXValue = copyAttribute(kAXSizeAttribute, of: element)
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue, .cgPoint, &position),
            AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
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

    /// The item's frame, specified in screen coordinates with a top-left origin.
    let frame: CGRect?

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
