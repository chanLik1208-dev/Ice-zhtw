//
//  MenuBarItemSpacingManager.swift
//  Ice
//

import Cocoa
import Combine

/// Manager for menu bar item spacing.
@MainActor
final class MenuBarItemSpacingManager {
    /// UserDefaults keys.
    private enum Key: String {
        case spacing = "NSStatusItemSpacing"
        case padding = "NSStatusItemSelectionPadding"

        /// The default value for the key.
        var defaultValue: Int {
            switch self {
            case .spacing: 16
            case .padding: 16
            }
        }
    }

    /// An error that groups multiple failed app relaunches.
    private struct GroupedRelaunchError: LocalizedError {
        let failedApps: [String]

        var errorDescription: String? {
            String(localized: "The following applications failed to quit and were not restarted:") + "\n" + failedApps.joined(separator: "\n")
        }

        var recoverySuggestion: String? {
            String(localized: "You may need to log out for the changes to take effect.")
        }
    }

    /// Delay before force terminating an app.
    private let forceTerminateDelay = 1

    /// The offset to apply to the default spacing and padding.
    /// Does not take effect until ``applyOffset()`` is called.
    var offset = 0

    /// An error that occurs when a `defaults` command fails.
    private struct DefaultsCommandError: LocalizedError {
        let arguments: [String]
        let status: Int32

        var errorDescription: String? {
            String(localized: "Failed to save the menu bar item spacing (exit code \(status)).")
        }

        var recoverySuggestion: String? {
            "defaults " + arguments.joined(separator: " ")
        }
    }

    /// An error that occurs when the system reverts the spacing after it was applied.
    private struct SpacingRevertedError: LocalizedError {
        var errorDescription: String? {
            String(localized: "macOS reverted the menu bar item spacing after it was applied.")
        }

        var recoverySuggestion: String? {
            String(localized: "This version of macOS may not support changing the menu bar item spacing.")
        }
    }

    /// The domains that the spacing is written to.
    ///
    /// The value is written to both the current host's global domain and the
    /// global domain, as different versions of macOS read it from different
    /// places.
    private static let domainArguments: [[String]] = [
        ["-currentHost"],
        [],
    ]

    /// Runs the `defaults` command with the given arguments, returning its output.
    @discardableResult
    private func runDefaults(_ arguments: [String]) async throws -> String {
        let task = Task.detached {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(filePath: "/usr/bin/defaults")
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw DefaultsCommandError(arguments: arguments, status: process.terminationStatus)
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try await task.value
    }

    /// Removes the value for the specified key.
    private func removeValue(forKey key: Key) async {
        for domain in Self.domainArguments {
            // Deleting a key that doesn't exist fails, which is fine.
            _ = try? await runDefaults(domain + ["delete", "-globalDomain", key.rawValue])
        }
    }

    /// Sets the value for the specified key to the key's default value plus the given offset.
    private func setOffset(_ offset: Int, forKey key: Key) async throws {
        for domain in Self.domainArguments {
            try await runDefaults(domain + ["write", "-globalDomain", key.rawValue, "-int", String(key.defaultValue + offset)])
        }
    }

    /// Returns the values currently stored for the specified key, one for each
    /// of the domains in ``domainArguments``.
    private func storedValues(forKey key: Key) async -> [Int?] {
        var values = [Int?]()
        for domain in Self.domainArguments {
            let output = try? await runDefaults(domain + ["read", "-globalDomain", key.rawValue])
            values.append(output.flatMap { Int($0) })
        }
        return values
    }

    /// Returns a log string for the given app.
    private nonisolated func logString(for app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "<NIL>"
    }

    /// Asynchronously signals the given app to quit.
    private func signalAppToQuit(_ app: NSRunningApplication) async throws {
        if app.isTerminated {
            Logger.spacing.debug("Application \"\(logString(for: app))\" is already terminated")
            return
        } else {
            Logger.spacing.debug("Signaling application \"\(logString(for: app))\" to quit")
        }

        app.terminate()

        /// Resumes a continuation at most once, from any context.
        final class Resumer: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Error>?
            var cancellable: AnyCancellable?

            init(_ continuation: CheckedContinuation<Void, Error>) {
                self.continuation = continuation
            }

            func resume(with result: Result<Void, Error>) {
                lock.lock()
                let continuation = self.continuation
                self.continuation = nil
                lock.unlock()
                cancellable?.cancel()
                continuation?.resume(with: result)
            }
        }

        struct QuitTimeoutError: Error { }

        return try await withCheckedThrowingContinuation { continuation in
            let resumer = Resumer(continuation)

            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(forceTerminateDelay))
                if !app.isTerminated {
                    Logger.spacing.debug("Application \"\(logString(for: app))\" did not terminate within \(forceTerminateDelay) seconds, attempting to force terminate")
                    app.forceTerminate()
                }
                // Don't wait forever for an app that refuses to quit, or
                // applying the spacing never finishes.
                try await Task.sleep(for: .seconds(forceTerminateDelay * 2))
                if !app.isTerminated {
                    Logger.spacing.debug("Application \"\(logString(for: app))\" could not be terminated")
                    resumer.resume(with: .failure(QuitTimeoutError()))
                }
            }

