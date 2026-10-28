import Foundation
import SaySoAI
import Security
import SwiftUI
import TsundokuCore

/// One window-scoped draft, shared across pane changes. No credential values
/// enter status strings or diagnostics. Loading is deferred until AI is opened,
/// and the key is kept per service: switching profiles must never send one
/// service's key to another.
@MainActor public final class ProviderSettingsState: ObservableObject {
    @Published public var draftKey = "" {
        didSet {
            guard draftKey != oldValue else { return }
            if loadedProfileID != nil { keyStatus = ""; invalidateTest() }
        }
    }
    @Published public private(set) var keyStatus = ""
    @Published public private(set) var testStatus = ""
    @Published public private(set) var testing = false
    @Published public private(set) var signingIn = false
    @Published public private(set) var signInStatus = ""
    @Published public private(set) var models: [AIModel] = []
    @Published public private(set) var modelStatus = ""
    @Published public private(set) var loadingModels = false
    private var savedKey = ""
    private var loadedProfileID: String?
    private let loadKey: (String) -> String
    private let writeKey: (String, String) -> OSStatus
    private let removeKey: (String) -> Void
    private let forgetLegacyKey: () -> Void
    private let connectionTest: (AISettings) async throws -> String
    private let modelFetch:
        (AIProviderProfile, URL, String?) async throws -> [AIModel]
    private var generation = 0
    private var modelGeneration = 0
    private var signInGeneration = 0
    private var testTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?

    public init(
        loadKey: @escaping (String) -> String = {
            AIService.httpKey(profileID: $0) ?? ""
        },
        saveKey: @escaping (String, String) -> OSStatus = {
            Keychain.set($0, account: AIService.keyAccount(for: $1))
        },
        deleteKey: @escaping (String) -> Void = { profile in
            Keychain.remove(account: AIService.keyAccount(for: profile))
        },
        forgetLegacyKey: @escaping () -> Void = {
            Keychain.remove(account: AIService.legacyKeyAccount)
        },
        connectionTest: @escaping (AISettings) async throws -> String = {
            try await AIConnection.test(settings: $0)
        },
        modelFetch: @escaping (AIProviderProfile, URL, String?) async throws
            -> [AIModel] = { profile, base, key in
                try await ModelCatalog().fetch(
                    ModelCatalog.Request(
                        profile: profile, baseURL: base, apiKey: key))
            }
    ) {
        self.loadKey = loadKey
        self.writeKey = saveKey
        self.removeKey = deleteKey
        self.forgetLegacyKey = forgetLegacyKey
        self.connectionTest = connectionTest
        self.modelFetch = modelFetch
    }

    public var hasUnsavedKey: Bool {
        loadedProfileID != nil && draftKey != savedKey
    }

    /// Whether the keychain holds a key for the loaded profile. An empty
    /// draft is not the same thing: the reader may have typed and not saved.
    public var hasStoredKey: Bool { !savedKey.isEmpty }

    /// Remove the stored key for the loaded profile. The draft is cleared with
    /// it, so the field cannot keep showing a secret the keychain no longer
    /// has.
    public func forgetKey() {
        guard let profile = loadedProfileID else { return }
        removeKey(profile)
        savedKey = ""
        draftKey = ""
        keyStatus = "No key stored."
        invalidateTest()
        invalidateCatalogue()
    }

    public func loadKeyIfNeeded(profileID: String) {
        guard loadedProfileID != profileID else { return }
        loadedProfileID = profileID
        savedKey = loadKey(profileID)
        draftKey = savedKey
        keyStatus = ""
        invalidateTest()
        invalidateCatalogue()
    }

    public func saveKey(profileID: String) {
        guard hasUnsavedKey else { return }
        let status = writeKey(draftKey, profileID)
        if status == errSecSuccess {
            savedKey = draftKey
            keyStatus = "Saved"
            // The old single-key account is superseded by the per-service one.
            if profileID == AIProviderProfile.custom.id { forgetLegacyKey() }
        } else {
            keyStatus = "Could not save key (\(status)). Try again."
        }
        invalidateTest()
    }

    public func invalidateTest() {
        generation += 1
        testTask?.cancel()
        testTask = nil
        testing = false
        testStatus = ""
    }

