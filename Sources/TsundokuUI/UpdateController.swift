import AppKit
import Foundation
import TsundokuCore

/// Owns the update check's UI state, its daily schedule and its preference.
///
/// The check never downloads or installs anything: it reports a newer release
/// and opens its GitHub page. Automatic checks run at most once a day and can
/// be turned off; the request carries no archive or reading data.
@MainActor
public final class UpdateController: ObservableObject {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(UpdateRelease)
        case failed(String)
        case unavailable
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastChecked: Date?
    @Published public var automaticallyChecks: Bool {
        didSet {
            defaults.set(automaticallyChecks, forKey: Self.automaticKey)
            if automaticallyChecks {
                if isDue { check() }
                startMonitoring()
            } else {
                monitorTask?.cancel()
                monitorTask = nil
            }
        }
    }

    public let currentVersion: String?
    private let defaults: UserDefaults
    private let checker: @Sendable (String) async -> UpdateCheckResult
    private let now: @Sendable () -> Date
    private var checkTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    static let automaticKey = "updates.automatic"
    static let lastCheckKey = "updates.lastCheck"
    static let latestVersionKey = "updates.latestVersion"
    static let latestURLKey = "updates.latestURL"
    static let latestPublishedKey = "updates.latestPublished"
    static let interval: TimeInterval = 24 * 60 * 60

    public init(
        defaults: UserDefaults = .standard,
        currentVersion: String? = Bundle.main.infoDictionary?[
            "CFBundleShortVersionString"] as? String,
        checker: @escaping @Sendable (String) async -> UpdateCheckResult = {
            await UpdateCheck.check(currentVersion: $0)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.checker = checker
        self.now = now
        self.automaticallyChecks =
            defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        if let stamp = defaults.object(forKey: Self.lastCheckKey) as? Date {
            lastChecked = stamp
        }
        if currentVersion == nil {
            state = .unavailable
        } else if let cached = Self.cachedRelease(defaults),
            let currentVersion,
            UpdateCheck.isNewer(cached.version, than: currentVersion)
        {
            state = .available(cached)
        } else if lastChecked != nil, let currentVersion {
            // The cache is younger than a day and names no newer release.
            state = .upToDate(currentVersion)
        }
    }

    public var isChecking: Bool { state == .checking }

    public var availableRelease: UpdateRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    public var versionLabel: String { currentVersion ?? "dev" }

    public var statusText: String {
        switch state {
        case .idle:
            guard let lastChecked else { return "Not checked yet." }
            return "Last checked "
                + lastChecked.formatted(date: .abbreviated, time: .shortened)
                + "."
        case .checking:
            return "Checking GitHub for a newer release…"
        case .upToDate(let version):
            return "Tsundoku \(version) is the latest release."
        case .available(let release):
            return "Tsundoku \(release.version) is available."
        case .failed(let message):
            return message
        case .unavailable:
            return "Development builds are not checked."
        }
    }

    /// Starts the daily schedule and performs a due check. A development
    /// build has no version and never checks.
    public func start() {
        guard currentVersion != nil else {
            state = .unavailable
            return
        }
        guard automaticallyChecks else { return }
        if isDue { check() }
        startMonitoring()
    }

    public func check() {
        guard let currentVersion else {
            state = .unavailable
            return
        }
        checkTask?.cancel()
        state = .checking
        checkTask = Task { [weak self, checker, now] in
            let result = await checker(currentVersion)
            guard let self, !Task.isCancelled else { return }
            state = Self.state(result)
            lastChecked = now()
            defaults.set(lastChecked, forKey: Self.lastCheckKey)
            Self.cache(result, defaults: defaults)
            TsundokuDiagnostics.shared.event(
                "update_check",
                [
                    "result": Self.diagnosticName(result),
                    "current": currentVersion,
                ])
        }
    }

    /// Waits for the check started by `check()`, for tests and callers that
    /// need the settled state without polling.
    public func awaitCheck() async {
        await checkTask?.value
    }

    public func openReleasePage() {
        NSWorkspace.shared.open(availableRelease?.url ?? UpdateCheck.releasePage)
    }

    private var isDue: Bool {
        guard let lastChecked else { return true }
        return now().timeIntervalSince(lastChecked) >= Self.interval
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        guard automaticallyChecks else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.interval))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled,
                    self.automaticallyChecks
                else { return }
                self.check()
            }
        }
    }

    private static func cachedRelease(
        _ defaults: UserDefaults
    ) -> UpdateRelease? {
        guard let version = defaults.string(forKey: latestVersionKey),
            let rawURL = defaults.string(forKey: latestURLKey),
            let url = URL(string: rawURL),
            UpdateCheck.isAllowedReleaseURL(url)
        else { return nil }
        let stamp = defaults.object(forKey: latestPublishedKey) as? Date
        return UpdateRelease(version: version, url: url, publishedAt: stamp)
    }

    private static func cache(
        _ result: UpdateCheckResult, defaults: UserDefaults
    ) {
        switch result {
        case .available(let release):
            defaults.set(release.version, forKey: latestVersionKey)
            defaults.set(
                release.url.absoluteString, forKey: latestURLKey)
            defaults.set(release.publishedAt, forKey: latestPublishedKey)
        case .upToDate:
            defaults.removeObject(forKey: latestVersionKey)
            defaults.removeObject(forKey: latestURLKey)
            defaults.removeObject(forKey: latestPublishedKey)
        case .failed:
            // Keep the last known release; a transient failure must not erase
            // an update the reader has already been told about.
            break
        }
    }

    private static func state(_ result: UpdateCheckResult) -> State {
        switch result {
        case .upToDate(let version): .upToDate(version)
        case .available(let release): .available(release)
        case .failed(let message): .failed(message)
        }
    }

    private static func diagnosticName(_ result: UpdateCheckResult) -> String {
        switch result {
        case .upToDate: "up_to_date"
        case .available(let release): "available:\(release.version)"
        case .failed: "failed"
        }
    }
}
