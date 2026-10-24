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
    private var requestedReaderFocus: AccessFocus?
    private let relaunchTimeout: Duration
    @Published public private(set) var relaunchPending = false
    @Published public private(set) var relaunchError: String?
    @Published public private(set) var relaunchErrorFocus: AccessFocus?
    @Published public private(set) var readerAccessRequested = false
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
    private let resumeAccessKey = "permissions.resumeAccessOnLaunch"
    private let librarySetupKey = "permissions.librarySetupPending"
    private let librarySetupDateKey = "permissions.librarySetupRequestedAt"
    private let now: () -> Date
    private var setupGeneration = 0
    private var importedSetupSources: Set<BookSource> = []
    @Published public private(set) var readableLibrarySources: [BookSource] = []
    public var onRelaunchRequested: (() throws -> Void)?
    public var onRelaunchFailed: (() -> Void)?
    private var applicationIsTerminating = false
    public var onLibraryAccessReady: (() -> Void)?

    public var librarySetupPending: Bool {
        guard setupDefaults.bool(forKey: librarySetupKey),
            let requested = setupDefaults.object(forKey: librarySetupDateKey) as? Date else { return false }
        let age = now().timeIntervalSince(requested)
        return age >= 0 && age < 24 * 3600
    }
    public var librarySetupGeneration: Int { setupGeneration }
    public var libraryReady: Bool { !readableLibrarySources.isEmpty }
    public var companionReady: Bool { accessibility }
    public var captureReady: Bool { accessibility && screenRecording }
    public var libraryInstruction: String? {
        if libraryReady {
            guard librarySetupPending, libraryFailures.contains(where: \.accessDenied) else { return nil }
            return "Enable Tsundoku in Full Disk Access to import the blocked library, then return here."
        }
        guard librarySetupPending || libraryStatus == .blocked else { return nil }
        return "In Full Disk Access, turn on Tsundoku, then return here."
    }
    public var accessResumeFocus: AccessFocus? {
        guard setupDefaults.bool(forKey: resumeAccessKey),
            let requested = setupDefaults.object(forKey: "permissions.resumeAccessRequestedAt") as? Date,
            (0..<(24 * 3600)).contains(now().timeIntervalSince(requested)) else { return nil }
        let focus = setupDefaults.string(forKey: "permissions.resumeAccessFocus").flatMap(AccessFocus.init(rawValue:)) ?? .library
        return focus != .library || librarySetupPending ? focus : nil
    }
    public var accessResumeIntent: AccessIntent? {
        guard let focus = accessResumeFocus else { return nil }
        return setupDefaults.string(forKey: "permissions.resumeAccessIntent").flatMap(AccessIntent.init(rawValue:))
            ?? (focus == .library ? .library : focus == .accessibility ? .companion : .capture)
    }
    private func clearAccessResume() {
        for key in [resumeAccessKey, "permissions.resumeAccessRequestedAt", "permissions.resumeAccessFocus", "permissions.resumeAccessIntent"] {
            setupDefaults.removeObject(forKey: key)
        }
    }
    func cancelReaderRecovery(intent: AccessIntent) {
        if accessResumeIntent == intent { clearAccessResume() }
    }
    public func consumeAccessResume() -> Bool {
        let resume = accessResumeFocus != nil
        clearAccessResume()
        return resume
    }
    /// Called after the importer commits a readable source, including an empty store.
    public func completeLibrarySetup(importedSources: Set<BookSource>, failures: [LibraryImportFailure] = [], generation: Int? = nil) {
        guard generation == nil || generation == setupGeneration, librarySetupPending, !importedSources.isEmpty else { return }
        guard !failures.contains(where: \.accessDenied) else { return }
        cancelLibrarySetup(clearResume: accessResumeFocus == nil || accessResumeFocus == .library)
    }

    public func relaunchFocus(for intent: AccessIntent?) -> AccessFocus? {
        switch intent {
        case .library: return nil
        case .companion: return companionReady ? nil : .accessibility
        case .capture: return !accessibility ? .accessibility : screenRecording ? nil : .screenRecording
        case nil:
            guard let focus = requestedReaderFocus else { return nil }
            return focus == .accessibility ? (accessibility ? nil : focus) : (screenRecording ? nil : focus)
        }
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
            let listing = await FullDiskAccessListingRequest.request()
            TsundokuDiagnostics.shared.event("library_listing_requested", ["outcome": listing.rawValue])
            let result = await Task.detached { FullDiskAccessRegistration.request() }.value
            TsundokuDiagnostics.shared.event("library_registration_attempted", [
                "attempted": result.attempted, "directory_reads": result.directoriesRead,
                "header_bytes_read": result.headerBytesRead, "permission_denials": result.permissionDenials,
                "missing_targets": result.missingTargets, "other_failures": result.otherFailures,
            ])
            // The privacy extension caches its list across pane navigation.
            // Cooperatively close Settings so the subsequent open loads the new
            // entry. Never force-quit it, operate its controls, or change a grant.
            if listing != .unavailable, !Task.isCancelled {
                for settings in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences") {
                    guard settings.terminate() else { continue }
                    for _ in 0..<40 where !settings.isTerminated && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
        },
        librarySettingsOpener: @escaping () -> Bool = {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") else { return false }
            return NSWorkspace.shared.open(url)
        },
        setupDefaults: UserDefaults = .standard,
        relaunchTimeout: Duration = .seconds(65),
        now: @escaping () -> Date = Date.init
    ) {
        self.accessibilityCheck = accessibilityCheck
        self.screenRecordingCheck = screenRecordingCheck
        self.screenAccessCheck = screenAccessCheck
        self.libraryAccessCheck = libraryAccessCheck
        self.librarySettingsOpener = librarySettingsOpener
        self.libraryRegistrationRequest = libraryRegistrationRequest
        self.setupDefaults = setupDefaults
        self.relaunchTimeout = relaunchTimeout
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

    public func cancelLibrarySetup(clearResume: Bool = true) {
        guard !applicationIsTerminating else { return }
        libraryRegistrationID = nil
        libraryRegistrationTask?.cancel()
        libraryRegistrationTask = nil
        libraryRegistrationInProgress = false
        setupGeneration += 1
        importedSetupSources.removeAll()
        setupDefaults.removeObject(forKey: librarySetupKey)
        setupDefaults.removeObject(forKey: librarySetupDateKey)
        if clearResume, accessResumeFocus == nil || accessResumeFocus == .library { clearAccessResume() }
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
        guard !applicationIsTerminating, generation == setupGeneration else { libraryChecking = false; return }
        libraryStatus = result.status
        readableLibrarySources = result.readableSources
        libraryFailures = result.failures
        libraryChecking = false
        guard generation == setupGeneration, pendingAtStart, librarySetupPending, !libraryRegistrationInProgress else { return }
        let newSources = Set(result.readableSources).subtracting(importedSetupSources)
        importedSetupSources.formUnion(newSources)
        if result.status == .notFound { cancelLibrarySetup(clearResume: accessResumeFocus == nil || accessResumeFocus == .library) }
        if !newSources.isEmpty { onLibraryAccessReady?() }
    }

    public func importReadableLibrary() {
        guard !readableLibrarySources.isEmpty, !libraryChecking else { return }
        onLibraryAccessReady?()
    }

    public func requestRelaunch(focus: AccessFocus = .library, intent: AccessIntent? = nil) {
        guard !relaunchPending, !applicationIsTerminating else { return }
        relaunchError = nil
        relaunchErrorFocus = focus
        let hadLibraryIntent = librarySetupPending
        let previousLibraryDate = setupDefaults.object(forKey: librarySetupDateKey)
        let requestGeneration = setupGeneration
        // Only an explicit restart arms future presentation.
        if focus == .library {
            setupDefaults.set(true, forKey: librarySetupKey)
            setupDefaults.set(now(), forKey: librarySetupDateKey)
        }
        setupDefaults.set(true, forKey: resumeAccessKey)
        setupDefaults.set(now(), forKey: "permissions.resumeAccessRequestedAt")
        setupDefaults.set(focus.rawValue, forKey: "permissions.resumeAccessFocus")
        setupDefaults.set((intent ?? (focus == .library ? .library : focus == .accessibility ? .companion : .capture)).rawValue,
            forKey: "permissions.resumeAccessIntent")
        func failedRelaunch() {
            clearAccessResume()
            if focus == .library && setupGeneration == requestGeneration {
                if hadLibraryIntent { setupDefaults.set(previousLibraryDate, forKey: librarySetupDateKey) }
                else { cancelLibrarySetup() }
            }
            onRelaunchFailed?()
        }
        func reportFailure(_ message: String) {
            relaunchError = message
            if focus == .library { librarySettingsError = message }
        }
        guard let onRelaunchRequested else {
            reportFailure("Quit Tsundoku, then reopen it from Applications.")
            return
        }
        relaunchPending = true
        do {
            try onRelaunchRequested()
            Task { [weak self] in
                try? await Task.sleep(for: self?.relaunchTimeout ?? .seconds(65))
                guard let self, !self.applicationIsTerminating else { return }
                self.relaunchPending = false
                failedRelaunch()
                reportFailure("Tsundoku did not quit. Close any open dialog, then try again.")
            }
        } catch {
            failedRelaunch()
            relaunchPending = false
            reportFailure("Could not reopen Tsundoku: \(error.localizedDescription). Quit and reopen it from Applications.")
        }
    }

    public func requestAccessibility() {
        readerAccessRequested = true
        requestedReaderFocus = .accessibility
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openAccessibilitySettings()
    }

    public func requestScreenRecording() {
        readerAccessRequested = true
        requestedReaderFocus = .screenRecording
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