            resumer.cancellable = app.publisher(for: \.isTerminated).sink { [weak self] isTerminated in
                guard
                    let self,
                    isTerminated
                else {
                    return
                }
                timeoutTask.cancel()
                Logger.spacing.debug("Application \"\(logString(for: app))\" terminated successfully")
                resumer.resume(with: .success(()))
            }
        }
    }

    /// Asynchronously launches the app at the given URL.
    private nonisolated func launchApp(at applicationURL: URL, bundleIdentifier: String) async throws {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            Logger.spacing.debug("Application \"\(logString(for: app))\" is already open, so skipping launch")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }

    /// Asynchronously relaunches the given app.
    private func relaunchApp(_ app: NSRunningApplication) async throws {
        struct RelaunchError: Error { }
        guard
            let url = app.bundleURL,
            let bundleIdentifier = app.bundleIdentifier
        else {
            throw RelaunchError()
        }
        try await signalAppToQuit(app)
        if app.isTerminated {
            try await launchApp(at: url, bundleIdentifier: bundleIdentifier)
        } else {
            throw RelaunchError()
        }
    }

    /// Applies the current ``offset``.
    ///
    /// - Note: Calling this restarts all apps with a menu bar item.
    func applyOffset() async throws {
        let offset = offset
        if offset == 0 {
            await removeValue(forKey: .spacing)
            await removeValue(forKey: .padding)
        } else {
            try await setOffset(offset, forKey: .spacing)
            try await setOffset(offset, forKey: .padding)
        }

        try? await Task.sleep(for: .milliseconds(100))

        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        let pids = Set(items.map { $0.sourcePID })

        var failedApps = [String]()

        await withTaskGroup(of: Void.self) { group in
            for pid in pids {
                guard
                    let app = NSRunningApplication(processIdentifier: pid),
                    app.bundleIdentifier != "com.apple.controlcenter", // ControlCenter handles its own relaunch, so skip it.
                    app != .current
                else {
                    continue
                }
                group.addTask { @MainActor in
                    do {
                        try await self.relaunchApp(app)
                    } catch {
                        guard let name = app.localizedName else {
                            return
                        }
                        if app.bundleIdentifier == "com.apple.Spotlight" {
                            // Spotlight automatically relaunches, so only consider it a failure if it never quit.
                            if
                                let latestSpotlightInstance = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Spotlight").first,
                                latestSpotlightInstance.processIdentifier == app.processIdentifier
                            {
                                failedApps.append(name)
                            }
                        } else {
                            failedApps.append(name)
                        }
                    }
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(100))

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first {
            do {
                try await signalAppToQuit(app)
            } catch {
                if let name = app.localizedName {
                    failedApps.append(name)
                }
            }
        }

        if !failedApps.isEmpty {
            throw GroupedRelaunchError(failedApps: failedApps)
        }

        // Make sure that the system didn't revert the values once the
        // apps were relaunched.
        try? await Task.sleep(for: .seconds(2))
        for key in [Key.spacing, Key.padding] {
            let expected: Int? = offset == 0 ? nil : key.defaultValue + offset
            let values = await storedValues(forKey: key)
            Logger.spacing.info("Stored values for \(key.rawValue): \(String(describing: values)), expected \(String(describing: expected))")
            if values.contains(where: { $0 != expected }) {
                throw SpacingRevertedError()
            }
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let spacing = Logger(category: "Spacing")
}
