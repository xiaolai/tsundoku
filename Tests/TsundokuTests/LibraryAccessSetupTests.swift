import Foundation
import Testing
@testable import TsundokuCore
@testable import TsundokuUI

@MainActor
struct LibraryAccessSetupTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "tsundoku-library-setup-\(UUID().uuidString)")!
    }

    @Test func grantOpensSettingsWithoutRequiringCheckFirst() async {
        let store = defaults()
        var opened = 0
        var probes = 0
        var imports = 0
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { probes += 1; return LibraryAccessResult(readableSources: [.appleBooks], failures: []) },
            librarySettingsOpener: { opened += 1; return true }, setupDefaults: store)
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        #expect(opened == 1)
        #expect(probes == 0)
        #expect(model.librarySetupPending)
        model.resumeLibrarySetupIfNeeded()
        for _ in 0..<100 where imports == 0 { await Task.yield() }
        #expect(probes == 1)
        #expect(imports == 1)
        #expect(model.libraryStatus == .available)
        #expect(!model.librarySetupPending)
    }

    @Test func verificationHasNoImportSideEffect() async {
        var imports = 0
        let model = PermissionsModel(accessibilityCheck: { true }, screenRecordingCheck: { true },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [.kindle], failures: []) },
            librarySettingsOpener: { true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        await model.verifyLibraryAccess()
        await model.verifyLibraryAccess()
        #expect(imports == 0, "Checking access alone must not import")
        model.importReadableLibrary()
        #expect(imports == 1, "An explicit import action is available after checking")
        #expect(!model.setupIncomplete)
    }

    @Test func partialSetupImportsReadableSourcesOnceAndKeepsRecoveryPending() async {
        var imports = 0
        let denied = LibraryImportFailure(source: .kindle, error: SQLiteError(code: 23, message: "denied"))
        let model = PermissionsModel(accessibilityCheck: { true }, screenRecordingCheck: { true },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [.appleBooks], failures: [denied]) },
            librarySettingsOpener: { true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        await model.verifyLibraryAccess()
        await model.verifyLibraryAccess()
        #expect(model.libraryStatus == .blocked)
        #expect(model.librarySetupPending)
        #expect(imports == 1)
        #expect(model.readableLibrarySources == [.appleBooks])
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

    @Test func onlyTheCurrentGuideCanCancelSetup() {
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            librarySettingsOpener: { true }, setupDefaults: defaults())
        let first = UUID(), second = UUID()
        model.requestLibraryAccess()
        model.claimLibraryGuide(first)
        model.claimLibraryGuide(second)
        model.dismissLibraryGuide(first)
        #expect(model.librarySetupPending)
        #expect(model.activeLibraryGuideID == second)
        model.dismissLibraryGuide(second)
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
        #expect(failed.librarySetupPending)
    }

    @Test func cancelledOldRequestCannotCompleteNewRequest() async throws {
        var continuation: CheckedContinuation<LibraryAccessResult, Never>?
        var imports = 0
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { await withCheckedContinuation { continuation = $0 } },
            librarySettingsOpener: { true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        let task = Task { await model.verifyLibraryAccess() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        model.cancelLibrarySetup()
        model.requestLibraryAccess()
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
            librarySettingsOpener: { true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        await model.verifyLibraryAccess()
        #expect(model.libraryStatus == .blocked)
        #expect(model.setupIncomplete)
        #expect(model.librarySetupPending)
        #expect(imports == 0)
        model.cancelLibrarySetup()
    }

    @Test func pendingSetupSurvivesRelaunchAndCanBeDeferred() async {
        let store = defaults()
        let first = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            librarySettingsOpener: { true }, setupDefaults: store)
        first.requestLibraryAccess()
        let resumed = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [.kindle], failures: []) },
            librarySettingsOpener: { true }, setupDefaults: store)
        #expect(resumed.librarySetupPending)
        resumed.cancelLibrarySetup()
        #expect(!first.librarySetupPending)
    }

    @Test func noLibraryAndSettingsFailureAreExplained() async {
        let model = PermissionsModel(accessibilityCheck: { true }, screenRecordingCheck: { true },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [], failures: []) },
            librarySettingsOpener: { false }, setupDefaults: defaults())
        model.requestLibraryAccess()
        #expect(model.librarySettingsError?.contains("Privacy & Security") == true)
        await model.verifyLibraryAccess()
        #expect(model.libraryStatus == .notFound)
        #expect(!model.librarySetupPending)
        #expect(!model.setupIncomplete)
    }
    @Test func quitAndReopenResumesVerificationAndImport() async {
        let store = defaults()
        let first = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            librarySettingsOpener: { true }, setupDefaults: store)
        first.requestLibraryAccess()
        first.prepareForTermination()
        first.cancelLibrarySetup() // Sheet teardown during quit must preserve the pending intent.
        #expect(first.librarySetupPending)
        var imports = 0
        let resumed = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [.kindle], failures: []) },
            librarySettingsOpener: { true }, setupDefaults: store)
        resumed.onLibraryAccessReady = { imports += 1 }
        resumed.resumeLibrarySetupIfNeeded()
        for _ in 0..<100 where imports == 0 { await Task.yield() }
        #expect(imports == 1)
        #expect(!resumed.librarySetupPending)
    }

    @Test func deferringDuringVerificationDoesNotStartImport() async throws {
        var continuation: CheckedContinuation<LibraryAccessResult, Never>?
        var imports = 0
        let model = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { await withCheckedContinuation { continuation = $0 } },
            librarySettingsOpener: { true }, setupDefaults: defaults())
        model.onLibraryAccessReady = { imports += 1 }
        model.requestLibraryAccess()
        let task = Task { await model.verifyLibraryAccess() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        model.cancelLibrarySetup()
        pending.resume(returning: LibraryAccessResult(readableSources: [.kindle], failures: []))
        await task.value
        #expect(imports == 0)
        #expect(!model.librarySetupPending)
    }

}
