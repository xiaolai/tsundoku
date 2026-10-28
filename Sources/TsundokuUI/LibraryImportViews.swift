import SwiftUI
import TsundokuCore

struct LibraryEmptyState: View {
    @ObservedObject var model: AppModel
    let annotations: Bool
    let hasImportedRecords: Bool
    let resetFilters: () -> Void

    private var failure: LibraryImportFailure? {
        hasImportedRecords ? nil : model.importFailures.first
    }
    private var title: String {
        if hasImportedRecords { return "No Matches" }
        if model.isImporting { return "Importing Library…" }
        if let failure { return failure.accessDenied ? "Library Access Needed" : "Library Import Failed" }
        return annotations ? "No Annotations Imported" : "No Books Imported"
    }
    private var message: String {
        if hasImportedRecords { return "Try another filter or search." }
        if model.isImporting { return "Reading local Kindle and Apple Books data." }
        if let failure { return failure.summary }
        return model.emptyLibraryMessage
    }

    /// A first run has nothing to filter and no error to explain: it needs to
    /// know what the app is for and which three things to switch on.
    private var isFirstRun: Bool {
        !hasImportedRecords && failure == nil && !model.isImporting
            && model.archive != nil && model.archiveError == nil
    }

    var body: some View {
        Group {
            if let detail = model.archiveError {
                archiveUnavailable(detail)
            } else if model.isHydrating && !hasImportedRecords {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Opening Your Library…").font(.headline)
                    Text(
                        "Reading the local archive. This happens once per "
                            + "launch."
                    )
                    .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isFirstRun {
                SetupChecklist(model: model)
            } else {
                standardState
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var standardState: some View {
        VStack(spacing: 14) {
            if model.isImporting && !hasImportedRecords {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: failure?.accessDenied == true ? "lock" : annotations ? "highlighter" : "book.closed")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if hasImportedRecords {
                Button("Reset Filters", action: resetFilters)
            } else if model.isImporting {
                Button("Cancel Import") { model.cancelLibraryImport() }
            } else if failure != nil {
                HStack {
                    if failure?.accessDenied == true, model.permissions != nil {
                        Button("Grant Library Access…", action: model.requestLibraryAccess)
                        IconButton("Review Import Error", systemImage: "info.circle") { model.showImportReport = true }
                    } else {
                        Button("Review Import Error") { model.showImportReport = true }
                    }
                    IconButton("Retry Import", systemImage: "arrow.clockwise") { model.importLibrary() }
                        .disabled(model.isImporting)
                }
            } else if !model.isImporting {
                Button("Import Library") { model.importLibrary() }
                    .disabled(model.archive == nil)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// An archive that will not open used to look like an empty library with
    /// an Import button that silently did nothing. It says so instead, names
    /// the file, and offers the two actions that can help.
    private func archiveUnavailable(_ detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Library Archive Unavailable").font(.headline)
            Text(
                "Tsundoku could not open its archive, so nothing can be read "
                    + "or saved. The file is not deleted."
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Technical Detail") {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            .frame(maxWidth: 420, alignment: .leading)
            HStack {
                Button("Try Again") { model.reopenArchive() }
                Button("Show in Finder") { model.revealArchiveFile() }
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The first-run checklist. It names what the app does and the three switches
/// it needs, each with the control that sets it, so a new reader does not have
/// to discover Full Disk Access by failing.
struct SetupChecklist: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Tsundoku").font(.title3.bold())
            Text(
                "Tsundoku reads the Kindle and Apple Books libraries on this "
                    + "Mac, keeps your annotations in a local archive, and can "
                    + "ask an AI provider about the page you are reading."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            step(
                title: "Import your library",
                detail: "Reads what Kindle and Apple Books store locally. "
                    + "Nothing leaves this Mac.",
                done: false
            ) {
                Button("Import Library") { model.importLibrary() }
                    .disabled(model.archive == nil)
            }
            step(
                title: "Allow library access",
                detail: "The import needs Full Disk Access. macOS grants it "
                    + "only after a relaunch.",
                done: permissions?.libraryReady
            ) {
                Button("Review Library Access…") {
                    openSettings(.access, focus: .library)
                }
            }
            step(
                title: "Choose an AI provider",
                detail: "An OpenAI-compatible service, the Claude or Codex "
                    + "command line, or the on-device model.",
                done: nil
            ) {
                Button("AI Settings…") { openSettings(.ai) }
            }
            step(
                title: "Allow reader access",
                detail: "Accessibility reads the current page for the "
                    + "companion; Screen Recording is needed by capture.",
                done: permissions?.companionReady
            ) {
                Button("Review Access…") { openSettings(.access) }
            }
        }
        .padding(28)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissions: PermissionsModel? { model.permissions }

    private func openSettings(_ pane: SettingsPane, focus: AccessFocus? = nil) {
        model.openSettingsWindow?(SettingsRoute(pane: pane, focus: focus))
    }

    @ViewBuilder
    private func step(
        title: String, detail: String, done: Bool?,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: done == true
                    ? "checkmark.circle.fill"
                    : done == false ? "circle" : "smallcircle.filled.circle"
            )
            .foregroundStyle(done == true ? Color.green : Color.secondary)
            .font(.body)
            .accessibilityLabel(done == true ? "Done" : "Not done yet")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
                    .controlSize(.small)
            }
        }
    }
}

/// A permission that was revoked during the session must stay visible: the
/// features it breaks fail later, in another window, with a different error.
struct PermissionBanner: View {
    @ObservedObject var model: AppModel
    @State private var dismissed = false

    var body: some View {
        if let permissions = model.permissions {
            ObservedPermissionBanner(
                model: model, permissions: permissions, dismissed: $dismissed)
        }
    }
}

private struct ObservedPermissionBanner: View {
    @ObservedObject var model: AppModel
    @ObservedObject var permissions: PermissionsModel
    @Binding var dismissed: Bool

    private var problems: [String] {
        var problems: [String] = []
        if !permissions.accessibility {
            problems.append("the companion and capture need Accessibility")
        }
        if !permissions.screenRecording {
            problems.append("capture needs Screen Recording")
        }
        if !permissions.libraryReady, !model.books.isEmpty {
            problems.append("library imports need Full Disk Access")
        }
        return problems
    }

    var body: some View {
        if !problems.isEmpty, !dismissed {
            HStack(spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Access is incomplete: \(problems.joined(separator: "; ")).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Review Access…") {
                    model.openSettingsWindow?(SettingsRoute(pane: .access))
                }
                .controlSize(.small)
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide until the app is reopened")
                .accessibilityLabel("Hide access warning")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
        }
    }
}

struct LibraryImportReportView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Library Import").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.isImporting {
                        ProgressView("Reading local libraries…")
                    } else if model.importFailures.isEmpty {
                        Label(model.status, systemImage: "checkmark.circle")
                    }
                    ForEach(model.importFailures) { failure in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(failure.source.displayName).font(.headline)
                            Text(failure.summary)
                            DisclosureGroup("Technical Details") {
                                Text(failure.detail).font(.caption)
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    if model.importFailures.contains(where: \.accessDenied) {
                        Text("Allow access when macOS asks. If access stays blocked, enable Tsundoku in Full Disk Access, then quit and reopen it.")
                        Text("Accessibility and Screen Recording do not grant library access.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Grant Full Disk Access…", action: model.requestLibraryAccess)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Retry Import") { model.importLibrary() }
                    .disabled(model.isImporting)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 540, height: 430)
    }
}

/// The window's own feedback. It sits over the content, has a severity, and
/// keeps failures until dismissed; the sidebar footer stays for import status.
struct BannerView: View {
    @ObservedObject var model: AppModel
    @State private var showLog = false

    var body: some View {
        if let banner = model.banner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: banner.severity))
                    .foregroundStyle(tint(for: banner.severity))
                VStack(alignment: .leading, spacing: 4) {
                    Text(banner.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = banner.detail {
                        DisclosureGroup("Technical Detail") {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                }
                Spacer(minLength: 8)
                if !model.errorLog.isEmpty {
                    Button("Earlier Errors") { showLog = true }
                        .controlSize(.small)
                }
                Button {
                    model.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss message")
                .help("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint(for: banner.severity).opacity(0.35)))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .sheet(isPresented: $showLog) {
                BannerLogView(model: model)
            }
        }
    }

    private func symbol(for severity: AppModel.Banner.Severity) -> String {
        switch severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func tint(for severity: AppModel.Banner.Severity) -> Color {
        switch severity {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct BannerLogView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Earlier Messages").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if model.errorLog.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            } else {
                List(model.errorLog) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            entry.createdAt.formatted(
                                date: .abbreviated, time: .standard)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(entry.text)
                        if let detail = entry.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 320)
    }
}
