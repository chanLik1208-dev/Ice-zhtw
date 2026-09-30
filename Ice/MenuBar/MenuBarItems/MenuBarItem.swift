//
//  MenuBarItem.swift
//  Ice
//

import Cocoa

// MARK: - MenuBarItem

/// A representation of an item in the menu bar.
struct MenuBarItem {
    /// The item's window.
    let window: WindowInfo

    /// The menu bar item info associated with this item.
    let info: MenuBarItemInfo

    /// The process identifier of the application that created the item.
    ///
    /// Before macOS 26, this is the same as ``ownerPID``. Starting with
    /// macOS 26, item windows are owned by Control Center, and this is
    /// resolved separately.
    let sourcePID: pid_t

    /// The title of the item.
    let title: String?

    /// The identifier of the item's window.
    var windowID: CGWindowID {
        window.windowID
    }

    /// The frame of the item's window.
    var frame: CGRect {
        window.frame
    }

    /// A Boolean value that indicates whether the item is on screen.
    var isOnScreen: Bool {
        window.isOnScreen
    }

    /// A Boolean value that indicates whether the item can be moved.
    var isMovable: Bool {
        let immovableItems = Set(MenuBarItemInfo.immovableItems)
        return !immovableItems.contains(info)
    }

    /// A Boolean value that indicates whether the item can be hidden.
    var canBeHidden: Bool {
        let nonHideableItems = Set(MenuBarItemInfo.nonHideableItems)
        return !nonHideableItems.contains(info)
    }

    /// The process identifier of the application that owns the item's window.
    ///
    /// Events that target the item's window should be posted to this process.
    /// To identify the application that created the item, use ``sourcePID``.
    var ownerPID: pid_t {
        window.ownerPID
    }

    /// The name of the application that owns the item.
    ///
    /// This may have a value when ``owningApplication`` does not have
    /// a localized name.
    var ownerName: String? {
        if sourcePID != window.ownerPID {
            return owningApplication?.localizedName
        }
        return window.ownerName
    }

    /// The application that owns the item.
    var owningApplication: NSRunningApplication? {
        NSRunningApplication(processIdentifier: sourcePID)
    }

    /// A name associated with the item that is suited for display to
    /// the user.
    var displayName: String {
        var fallback: String { String(localized: "Unknown") }
        guard let owningApplication else {
            return ownerName ?? title ?? fallback
        }
        var bestName: String {
            owningApplication.localizedName ??
            ownerName ??
            owningApplication.bundleIdentifier ??
            fallback
        }
        guard let title else {
            return bestName
        }
        // by default, use the application name, but handle a few special cases
        return switch MenuBarItemInfo.Namespace(owningApplication.bundleIdentifier) {
        case .controlCenter:
            switch title {
            case "AccessibilityShortcuts": String(localized: "Accessibility Shortcuts")
            case "BentoBox": bestName // Control Center
            case "Battery": String(localized: "Battery")
            case "Bluetooth": String(localized: "Bluetooth")
            case "Clock": String(localized: "Clock")
            case "Display": String(localized: "Display")
            case "Sound": String(localized: "Sound")
            case "FocusModes": String(localized: "Focus")
            case "KeyboardBrightness": String(localized: "Keyboard Brightness")
            case "MusicRecognition": String(localized: "Music Recognition")
            case "NowPlaying": String(localized: "Now Playing")
            case "ScreenMirroring": String(localized: "Screen Mirroring")
            case "StageManager": String(localized: "Stage Manager")
            case "UserSwitcher": String(localized: "Fast User Switching")
            case "WiFi": String(localized: "Wi-Fi")
            default: title
            }
        case .systemUIServer:
            switch title {
            case "TimeMachine.TMMenuExtraHost"/*Sonoma*/, "TimeMachineMenuExtra.TMMenuExtraHost"/*Sequoia*/: String(localized: "Time Machine")
            default: title
            }
        case MenuBarItemInfo.Namespace("com.apple.Passwords.MenuBarExtra"): String(localized: "Passwords")
        default:
            bestName
        }
    }

