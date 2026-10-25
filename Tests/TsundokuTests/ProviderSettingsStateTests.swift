import Foundation
import SaySoAI
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
struct ProviderSettingsStateTests {
    @Test func keyLoadsLazilyAndDraftSurvivesNavigation() {
        var reads = 0
        let state = ProviderSettingsState(loadKey: { _ in reads += 1; return "fixture-original" }, saveKey: { _, _ in 0 })
        #expect(reads == 0)
        state.loadKeyIfNeeded(profileID: "custom")
        state.draftKey = "fixture-draft"
        state.loadKeyIfNeeded(profileID: "custom")
        #expect(reads == 1)
        #expect(state.draftKey == "fixture-draft")
        #expect(state.hasUnsavedKey)
    }

    @Test func switchingServiceLoadsThatServicesKey() {
        let keys = ["custom": "fixture-custom", "deepseek": "fixture-deepseek"]
        var loaded: [String] = []
        let state = ProviderSettingsState(loadKey: { id in
            loaded.append(id); return keys[id] ?? ""
        }, saveKey: { _, _ in 0 })
        state.loadKeyIfNeeded(profileID: "custom")
        #expect(state.draftKey == "fixture-custom")
        state.loadKeyIfNeeded(profileID: "deepseek")
        #expect(state.draftKey == "fixture-deepseek")
        #expect(loaded == ["custom", "deepseek"])
    }

    @Test func savingWritesTheKeyToTheCurrentService() {
        var written: [(String, String)] = []
        let state = ProviderSettingsState(loadKey: { _ in "" },
            saveKey: { value, id in written.append((value, id)); return 0 })
        state.loadKeyIfNeeded(profileID: "openai")
        state.draftKey = "fixture-new"
        state.saveKey(profileID: "openai")
        #expect(written.count == 1)
        #expect(written.first?.0 == "fixture-new")
        #expect(written.first?.1 == "openai")
        #expect(state.keyStatus == "Saved")
    }

    @Test func failedSaveRetainsDraftAndRetryCanSucceed() {
        var fail = true
        let state = ProviderSettingsState(loadKey: { _ in "fixture-original" }, saveKey: { _, _ in fail ? -1 : 0 })
        state.loadKeyIfNeeded(profileID: "custom")
        state.draftKey = "fixture-replacement"
        state.saveKey(profileID: "custom")
        #expect(state.hasUnsavedKey)
        #expect(state.keyStatus.contains("Could not save"))
        fail = false
        state.saveKey(profileID: "custom")
        #expect(!state.hasUnsavedKey)
        #expect(state.keyStatus == "Saved")
    }

    @Test func invalidatedProviderTestCannotOverwriteNewStatus() async throws {
        var continuation: CheckedContinuation<String, any Error>?
        let state = ProviderSettingsState(loadKey: { _ in "" }, saveKey: { _, _ in 0 },
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
        let state = ProviderSettingsState(loadKey: { _ in "fixture-original" }, saveKey: { _, _ in 0 },
            connectionTest: { _ in "Connected · Fixture" })
        state.loadKeyIfNeeded(profileID: "custom")
        state.draftKey = "fixture-new"
        state.saveKey(profileID: "custom")
        state.test(settings: AISettings(provider: .http))
        for _ in 0..<100 where state.testing { await Task.yield() }
        let unchanged = state.draftKey
        state.draftKey = unchanged
        #expect(state.keyStatus == "Saved")
        #expect(state.testStatus == "Connected · Fixture")
    }

    @Test func failedTestShowsTheProviderReasonWithoutTheKey() async {
        let state = ProviderSettingsState(loadKey: { _ in "fixture-key-value-123" }, saveKey: { _, _ in 0 },
            connectionTest: { _ in
                throw AIProviderError.server(
                    status: 400,
                    message: #"Model Not Exist, echo fixture-key-value-123"#)
            })
        state.loadKeyIfNeeded(profileID: "custom")
        state.test(settings: AISettings(provider: .http))
        for _ in 0..<100 where state.testing { await Task.yield() }
        #expect(state.testStatus.contains("400"))
        #expect(state.testStatus.contains("Model Not Exist"))
        #expect(state.testStatus.contains("<key>"))
        #expect(!state.testStatus.contains("fixture-key-value-123"))
    }

    @Test func failureDetailIsBoundedAndRedactsOnlyPlausibleKeys() {
        let long = String(repeating: "x", count: 400)
        #expect(ProviderSettingsState.detail(
            for: AIProviderError.framework(long), provider: .http, secrets: []).count == 300)
        #expect(ProviderSettingsState.detail(
            for: AIProviderError.server(status: 401, message: "bad fixture-secret-abcdef"),
            provider: .http, secrets: ["fixture-secret-abcdef"]).contains("<key>"))
        #expect(ProviderSettingsState.detail(
            for: AIProviderError.server(status: 401, message: "bad abc"),
            provider: .http, secrets: ["abc"])
            == "The endpoint answered 401: bad abc")
        #expect(ProviderSettingsState.detail(
            for: AIProviderError.insecureEndpoint, provider: .http, secrets: [])
            == AIProviderFailure.message(for: AIProviderError.insecureEndpoint, provider: .http))
    }

    @Test func modelFetchFailureIsWorded() async {
        let state = ProviderSettingsState(loadKey: { _ in "" }, saveKey: { _, _ in 0 },
            modelFetch: { _, _, _ in throw ModelCatalogError.unauthorised })
        state.loadKeyIfNeeded(profileID: "deepseek")
        state.loadModels(settings: AISettings(provider: .http, model: "deepseek-flash", httpProfileID: "deepseek"))
        for _ in 0..<100 where state.loadingModels { await Task.yield() }
        #expect(state.modelStatus == "The service refused the key.")
    }
}