    public func test(settings: AISettings) {
        guard !testing, settings.provider != .http || !hasUnsavedKey else {
            return
        }
        invalidateTest()
        testing = true
        let current = generation
        testTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.connectionTest(settings)
                guard !Task.isCancelled, self.generation == current else {
                    return
                }
                self.testStatus = result
            } catch {
                guard !Task.isCancelled, self.generation == current else {
                    return
                }
                self.testStatus = Self.detail(
                    for: error, provider: settings.provider,
                    secrets: [self.savedKey, self.draftKey])
            }
            guard self.generation == current else { return }
            self.testing = false
            self.testTask = nil
        }
    }

    /// The documented `codex login`, in the app's own Codex home. Its output —
    /// the URL and the code — is shown as it arrives; the browser is opened by
    /// the CLI.
    public func signIn(settings: AISettings) {
        guard settings.provider == .codexCLI, !signingIn else { return }
        signInGeneration += 1
        let generation = signInGeneration
        signingIn = true
        signInStatus = "Opening the browser…"
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await AIConnection.signInToCodex(
                    settings: settings,
                    onLine: { [weak self] line in
                        Task { @MainActor in
                            guard let self, self.signingIn,
                                self.signInGeneration == generation
                            else { return }
                            let text = line.trimmingCharacters(
                                in: .whitespacesAndNewlines)
                            if !text.isEmpty {
                                self.signInStatus = String(text.prefix(160))
                            }
                        }
                    })
                guard
                    !Task.isCancelled, self.signInGeneration == generation
                else { return }
                self.signInStatus = "Signed in."
                self.invalidateTest()
            } catch {
                guard
                    !Task.isCancelled, self.signInGeneration == generation
                else { return }
                self.signInStatus = AIProviderFailure.message(
                    for: error, provider: .codexCLI)
            }
            guard self.signInGeneration == generation else { return }
            self.signingIn = false
            self.signInTask = nil
        }
    }

    /// Stop a pending sign-in and its child, and drop any feedback from an
    /// earlier one; switching away from the provider must not leave
    /// `codex login` running for up to five minutes, nor show its outcome for
    /// a provider that never signed in.
    public func clearSignIn() {
        signInGeneration += 1
        signInTask?.cancel()
        signInTask = nil
        signingIn = false
        signInStatus = ""
    }

    /// A catalogue belongs to the service and address it was fetched from:
    /// changing either discards the list and cancels its fetch, so a late
    /// response cannot populate another service's menu.
    public func invalidateCatalogue() {
        modelGeneration += 1
        modelTask?.cancel()
        modelTask = nil
        loadingModels = false
        models = []
        modelStatus = ""
    }

    /// The service's own model list, a configuration aid, not an answer.
    public func loadModels(settings: AISettings) {
        guard settings.provider == .http else { return }
        guard
            let url = AIService.httpBaseURL(settings),
            AIService.endpointIsUsable(url)
        else {
            let typed = settings.endpoint.trimmingCharacters(
                in: .whitespacesAndNewlines)
            modelStatus =
                typed.isEmpty
                ? "Set the endpoint first."
                : "The endpoint is not a valid URL."
            return
        }
        let base = AIService.httpBase(url)
        invalidateCatalogue()
        let generation = modelGeneration
        loadingModels = true
        let profile = AIService.httpProfile(settings)
        let key = loadedProfileID == profile.id ? savedKey : loadKey(profile.id)
        modelTask = Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await self.modelFetch(profile, base, key)
                guard
                    !Task.isCancelled, self.modelGeneration == generation
                else { return }
                self.models = list
                self.modelStatus =
                    list.isEmpty
                    ? "The service listed no models." : "\(list.count) models"
            } catch {
                guard
                    !Task.isCancelled, self.modelGeneration == generation
                else { return }
                self.modelStatus = AIProviderFailure.modelsMessage(for: error)
            }
            guard self.modelGeneration == generation else { return }
            self.loadingModels = false
            self.modelTask = nil
        }
    }

    /// Why a connection test failed, bounded, with the stored key removed in
    /// case an endpoint echoed it.
    nonisolated static func detail(
        for error: any Error, provider: TsundokuCore.AIProviderKind,
        secrets: [String]
    ) -> String {
        var text = AIProviderFailure.message(for: error, provider: provider)
        for secret in secrets where secret.count >= 8 {
            text = text.replacingOccurrences(of: secret, with: "<key>")
        }
        return String(text.prefix(300))
    }
}
