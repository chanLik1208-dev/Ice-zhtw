//
//  RemoveSidebarToggle.swift
//  Ice
//

import SwiftUI

extension View {
    /// Removes the sidebar toggle button from the toolbar.
    func removeSidebarToggle() -> some View {
        toolbar(removing: .sidebarToggle)
            .toolbar {
                // Keep the placeholder from intercepting clicks meant for
                // the window's title bar buttons (e.g. on macOS 26).
                Color.clear
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
