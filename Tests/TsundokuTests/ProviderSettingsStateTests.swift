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

    @Test func failedTestShowsTheProviderReasonWithoutTheKey() async {
        let state = ProviderSettingsState(loadKey: { "fixture-key-value-123" }, saveKey: { _ in 0 },
            connectionTest: { _ in
                throw AIProviderError.http(
                    400, #"{"error":"Model Not Exist","echo":"fixture-key-value-123"}"#)
            })
        state.loadKeyIfNeeded()
        state.test(settings: AISettings(provider: .http))
        for _ in 0..<100 where state.testing { await Task.yield() }
        #expect(state.testStatus.contains("400"))
        #expect(state.testStatus.contains("Model Not Exist"))
        #expect(state.testStatus.contains("<key>"))
        #expect(!state.testStatus.contains("fixture-key-value-123"))
    }

    @Test func failureDetailIsBoundedAndRedactsOnlyPlausibleKeys() {
        let long = String(repeating: "x", count: 400)
        #expect(ProviderSettingsState.detail(for: AIProviderError.failed(long), secrets: []).count == 300)
        #expect(ProviderSettingsState.detail(
            for: AIProviderError.http(401, "bad fixture-secret-abcdef"),
            secrets: ["fixture-secret-abcdef"]).contains("<key>"))
        #expect(ProviderSettingsState.detail(
            for: AIProviderError.http(401, "bad abc"), secrets: ["abc"])
            == "The endpoint answered 401: bad abc")
        #expect(ProviderSettingsState.detail(for: AIProviderError.invalidEndpoint, secrets: [])
            == "The endpoint is not a valid HTTPS or loopback HTTP URL.")
    }

}
