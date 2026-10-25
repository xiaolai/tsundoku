import Foundation
import SaySoAI
import SaySoAICLI
import SaySoAIApple

#if canImport(FoundationModels)
import FoundationModels

/// The on-device answer shape: one field, so guided generation cannot answer
/// in prose that fails to parse.
@available(macOS 26.4, *)
@Generable
public struct AppleAnswer: Sendable {
    @Guide(description: "The answer, as plain text.")
    public var answer: String
}
#endif

/// A configuration problem this app finds before any request. Kept apart from
/// sayso's failures so a sentence the app wrote is never mistaken for a
/// library code and reworded.
public enum AIProviderConfigurationError: Error, Equatable, Sendable {
    case modelRequired(String)
    case appleNeedsNewerSystem
}

/// Turns settings into a provider and a question into an answer.
///
/// The transport, the CLI processes and Apple's model are sayso's; what stays
/// here is what Tsundoku alone knows — which profile a reader picked, where
/// the key lives, the prompt, and the words a failure is shown in.
public enum AIService {
    public static func answer(
        for request: AIRequest, settings: AISettings
    ) async throws -> AIAnswer {
        let provider = try provider(for: settings)
        let text = try await provider.answer(
            to: AIComposer.prompt(for: request, settings: settings))
        return AIAnswer(text: text, provider: providerName(for: settings))
    }

    /// The provider the settings name. Construction checks what can be checked
    /// without a request; presence, version and sign-in are the provider's own
    /// `check()`/`probe()`, run by the Settings test.
    public static func provider(for settings: AISettings) throws
        -> any AIProvider
    {
        switch settings.provider {
        case .http: return try httpProvider(settings)
        case .claudeCLI: return claudeProvider(settings)
        case .codexCLI: return try codexProvider(settings)
        case .appleOnDevice: return try appleProvider()
        }
    }

    /// What an answer is labelled with. HTTP names the service, not the wire.
    public static func providerName(for settings: AISettings) -> String {
        guard settings.provider == .http else {
            return settings.provider.displayName
        }
        return httpProfile(settings).name
    }

    // MARK: - HTTP

    /// The chosen service, or `custom` for an id this build does not know —
    /// so a settings blob from a newer version still opens.
    public static func httpProfile(_ settings: AISettings) -> AIProviderProfile {
        AIProviderProfile.profile(id: settings.httpProfileID) ?? .custom
    }

    /// An id this build does not know must not stay in the settings: requests
    /// would resolve it to `custom` while the window hid the endpoint field and
    /// stored keys under the unknown id.
    public static func normalizedProfileID(_ raw: String) -> String {
        AIProviderProfile.profile(id: raw) == nil
            ? AIProviderProfile.custom.id : raw
    }

    public static var knownServiceIDs: [String] {
        AIProviderProfile.known.map(\.id)
    }

    /// The known service whose base address a saved endpoint already names, so
    /// a reader who upgraded from a typed URL lands on that service in the menu
    /// instead of staying on Custom.
    public static func matchingProfileID(for endpoint: String) -> String? {
        let typed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, let url = URL(string: typed) else { return nil }
        var candidate = httpBase(url).absoluteString
        while candidate.hasSuffix("/") { candidate.removeLast() }
        return AIProviderProfile.known.first { profile in
            guard profile.id != AIProviderProfile.custom.id,
                let base = profile.baseURL?.absoluteString
            else { return false }
            var known = base
            while known.hasSuffix("/") { known.removeLast() }
            return known == candidate
        }?.id
    }

    /// After an upgrade turns a saved custom endpoint into the service it
    /// names, the key saved under `custom` must move with it; otherwise the
    /// reader's working setup looks like a lost key. Moves only when the
    /// service has no key of its own and the endpoint is exactly that
    /// service's.
    public static func migrateLegacyKeyIfNeeded(
        profileID: String, endpoint: String
    ) {
        let target = keyAccount(for: profileID)
        let legacyAccount = keyAccount(for: AIProviderProfile.custom.id)
        let legacy = Keychain.get(account: legacyAccount)
        guard
            shouldMigrateLegacyKey(
                profileID: profileID, endpoint: endpoint,
                hasTargetKey: !(Keychain.get(account: target) ?? "").isEmpty,
                legacyKey: legacy)
        else { return }
        guard let legacy,
            Keychain.set(legacy, account: target) == errSecSuccess
        else { return }
        Keychain.remove(account: legacyAccount)
    }