    /// A Boolean value that indicates whether the item is currently
    /// in the menu bar.
    var isCurrentlyInMenuBar: Bool {
        let list = Set(Bridging.getWindowList(option: .menuBarItems))
        return list.contains(windowID)
    }

    /// A string to use for logging purposes.
    var logString: String {
        String(describing: info)
    }

    /// Creates a menu bar item from the given window.
    ///
    /// This initializer does not perform any checks on the window to ensure that
    /// it is a valid menu bar item window. Only call this initializer if you are
    /// certain that the window is valid.
    private init(uncheckedItemWindow itemWindow: WindowInfo) {
        let source = MenuBarItemSourceResolver.source(for: itemWindow)
        let sourcePID = source?.pid ?? itemWindow.ownerPID
        let title = source?.title ?? itemWindow.title
        self.window = itemWindow
        self.sourcePID = sourcePID
        self.title = title
        self.info = MenuBarItemInfo(
            namespace: MenuBarItemInfo.Namespace(
                NSRunningApplication(processIdentifier: sourcePID)?.bundleIdentifier
            ),
            title: title ?? ""
        )
    }

    /// Creates a menu bar item.
    ///
    /// The parameters passed into this initializer are verified during the menu
    /// bar item's creation. If `itemWindow` does not represent a menu bar item,
    /// the initializer will fail.
    ///
    /// - Parameter itemWindow: A window that contains information about the item.
    init?(itemWindow: WindowInfo) {
        guard itemWindow.isMenuBarItem else {
            return nil
        }
        self.init(uncheckedItemWindow: itemWindow)
    }

    /// Creates a menu bar item with the given window identifier.
    ///
    /// The parameters passed into this initializer are verified during the menu
    /// bar item's creation. If `windowID` does not represent a menu bar item,
    /// the initializer will fail.
    ///
    /// - Parameter windowID: An identifier for a window that contains information
    ///   about the item.
    init?(windowID: CGWindowID) {
        guard let window = WindowInfo(windowID: windowID) else {
            return nil
        }
        self.init(itemWindow: window)
    }
}

// MARK: MenuBarItem Getters
extension MenuBarItem {
    /// Returns an array of the current menu bar items in the menu bar on the given display.
    ///
    /// - Parameters:
    ///   - display: The display to retrieve the menu bar items on. Pass `nil` to return the
    ///     menu bar items across all displays.
    ///   - onScreenOnly: A Boolean value that indicates whether only the menu bar items that
    ///     are on screen should be returned.
    ///   - activeSpaceOnly: A Boolean value that indicates whether only the menu bar items
    ///     that are on the active space should be returned.
    static func getMenuBarItems(on display: CGDirectDisplayID? = nil, onScreenOnly: Bool, activeSpaceOnly: Bool) -> [MenuBarItem] {
        var option: Bridging.WindowListOption = [.menuBarItems]

        var titlePredicate: (MenuBarItem) -> Bool = { _ in true }
        var boundsPredicate: (CGWindowID) -> Bool = { _ in true }

        if onScreenOnly {
            option.insert(.onScreen)
        }
        if activeSpaceOnly {
            option.insert(.activeSpace)
            titlePredicate = { $0.title != "" }
        }
        if let display {
            let displayBounds = CGDisplayBounds(display)
            boundsPredicate = { windowID in
                guard let windowFrame = Bridging.getWindowFrame(for: windowID) else {
                    return false
                }
                return displayBounds.intersects(windowFrame)
            }
        }

        return Bridging.getWindowList(option: option).lazy
            .filter(boundsPredicate)
            .compactMap { windowID in
                MenuBarItem(windowID: windowID)
            }
            .filter(titlePredicate)
            .sortedByOrderInMenuBar()
    }
}

// MARK: MenuBarItem: Equatable
extension MenuBarItem: Equatable {
    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool {
        lhs.window == rhs.window
    }
}

// MARK: MenuBarItem: Hashable
extension MenuBarItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(window)
    }
}