@MainActor
struct AIProviderAdoptionTests {
    @Test func settingsWithoutAProfileDecodeAsCustom() throws {
        let json = #"{"provider":"http","model":"deepseek-chat","endpoint":"https://api.deepseek.com"}"#
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(settings.httpProfileID == "custom")
    }

    @Test func settingsKeepAStoredProfile() throws {
        let json = #"{"provider":"http","httpProfileID":"deepseek","model":"deepseek-chat"}"#
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(settings.httpProfileID == "deepseek")
    }

    @Test func aKnownProfileSuppliesItsAddressAndAuth() {
        let settings = AISettings(provider: .http, model: "deepseek-chat", httpProfileID: "deepseek")
        let profile = AIService.httpProfile(settings)
        #expect(profile.id == "deepseek")
        #expect(profile.auth == .bearer)
        #expect(profile.tokenField == .maxTokensFirst)
        #expect(AIService.httpBaseURL(settings)?.absoluteString == "https://api.deepseek.com")
    }

    @Test func anUnknownProfileFallsBackToCustomWithTheTypedAddress() {
        let settings = AISettings(provider: .http, model: "m", endpoint: "https://example.com/v1", httpProfileID: "gone")
        #expect(AIService.httpProfile(settings).id == "custom")
        #expect(AIService.httpBaseURL(settings)?.absoluteString == "https://example.com/v1")
    }

    @Test func theKeyAccountIsPerService() {
        #expect(AIService.keyAccount(for: "deepseek") == "http.apiKey.deepseek")
        #expect(AIService.legacyKeyAccount == "http.apiKey")
    }

    @Test func anEmptyModelIsRefusedRatherThanGuessed() {
        let settings = AISettings(provider: .http, model: "", httpProfileID: "deepseek")
        #expect(throws: AIProviderError.self) {
            try AIService.provider(for: settings)
        }
    }

    @Test func claudeStructuredOutputBecomesPlainText() {
        #expect(AIService.ClaudeAnswerProvider.answerText(#"{"answer":"a sentence"}"#) == "a sentence")
        #expect(AIService.ClaudeAnswerProvider.answerText("plain text") == "plain text")
        #expect(AIService.ClaudeAnswerProvider.answerText(#"{"other":1}"#) == #"{"other":1}"#)
    }

    @Test func failuresAreWordedForTheReader() {
        #expect(AIProviderFailure.message(for: AIProviderError.unauthorised, provider: .http).contains("401"))
        #expect(AIProviderFailure.message(for: AIProviderError.server(status: 400, message: "Model Not Exist"), provider: .http)
            == "The endpoint answered 400: Model Not Exist")
        #expect(AIProviderFailure.message(for: AIProviderError.notInstalled, provider: .codexCLI).contains("Codex CLI"))
        #expect(AIProviderFailure.message(for: AIProviderError.versionTooOld, provider: .claudeCLI).contains("Claude CLI"))
        #expect(AIProviderFailure.message(for: AIProviderError.unavailable(.deviceNotEligible), provider: .appleOnDevice)
            .contains("does not support Apple Intelligence"))
        #expect(AIProviderFailure.message(for: AIProviderError.cancelled, provider: .http) == "Cancelled.")
    }

    @Test func cancellationIsRecognisedThroughTheAdapter() {
        #expect(AIProviderFailure.isCancelled(AIProviderError.cancelled))
        #expect(AIProviderFailure.isCancelled(CancellationError()))
        #expect(!AIProviderFailure.isCancelled(AIProviderError.timeout))
    }
}