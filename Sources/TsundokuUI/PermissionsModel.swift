import AppKit
import ScreenCaptureKit
import SwiftUI
import TsundokuCore

public enum ScreenAccessCheck: Sendable {
    case preflight, verified, unverified, denied, failed
}

public struct PermissionSnapshot: Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool
    public var screenCheck: ScreenAccessCheck
    public var lastChecked: Date?
    public var isChecking = false
    public var detail: String?

    public var screenStatus: String {
        if isChecking { return "Checking…" }
        switch screenCheck {
        case .preflight: return "Available"
        case .verified: return "Verified"
        case .unverified: return "Not verified"
        case .denied: return "Unavailable"
        case .failed: return "Check failed"
        }
    }

    public var checkResult: String? {
        guard let lastChecked else { return nil }
        return "Checked \(lastChecked.formatted(date: .omitted, time: .standard)). Accessibility: \(accessibility ? "available" : "unavailable"). Screen Recording: \(screenStatus.lowercased())."
    }
}

/// Reports effective access for this process; it cannot read the switches in System Settings.
@MainActor
public final class PermissionsModel: ObservableObject {
    @Published public private(set) var snapshot: PermissionSnapshot
    private let accessibilityCheck: () -> Bool
    private let screenRecordingCheck: () -> Bool
    private let screenAccessCheck: @MainActor () async throws -> Void
    private var previousPreflight: Bool
    private var checkScreenOnNextActivation = false
    @Published public private(set) var relaunchPending = false
    @Published public private(set) var activeLibraryGuideID: UUID?
    @Published public private(set) var libraryStatus: LibraryAccessStatus = .notChecked
    @Published public private(set) var libraryChecking = false
    @Published public private(set) var libraryRegistrationInProgress = false
    @Published public private(set) var libraryFailures: [LibraryImportFailure] = []
    @Published public private(set) var librarySettingsError: String?
    private let libraryAccessCheck: @MainActor () async -> LibraryAccessResult
    private let librarySettingsOpener: () -> Bool
    private let libraryRegistrationRequest: @MainActor () async -> Void
    private var libraryRegistrationTask: Task<Void, Never>?
    private var libraryRegistrationID: UUID?
    private let setupDefaults: UserDefaults
    private let librarySetupKey = "permissions.librarySetupPending"
    private let librarySetupDateKey = "permissions.librarySetupRequestedAt"
    private let now: () -> Date
    private var setupGeneration = 0
    private var importedSetupSources: Set<BookSource> = []
    @Published public private(set) var readableLibrarySources: [BookSource] = []
    public var onRelaunchRequested: (() throws -> Void)?
    private var applicationIsTerminating = false
    public var onLibraryAccessReady: (() -> Void)?

    public var librarySetupPending: Bool {
        guard setupDefaults.bool(forKey: librarySetupKey),
            let requested = setupDefaults.object(forKey: librarySetupDateKey) as? Date else { return false }
        let age = now().timeIntervalSince(requested)
        return age >= 0 && age < 24 * 3600
    }
    public var setupIncomplete: Bool {
        missing || (libraryStatus != .available && libraryStatus != .notFound)
    }

    public var accessibility: Bool { snapshot.accessibility }
    public var screenRecording: Bool { snapshot.screenRecording }
    public var lastChecked: Date? { snapshot.lastChecked }
    public var isChecking: Bool { snapshot.isChecking }
    public var checkResult: String? { snapshot.checkResult }
    public var missing: Bool { !(accessibility && screenRecording) }

