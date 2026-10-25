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
    @Test func theLegacyKeyMovesOnlyToTheServiceItBelongsTo() {
        let endpoint = "https://api.deepseek.com"
        #expect(AIService.shouldMigrateLegacyKey(
            profileID: "deepseek", endpoint: endpoint, hasTargetKey: false,
            legacyKey: "fixture-legacy"))
        #expect(!AIService.shouldMigrateLegacyKey(
            profileID: "custom", endpoint: endpoint, hasTargetKey: false,
            legacyKey: "fixture-legacy"))
        #expect(!AIService.shouldMigrateLegacyKey(
            profileID: "deepseek", endpoint: endpoint, hasTargetKey: true,
            legacyKey: "fixture-legacy"))
        #expect(!AIService.shouldMigrateLegacyKey(
            profileID: "deepseek", endpoint: "https://llm.example.com",
            hasTargetKey: false, legacyKey: "fixture-legacy"))
        #expect(!AIService.shouldMigrateLegacyKey(
            profileID: "deepseek", endpoint: endpoint, hasTargetKey: false,
            legacyKey: nil))
    }

    @Test func aSavedEndpointAdoptsTheServiceItNames() throws {
        // An upgrade from a typed URL should land on the service in the menu,
        // not stay on Custom.
        let json = #"{"provider":"http","model":"deepseek-chat","endpoint":"https://api.deepseek.com"}"#
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(settings.httpProfileID == "deepseek")
    }

    @Test func anUnknownEndpointStaysCustom() throws {
        let json = #"{"provider":"http","model":"m","endpoint":"https://llm.example.com/v1"}"#
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(settings.httpProfileID == "custom")
        #expect(AIService.matchingProfileID(for: "https://api.deepseek.com/") == "deepseek")
        #expect(AIService.matchingProfileID(for: "") == nil)
        #expect(AIService.matchingProfileID(for: "https://api.deepseek.com/v1") == nil)
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
        #expect(throws: AIProviderConfigurationError.modelRequired("DeepSeek")) {
            try AIService.provider(for: settings)
        }
    }

    @Test func claudeStructuredOutputBecomesPlainText() throws {
        #expect(try AIService.ClaudeAnswerProvider.answerText(#"{"answer":"a sentence"}"#) == "a sentence")
        #expect(try AIService.ClaudeAnswerProvider.answerText("plain text") == "plain text")
        #expect(try AIService.ClaudeAnswerProvider.answerText(#"{"other":1}"#) == #"{"other":1}"#)
    }

    @Test func aBlankClaudeAnswerIsRefused() {
        #expect(throws: AIProviderError.refused) {
            try AIService.ClaudeAnswerProvider.answerText(#"{"answer":"   "}"#)
        }
        #expect(throws: AIProviderError.refused) {
            try AIService.ClaudeAnswerProvider.answerText("")
        }
    }

    @Test func aSavedFullEndpointKeepsOneCompletionsPath() {
        #expect(AIService.httpBase(URL(string: "https://api.example.com/v1/chat/completions")!)
            .absoluteString == "https://api.example.com/v1")
        #expect(AIService.httpBase(URL(string: "https://api.example.com/v1/chat/completions/")!)
            .absoluteString == "https://api.example.com/v1")
        #expect(AIService.httpBase(URL(string: "https://api.example.com/v1")!)
            .absoluteString == "https://api.example.com/v1")
        #expect(AIService.httpBase(URL(string: "https://api.example.com")!)
            .absoluteString == "https://api.example.com")
        // Percent-encoding survives: `%2F` is not turned into a path separator.
        #expect(AIService.httpBase(URL(string: "https://api.example.com/a%2Fb/chat/completions")!)
            .absoluteString == "https://api.example.com/a%2Fb")
    }

    @Test func anUnknownServiceIdNormalisesToCustom() throws {
        let settings = AISettings(provider: .http, model: "m", httpProfileID: "gone")
        #expect(settings.httpProfileID == "custom")
        // An id this build does not know and an endpoint that names no known
        // service stays custom; had the default Ollama endpoint been kept, the
        // migration below would (correctly) call it Ollama.
        let json = #"{"provider":"http","httpProfileID":"gone","endpoint":"https://llm.example.com/v1"}"#
        let decoded = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(decoded.httpProfileID == "custom")
    }

    @Test func configurationFailuresAreWorded() {
        #expect(AIProviderFailure.message(
            for: AIProviderConfigurationError.modelRequired("DeepSeek"), provider: .http)
            == "Choose a model for DeepSeek before asking.")
        #expect(AIProviderFailure.message(
            for: AIProviderConfigurationError.appleNeedsNewerSystem, provider: .appleOnDevice)
            .contains("26.4"))
    }

    @Test func aFrameworkCodeBecomesASentence() {
        let message = AIProviderFailure.message(
            for: AIProviderError.framework("spawn 2"), provider: .claudeCLI)
        #expect(message.contains("Claude CLI could not run"))
        #expect(message.contains("spawn 2"))
        #expect(!message.hasPrefix("spawn 2"))
    }

    @Test func endpointUsabilityMatchesTheTransportRule() {
        #expect(AIService.endpointIsUsable(URL(string: "https://api.deepseek.com")!))
        #expect(AIService.endpointIsUsable(URL(string: "http://127.0.0.1:11434/v1")!))
        #expect(AIService.endpointIsUsable(URL(string: "http://localhost:1234/v1")!))
        #expect(!AIService.endpointIsUsable(URL(string: "http://api.example.com")!))
        #expect(!AIService.endpointIsUsable(URL(string: "example.com")!))
        #expect(!AIService.endpointIsUsable(URL(string: "ftp://example.com")!))
    }

    @Test func aPastedEndpointIsTrimmedBeforeUse() throws {
        // A leading space is invisible in the field and makes URL(string:) nil.
        let settings = AISettings(
            provider: .http, model: "m", endpoint: " https://api.deepseek.com\n",
            httpProfileID: "custom")
        #expect(AIService.httpBaseURL(settings)?.absoluteString == "https://api.deepseek.com")
        let json = #"{"provider":"http","endpoint":" https://api.deepseek.com "}"#
        let decoded = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(decoded.endpoint == "https://api.deepseek.com")
    }

    @Test func aPaddedEndpointStillFetchesModels() async {
        let state = ProviderSettingsState(loadKey: { _ in "" }, saveKey: { _, _ in 0 },
            modelFetch: { _, base, _ in
                #expect(base.absoluteString == "https://api.deepseek.com")
                return [AIModel(id: "deepseek-chat")]
            })
        state.loadKeyIfNeeded(profileID: "custom")
        state.loadModels(settings: AISettings(
            provider: .http, model: "", endpoint: " https://api.deepseek.com",
            httpProfileID: "custom"))
        for _ in 0..<100 where state.loadingModels { await Task.yield() }
        #expect(state.models.map(\.id) == ["deepseek-chat"])
        #expect(state.modelStatus == "1 models")
    }

    @Test func catalogueFailuresNameTheActualProblem() async {
        let state = ProviderSettingsState(loadKey: { _ in "" }, saveKey: { _, _ in 0 },
            modelFetch: { _, _, _ in [] })
        state.loadKeyIfNeeded(profileID: "custom")
        state.loadModels(settings: AISettings(provider: .http, model: "", endpoint: "  ", httpProfileID: "custom"))
        for _ in 0..<20 { await Task.yield() }
        #expect(state.modelStatus == "Set the endpoint first.")
        state.loadModels(settings: AISettings(provider: .http, model: "", endpoint: "example.com", httpProfileID: "custom"))
        for _ in 0..<20 { await Task.yield() }
        #expect(state.modelStatus == "The endpoint is not a valid URL.")
    }

    @Test func aCatalogueFromTheOldServiceIsDropped() async {
        let state = ProviderSettingsState(loadKey: { _ in "" }, saveKey: { _, _ in 0 },
            modelFetch: { _, _, _ in
                try await Task.sleep(for: .milliseconds(50))
                return [AIModel(id: "old-model")]
            })
        state.loadKeyIfNeeded(profileID: "deepseek")
        state.loadModels(settings: AISettings(provider: .http, model: "m", httpProfileID: "deepseek"))
        state.invalidateCatalogue()
        // Long enough for the cancelled fetch to have returned had it been
        // allowed to publish.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(state.models.isEmpty)
        #expect(!state.loadingModels)
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