import Foundation
import Testing
@testable import TsundokuUI
@testable import TsundokuCore

@MainActor
struct SettingsNavigationTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "settings-navigation-\(UUID())")! }

    @Test func ordinarySelectionSurvivesRecoveryAndClose() {
        let store = defaults()
        let navigation = SettingsNavigation(defaults: store)
        navigation.select(.ai)
        navigation.open(SettingsRoute(pane: .access, focus: .library, intent: .library), wasVisible: false)
        #expect(navigation.selectedPane == .access)
        #expect(navigation.intent == .library)
        navigation.windowClosed()
        #expect(navigation.intent == .library)
        navigation.open(nil, wasVisible: false)
        #expect(navigation.selectedPane == .ai)
        #expect(SettingsNavigation(defaults: store).selectedPane == .ai)
    }

    @Test func manualPaneSwitchDoesNotCancelIntent() {
        let navigation = SettingsNavigation(defaults: defaults())
        navigation.open(SettingsRoute(pane: .access, focus: .screenRecording, intent: .capture), wasVisible: true)
        navigation.select(.companion)
        #expect(navigation.intent == .capture)
        #expect(!navigation.closeOnReturn)
        navigation.cancelIntent()
        #expect(navigation.intent == nil)
    }

    @Test func staleReturnCannotConsumeNewIntent() {
        let navigation = SettingsNavigation(defaults: defaults())
        navigation.open(SettingsRoute(pane: .access, intent: .library), wasVisible: false)
        let old = navigation.intentID
        navigation.open(SettingsRoute(pane: .access, intent: .capture), wasVisible: true)
        #expect(!navigation.finishIntent(id: old))
        #expect(navigation.intent == .capture)
    }

    @Test func invalidSavedPaneFallsBack() {
        let store = defaults()
        store.set("removed", forKey: "settings.lastPane")
        // A first opening starts on Access, where setup failures are fixed.
        #expect(SettingsNavigation(defaults: store).selectedPane == .access)
    }

    @Test func readinessIsPerFeatureAndLibraryCheckDoesNotVerifyScreen() async {
        var screenChecks = 0
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            screenAccessCheck: { screenChecks += 1 },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [.appleBooks], failures: []) },
            setupDefaults: defaults())
        await permissions.verifyLibraryAccess()
        #expect(permissions.libraryReady)
        #expect(!permissions.companionReady && !permissions.captureReady)
        #expect(screenChecks == 0)
        #expect(permissions.libraryInstruction == nil)
    }

    @Test func manageDoesNotRegisterOrStartImportIntent() {
        var opens = 0
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: { Issue.record("Manage must not request authorization") },
            librarySettingsOpener: { opens += 1; return true }, setupDefaults: defaults())
        permissions.openLibrarySettings()
        #expect(opens == 1)
        #expect(!permissions.librarySetupPending)
    }

    @Test func explicitRelaunchArmsOnlyOneResume() {
        let store = defaults()
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false }, setupDefaults: store)
        permissions.onRelaunchRequested = {}
        permissions.requestRelaunch()
        #expect(permissions.consumeAccessResume())
        #expect(!permissions.consumeAccessResume())
    }

    @Test func ordinaryPendingIntentDoesNotArmResume() async {
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: defaults())
        permissions.requestLibraryAccess()
        for _ in 0..<100 where permissions.libraryRegistrationInProgress { await Task.yield() }
        #expect(permissions.librarySetupPending)
        #expect(!permissions.consumeAccessResume())
    }
    @Test func onlyExplicitTaskReturnClosesARecoveryWindow() {
        let navigation = SettingsNavigation(defaults: defaults())
        var returned: [(AccessIntent, Bool)] = []
        navigation.onReturnToTask = { returned.append(($0, $1)) }
        navigation.open(SettingsRoute(pane: .access, intent: .capture), wasVisible: false)
        navigation.windowClosed()
        #expect(returned.isEmpty)
        navigation.returnToTask()
        navigation.returnToTask()
        #expect(returned.count == 1 && returned[0].0 == .capture && returned[0].1)
    }

    @Test func firstUseHasAUsefulWindowAndRelaunchFlagsCannotOverrideRecovery() {
        #expect(SettingsLaunchPolicy.shouldPresentLibrary(firstUse: true, arguments: []))
        #expect(!SettingsLaunchPolicy.shouldPresentLibrary(firstUse: false, arguments: []))
        #expect(!SettingsLaunchPolicy.shouldPresentLibrary(firstUse: true, arguments: [], isLoginLaunch: true))
        #expect(!SettingsLaunchPolicy.shouldPresentLibrary(firstUse: true, arguments: ["--shell-only"]))
        #expect(!SettingsLaunchPolicy.shouldPresentLibrary(firstUse: true, arguments: ["--section", "settings"]))
        #expect(SettingsLaunchPolicy.relaunchArguments(["--open-settings", "--settings-pane", "AI Provider", "--archive-path", "fixture", "--section", "exports"]) == ["--archive-path", "fixture"])
    }

    @Test func readerRelaunchDoesNotCreateALibraryImportIntent() {
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false }, setupDefaults: defaults())
        permissions.onRelaunchRequested = {}
        permissions.requestRelaunch(focus: .screenRecording)
        #expect(!permissions.librarySetupPending)
        #expect(permissions.accessResumeFocus == .screenRecording)
        #expect(permissions.consumeAccessResume())
        #expect(!permissions.consumeAccessResume())
    }

    @Test func companionReadinessDoesNotSuggestAScreenPermissionRestart() {
        let permissions = PermissionsModel(accessibilityCheck: { true }, screenRecordingCheck: { false }, setupDefaults: defaults())
        #expect(permissions.relaunchFocus(for: .companion) == nil)
        #expect(permissions.relaunchFocus(for: .capture) == .screenRecording)
        #expect(permissions.relaunchFocus(for: .library) == nil)
    }

    @Test func captureWithMissingAccessibilityResumesAsCapture() {
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false }, setupDefaults: defaults())
        permissions.onRelaunchRequested = {}
        permissions.requestRelaunch(focus: .accessibility, intent: .capture)
        #expect(permissions.accessResumeFocus == .accessibility)
        #expect(permissions.accessResumeIntent == .capture)
    }

    @Test func failedOrTimedOutRelaunchDoesNotArmALaterLaunch() async throws {
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            setupDefaults: defaults(), relaunchTimeout: .milliseconds(5))
        permissions.onRelaunchRequested = {}
        permissions.requestRelaunch()
        for _ in 0..<100 where permissions.relaunchPending { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!permissions.relaunchPending)
        #expect(!permissions.consumeAccessResume())
        #expect(!permissions.librarySetupPending)
    }

    @Test func failedRelaunchPreservesAnAlreadyRequestedImport() async {
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: defaults())
        permissions.requestLibraryAccess()
        for _ in 0..<100 where permissions.libraryRegistrationInProgress { await Task.yield() }
        permissions.onRelaunchRequested = { throw CocoaError(.fileNoSuchFile) }
        permissions.requestRelaunch()
        #expect(permissions.librarySetupPending)
        #expect(!permissions.consumeAccessResume())
    }

    @Test func cancellingLibraryWorkPreservesIndependentReaderRecovery() async {
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: defaults())
        permissions.requestLibraryAccess()
        for _ in 0..<100 where permissions.libraryRegistrationInProgress { await Task.yield() }
        permissions.onRelaunchRequested = {}
        permissions.requestRelaunch(focus: .screenRecording, intent: .capture)
        permissions.cancelLibrarySetup()
        #expect(permissions.accessResumeIntent == .capture)
        permissions.cancelReaderRecovery(intent: .companion)
        #expect(permissions.accessResumeIntent == .capture)
        permissions.cancelReaderRecovery(intent: .capture)
        #expect(!permissions.consumeAccessResume())
    }

}
