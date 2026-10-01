//
//  SettingsWindow.swift
//  Ice
//

import SwiftUI

struct SettingsWindow: Scene {
    @ObservedObject var appState: AppState

    var body: some Scene {
        Window(Constants.settingsWindowTitle, id: Constants.settingsWindowID) {
            SettingsView()
                .readWindow { window in
                    guard let window else {
                        return
                    }
                    appState.assignSettingsWindow(window)
                }
                .localEventMonitor(mask: .keyDown) { event in
                    closeSettingsWindowIfNeeded(for: event)
                }
                .frame(minWidth: 825, minHeight: 500)
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 625)
        .environmentObject(appState)
        .environmentObject(appState.navigationState)
    }

    /// Closes the settings window if the given event is the standard
    /// close shortcut (Command-W) and the settings window is key.
    ///
    /// The app hides its main menu and removes the window's commands,
    /// so the shortcut is handled explicitly here.
    private func closeSettingsWindowIfNeeded(for event: NSEvent) -> NSEvent? {
        MainActor.assumeIsolated {
            guard
                let window = appState.settingsWindow,
                window.isKeyWindow,
                event.window === window,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers?.lowercased() == "w"
            else {
                return event
            }
            window.performClose(nil)
            return nil
        }
    }
}