    /// The decision the migration acts on, as a value, so its matrix is
    /// testable without a Keychain.
    static func shouldMigrateLegacyKey(
        profileID: String, endpoint: String, hasTargetKey: Bool,
        legacyKey: String?
    ) -> Bool {
        profileID != AIProviderProfile.custom.id
            && matchingProfileID(for: endpoint) == profileID
            && !hasTargetKey
            && !(legacyKey ?? "").isEmpty
    }

    /// A saved id this build knows, with a custom one upgraded to the service
    /// its endpoint names.
    public static func migratedProfileID(
        _ raw: String, endpoint: String
    ) -> String {
        let known = normalizedProfileID(raw)
        guard known == AIProviderProfile.custom.id else { return known }
        return matchingProfileID(for: endpoint) ?? known
    }

    /// Whether an address is one the HTTP provider accepts: HTTPS anywhere, or
    /// plain HTTP only on this Mac. `URL(string:)` accepts a scheme-less string
    /// like `example.com`, so parsing alone proves nothing.
    public static func endpointIsUsable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host,
            !host.isEmpty
        else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    /// The base sayso appends `chat/completions` to. The old client accepted an
    /// endpoint that already named the full path, so a saved one must not get
    /// the suffix twice.
    public static func httpBase(_ url: URL) -> URL {
        guard
            var components = URLComponents(
                url: url, resolvingAgainstBaseURL: false)
        else { return url }
        // Percent-encoded on purpose: `path` decodes `%2F` into `/`, which
        // would change how an exotic endpoint routes.
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let suffix = "/chat/completions"
        if path.hasSuffix(suffix) { path.removeLast(suffix.count) }
        components.percentEncodedPath = path
        return components.url ?? url
    }

    /// The base address the provider will use: the profile's own for a known
    /// service, the typed one for `custom`. Whitespace is trimmed: the field
    /// hides a pasted leading space, and `URL(string:)` refuses the string
    /// while a reader sees a perfectly good address.
    public static func httpBaseURL(_ settings: AISettings) -> URL? {
        let profile = httpProfile(settings)
        if profile.id == AIProviderProfile.custom.id {
            return URL(
                string: settings.endpoint.trimmingCharacters(
                    in: .whitespacesAndNewlines))
        }
        return profile.baseURL
    }

    /// A key per service: switching from DeepSeek to OpenAI must not send one
    /// service's key to the other.
    public static func keyAccount(for profileID: String) -> String {
        "http.apiKey.\(profileID)"
    }

    /// The account that held the only key before profiles existed.
    public static let legacyKeyAccount = "http.apiKey"

    public static func httpKey(profileID: String) -> String? {
        if let key = Keychain.get(account: keyAccount(for: profileID)),
            !key.isEmpty
        {
            return key
        }
        // The old single key belonged to whichever endpoint was typed, which
        // is what `custom` is.
        if profileID == AIProviderProfile.custom.id,
            let legacy = Keychain.get(account: legacyKeyAccount), !legacy.isEmpty
        {
            return legacy
        }
        return nil
    }