    public init(
        accessibilityCheck: @escaping () -> Bool = {
            guard AXIsProcessTrusted() else { return false }
            var value: CFTypeRef?
            let element = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(element, 0.25)
            let result = AXUIElementCopyAttributeValue(element,
                kAXFocusedApplicationAttribute as CFString, &value)
            // Missing focus or a temporarily unresponsive application isn't a denied grant.
            return result != .apiDisabled
        },
        screenRecordingCheck: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        screenAccessCheck: @escaping @MainActor () async throws -> Void = {
            // Enumerates permitted capture sources; never captures pixels or audio.
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        },
        libraryAccessCheck: @escaping @MainActor () async -> LibraryAccessResult = {
            func launchPath(_ option: String) -> URL? {
                let args = CommandLine.arguments
                guard let i = args.firstIndex(of: option), args.indices.contains(i + 1) else { return nil }
                return URL(fileURLWithPath: args[i + 1])
            }
            let kindle = launchPath("--kindle-library-path").map { KindlePaths(container: $0) } ?? .standard()
            let books = launchPath("--books-data-path").map { BooksPaths(container: $0) } ?? .standard()
            return await Task.detached { LibraryAccessProbe.check(kindle: kindle, books: books) }.value
        },
        libraryRegistrationRequest: @escaping @MainActor () async -> Void = {
            let result = await Task.detached { FullDiskAccessRegistration.request() }.value
            TsundokuDiagnostics.shared.event("library_registration_attempted", [
                "attempted": result.attempted, "directory_reads": result.directoriesRead,
                "header_bytes_read": result.headerBytesRead, "permission_denials": result.permissionDenials,
                "missing_targets": result.missingTargets, "other_failures": result.otherFailures,
            ])
        },
        librarySettingsOpener: @escaping () -> Bool = {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") else { return false }
            return NSWorkspace.shared.open(url)
        },
        setupDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.accessibilityCheck = accessibilityCheck
        self.screenRecordingCheck = screenRecordingCheck
        self.screenAccessCheck = screenAccessCheck
        self.libraryAccessCheck = libraryAccessCheck
        self.librarySettingsOpener = librarySettingsOpener
        self.libraryRegistrationRequest = libraryRegistrationRequest
        self.setupDefaults = setupDefaults
        self.now = now
        if setupDefaults.bool(forKey: librarySetupKey), setupDefaults.object(forKey: librarySetupDateKey) == nil {
            setupDefaults.set(now(), forKey: librarySetupDateKey)
        }
        if let requested = setupDefaults.object(forKey: librarySetupDateKey) as? Date,
            !(0..<(24 * 3600)).contains(now().timeIntervalSince(requested)) {
            setupDefaults.removeObject(forKey: librarySetupKey)
            setupDefaults.removeObject(forKey: librarySetupDateKey)
        }
        let screen = screenRecordingCheck()
        previousPreflight = screen
        snapshot = PermissionSnapshot(accessibility: accessibilityCheck(),
            screenRecording: screen, screenCheck: screen ? .preflight : .unverified)
    }

    /// Quiet preflight for activation/capture paths. Never opens a consent prompt.
    public func refresh(invalidateVerification: Bool = false) {
        let screen = screenRecordingCheck()
        let keepVerification = !invalidateVerification && screen == previousPreflight
            && (snapshot.screenCheck == .verified || snapshot.screenCheck == .denied)
        previousPreflight = screen
        snapshot = PermissionSnapshot(
            accessibility: accessibilityCheck(),
            screenRecording: keepVerification ? snapshot.screenRecording : screen,
            screenCheck: keepVerification ? snapshot.screenCheck : screen ? .preflight : .unverified,
            lastChecked: keepVerification ? snapshot.lastChecked : Date(),
            isChecking: snapshot.isChecking,
            detail: keepVerification ? snapshot.detail : nil)
    }

    public func applicationBecameActive() {
        refresh()
        resumeLibrarySetupIfNeeded()
        if checkScreenOnNextActivation {
            checkScreenOnNextActivation = false
            Task { await verifyAccess() }
        }
    }

    /// Explicit user verification uses the same framework as screen capture.
    public func verifyAccess() async {
        guard !isChecking else { return }
        snapshot.isChecking = true
        var next = snapshot
        do {
            try await screenAccessCheck()
            next.screenRecording = true
            next.screenCheck = .verified
            next.detail = nil
        } catch is CancellationError {
            next.screenRecording = screenRecordingCheck()
            next.screenCheck = next.screenRecording ? .preflight : .unverified
            next.detail = "Verification was cancelled."
        } catch {
            let ns = error as NSError
            let denied = ns.domain == SCStreamError.errorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue
            next.screenRecording = denied ? false : screenRecordingCheck()
            next.screenCheck = denied ? .denied : .failed
            next.detail = "\(ns.domain) (\(ns.code)): \(ns.localizedDescription)"
        }
        next.accessibility = accessibilityCheck()
        next.lastChecked = Date()
        next.isChecking = false
        snapshot = next
    }

