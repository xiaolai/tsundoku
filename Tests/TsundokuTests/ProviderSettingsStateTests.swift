import Foundation
import Testing
@testable import TsundokuUI
@testable import TsundokuCore

@MainActor
struct ProviderSettingsStateTests {
    @Test func keyLoadsLazilyAndDraftSurvivesNavigation() {
        var reads = 0
        let state = ProviderSettingsState(loadKey: { reads += 1; return "fixture-original" }, saveKey: { _ in 0 })
        #expect(reads == 0)
        state.loadKeyIfNeeded()
        state.draftKey = "fixture-draft"
        state.loadKeyIfNeeded()
        #expect(reads == 1)
        #expect(state.draftKey == "fixture-draft")
        #expect(state.hasUnsavedKey)
    }

    @Test func failedSaveRetainsDraftAndRetryCanSucceed() {
        var fail = true
        let state = ProviderSettingsState(loadKey: { "fixture-original" }, saveKey: { _ in fail ? -1 : 0 })
        state.loadKeyIfNeeded()
        state.draftKey = "fixture-replacement"
        state.saveKey()
        #expect(state.hasUnsavedKey)
        #expect(state.keyStatus.contains("Could not save"))
        fail = false
        state.saveKey()
        #expect(!state.hasUnsavedKey)
        #expect(state.keyStatus == "Saved")
    }

    @Test func invalidatedProviderTestCannotOverwriteNewStatus() async throws {
        var continuation: CheckedContinuation<String, any Error>?
        let state = ProviderSettingsState(loadKey: { "" }, saveKey: { _ in 0 },
            connectionTest: { _ in try await withCheckedThrowingContinuation { continuation = $0 } })
        state.test(settings: AISettings())
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        state.invalidateTest()
        pending.resume(returning: "Stale success")
        for _ in 0..<20 { await Task.yield() }
        #expect(!state.testing)
        #expect(state.testStatus.isEmpty)
    }
    @Test func committingAnUnchangedKeyDoesNotClearFeedback() async {
        let state = ProviderSettingsState(loadKey: { "fixture-original" }, saveKey: { _ in 0 },
            connectionTest: { _ in "Connected · Fixture" })
        state.loadKeyIfNeeded()
        state.draftKey = "fixture-new"
        state.saveKey()
        state.test(settings: AISettings(provider: .http))
        for _ in 0..<100 where state.testing { await Task.yield() }
        let unchanged = state.draftKey
        state.draftKey = unchanged
        #expect(state.keyStatus == "Saved")
        #expect(state.testStatus == "Connected · Fixture")
    }

}