    static func httpProvider(_ settings: AISettings) throws -> any AIProvider {
        let profile = httpProfile(settings)
        guard let url = httpBaseURL(settings).map(httpBase) else {
            throw AIProviderError.insecureEndpoint
        }
        // No invented model: the old fallback sent `gpt-4o-mini` to endpoints
        // that never served it, and the server's refusal was the first sign.
        let model = settings.model.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AIProviderConfigurationError.modelRequired(profile.name)
        }
        return try HTTPProvider(
            configuration: HTTPProvider.Configuration(
                endpoint: url, model: model,
                apiKey: httpKey(profileID: profile.id),
                auth: profile.auth, tokenField: profile.tokenField))
    }

    // MARK: - CLIs

    static let answerSchema = #"{"type":"object","properties":{"answer":{"type":"string","description":"The answer as plain text."}},"required":["answer"],"additionalProperties":false}"#

    /// Claude returns the schema's object as JSON; the CLI's flags make the
    /// answer the only field in it. The wrapper is the one place that shape is
    /// unwrapped, so every caller sees plain text.
    struct ClaudeAnswerProvider: AIProvider {
        let cli: ClaudeCLIProvider

        var id: AIProviderID { cli.id }

        func answer(to question: String) async throws(AIProviderError)
            -> String
        {
            try Self.answerText(try await cli.answer(to: question))
        }

        static func answerText(_ raw: String) throws(AIProviderError)
            -> String
        {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let text: String
            if let data = trimmed.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let answer = object["answer"] as? String
            {
                text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = trimmed
            }
            // A schema permits an empty string; a blank answer is no answer.
            guard !text.isEmpty else { throw .refused }
            return text
        }
    }

    static func claudeProvider(_ settings: AISettings) -> any AIProvider {
        // sayso discovers the Claude binary itself and throws `.notInstalled`
        // when there is none, so no preflight is needed here.
        ClaudeAnswerProvider(
            cli: ClaudeCLIProvider(
                configuration: ClaudeCLIProvider.Configuration(
                    configDirectory: claudeConfigDirectory(),
                    workingDirectory: providerWorkingDirectory(),
                    model: settings.model.isEmpty ? nil : settings.model,
                    timeout: .seconds(240), answerSchema: answerSchema)))
    }

    /// Claude Code keeps its sign-in in the Keychain slot it derives from
    /// `CLAUDE_CONFIG_DIR` and has no non-interactive login, so an app-owned
    /// folder would demand a second sign-in no code can complete. The reader's
    /// own folder keeps the CLI they signed in working; the provider's flags
    /// switch off everything that folder configures.
    static func claudeConfigDirectory() -> URL {
        if let configured = ProcessInfo.processInfo.environment[
            "CLAUDE_CONFIG_DIR"], !configured.isEmpty
        {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static func codexProvider(_ settings: AISettings) throws
        -> any AIProvider
    {
        // sayso creates and checks the app's own home before it probes the
        // sign-in (v0.5.1); a missing binary and a missing home are its
        // `.notInstalled` and `.notSignedIn`, not the app's to pre-detect.
        try CodexCLIProvider(
            configuration: CodexCLIProvider.Configuration(
                codexHome: codexHome(),
                workingDirectory: providerWorkingDirectory(),
                model: settings.model.isEmpty ? nil : settings.model,
                timeout: .seconds(240)))
    }

    /// The app's own Codex home. sayso refuses a folder other users can write
    /// to, and the reader's `~/.codex` is commonly 0755; a home of the app's
    /// own also keeps the reader's MCP servers and rules out of the child. It
    /// starts signed out, which the Sign In button completes.
    public static func codexHome() -> URL {
        supportDirectory().appendingPathComponent("Codex", isDirectory: true)
    }

    static func providerWorkingDirectory() -> URL {
        supportDirectory().appendingPathComponent(
            "Work", isDirectory: true)
    }

    static func supportDirectory() -> URL {
        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tsundoku/AI", isDirectory: true)
    }

    // MARK: - Apple

    static func appleProvider() throws -> any AIProvider {
        #if canImport(FoundationModels)
        if #available(macOS 26.4, *) {
            return AppleOnDeviceProvider<AppleAnswer>(
                configuration: AppleAnswerConfiguration { $0.answer })
        }
        throw AIProviderConfigurationError.appleNeedsNewerSystem
        #else
        throw AIProviderConfigurationError.appleNeedsNewerSystem
        #endif
    }
}

/// The connection test: what Settings shows when the reader presses Test.
public enum AIConnection {
    /// The documented `codex login`, in the app's own Codex home. Kept here so
    /// the UI never sees a sayso type: the CLI prints the browser URL and code,
    /// and the callback carries those lines as they arrive.
    public static func signInToCodex(
        settings: AISettings,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let provider = try AIService.provider(for: settings)
        guard let cli = provider as? CodexCLIProvider else {
            throw AIProviderError.badShape
        }
        _ = try await cli.login(onLine: onLine)
    }

    public static func test(settings: AISettings) async throws -> String {
        switch settings.provider {
        case .http:
            let provider = try AIService.provider(for: settings)
            guard let http = provider as? HTTPProvider else {
                throw AIProviderError.badShape
            }
            // One token proves the address, the model and the key.
            guard case .ready = try await http.probe() else {
                throw AIProviderError.badShape
            }
            return "Connected · \(AIService.httpProfile(settings).name)"
        case .claudeCLI:
            let provider = try AIService.provider(for: settings)
            guard let cli = provider as? AIService.ClaudeAnswerProvider else {
                throw AIProviderError.badShape
            }
            // Claude's check proves the binary, its version and the app's
            // folders; it does not spend a model call, so sign-in stays
            // unverified until the first ask.
            return "Installed · Claude CLI \(try await cli.cli.check()) (sign-in unverified)"
        case .codexCLI:
            let provider = try AIService.provider(for: settings)
            guard let cli = provider as? CodexCLIProvider else {
                throw AIProviderError.badShape
            }
            return "Connected · Codex CLI \(try await cli.check())"
        case .appleOnDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26.4, *) {
                let availability =
                    AppleOnDeviceProvider<AppleAnswer>.availability()
                guard case .available = availability else {
                    throw AIProviderError.unavailable(availability)
                }
                return "Available · Apple on-device"
            }
            #endif
            throw AIProviderConfigurationError.appleNeedsNewerSystem
        }
    }
}

