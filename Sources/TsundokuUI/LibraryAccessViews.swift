import AppKit
import SwiftUI

enum LibraryAppLocation {
    static func requiresInstallation(_ url: URL) -> Bool {
        url.pathExtension.lowercased() != "app" || url.path.hasPrefix("/Volumes/") || url.pathComponents.contains("AppTranslocation")
    }
}

struct LibraryAccessRequestButton: View {
    @ObservedObject var permissions: PermissionsModel
    var title = "Grant Full Disk Access…"
    var resumeSetup = false
    @State private var showGuide = false

    var body: some View {
        Button(title) {
            showGuide = true
            permissions.requestLibraryAccess()
        }
        .disabled(permissions.libraryChecking)
        .background {
            LibraryAccessGuidePresenter(permissions: permissions, isPresented: $showGuide)
                .frame(width: 0, height: 0)
        }
        .onAppear {
            if resumeSetup && permissions.librarySetupPending { showGuide = true }
        }
    }
}

struct LibraryAccessGuidePresenter: View {
    @ObservedObject var permissions: PermissionsModel
    @Binding var isPresented: Bool
    @State private var guideID = UUID()

    var body: some View {
        InspectorPanel(isPresented: $isPresented, title: "Library Access",
            initialSize: NSSize(width: 540, height: 540), keepsVisibleWhenInactive: true) {
            LibraryAccessGuideView(permissions: permissions, onClose: { isPresented = false })
        }
        .onChange(of: isPresented) { _, presented in
            if presented { permissions.claimLibraryGuide(guideID) }
            else { permissions.dismissLibraryGuide(guideID) }
        }
        .onAppear {
            if isPresented { permissions.claimLibraryGuide(guideID) }
        }
        .onChange(of: permissions.activeLibraryGuideID) { _, active in
            if isPresented && active != guideID { isPresented = false }
        }
        .onDisappear { permissions.dismissLibraryGuide(guideID) }
    }
}

struct LibraryAccessRow: View {
    @ObservedObject var permissions: PermissionsModel
    var resumeSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Library Access").font(.subheadline.weight(.semibold))
                Spacer()
                Text(permissions.libraryChecking ? "Checking…" : permissions.libraryStatus.title)
                    .font(.caption).foregroundStyle(.secondary)
                IconButton("Re-check Library Access", systemImage: "arrow.clockwise") {
                    Task { await permissions.verifyLibraryAccess() }
                }.disabled(permissions.libraryChecking)
            }
            HStack {
                Text("Read Kindle and Apple Books libraries.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !permissions.readableLibrarySources.isEmpty {
                    IconButton("Import Library", systemImage: "square.and.arrow.down", action: permissions.importReadableLibrary)
                }
                LibraryAccessRequestButton(permissions: permissions,
                    title: permissions.libraryStatus == .available ? "Full Disk Access…" : "Grant Full Disk Access…",
                    resumeSetup: resumeSetup)
                    .controlSize(.small)
            }
        }
    }
}

struct LibraryAccessGuideView: View {
    @ObservedObject var permissions: PermissionsModel
    let onClose: () -> Void
    private var appURL: URL { Bundle.main.bundleURL }
    private var needsInstallation: Bool { LibraryAppLocation.requiresInstallation(appURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Grant Library Access").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if needsInstallation {
                        Label("Install Tsundoku in Applications first.", systemImage: "externaldrive.badge.exclamationmark")
                        Text("This copy is running from a disk image or a temporary location. Quit, move Tsundoku to Applications, then reopen that copy before granting access.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Show Applications in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
                        }
                    } else {
                        Text("In Full Disk Access, add this app and turn it on.")
                    }
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable().frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tsundoku").font(.headline)
                            Text("Drag into the Full Disk Access list, or use its + button.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .onDrag { needsInstallation ? NSItemProvider() : NSItemProvider(object: appURL as NSURL) }
                    .opacity(needsInstallation ? 0.5 : 1)
                    .accessibilityLabel("Tsundoku app. Drag into Full Disk Access.")
                    Text("If an older Tsundoku entry is listed but access stays blocked, remove it and add this copy.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Return here after enabling access. Your library will be checked and imported automatically. If access stays blocked, quit and reopen Tsundoku below; setup will resume.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Full Disk Access…", action: permissions.requestLibraryAccess)
                            .disabled(needsInstallation)
                        IconButton("Show Tsundoku in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([appURL])
                        }
                        IconButton("Copy App Location", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appURL.path, forType: .string)
                        }
                    }
                    if let error = permissions.librarySettingsError {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if permissions.libraryChecking {
                        ProgressView("Verifying library access…")
                    } else {
                        Label(permissions.libraryStatus.title,
                            systemImage: permissions.libraryStatus == .available ? "checkmark.circle" : "info.circle")
                        if permissions.libraryStatus == .notFound {
                            Text("Open Kindle or Apple Books and download a book before importing.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !permissions.libraryFailures.isEmpty {
                        DisclosureGroup("Check Details") {
                            ForEach(permissions.libraryFailures) { failure in
                                Text("\(failure.source.displayName): \(failure.detail)")
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if permissions.libraryStatus == .blocked && !needsInstallation {
                Button("Quit and Reopen Tsundoku", action: permissions.requestRelaunch)
                    .help("Restart this copy and resume library setup.")
                    .disabled(permissions.relaunchPending)
            }
            HStack {
                Button("Re-check Library Access") {
                    Task { await permissions.verifyLibraryAccess() }
                }.disabled(permissions.libraryChecking)
                Spacer()
                if permissions.libraryStatus == .available {
                    Button("Done", action: onClose).keyboardShortcut(.defaultAction)
                } else {
                    Button("Later", action: onClose).keyboardShortcut(.cancelAction)
                }
            }
        }.padding(24).frame(width: 540, height: 540)
    }
}
