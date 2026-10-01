//
//  UpdatesManager.swift
//  Ice
//

import SwiftUI

/// Manager for app updates.
///
/// Updates are checked against the GitHub releases of this fork, rather than
/// the upstream Sparkle appcast, so that the app is never offered (or replaced
/// by) an upstream build that lacks the fork's changes.
@MainActor
final class UpdatesManager: ObservableObject {
    /// A release published on GitHub.
    private struct Release: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
        }

        /// The version string of the release, without a leading "v".
        var versionString: String {
            if tagName.lowercased().hasPrefix("v") {
                String(tagName.dropFirst())
            } else {
                tagName
            }
        }
    }

    /// The result of an update check.
    private enum CheckResult {
        case updateAvailable(Release)
        case upToDate
        case failed(Error)
    }

    /// An error that can occur during an update check.
    private enum CheckError: LocalizedError {
        case badResponse(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .badResponse(let statusCode):
                String(localized: "The server returned an unexpected response (\(statusCode)).")
            }
        }
    }

    /// The URL of the API endpoint for the latest release of the app.
    private static let latestReleaseURL: URL = {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://api.github.com/repos/chanLik1208-dev/Ice-zhtw/releases/latest")!
    }()

    /// The interval between automatic update checks.
    private static let automaticCheckInterval: TimeInterval = 60 * 60 * 24

    /// A Boolean value that indicates whether an update check is in progress.
    @Published private(set) var isCheckingForUpdates = false

    /// The date of the last update check.
    @Published private(set) var lastUpdateCheckDate: Date? {
        didSet {
            Defaults.set(lastUpdateCheckDate, forKey: .lastUpdateCheckDate)
        }
    }

    /// A Boolean value that indicates whether to automatically check for updates.
    @Published var automaticallyChecksForUpdates = true {
        didSet {
            Defaults.set(automaticallyChecksForUpdates, forKey: .automaticallyChecksForUpdates)
            if isSetUp {
                scheduleAutomaticChecks()
            }
        }
    }

    /// A Boolean value that indicates whether the user can check for updates.
    var canCheckForUpdates: Bool {
        !isCheckingForUpdates
    }

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The timer that drives automatic update checks.
    private var automaticCheckTimer: Timer?

    /// The version for which the user was last notified of an update.
    private var lastNotifiedVersion: String?

    /// A Boolean value that indicates whether the manager has been set up.
    private var isSetUp = false

    /// Creates an updates manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the manager.
    func performSetup() {
        Defaults.ifPresent(key: .automaticallyChecksForUpdates, assign: &automaticallyChecksForUpdates)
        lastUpdateCheckDate = Defaults.object(forKey: .lastUpdateCheckDate) as? Date
        isSetUp = true
        scheduleAutomaticChecks()
    }

    /// Schedules or cancels automatic update checks, depending on the
    /// value of ``automaticallyChecksForUpdates``.
    private func scheduleAutomaticChecks() {
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil

        guard automaticallyChecksForUpdates else {
            return
        }

        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performAutomaticCheckIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        automaticCheckTimer = timer

        // Check shortly after launch, without delaying setup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.performAutomaticCheckIfNeeded()
        }
    }

    /// Performs an automatic update check if enough time has passed since
    /// the last check.
    private func performAutomaticCheckIfNeeded() {
        guard
            automaticallyChecksForUpdates,
            !isCheckingForUpdates
        else {
            return
        }
        if
            let lastUpdateCheckDate,
            Date.now.timeIntervalSince(lastUpdateCheckDate) < Self.automaticCheckInterval
        {
            return
        }
        isCheckingForUpdates = true
        Task {
            let result = await performCheck()
            handleAutomaticCheckResult(result)
        }
    }

    /// Checks for app updates, presenting the result to the user.
    func checkForUpdates() {
        guard !isCheckingForUpdates else {
            return
        }
        isCheckingForUpdates = true
        Task {
            let result = await performCheck()
            presentUserInitiatedCheckResult(result)
        }
    }

    /// Fetches the latest release and compares it to the current version.
    ///
    /// The caller is responsible for setting ``isCheckingForUpdates`` to `true`
    /// before calling this method, to prevent overlapping checks.
    private func performCheck() async -> CheckResult {
        defer {
            isCheckingForUpdates = false
        }

        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            lastUpdateCheckDate = .now

            // No release has been published yet.
            if statusCode == 404 {
                return .upToDate
            }
            guard (200..<300).contains(statusCode) else {
                throw CheckError.badResponse(statusCode: statusCode)
            }

            let release = try JSONDecoder().decode(Release.self, from: data)
            if Self.isVersion(release.versionString, newerThan: Constants.versionString) {
                return .updateAvailable(release)
            }
            return .upToDate
        } catch {
            Logger.updates.error("Failed to check for updates: \(error)")
            return .failed(error)
        }
    }

    /// Handles the result of an automatic update check.
    private func handleAutomaticCheckResult(_ result: CheckResult) {
        guard
            let appState,
            case .updateAvailable(let release) = result,
            release.versionString != lastNotifiedVersion
        else {
            return
        }
        lastNotifiedVersion = release.versionString
        appState.userNotificationManager.requestAuthorization()
        appState.userNotificationManager.addRequest(
            with: .updateCheck,
            title: String(localized: "A new update is available"),
            body: String(localized: "Version \(release.versionString) is now available")
        )
    }

    /// Presents the result of a user-initiated update check.
    private func presentUserInitiatedCheckResult(_ result: CheckResult) {
        guard let appState else {
            return
        }

        appState.userNotificationManager.removeDeliveredNotifications(with: [.updateCheck])

        let alert = NSAlert()
        var releaseURL: URL?

        switch result {
        case .updateAvailable(let release):
            releaseURL = release.htmlURL
            alert.messageText = String(localized: "A new update is available")
            alert.informativeText = String(
                localized: "Ice \(release.versionString) is now available. You are currently using version \(Constants.versionString)."
            )
            alert.addButton(withTitle: String(localized: "Download"))
            alert.addButton(withTitle: String(localized: "Later"))
        case .upToDate:
            alert.messageText = String(localized: "You're up to date!")
            alert.informativeText = String(
                localized: "Ice \(Constants.versionString) is currently the newest version available."
            )
        case .failed(let error):
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Failed to check for updates")
            alert.informativeText = error.localizedDescription
        }

        appState.activate(withPolicy: .regular)
        let response = alert.runModal()

        if
            let releaseURL,
            response == .alertFirstButtonReturn
        {
            NSWorkspace.shared.open(releaseURL)
        }

        // Return to the accessory policy if there is no window left to show.
        if appState.settingsWindow?.isVisible != true {
            appState.deactivate(withPolicy: .accessory)
        }
    }

    /// Returns a Boolean value that indicates whether the first version
    /// string represents a newer version than the second.
    ///
    /// Versions are compared by their numeric components, so "0.11.13",
    /// "v0.11.13", and "0.11.12-zhtw.1" are all newer than "0.11.12".
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        func components(of version: String) -> [Int] {
            version
                .split { !($0.isASCII && $0.isNumber) }
                .compactMap { Int($0) }
        }

        let lhsComponents = components(of: lhs)
        let rhsComponents = components(of: rhs)

        for index in 0..<max(lhsComponents.count, rhsComponents.count) {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
        }
        return false
    }
}

// MARK: UpdatesManager: BindingExposable
extension UpdatesManager: BindingExposable { }

// MARK: - Logger
private extension Logger {
    static let updates = Logger(category: "Updates")
}