/// The reader-facing words for a provider failure.
///
/// sayso's errors carry a stable code and deliberately no sentence; the app
/// words them. A `.server` refusal already carries the service's own message,
/// bounded and scrubbed of the key by the library.
public enum AIProviderFailure {
    public static func isCancelled(_ error: any Error) -> Bool {
        guard let providerError = error as? AIProviderError else {
            return error is CancellationError
        }
        if case .cancelled = providerError { return true }
        return error is CancellationError
    }

    public static func message(
        for error: any Error, provider: AIProviderKind
    ) -> String {
        if let configuration = error as? AIProviderConfigurationError {
            switch configuration {
            case .modelRequired(let service):
                return "Choose a model for \(service) before asking."
            case .appleNeedsNewerSystem:
                return "Apple on-device needs macOS 26.4 or later."
            }
        }
        guard let failure = error as? AIProviderError else {
            return error.localizedDescription
        }
        switch failure {
        case .insecureEndpoint:
            return "The endpoint must be an HTTPS address, or plain HTTP on this Mac (loopback only)."
        case .redirectRefused:
            return "The endpoint redirected to another address, so the key was not sent. Use the final address."
        case .unreachable:
            return "Could not reach the endpoint."
        case .unauthorised:
            return "The endpoint refused the key (401). Save a key that belongs to this service."
        case .modelNotFound:
            return "The endpoint does not know this model. Pick one from the service's list."
        case .rateLimited:
            return "The service is rate-limiting requests. Wait a moment and try again."
        case .refused:
            return "The model declined to answer."
        case .truncated:
            return "The answer was cut off at the token limit, so it was discarded."
        case .badShape:
            return "The endpoint answered in an unexpected shape."
        case .server(let status, let message):
            return "The endpoint answered \(status): \(message)"
        case .timeout:
            return "The endpoint did not answer in time."
        case .cancelled:
            return "Cancelled."
        case .notInstalled:
            return "\(cliName(provider)) is not installed or not on the app's search path."
        case .notSignedIn:
            return "\(cliName(provider)) is not signed in."
        case .versionTooOld:
            return "The installed \(cliName(provider)) is older than this app requires. Update it."
        case .unsupportedAuth:
            return "\(cliName(provider)) is signed in a way this app does not accept. Sign in again with the app."
        case .unavailable(let reason):
            return "Apple on-device is unavailable: \(availabilityText(reason))"
        case .contextExceeded:
            return "The passage is too long for the on-device model."
        case .guardrail:
            return "The model's guardrails refused this text."
        case .framework(let code):
            // sayso's framework cases are short internal codes ("folder",
            // "spawn 2", "generation"); a reader gets a sentence, the code
            // stays for a bug report.
            switch provider {
            case .appleOnDevice:
                return "Apple's on-device model failed (code: \(code))."
            case .claudeCLI, .codexCLI:
                return "\(cliName(provider)) could not run (code: \(code)). Try again, or sign in again if it persists."
            case .http:
                return "The endpoint client failed (code: \(code))."
            }
        }
    }

    /// Why a model list could not be fetched. A catalogue is a configuration
    /// aid, so its failures are worded apart from an answer's.
    public static func modelsMessage(for error: any Error) -> String {
        guard let failure = error as? ModelCatalogError else {
            return error.localizedDescription
        }
        switch failure {
        case .noList:
            return "This service does not list its models; type the model name."
        case .missingKey:
            return "Save a key first, then fetch the models."
        case .unreachable:
            return "Could not reach the service."
        case .unauthorised:
            return "The service refused the key."
        case .rateLimited:
            return "The service is rate-limiting requests. Try again shortly."
        case .timeout:
            return "The service did not answer in time."
        case .cancelled:
            return "Cancelled."
        case .server(let status, let message):
            return "The service answered \(status): \(message)"
        case .badShape:
            return "The service's model list was not readable."
        }
    }

    static func cliName(_ provider: AIProviderKind) -> String {
        switch provider {
        case .claudeCLI: "Claude CLI"
        case .codexCLI: "Codex CLI"
        case .http: "The endpoint"
        case .appleOnDevice: "Apple on-device"
        }
    }

    static func availabilityText(_ reason: AppleAvailability) -> String {
        switch reason {
        case .available: "available"
        case .deviceNotEligible: "this Mac does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled: "turn on Apple Intelligence in System Settings."
        case .modelNotReady: "the model is still downloading."
        case .system: "the system gave no reason."
        case .unknown: "the system gave an unknown reason."
        @unknown default: "the system gave an unknown reason."
        }
    }
}
