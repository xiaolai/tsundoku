import Foundation
import Testing
@testable import TsundokuCore
@testable import TsundokuUI

/// The access-check closure is main-actor isolated and Sendable, so a flag it
/// reads cannot be a local variable mutated after capture. Both the closure and
/// the test run on the main actor, which this box makes explicit.
@MainActor
private final class AccessState {
    var granted = false
}

@MainActor
struct LibraryAccessSetupTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "tsundoku-library-setup-\(UUID().uuidString)")!
    }

    private func waitForRegistration(_ model: PermissionsModel) async {
        for _ in 0..<100 where model.libraryRegistrationInProgress { await Task.yield() }
        #expect(!model.libraryRegistrationInProgress)
    }

    @Test func registrationPrecedesSettingsAndDoesNotGrantOrImport() async throws {
        var events: [String] = []
        var continuation: CheckedContinuation<Void, Never>?
        var imports = 0
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: {
                events.append("registration")
                await withCheckedContinuation { continuation = $0 }
            }, librarySettingsOpener: { events.append("settings"); return true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        model.requestLibraryAccess()
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        #expect(events == ["registration"])
        #expect(model.libraryRegistrationInProgress)
        let pending = try #require(continuation)
        pending.resume()
        for _ in 0..<100 where model.libraryRegistrationInProgress { await Task.yield() }
        #expect(events == ["registration", "settings"])
        #expect(model.libraryStatus == .notChecked)
        #expect(model.librarySetupPending)
        #expect(imports == 0)
    }

    @Test func cancellingRegistrationDoesNotOpenSettingsAfterward() async throws {
        var opened = 0
        var continuation: CheckedContinuation<Void, Never>?
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: { await withCheckedContinuation { continuation = $0 } },
            librarySettingsOpener: { opened += 1; return true }, setupDefaults: defaults())
        model.requestLibraryAccess()
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        model.cancelLibrarySetup()
        pending.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(opened == 0)
        #expect(!model.librarySetupPending)
        #expect(!model.libraryRegistrationInProgress)
    }

    @Test func oldRegistrationCannotFinishNewRequest() async throws {
        var continuations: [CheckedContinuation<Void, Never>] = []
        var opened = 0
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: { await withCheckedContinuation { continuations.append($0) } },
            librarySettingsOpener: { opened += 1; return true }, setupDefaults: defaults())
        model.requestLibraryAccess()
        for _ in 0..<100 where continuations.count < 1 { await Task.yield() }
        #expect(continuations.count == 1)
        model.cancelLibrarySetup()
        model.requestLibraryAccess()
        for _ in 0..<100 where continuations.count < 2 { await Task.yield() }
        #expect(continuations.count == 2)
        guard continuations.count == 2 else { continuations.forEach { $0.resume() }; return }
        continuations[0].resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(opened == 0)
        #expect(model.libraryRegistrationInProgress)
        continuations[1].resume()
        await waitForRegistration(model)
        #expect(opened == 1)
    }

    @Test func terminatingDuringRegistrationPreservesIntentWithoutOpeningSettings() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        var opened = 0
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: { await withCheckedContinuation { continuation = $0 } },
            librarySettingsOpener: { opened += 1; return true }, setupDefaults: defaults())
        model.requestLibraryAccess()
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        model.prepareForTermination()
        pending.resume()
        await waitForRegistration(model)
        #expect(opened == 0)
        #expect(model.librarySetupPending)
    }

    @Test func grantOpensSettingsWithoutRequiringCheckFirst() async {
        let store = defaults()
        var opened = 0
        var probes = 0
        var imports = 0
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { probes += 1; return LibraryAccessResult(readableSources: [.appleBooks], failures: []) },
            libraryRegistrationRequest: {}, librarySettingsOpener: { opened += 1; return true }, setupDefaults: store)
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        await waitForRegistration(model)
        #expect(opened == 1)
        #expect(probes == 0)
        #expect(model.librarySetupPending)
        model.resumeLibrarySetupIfNeeded()
        for _ in 0..<100 where imports == 0 { await Task.yield() }
        #expect(probes == 1)
        #expect(imports == 1)
        #expect(model.libraryStatus == .available)
        #expect(model.librarySetupPending, "A read probe alone does not commit the import")
        model.completeLibrarySetup(importedSources: [.appleBooks])
        #expect(!model.librarySetupPending)
    }

    @Test func verificationHasNoImportSideEffect() async {
        var imports = 0
        let model = PermissionsModel(accessibilityCheck: { true }, screenRecordingCheck: { true },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [.kindle], failures: []) },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        await model.verifyLibraryAccess()
        await model.verifyLibraryAccess()
        #expect(imports == 0, "Checking access alone must not import")
        model.importReadableLibrary()
        #expect(imports == 1, "An explicit import action is available after checking")
        #expect(model.libraryReady)
    }

    @Test func partialSetupFinishesOnlyAfterAReadableSourceIsImported() async {
        var imports = 0
        let denied = LibraryImportFailure(source: .kindle, error: SQLiteError(code: 23, message: "denied"))
        let model = PermissionsModel(accessibilityCheck: { true }, screenRecordingCheck: { true },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [.appleBooks], failures: [denied]) },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        await waitForRegistration(model)
        await model.verifyLibraryAccess()
        await model.verifyLibraryAccess()
        #expect(model.libraryStatus == .blocked)
        #expect(model.librarySetupPending)
        #expect(imports == 1)
        #expect(model.readableLibrarySources == [.appleBooks])
        model.completeLibrarySetup(importedSources: [.appleBooks], failures: [denied])
        #expect(model.librarySetupPending, "Continue waiting while the person is still granting access")
        #expect(!model.consumeAccessResume(), "Partial access does not arm a setup window on normal launch")
        model.cancelLibrarySetup() // Only an explicit Cancel stops waiting for the blocked source.
        #expect(!model.librarySetupPending)
        #expect(model.libraryStatus == .blocked, "The other source's warning remains visible")
    }

    @Test func pendingSetupExpiresButLegacyIntentIsMigrated() {
        let store = defaults()
        store.set(true, forKey: "permissions.librarySetupPending")
        var now = Date(timeIntervalSince1970: 1_000_000)
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            setupDefaults: store, now: { now })
        #expect(model.librarySetupPending)
        now = now.addingTimeInterval(24 * 3600 + 1)
        #expect(!model.librarySetupPending)
    }

    @Test func closingOrSwitchingSettingsDoesNotCancelSetup() async {
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: defaults())
        let navigation = SettingsNavigation(defaults: defaults())
        navigation.onCancelSetup = { _ in model.cancelLibrarySetup() }
        model.requestLibraryAccess()
        await waitForRegistration(model)
        navigation.open(SettingsRoute(pane: .access, intent: .library), wasVisible: false)
        navigation.select(.ai)
        navigation.windowClosed()
        #expect(model.librarySetupPending)
        navigation.cancelIntent()
        #expect(!model.librarySetupPending)
    }

    @Test func relaunchRequestsAreSingleFlightAndFailuresAreRecoverable() {
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false }, setupDefaults: defaults())
        var calls = 0
        model.onRelaunchRequested = { calls += 1 }
        model.requestRelaunch()
        model.requestRelaunch()
        #expect(calls == 1)
        #expect(model.relaunchPending && model.librarySetupPending)
        let failed = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false }, setupDefaults: defaults())
        failed.onRelaunchRequested = { throw CocoaError(.fileNoSuchFile) }
        failed.requestRelaunch()
        #expect(!failed.relaunchPending)
        #expect(failed.librarySettingsError?.contains("Could not reopen") == true)
        #expect(!failed.librarySetupPending)
        #expect(!failed.consumeAccessResume())
    }

    @Test func cancelledOldRequestCannotCompleteNewRequest() async throws {
        var continuation: CheckedContinuation<LibraryAccessResult, Never>?
        var imports = 0
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { await withCheckedContinuation { continuation = $0 } },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        await waitForRegistration(model)
        let task = Task { await model.verifyLibraryAccess() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        model.cancelLibrarySetup()
        model.requestLibraryAccess()
        await waitForRegistration(model)
        pending.resume(returning: LibraryAccessResult(readableSources: [.kindle], failures: []))
        await task.value
        #expect(imports == 0)
        #expect(model.librarySetupPending)
    }

    @Test func deniedAccessDoesNotDeclareSetupCompleteOrImport() async {
        var imports = 0
        let denied = LibraryImportFailure(source: .kindle, error: SQLiteError(code: 23, message: "authorization denied"))
        let model = PermissionsModel(accessibilityCheck: { true }, screenRecordingCheck: { true },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [], failures: [denied]) },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        await waitForRegistration(model)
        await model.verifyLibraryAccess()
        #expect(model.libraryStatus == .blocked)
        #expect(!model.libraryReady)
        #expect(model.librarySetupPending)
        #expect(imports == 0)
        model.cancelLibrarySetup()
    }

    @Test func pendingSetupSurvivesRelaunchAndCanBeDeferred() async {
        let store = defaults()
        let first = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: store)
        first.requestLibraryAccess()
        await waitForRegistration(first)
        let resumed = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [.kindle], failures: []) },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: store)
        #expect(resumed.librarySetupPending)
        resumed.cancelLibrarySetup()
        #expect(!first.librarySetupPending)
    }

    @Test func noLibraryAndSettingsFailureAreExplained() async {
        let model = PermissionsModel(accessibilityCheck: { true }, screenRecordingCheck: { true },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [], failures: []) },
            libraryRegistrationRequest: {}, librarySettingsOpener: { false }, setupDefaults: defaults())
        model.requestLibraryAccess()
        await waitForRegistration(model)
        #expect(model.librarySettingsError?.contains("Privacy & Security") == true)
        await model.verifyLibraryAccess()
        #expect(model.libraryStatus == .notFound)
        #expect(!model.librarySetupPending)
        #expect(!model.libraryReady)
        #expect(model.libraryInstruction == nil)
    }
    @Test func quitAndReopenResumesVerificationAndImport() async {
        let store = defaults()
        let first = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: store)
        first.requestLibraryAccess()
        await waitForRegistration(first)
        first.prepareForTermination()
        first.cancelLibrarySetup() // Sheet teardown during quit must preserve the pending intent.
        #expect(first.librarySetupPending)
        var imports = 0
        let resumed = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [.kindle], failures: []) },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: store)
        resumed.onLibraryAccessReady = { imports += 1 }
        resumed.resumeLibrarySetupIfNeeded()
        for _ in 0..<100 where imports == 0 { await Task.yield() }
        #expect(imports == 1)
        resumed.completeLibrarySetup(importedSources: [.kindle])
        #expect(!resumed.librarySetupPending)
    }

    @Test func deferringDuringVerificationDoesNotStartImport() async throws {
        var continuation: CheckedContinuation<LibraryAccessResult, Never>?
        var imports = 0
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { await withCheckedContinuation { continuation = $0 } },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        await waitForRegistration(model)
        let task = Task { await model.verifyLibraryAccess() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        model.cancelLibrarySetup()
        pending.resume(returning: LibraryAccessResult(readableSources: [.kindle], failures: []))
        await task.value
        #expect(imports == 0)
        #expect(!model.librarySetupPending)
    }

    @Test func partialImportKeepsWaitingForTheSourceBeingGranted() async {
        let access = AccessState()
        var imports = 0
        let denied = LibraryImportFailure(source: .kindle, error: SQLiteError(code: 23, message: "denied"))
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { LibraryAccessResult(readableSources: access.granted ? [.appleBooks, .kindle] : [.appleBooks], failures: access.granted ? [] : [denied]) },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        await waitForRegistration(model)
        await model.verifyLibraryAccess()
        model.completeLibrarySetup(importedSources: [.appleBooks], failures: [denied])
        #expect(model.librarySetupPending)
        #expect(!model.consumeAccessResume())
        await model.verifyLibraryAccess()
        #expect(imports == 1, "Already imported sources are not repeated on activation")
        access.granted = true
        await model.verifyLibraryAccess()
        #expect(imports == 2, "Late approval imports the newly readable source")
        model.completeLibrarySetup(importedSources: [.appleBooks, .kindle])
        #expect(!model.librarySetupPending)
    }

}
