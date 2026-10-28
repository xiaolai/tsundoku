import Security
import SaySoAI
import SwiftUI
import TsundokuCore

/// One row of the provider menu: a service on the OpenAI-compatible wire, or
/// one of the local sources. Settings still store the kind and the service id
/// separately; this only decides how the menu presents them, so a reader picks
/// "DeepSeek" rather than knowing what an endpoint is.
private enum AIProviderChoice: Hashable {
    case service(String)
    case kind(TsundokuCore.AIProviderKind)
}

public struct SettingsView: View {
    let pane: SettingsPane
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var providerState: ProviderSettingsState
    @ObservedObject var updateChecker: UpdateController

    public init(model: AppModel, pane: SettingsPane, navigation: SettingsNavigation,
        providerState: ProviderSettingsState,
        updateChecker: UpdateController) {
        self.model = model; self.pane = pane; self.navigation = navigation
        self.providerState = providerState
        self.updateChecker = updateChecker
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
                    Picker("Provider", selection: providerChoice) {
                        Section("Services") {
                            ForEach(
                                AIProviderProfile.known.filter {
                                    $0.id != AIProviderProfile.custom.id
                                }
                            ) { profile in
                                Text(profile.name)
                                    .tag(AIProviderChoice.service(profile.id))
                            }
                            Text("Custom endpoint")
                                .tag(
                                    AIProviderChoice.service(
                                        AIProviderProfile.custom.id))
                        }
                        Section("Local") {
                            Text("Claude CLI")
                                .tag(AIProviderChoice.kind(.claudeCLI))
                            Text("Codex CLI")
                                .tag(AIProviderChoice.kind(.codexCLI))
                            Text("Apple on-device")
                                .tag(AIProviderChoice.kind(.appleOnDevice))
                        }
                    }
                    .disabled(providerState.testing)
                    .help(providerNote)

                    if model.settings.provider == .http {
                        if AIService.httpProfile(model.settings).id
                            == AIProviderProfile.custom.id
                        {
                            TextField(
                                "Endpoint", text: $model.settings.endpoint
                            )
                            .disabled(providerState.testing)
                        } else if let base = AIService.httpBaseURL(
                            model.settings)
                        {
                            LabeledContent("Endpoint") {
                                Text(base.absoluteString)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let note = AIService.httpProfile(model.settings)
                            .note
                        {
                            Text(note).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        // The key comes before the model: fetching the
                        // catalogue and testing the connection both need it,
                        // and a reader should not meet a model picker that
                        // cannot work yet.
                        SecureField("API Key", text: $providerState.draftKey)
                            .accessibilityIdentifier("provider-api-key")
                            .disabled(providerState.testing)
                            .help("Stored in the Keychain, one key per service. Environment variables and .env files are not read.")
                            .onSubmit {
                                providerState.saveKey(
                                    profileID: model.settings.httpProfileID)
                            }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(providerState.keyStatus.isEmpty && providerState.hasUnsavedKey ? "Unsaved key" : providerState.keyStatus)
                                Text("Stored in the Keychain, one key per service; environment variables are not read.")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Save Key") {
                                providerState.saveKey(
                                    profileID: model.settings.httpProfileID)
                            }
                            .disabled(!providerState.hasUnsavedKey || providerState.testing)
                        }
                    }

                    HStack {
                        TextField(
                            "Model", text: $model.settings.model,
                            prompt: Text(modelPrompt)
                        )
                        .disabled(providerState.testing)
                        if model.settings.provider == .http {
                            Menu {
                                ForEach(providerState.models) { option in
                                    Button(option.name ?? option.id) {
                                        model.settings.model = option.id
                                    }
                                }
                                if !providerState.models.isEmpty {
                                    Divider()
                                }
                                Button(
                                    providerState.models.isEmpty
                                        ? "Fetch Models" : "Refresh Models"
                                ) {
                                    providerState.loadModels(
                                        settings: model.settings)
                                }
                                .disabled(providerState.loadingModels)
                            } label: {
                                Label("Models", systemImage: "list.bullet")
                            }
                            .disabled(providerState.testing)
                        }
                    }
                    if model.settings.provider == .http,
                        !providerState.modelStatus.isEmpty
                    {
                        Text(providerState.modelStatus).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "Answer Language", text: $model.settings.language,
                        prompt: Text("Same as the question")
                    )
                    .disabled(providerState.testing)
                    .help(
                        "Leave empty to answer in the language of the "
                            + "reader's question.")
                    Toggle(
                        "Record Pages While Tracking",
                        isOn: $model.settings.sessionLogging
                    )
                    .disabled(providerState.testing)

                    if model.settings.provider == .http {
                        DisclosureGroup("Advanced") {
                            TextField(
                                "Max answer tokens",
                                value: $model.settings.answerTokens,
                                format: .number
                            )
                            .disabled(providerState.testing)
                            .help(
                                "Upper bound for the answer. The full "
                                    + "passage and conversation are sent; "
                                    + "this bounds only what comes back. A "
                                    + "reasoning model spends part of it "
                                    + "before writing, and the service may "
                                    + "enforce a lower limit.")
                            Text(
                                "The passage and conversation have no "
                                    + "app-side character cap.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if model.settings.provider == .codexCLI,
                        !providerState.signInStatus.isEmpty
                    {
                        Text(providerState.signInStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                            Text("Connection")
                            Spacer(minLength: 0)
                            if model.settings.provider == .codexCLI {
                                IconButton(
                                    "Sign In",
                                    systemImage: "person.badge.key"
                                ) {
                                    providerState.signIn(
                                        settings: model.settings)
                                }
                                .controlSize(.small)
                                .disabled(
                                    providerState.testing
                                        || providerState.signingIn)
                            }
                            IconButton("Test Provider", systemImage: "network")
                            { providerState.test(settings: model.settings) }
                            .controlSize(.small)
                            .disabled(providerState.testing || (model.settings.provider == .http && providerState.hasUnsavedKey))
                            if providerState.testing || providerState.signingIn {
                                ProgressView().controlSize(.small)
                            }
                            Text(providerState.testStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                    }
                    .onChange(of: model.settings.provider) { _, provider in
                        providerState.clearSignIn()
                        if provider == .http {
                            providerState.loadKeyIfNeeded(
                                profileID: model.settings.httpProfileID)
                        }
                        providerState.invalidateTest()
                    }
                    .onChange(of: model.settings.httpProfileID) { _, profile in
                        providerState.loadKeyIfNeeded(profileID: profile)
                    }
                    .onChange(of: model.settings.model) { _, _ in
                        providerState.invalidateTest()
                    }
                    .onChange(of: model.settings.endpoint) { _, _ in
                        providerState.invalidateCatalogue()
                        providerState.invalidateTest()
                    }
                    if model.settings.provider == .http,
                        providerState.hasUnsavedKey
                    {
                        Text("Save the key before testing the connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Conversation Context") {
                    Toggle(
                        "Compact automatically when context is large",
                        isOn: $model.settings.autoCompact
                    )
                    TextField(
                        "Compact at characters",
                        value: $model.settings.compactThresholdCharacters,
                        format: .number
                    )
                    .disabled(!model.settings.autoCompact)
                    .help(
                        "An approximate character count, not a model token "
                            + "count. Manual Compact is always available.")
                    Text(
                        "Compaction summarizes older turns for the model. "
                            + "Every original message stays in the transcript; "
                            + "the current page, chapter or book is never "
                            + "shortened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                Section("Chat History") {
                    if let storage = model.conversationStorage {
                        LabeledContent("Stored") {
                            Text(
                                "\(storage.conversations) chats · "
                                    + "\(storage.turns) turns · "
                                    + "\(storage.compactions) summaries")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker(
                        "Keep chats",
                        selection: $model.settings.chatRetentionDays
                    ) {
                        Text("Forever").tag(0)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("365 days").tag(365)
                    }
                    .help(
                        "Old chats are removed only after you review the "
                            + "first cleanup. Saved notes are kept.")
                    .disabled(model.retentionBusy)
                    if model.settings.chatRetentionDays > 0 {
                        HStack(spacing: 8) {
                            Button("Review Old Chats…") {
                                model.reviewChatRetention()
                            }
                            .controlSize(.small)
                            .disabled(model.retentionBusy)
                            if model.retentionBusy {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    Text(
                        "Deleting a chat keeps its saved notes and removes "
                            + "its cards. Compaction summaries are deleted "
                            + "with the chat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Section("Updates") {
                    Toggle(
                        "Check for Updates Automatically",
                        isOn: $updateChecker.automaticallyChecks)
                    LabeledContent("Status") {
                        Text(updateChecker.statusText)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button(
                            updateChecker.isChecking ? "Checking…" : "Check Now"
                        ) { updateChecker.check() }
                        .disabled(updateChecker.isChecking)
                        if updateChecker.availableRelease != nil {
                            Button("View Release") {
                                updateChecker.openReleasePage()
                            }
                        }
                    }
                    Text(
                        "The check asks GitHub for the latest release and "
                            + "sends no library or reading data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert(
            "Remove Old Chats?",
            isPresented: Binding(
                get: { model.retentionImpact != nil },
                set: { if !$0 { model.dismissRetentionImpact() } })
        ) {
            Button("Remove Old Chats", role: .destructive) {
                model.performChatRetention()
            }
            Button("Cancel", role: .cancel) {
                model.dismissRetentionImpact()
            }
        } message: {
            if let impact = model.retentionImpact {
                Text(impact.deletionSentence(includeConversations: true))
            }
        }
        .task { if pane == .ai && model.settings.provider == .http { providerState.loadKeyIfNeeded(profileID: model.settings.httpProfileID) } }
    }

    /// The menu's selection, mapped onto the two stored fields.
    private var providerChoice: Binding<AIProviderChoice> {
        Binding(
            get: {
                let settings = model.settings
                if settings.provider == .http {
                    return .service(AIService.httpProfile(settings).id)
                }
                return .kind(settings.provider)
            },
            set: { choice in
                switch choice {
                case .service(let id):
                    model.settings.provider = .http
                    model.settings.httpProfileID = id
                case .kind(let kind):
                    model.settings.provider = kind
                }
            })
    }

    private var providerNote: String {
        if model.settings.provider == .http {
            return AIService.httpProfile(model.settings).note
                ?? "Any OpenAI-compatible service. The key is kept in the Keychain, one key per service."
        }
        return switch model.settings.provider {
        case .claudeCLI:
            "Uses the local Claude CLI and its existing login."
        case .codexCLI:
            "Uses the local Codex CLI in the app's own home. Sign in once with Sign In."
        case .appleOnDevice:
            "Apple's on-device model. No page leaves this Mac."
        case .http:
            ""
        }
    }

    /// The model field's placeholder: the service's first known model, or a
    /// demand, never an invented default that the service may not serve.
    private var modelPrompt: String {
        guard model.settings.provider == .http else {
            return "Provider default"
        }
        return AIService.httpProfile(model.settings).hints.first
            ?? "Required"
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
