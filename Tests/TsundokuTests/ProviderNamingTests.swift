import Foundation
import SaySoAI
import Testing

@testable import TsundokuCore

@Suite("Provider naming")
struct ProviderNamingTests {
    @Test("a known service is named by the service, not the transport")
    func knownService() {
        var settings = AISettings()
        settings.provider = .http
        settings.httpProfileID = "deepseek"
        settings.endpoint = "https://api.deepseek.com"
        let name = AIService.providerName(for: settings)
        #expect(name == "DeepSeek")
        #expect(!name.contains("OpenAI-compatible"))

        // A service whose catalogue name carries the protocol label loses it.
        settings.httpProfileID = "anthropic"
        let anthropic = AIService.providerName(for: settings)
        #expect(anthropic == "Anthropic")
    }

    @Test("a custom endpoint is named by its host")
    func customEndpoint() {
        var settings = AISettings()
        settings.provider = .http
        settings.httpProfileID = AIProviderProfile.custom.id
        settings.endpoint = "http://192.0.2.10:11434/v1"
        let name = AIService.providerName(for: settings)
        #expect(name.contains("192.0.2.10"))
        #expect(name.contains(":11434"))
        #expect(!name.contains("OpenAI-compatible"))
    }

    @Test("the command-line providers keep their own names")
    func commandLine() {
        var settings = AISettings()
        settings.provider = .claudeCLI
        #expect(AIService.providerName(for: settings) == "Claude CLI")
        settings.provider = .codexCLI
        #expect(AIService.providerName(for: settings) == "Codex CLI")
    }
}
