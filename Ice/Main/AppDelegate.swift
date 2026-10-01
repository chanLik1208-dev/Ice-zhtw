//
//  AppDelegate.swift
//  Ice
//

import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var appState: AppState?

    /// A Boolean value that indicates whether the app was launched
    /// automatically as a login item.
    private var wasLaunchedAsLoginItem = false

    // MARK: NSApplicationDelegate Methods

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let appState else {
            Logger.appDelegate.warning("Missing app state in applicationWillFinishLaunching")
            return
        }

        // Assign the delegate to the shared app state.
        appState.assignAppDelegate(self)

        // Allow the app to set the cursor in the background.
        appState.setsCursorInBackground = true

        // The launch event is only available while the app is launching.
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            wasLaunchedAsLoginItem = event.eventID == AEEventID(kAEOpenApplication) &&
                event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState else {
            Logger.appDelegate.warning("Missing app state in applicationDidFinishLaunching")
            return
        }

        // Dismiss the windows.
        appState.dismissSettingsWindow()
        appState.dismissPermissionsWindow()

        // Hide the main menu to make more space in the menu bar.
        if let mainMenu = NSApp.mainMenu {
            for item in mainMenu.items {
                item.isHidden = true
            }
        }

        // Perform setup after a small delay to ensure that the settings window
        // has been assigned.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard !appState.isPreview else {
                return
            }
            // If we have the required permissions, set up the shared app state.
            // Otherwise, open the permissions window.
            switch appState.permissionsManager.permissionsState {
            case .hasAllPermissions, .hasRequiredPermissions:
                appState.performSetup()
                // Without the Ice icon in the menu bar, the settings window is
                // the only visible sign that the app is running, so show it
                // whenever the user launches the app.
                if !Constants.isMenuBarItemManagementEnabled && !self.wasLaunchedAsLoginItem {
                    self.openSettingsWindow()
                }
            case .missingPermissions:
                appState.activate(withPolicy: .regular)
                appState.openPermissionsWindow()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Deactivate and set the policy to accessory when all windows are closed.
        appState?.deactivate(withPolicy: .accessory)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening the app (e.g. from Finder or Launchpad) shows the settings
        // window. This is the way to reach the settings when the Ice icon is
        // hidden or, on macOS 27 and later, not shown at all.
        if !flag {
            openSettingsWindow()
        }
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: Other Methods

    /// Assigns the app state to the delegate.
    func assignAppState(_ appState: AppState) {
        guard self.appState == nil else {
            Logger.appDelegate.warning("Multiple attempts made to assign app state")
            return
        }
        self.appState = appState
    }

    /// Opens the settings window and activates the app.
    @objc func openSettingsWindow() {
        guard let appState else {
            Logger.appDelegate.error("Failed to open settings window")
            return
        }
        // Small delay makes this more reliable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            appState.activate(withPolicy: .regular)
            appState.openSettingsWindow()
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let appDelegate = Logger(category: "AppDelegate")
}
