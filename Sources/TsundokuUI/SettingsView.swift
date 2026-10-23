import AppKit
import Security
import SwiftUI
import TsundokuCore

public enum SettingsPane: String, CaseIterable, Identifiable {
    case companion = "Companion"
    case ai = "AI Provider"
    case data = "Library Data"
    case about = "About"
    public var id: String { rawValue }
}

public struct SettingsView: View {
    let pane: SettingsPane?
    @ObservedObject var model: AppModel
    @State private var apiKey = Keychain.get(account: "http.apiKey") ?? ""
    @State private var testStatus = ""
    @State private var testing = false
    @State private var testGeneration = 0

    public init(model: AppModel, pane: SettingsPane? = nil) {
        self.model = model
        self.pane = pane
    }

    public var body: some View {
        Form {
            if pane == nil || pane == .companion {
                if let companion = model.companionSettings {
                    CompanionSettingsSection(store: companion)
                }

            }
            if pane == nil || pane == .ai {
                Section("Reading Companion") {
                    Picker("Provider", selection: $model.settings.provider) {
                        ForEach(AIProviderKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .disabled(testing)
                    .help(providerNote)

                    TextField(
                        "Model", text: $model.settings.model,
                        prompt: Text("Provider default")
                    )
                    .disabled(testing)
                    if model.settings.provider == .http {
                        TextField("Endpoint", text: $model.settings.endpoint)
                            .disabled(testing)
                        SecureField("API Key", text: $apiKey)
                            .disabled(testing)
                        IconButton("Save Key to Keychain", systemImage: "key") {
                            let status = Keychain.set(
                                apiKey, account: "http.apiKey")
                            testStatus =
                                status == errSecSuccess
                                ? "Key saved to the login Keychain."
                                : "Could not save the key (OSStatus \(status))."
                        }
                        .controlSize(.small)
                        .disabled(testing)
                    }
                    TextField(
                        "Answer Language", text: $model.settings.language
                    )
                    .disabled(testing)
                    Toggle(
                        "Record Pages While Tracking",
                        isOn: $model.settings.sessionLogging
                    )
                    .disabled(testing)

                    LabeledContent("Connection") {
                        HStack(spacing: 8) {
                            IconButton("Test Provider", systemImage: "network")
                            { test() }
                            .controlSize(.small)
                            .disabled(testing)
                            if testing {
                                ProgressView().controlSize(.small)
                            }
                            Text(testStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }
                    .onChange(of: model.settings.provider) { _, _ in
                        testStatus = ""
                        testGeneration += 1
                    }
                    .onChange(of: model.settings.model) { _, _ in
                        testStatus = ""
                        testGeneration += 1
                    }
                    .onChange(of: model.settings.endpoint) { _, _ in
                        testStatus = ""
                        testGeneration += 1
                    }
                }

            }
            if pane == nil || pane == .companion {
                Section("Permissions") {
                    permissionRow(
                        "Accessibility",
                        detail: "Read the page and turn pages.",
                        granted: model.permissionAccessibility,
                        action: model.openAccessibilitySettings)
                    permissionRow(
                        "Screen Recording",
                        detail: "Capture the page for PDF export.",
                        granted: model.permissionScreen,
                        action: model.openScreenSettings)
                    IconButton("Re-check", systemImage: "arrow.clockwise") {
                        model.refreshPermissions()
                    }
                    .controlSize(.small)

                }

            }
            if pane == nil || pane == .data {
                Section("Library Data") {
                    LabeledContent("Archive") {
                        Text(archiveSummary)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(BookSource.allCases, id: \.self) { source in
                        LabeledContent(source.displayName) {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(
                                    model.sourceHealth[source]
                                        ?? "Not checked this session")
                                Text(
                                    "Last successful import: \(model.sourceLastImport[source]?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable")"
                                ).font(.caption)
                            }.foregroundStyle(.secondary).textSelection(
                                .enabled)
                        }
                    }
                    Text(
                        "Local caches may not contain every cloud annotation."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Last Import") {
                        Text(TsundokuFormat.relative(model.lastImport))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Export Folder") {
                        HStack(spacing: 8) {
                            Text(model.exportFolder.path)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            IconButton(
                                "Choose…", systemImage: "folder.badge.plus",
                                tooltip: "Choose export folder"
                            ) {
                                model.chooseExportFolder()
                            }
                        }
                    }
                    IconButton(
                        "Import Now", systemImage: "arrow.triangle.2.circlepath"
                    ) {
                        model.importLibrary()
                    }
                    .controlSize(.small)
                    .disabled(model.isImporting)
                    if let importError = model.importError {
                        Text(importError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

            }
            if pane == nil || pane == .about {
                Section("About") {
                    LabeledContent("Tsundoku") {
                        Text(version)
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        "Your local Kindle and Apple Books archive."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var providerNote: String {
        switch model.settings.provider {
        case .claudeCLI:
            "Uses the local Claude CLI and its existing login."
        case .codexCLI:
            "Uses the local Codex CLI and its existing login."
        case .http:
            "Any OpenAI-compatible endpoint. The key is kept in the Keychain."
        case .appleOnDevice:
            "Apple's on-device model. No page leaves this Mac."
        }
    }

    private var archiveSummary: String {
        let sessions = model.sessions.count
        return "\(model.ebookCount.formatted()) ebooks · "
            + "\(model.userAnnotationCount.formatted()) annotations · "
            + "\(sessions) " + (sessions == 1 ? "session" : "sessions")
    }

    private var version: String {
        let short =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String
        let build =
            Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case (let short?, let build?): return "\(short) (\(build))"
        case (let short?, nil): return short
        // Unbundled runs have no Info.plist; VERSION owns the release number.
        default: return "dev"
        }
    }

    private func permissionRow(
        _ title: String, detail: String, granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    Text(granted ? "Granted" : "Needed")
                        .foregroundStyle(.secondary)
                    IconButton("Open Settings", systemImage: "gearshape") {
                        action()
                    }
                    .controlSize(.small)
                }
            }.help(detail)
        }
    }

    private func test() {
        testing = true
        testStatus = ""
        testGeneration += 1
        let generation = testGeneration
        let settings = model.settings
        Task {
            let request = AIRequest(
                action: .explain,
                pageText: "The quick brown fox jumps over the lazy dog.",
                bookTitle: "Tsundoku test", language: settings.language)
            do {
                let answer = try await AIService.answer(
                    for: request, settings: settings)
                if generation == testGeneration {
                    testStatus =
                        "OK · \(answer.provider) · "
                        + "\(answer.text.count) characters"
                }
            } catch {
                if generation == testGeneration {
                    testStatus = "\(error)"
                }
            }
            if generation == testGeneration {
                testing = false
            }
        }
    }
}
