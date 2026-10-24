import Foundation
import ScreenCaptureKit
import Testing
@testable import TsundokuUI

@MainActor
struct PermissionsTests {
    @Test func refreshReadsBothProbesAgain() {
        var ax = false
        var screen = false
        var axCalls = 0
        var screenCalls = 0
        let model = PermissionsModel(
            accessibilityCheck: { axCalls += 1; return ax },
            screenRecordingCheck: { screenCalls += 1; return screen })
        #expect(model.missing)
        #expect(model.lastChecked == nil)
        ax = true
        model.refresh()
        #expect(model.accessibility)
        #expect(!model.screenRecording)
        #expect(model.missing)
        #expect(model.lastChecked != nil)
        screen = true
        model.refresh()
        #expect(!model.missing)
        #expect(axCalls == 3)
        #expect(screenCalls == 3)
        ax = false
        model.refresh()
        #expect(model.missing)
        #expect(!model.accessibility)
    }

    @Test func unchangedDenialStillRecordsCheck() {
        let model = PermissionsModel(
            accessibilityCheck: { false }, screenRecordingCheck: { false })
        model.refresh()
        #expect(model.lastChecked != nil)
        #expect(model.checkResult?.contains("not verified") == true)
    }
    @Test func verificationUsesFrameworkEvenWhenPreflightIsFalse() async {
        var probes = 0
        let model = PermissionsModel(accessibilityCheck: { true },
            screenRecordingCheck: { false }, screenAccessCheck: { probes += 1 })
        #expect(model.snapshot.screenStatus == "Not verified")
        model.refresh()
        #expect(probes == 0, "Quiet refresh must never open a consent prompt")
        await model.verifyAccess()
        #expect(probes == 1)
        #expect(model.screenRecording)
        #expect(model.snapshot.screenStatus == "Verified")
        model.refresh()
        #expect(model.screenRecording, "A capture preflight false must not overwrite a real framework success")
        model.refresh(invalidateVerification: true)
        #expect(model.snapshot.screenStatus == "Not verified")
    }

    @Test func frameworkDenialIsDifferentFromFrameworkFailure() async {
        let denied = PermissionsModel(accessibilityCheck: { true },
            screenRecordingCheck: { false }, screenAccessCheck: {
                throw NSError(domain: SCStreamError.errorDomain,
                    code: SCStreamError.Code.userDeclined.rawValue)
            })
        await denied.verifyAccess()
        #expect(denied.snapshot.screenStatus == "Unavailable")
        #expect(!denied.screenRecording)
        let failed = PermissionsModel(accessibilityCheck: { true },
            screenRecordingCheck: { true }, screenAccessCheck: {
                throw NSError(domain: SCStreamError.errorDomain,
                    code: SCStreamError.Code.failedApplicationConnectionInterrupted.rawValue)
            })
        await failed.verifyAccess()
        #expect(failed.snapshot.screenStatus == "Check failed")
        #expect(failed.screenRecording, "A framework failure is not proof of permission denial")
    }

    @Test func cancellationDoesNotClaimDenial() async {
        let model = PermissionsModel(accessibilityCheck: { true },
            screenRecordingCheck: { false }, screenAccessCheck: { throw CancellationError() })
        await model.verifyAccess()
        #expect(model.snapshot.screenStatus == "Not verified")
        #expect(!model.isChecking)
    }

    @Test func quietActivationPreservesVerifiedCaptureGate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(archiveURL: directory.appendingPathComponent("archive.sqlite"), recoverReaderSettings: false)
        let permissions = PermissionsModel(accessibilityCheck: { true }, screenRecordingCheck: { false }, screenAccessCheck: {})
        app.permissions = permissions
        await permissions.verifyAccess()
        permissions.applicationBecameActive()
        app.refreshPermissions()
        #expect(!app.permissionsNeeded, "Activation and the capture gate must preserve real framework success")
        #expect(app.permissionScreenStatus == "Verified")
    }

    @Test func appModelReceivesOneImmediateSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(archiveURL: directory.appendingPathComponent("archive.sqlite"), recoverReaderSettings: false)
        var ax = false
        var screen = false
        let permissions = PermissionsModel(accessibilityCheck: { ax }, screenRecordingCheck: { screen },
            screenAccessCheck: { #expect(app.permissionChecking) })
        app.permissions = permissions
        ax = true
        screen = true
        permissions.refresh()
        #expect(app.permissionAccessibility && app.permissionScreen)
        #expect(app.permissionCheckResult == permissions.checkResult)
        await app.verifyPermissions()
        #expect(app.permissionScreenStatus == "Verified")
        #expect(!app.permissionChecking)
        ax = false
        screen = false
        permissions.refresh(invalidateVerification: true)
        #expect(!app.permissionAccessibility && !app.permissionScreen)
        #expect(app.permissionScreenStatus == "Not verified")
        #expect(app.permissionCheckResult == permissions.checkResult)
    }

    @Test func overlappingVerificationDoesNotDuplicateRequests() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        let model = PermissionsModel(accessibilityCheck: { true }, screenRecordingCheck: { false },
            screenAccessCheck: {
                calls += 1
                await withCheckedContinuation { continuation = $0 }
            })
        let task = Task { await model.verifyAccess() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        #expect(model.isChecking)
        await model.verifyAccess()
        #expect(calls == 1)
        pending.resume()
        await task.value
        #expect(!model.isChecking)
        #expect(model.screenRecording)
    }

}
