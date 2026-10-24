import AppKit
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

    var body: some View {
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
        .accessibilityElement(children: .contain)
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