    /// First give TCC an access attempt attributed to this app, then open Settings.
    /// macOS controls listing; the person must still approve the access switch.
    public func requestLibraryAccess() {
        guard !libraryRegistrationInProgress, !applicationIsTerminating else { return }
        if !librarySetupPending {
            setupGeneration += 1
            importedSetupSources.removeAll()
        }
        setupDefaults.set(true, forKey: librarySetupKey)
        setupDefaults.set(now(), forKey: librarySetupDateKey)
        librarySettingsError = nil
        let id = UUID()
        libraryRegistrationID = id
        libraryRegistrationInProgress = true
        libraryRegistrationTask = Task { [weak self] in
            guard let self else { return }
            await self.libraryRegistrationRequest()
            guard self.libraryRegistrationID == id else { return }
            self.libraryRegistrationTask = nil
            self.libraryRegistrationID = nil
            self.libraryRegistrationInProgress = false
            guard !Task.isCancelled, !self.applicationIsTerminating, self.librarySetupPending else { return }
            self.openLibrarySettings()
        }
    }

    public func openLibrarySettings() {
        let opened = librarySettingsOpener()
        TsundokuDiagnostics.shared.event("library_access_settings_opened", ["success": opened])
        librarySettingsError = opened ? nil
            : "Open System Settings → Privacy & Security → Full Disk Access."
    }

    public func prepareForTermination() { applicationIsTerminating = true }

    public func cancelLibrarySetup() {
        guard !applicationIsTerminating else { return }
        libraryRegistrationID = nil
        libraryRegistrationTask?.cancel()
        libraryRegistrationTask = nil
        libraryRegistrationInProgress = false
        setupGeneration += 1
        importedSetupSources.removeAll()
        setupDefaults.removeObject(forKey: librarySetupKey)
        setupDefaults.removeObject(forKey: librarySetupDateKey)
    }

    public func resumeLibrarySetupIfNeeded() {
        guard librarySetupPending, !libraryRegistrationInProgress else { return }
        Task { await verifyLibraryAccess() }
    }

    public func verifyLibraryAccess() async {
        guard !libraryChecking, !libraryRegistrationInProgress, !applicationIsTerminating else { return }
        libraryChecking = true
        let pendingAtStart = librarySetupPending
        let generation = setupGeneration
        let result = await libraryAccessCheck()
        guard !applicationIsTerminating else { libraryChecking = false; return }
        libraryStatus = result.status
        readableLibrarySources = result.readableSources
        libraryFailures = result.failures
        libraryChecking = false
        guard generation == setupGeneration, pendingAtStart, librarySetupPending, !libraryRegistrationInProgress else { return }
        let newSources = Set(result.readableSources).subtracting(importedSetupSources)
        importedSetupSources.formUnion(newSources)
        if result.status == .available || result.status == .notFound {
            cancelLibrarySetup()
        }
        if !newSources.isEmpty { onLibraryAccessReady?() }
    }

    public func importReadableLibrary() {
        guard !readableLibrarySources.isEmpty, !libraryChecking else { return }
        onLibraryAccessReady?()
    }

    public func claimLibraryGuide(_ id: UUID) { activeLibraryGuideID = id }

    public func dismissLibraryGuide(_ id: UUID) {
        guard activeLibraryGuideID == id else { return }
        activeLibraryGuideID = nil
        cancelLibrarySetup()
    }

    public func requestRelaunch() {
        guard !relaunchPending else { return }
        // Relaunch must retain setup intent even if a guide is torn down during termination.
        setupDefaults.set(true, forKey: librarySetupKey)
        setupDefaults.set(now(), forKey: librarySetupDateKey)
        guard let onRelaunchRequested else {
            librarySettingsError = "Quit Tsundoku, then reopen it from Applications."
            return
        }
        relaunchPending = true
        do {
            try onRelaunchRequested()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(65))
                guard let self, !self.applicationIsTerminating else { return }
                self.relaunchPending = false
                self.librarySettingsError = "Tsundoku did not quit. Close any open dialog, then try again."
            }
        } catch {
            relaunchPending = false
            librarySettingsError = "Could not reopen Tsundoku: \(error.localizedDescription). Quit and reopen it from Applications."
        }
    }

    public func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openAccessibilitySettings()
    }

    public func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openScreenSettings()
    }

    public func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public func openScreenSettings() {
        checkScreenOnNextActivation = true
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ path: String) {
        if let url = URL(string: path) { NSWorkspace.shared.open(url) }
    }
}
