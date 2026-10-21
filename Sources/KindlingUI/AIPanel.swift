import AppKit
import SwiftUI
import KindlingCore

@MainActor
public final class AIPanelModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case loadingPage
        case loadingAnswer
        case ready
        case failed
    }

    @Published public var pageText = ""
    @Published public var bookTitle = ""
    @Published public var answer = ""
    @Published public var action: AIAction = .explain
    @Published public var question = ""
    @Published public var phase: Phase = .idle
    @Published public var provider = ""
    @Published public var error: String?
    @Published public var saved = false

    private weak var app: AppModel?

    public init(app: AppModel?) {
        self.app = app
    }

    public var excerpt: String {
        let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(420))
    }

    public var characterCount: Int { pageText.count }

    public func loadPage(autoRun: Bool = true) {
        phase = .loadingPage
        answer = ""
        error = nil
        saved = false
        Task {
            do {
                let page = try await Task.detached {
                    try KindleLive.currentPage()
                }.value
                self.pageText = page.text
                self.bookTitle =
                    self.app?.selectedBook?.title
                    ?? (page.title.isEmpty ? "the open book" : page.title)
                if page.text.isEmpty {
                    self.phase = .failed
                    self.error =
                        "This page exposes no text. Image pages need a "
                        + "screenshot or a vision model."
                    return
                }
                self.phase = .idle
                if autoRun {
                    self.run()
                }
            } catch {
                self.phase = .failed
                self.error = "\(error)"
            }
        }
    }

    public func run() {
        guard !pageText.isEmpty else { return }
        let settings = app?.settings ?? .defaults
        let request = AIRequest(
            action: action, pageText: pageText, bookTitle: bookTitle,
            question: question, language: settings.language)
        phase = .loadingAnswer
        answer = ""
        error = nil
        saved = false
        provider = settings.provider.displayName
        Task {
            do {
                let result = try await AIService.answer(
                    for: request, settings: settings)
                self.answer = result.text
                self.provider = result.provider
                self.phase = .ready
            } catch {
                self.error = "\(error)"
                self.phase = .failed
            }
        }
    }

    public func retry() {
        if pageText.isEmpty {
            loadPage()
        } else {
            run()
        }
    }

    public func copy() {
        guard !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    public func save() {
        guard !answer.isEmpty, let archive = app?.archive else { return }
        let settings = app?.settings ?? .defaults
        let request = AIRequest(
            action: action, pageText: pageText, bookTitle: bookTitle,
            question: question, language: settings.language)
        let prompt = AIComposer.prompt(for: request, settings: settings)
        try? archive.saveAISNote(
            asin: app?.selectedBook?.asin, position: nil,
            kind: action.rawValue, prompt: prompt, answer: answer,
            provider: provider)
        saved = true
    }
}

public struct AIPanelView: View {
    @ObservedObject var model: AIPanelModel
    @FocusState private var questionFocused: Bool

    public init(model: AIPanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            pageSection
            actionPicker
            if model.action == .ask {
                questionField
            }
            answerSection
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 560)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.bookTitle.isEmpty
                        ? "Current Page" : model.bookTitle
                )
                .font(.headline)
                .lineLimit(1)
                Text(
                    "Page · \(model.characterCount.formatted()) characters"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.provider.isEmpty ? "Local Page" : model.provider)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                model.loadPage(autoRun: false)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Read the current page again")
            .accessibilityLabel("Reload page")
        }
    }

    private var pageSection: some View {
        Text(model.excerpt.isEmpty ? "Reading the page…" : model.excerpt)
            .lineLimit(5)
            .textSelection(.enabled)
            .foregroundStyle(model.excerpt.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionPicker: some View {
        Picker("Action", selection: $model.action) {
            ForEach(AIAction.allCases, id: \.self) { action in
                Text(action == .define ? "Terms" : action.displayName)
                    .tag(action)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: model.action) { _, action in
            if action == .ask {
                questionFocused = true
            } else {
                model.run()
            }
        }
    }

    private var questionField: some View {
        HStack(spacing: 8) {
            TextField("Ask about this page…", text: $model.question)
                .textFieldStyle(.roundedBorder)
                .focused($questionFocused)
                .onSubmit { model.run() }
            Button("Ask") { model.run() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Answer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.phase == .loadingAnswer
                    || model.phase == .loadingPage
                {
                    ProgressView().controlSize(.small)
                }
            }
            Group {
                switch model.phase {
                case .loadingPage:
                    Text("Reading the current page…")
                        .foregroundStyle(.secondary)
                case .loadingAnswer:
                    Text("Asking \(model.provider)…")
                        .foregroundStyle(.secondary)
                case .failed:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.error ?? "Something went wrong.")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Try Again") { model.retry() }
                    }
                case .ready:
                    ScrollView {
                        MarkdownText(text: model.answer)
                            .textSelection(.enabled)
                            .frame(
                                maxWidth: .infinity, alignment: .leading)
                    }
                case .idle:
                    Text(
                        "Choose an action. Only this page is sent; the rest "
                            + "of the book stays on the Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(
                maxWidth: .infinity, maxHeight: .infinity,
                alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(
                model.provider.isEmpty
                    ? "Current page only"
                    : "Sent: current page · \(model.provider)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy") { model.copy() }
                .controlSize(.small)
                .disabled(model.answer.isEmpty)
            Button(model.saved ? "Saved" : "Save Note") { model.save() }
                .controlSize(.small)
                .disabled(model.answer.isEmpty || model.saved)
        }
    }
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
            Text(attributed)
                .font(.body)
                .lineSpacing(3)
        } else {
            Text(text)
                .font(.body)
                .lineSpacing(3)
        }
    }
}

@MainActor
public final class AIPanelController {
    public static let shared = AIPanelController()
    private var panel: NSPanel?
    private var model: AIPanelModel?

    private init() {}

    public func show(app: AppModel) {
        close()
        let model = AIPanelModel(app: app)
        let hosting = NSHostingView(rootView: AIPanelView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [
                .titled, .closable, .resizable, .nonactivatingPanel,
                .utilityWindow,
            ],
            backing: .buffered, defer: false)
        panel.title = "Reading Companion"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting
        panel.setFrameAutosaveName("KindlingAIPanel")
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
        self.model = model
        model.loadPage()
    }

    public func close() {
        panel?.close()
        panel = nil
        model = nil
    }
}
