//
//  Constants.swift
//  Ice
//

import SwiftUI

enum Constants {
    // swiftlint:disable force_unwrapping
    /// The version string in the app's bundle.
    static let versionString = Bundle.main.versionString!

    /// The build string in the app's bundle.
    static let buildString = Bundle.main.buildString!

    /// The user-readable copyright string in the app's bundle.
    static let copyrightString = Bundle.main.copyrightString!

    /// The bundle identifier of the app.
    static let bundleIdentifier = Bundle.main.bundleIdentifier!
    // swiftlint:enable force_unwrapping

    /// A Boolean value that indicates whether Ice manages menu bar items on
    /// the current version of macOS.
    ///
    /// On macOS 27 and later, Ice's menu bar items (the Ice icon and the section
    /// dividers), the hidden sections, and the Ice Bar are all disabled.
    static let isMenuBarItemManagementEnabled: Bool = {
        if #available(macOS 27, *) {
            return false
        }
        return true
    }()

    /// The identifier for the settings window.
    static let settingsWindowID = "SettingsWindow"

    /// The identifier for the permissions window.
    static let permissionsWindowID = "PermissionsWindow"

    /// The title for the settings window.
    static let settingsWindowTitle: LocalizedStringKey = "Ice"

    /// The title for the permissions window.
    static let permissionsWindowTitle: LocalizedStringKey = "Permissions"
}
