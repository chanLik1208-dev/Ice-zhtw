//
//  MenuBarItemSourceResolver.swift
//  Ice
//

import Cocoa

/// Resolves the application that a menu bar item actually belongs to.
///
/// Starting with macOS 26, the windows of all menu bar items are hosted by
/// Control Center, so the window's owner no longer identifies the app that
/// created the item. This resolver matches item windows against the frames
/// of each application's accessibility "extras menu bar" to recover the
/// source process, and against Ice's own status items to recover their
/// identifiers. On earlier versions of macOS, it does nothing.
///
/// The resolver can be used from any thread. Its state is protected by a lock.
enum MenuBarItemSourceResolver {
    /// The result of resolving a menu bar item window.
    struct Source {
        let pid: pid_t
        let title: String?
    }

    /// The frame of a status item owned by Ice, along with the title it should
    /// be identified by.
    private struct OwnItemFrame {
        let title: String
        let frame: CGRect
    }

    /// A frame in the menu bar belonging to a process.
    private struct ExtrasItemFrame {
        let pid: pid_t
        let frame: CGRect
    }

    /// A Boolean value that indicates whether resolution is needed on the
    /// current system.
    static let isResolutionNeeded: Bool = {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }()

    /// The bundle identifier of the process that hosts menu bar item windows.
    private static let hostBundleIdentifier = "com.apple.controlcenter"

    /// The maximum time to wait for a single accessibility request.
    private static let messagingTimeout: Float = 0.1

    /// The minimum interval between two accessibility snapshots.
    private static let snapshotInterval: TimeInterval = 0.5

    /// A lock that protects the resolver's state.
    private static let lock = NSLock()

    /// The frames of the status items owned by Ice.
    private static var ownItemFrames = [OwnItemFrame]()

    /// Resolved source processes, keyed by window identifier.
    private static var cache = [CGWindowID: pid_t]()

    /// The date of the most recent accessibility snapshot.
    private static var lastSnapshotDate = Date.distantPast

    /// The most recent accessibility snapshot.
    private static var snapshot = [ExtrasItemFrame]()

    /// Records the frame of a status item owned by Ice so that its window can
    /// be identified by the given title.
    ///
    /// - Parameters:
    ///   - cocoaFrame: The frame of the status item's window, with a bottom-left origin.
    ///   - title: The title that identifies the status item.
    @MainActor
    static func updateOwnItemFrame(_ cocoaFrame: CGRect, title: String) {
        guard isResolutionNeeded, let mainScreen = NSScreen.screens.first else {
            return
        }
        let frame = CGRect(
            x: cocoaFrame.minX,
            y: mainScreen.frame.maxY - cocoaFrame.maxY,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
        lock.lock()
        defer { lock.unlock() }
        ownItemFrames.removeAll { $0.title == title }
        ownItemFrames.append(OwnItemFrame(title: title, frame: frame))
    }

    /// Returns the source of the given menu bar item window, or `nil` if the
    /// window's owner already identifies the source, or it couldn't be resolved.
    static func source(for window: WindowInfo) -> Source? {
        guard
            isResolutionNeeded,
            NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier == hostBundleIdentifier
        else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        if let title = ownItemTitle(matching: window.frame) {
            return Source(pid: ProcessInfo.processInfo.processIdentifier, title: title)
        }

        if let pid = cache[window.windowID], NSRunningApplication(processIdentifier: pid) != nil {
            return Source(pid: pid, title: nil)
        }

        guard let pid = sourcePID(matching: window.frame) else {
            return nil
        }
        if cache.count > 512 {
            cache.removeAll()
        }
        cache[window.windowID] = pid
        return Source(pid: pid, title: nil)
    }

    // MARK: Own Items

    /// Returns the title of Ice's status item whose window matches the given
    /// frame, specified in screen coordinates with a top-left origin.
    private static func ownItemTitle(matching frame: CGRect) -> String? {
        ownItemFrames.first { framesMatch($0.frame, frame) }?.title
    }

    // MARK: Other Items

    /// Returns the process identifier of the application whose extras menu
    /// bar contains an item with the given frame.
    private static func sourcePID(matching frame: CGRect) -> pid_t? {
        if let match = snapshot.first(where: { framesMatch($0.frame, frame) }) {
            return match.pid
        }
        let now = Date()
        guard now.timeIntervalSince(lastSnapshotDate) >= snapshotInterval else {
            return nil
        }
        lastSnapshotDate = now
        snapshot = makeSnapshot()
        return snapshot.first { framesMatch($0.frame, frame) }?.pid
    }

    /// Returns the process identifiers of the running applications that have
    /// menu bar items, according to the accessibility API.
    ///
    /// Unlike the window list, this also works on macOS 27 and later, where
    /// menu bar items no longer have windows of their own. This method can
    /// block while waiting for unresponsive applications, so avoid calling it
    /// on the main thread.
    static func pidsOfApplicationsWithMenuBarItems() -> Set<pid_t> {
        Set(makeSnapshot().map { $0.pid })
    }

    /// Returns the frames of the extras menu bar items of all running applications.
    private static func makeSnapshot() -> [ExtrasItemFrame] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var result = [ExtrasItemFrame]()
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            // Querying our own process from the main thread would block
            // until the request times out. Ice's items are handled above.
            guard pid != currentPID, pid > 0, !app.isTerminated else {
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
            for child in children {
                if let frame = frame(of: child) {
                    result.append(ExtrasItemFrame(pid: pid, frame: frame))
                }
            }
        }
        return result
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

    /// Returns a Boolean value that indicates whether two frames describe
    /// the same menu bar item.
    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        return abs(lhs.midX - rhs.midX) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.midY - rhs.midY) <= lhs.height / 2 + tolerance
    }
}
