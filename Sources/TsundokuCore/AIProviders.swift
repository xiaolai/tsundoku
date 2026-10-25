import Darwin
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

    /// The base address the provider will use: the profile's own for a known
    /// service, the typed one for `custom`.
    public static func httpBaseURL(_ settings: AISettings) -> URL? {
        let profile = httpProfile(settings)
        if profile.id == AIProviderProfile.custom.id {
            return URL(string: settings.endpoint)
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
        guard let url = httpBaseURL(settings) else {
            throw AIProviderError.insecureEndpoint
        }
        // No invented model: the old fallback sent `gpt-4o-mini` to endpoints
        // that never served it, and the server's refusal was the first sign.
        let model = settings.model.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AIProviderError.framework(
                "Choose a model for \(profile.name) before asking.")
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
            Self.answerText(try await cli.answer(to: question))
        }

        static func answerText(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let answer = object["answer"] as? String
            else { return trimmed }
            return answer
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

    /// Where the app looks for a CLI: the inherited `PATH`, then the folders an
    /// installer uses and a Finder-launched app does not inherit. Resolving it
    /// here gives a missing Codex the honest `.notInstalled`; sayso's own probe
    /// reports that case as an opaque framework error.
    public static func findCLI(_ name: String) -> URL? {
        var candidates =
            (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map {
                URL(fileURLWithPath: String($0))
                    .appendingPathComponent(name)
            }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent("bin"),
            home.appendingPathComponent(".npm-global/bin"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent(".bun/bin"),
            home.appendingPathComponent("Library/pnpm"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
        ]
        candidates += folders.map { $0.appendingPathComponent(name) }
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
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
        guard let executable = findCLI("codex") else {
            throw AIProviderError.notInstalled
        }
        // sayso's probe reads the sign-in before it prepares the folders, and a
        // home that does not exist yet fails the probe as an opaque framework
        // error. Make it first, private, with the rules sayso would check.
        try ensurePrivateFolder(codexHome())
        try ensurePrivateFolder(providerWorkingDirectory())
        return try CodexCLIProvider(
            configuration: CodexCLIProvider.Configuration(
                executable: executable,
                codexHome: codexHome(),
                workingDirectory: providerWorkingDirectory(),
                model: settings.model.isEmpty ? nil : settings.model,
                timeout: .seconds(240)))
    }

    /// A folder the app owns alone: the CLI writes a credential into it, so a
    /// folder another user could write to (or a symlink to one) is refused, not
    /// repaired.
    static func ensurePrivateFolder(_ url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            do {
                try manager.createDirectory(
                    at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                throw AIProviderError.framework(
                    "Could not create the app's AI folder.")
            }
        }
        var info = stat()
        guard
            lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
            info.st_uid == getuid(), info.st_mode & 0o022 == 0
        else {
            throw AIProviderError.framework(
                "The app's AI folder at \(url.path) is not private. Remove it and try again.")
        }
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
        throw AIProviderError.framework(
            "Apple on-device needs macOS 26.4 or later.")
        #else
        throw AIProviderError.framework(
            "Apple on-device is not available in this build.")
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
            return "Connected · Claude CLI \(try await cli.cli.check())"
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
            throw AIProviderError.framework(
                "Apple on-device needs macOS 26.4 or later.")
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
        case .framework(let message):
            return message
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
