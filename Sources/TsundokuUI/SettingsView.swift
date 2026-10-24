import AppKit
import Security
import SwiftUI
import TsundokuCore

public struct SettingsView: View {
    let pane: SettingsPane
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var providerState: ProviderSettingsState

    public init(model: AppModel, pane: SettingsPane, navigation: SettingsNavigation,
        providerState: ProviderSettingsState) {
        self.model = model; self.pane = pane; self.navigation = navigation; self.providerState = providerState
    }

    public var body: some View {
        Group {
            if pane == .access, let permissions = model.permissions {
                AccessSettingsView(model: model, permissions: permissions, navigation: navigation)
            } else { form }
        }
        .accessibilityIdentifier("settings-pane-\(pane.rawValue)")
    }

    private var form: some View {
        Form {
            if pane == .companion {
                if let companion = model.companionSettings {
                    CompanionSettingsSection(store: companion)
                }

            }
            if pane == .ai {
                Section("Reading Companion") {
                    Picker("Provider", selection: $model.settings.provider) {
                        ForEach(AIProviderKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .disabled(providerState.testing)
                    .help(providerNote)

                    TextField(
                        "Model", text: $model.settings.model,
                        prompt: Text("Provider default")
                    )
                    .disabled(providerState.testing)
                    if model.settings.provider == .http {
                        TextField("Endpoint", text: $model.settings.endpoint)
                            .disabled(providerState.testing)
                        SecureField("API Key", text: $providerState.draftKey)
                            .accessibilityIdentifier("provider-api-key")
                            .disabled(providerState.testing)
                            .onSubmit { providerState.saveKey() }
                        HStack {
                            Text(providerState.keyStatus.isEmpty && providerState.hasUnsavedKey ? "Unsaved key" : providerState.keyStatus)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Save Key", action: providerState.saveKey)
                                .disabled(!providerState.hasUnsavedKey || providerState.testing)
                        }

                    }
                    TextField(
                        "Answer Language", text: $model.settings.language
                    )
                    .disabled(providerState.testing)
                    Toggle(
                        "Record Pages While Tracking",
                        isOn: $model.settings.sessionLogging
                    )
                    .disabled(providerState.testing)

                    HStack(spacing: 8) {
                            Text("Connection")
                            Spacer(minLength: 0)
                            IconButton("Test Provider", systemImage: "network")
                            { providerState.test(settings: model.settings) }
                            .controlSize(.small)
                            .disabled(providerState.testing || (model.settings.provider == .http && providerState.hasUnsavedKey))
                            if providerState.testing {
                                ProgressView().controlSize(.small)
                            }
                            Text(providerState.testStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                    }
                    .onChange(of: model.settings.provider) { _, provider in
                        if provider == .http { providerState.loadKeyIfNeeded() }
                        providerState.invalidateTest()
                    }
                    .onChange(of: model.settings.model) { _, _ in
                        providerState.invalidateTest()
                    }
                    .onChange(of: model.settings.endpoint) { _, _ in
                        providerState.invalidateTest()
                    }
                }

            }
            if pane == .data {
                Section("Library Data") {
                    LabeledContent("Access") {
                        IconButton("Review Library Access", systemImage: "lock.shield") {
                            model.openAccess(focus: .library)
                        }
                    }
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
            if pane == .about {
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
        .task { if pane == .ai && model.settings.provider == .http { providerState.loadKeyIfNeeded() } }
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

}
