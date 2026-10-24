import Foundation
import Security
import SwiftUI
import TsundokuCore

/// One window-scoped draft, shared across pane changes. No credential values
/// enter status strings or diagnostics. Loading is deferred until AI is opened.
@MainActor public final class ProviderSettingsState: ObservableObject {
    @Published public var draftKey = "" {
        didSet {
            guard draftKey != oldValue else { return }
            if loaded { keyStatus = ""; invalidateTest() }
        }
    }
    @Published public private(set) var keyStatus = ""
    @Published public private(set) var testStatus = ""
    @Published public private(set) var testing = false
    private var savedKey = ""
    private var loaded = false
    private let loadKey: () -> String
    private let writeKey: (String) -> OSStatus
    private let connectionTest: (AISettings) async throws -> String
    private var generation = 0
    private var testTask: Task<Void, Never>?

    public init(loadKey: @escaping () -> String = { Keychain.get(account: "http.apiKey") ?? "" },
        saveKey: @escaping (String) -> OSStatus = { Keychain.set($0, account: "http.apiKey") },
        connectionTest: @escaping (AISettings) async throws -> String = { settings in
            let request = AIRequest(action: .explain, pageText: "The quick brown fox jumps over the lazy dog.",
                bookTitle: "Tsundoku test", language: settings.language)
            let answer = try await AIService.answer(for: request, settings: settings)
            return "Connected · \(answer.provider)"
        }) {
        self.loadKey = loadKey; self.writeKey = saveKey; self.connectionTest = connectionTest
    }
    public var hasUnsavedKey: Bool { loaded && draftKey != savedKey }
    public func loadKeyIfNeeded() {
        guard !loaded else { return }
        savedKey = loadKey(); draftKey = savedKey; loaded = true
    }
    public func saveKey() {
        guard hasUnsavedKey else { return }
        let status = writeKey(draftKey)
        if status == errSecSuccess { savedKey = draftKey; keyStatus = "Saved" }
        else { keyStatus = "Could not save key (\(status)). Try again." }
        invalidateTest()
    }
    public func invalidateTest() {
        generation += 1; testTask?.cancel(); testTask = nil
        testing = false; testStatus = ""
    }
    public func test(settings: AISettings) {
        guard !testing, settings.provider != .http || !hasUnsavedKey else { return }
        invalidateTest(); testing = true
        let current = generation
        testTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.connectionTest(settings)
                guard !Task.isCancelled, self.generation == current else { return }
                self.testStatus = result
            } catch {
                guard !Task.isCancelled, self.generation == current else { return }
                // Providers can return URLs/error details, but never echo the key.
                self.testStatus = "Connection failed. Check the provider settings and try again."
            }
            guard self.generation == current else { return }
            self.testing = false; self.testTask = nil
        }
    }
}
