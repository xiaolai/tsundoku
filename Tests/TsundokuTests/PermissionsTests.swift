import Foundation
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
        #expect(model.checkResult?.contains("not granted") == true)
    }
}
