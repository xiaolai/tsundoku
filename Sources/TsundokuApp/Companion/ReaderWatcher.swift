import AppKit
import Foundation
import TsundokuCore

/// Watches the two reader applications and owns the one tracker.
///
/// Focus has two parts: the reader's own AX focused window, and which app is
/// frontmost. The AX focus attribute survives an app switch, so the tracker
/// cannot use it alone to decide the trigger is visible. Tsundoku itself
/// counts as frontmost-eligible: activating the app to type into the panel must
/// not hide that panel (the spike measured Books stealing the first key, and
/// the fix is activation, not hiding).
final class ReaderWatcher {
    var onSnapshot: ((ReaderSnapshot?) -> Void)?
    var onFullScreenChange: ((Bool) -> Void)?
    var onReaderKindChange: ((ReaderKind?) -> Void)?

    var forcedKind: ReaderKind?

    private var tracker: ReaderTracker?
    private var currentKind: ReaderKind?
    private var lastRawSnapshot: ReaderSnapshot?
    private var frontmostEligible = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                guard let app = Self.application(from: note) else { return }
                self?.handleLaunch(app)
            })
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                guard let app = Self.application(from: note) else { return }
                self?.handleTerminate(app)
            })
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                guard let app = Self.application(from: note) else { return }
                self?.handleActivate(app)
            })
        // Library, onboarding and status-menu windows can become key without
        // an application activation. Re-evaluate on either side of that.
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    self?.refreshEligibilityAndEmit()
                })
        }
        refreshFrontmostEligibility()
        selectInitial()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        stopTracker()
    }

    private static func application(from note: Notification)
        -> NSRunningApplication?
    {
        note.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
    }

    // MARK: - Selection

    private func selectInitial() {
        refreshFrontmostEligibility()
        if let forcedKind {
            start(kind: forcedKind, reason: "forced")
            return
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier,
            let kind = ReaderKind.from(bundleID: frontmost)
        {
            start(kind: kind, reason: "frontmost")
            return
        }
        for kind in [ReaderKind.kindle, ReaderKind.appleBooks]
        where ReaderContextLocator.isRunning(kind) {
            start(kind: kind, reason: "running")
            return
        }
    }

    private func start(kind: ReaderKind, reason: String) {
        if currentKind == kind, let tracker {
            tracker.refresh(source: "reader_reactivated")
            return
        }
        stopTracker()
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: kind.bundleID
            ).first
        else {
            TsundokuDiagnostics.shared.event(
                "reader_start_failed",
                ["reader": kind.rawValue, "reason": "not_running"])
            return
        }
        currentKind = kind
        onReaderKindChange?(kind)
        let tracker = ReaderTracker(
            kind: kind, pid: app.processIdentifier)
        tracker.onUpdate = { [weak self] snapshot in
            self?.emit(snapshot)
        }
        tracker.onFailure = { [weak self] reason in
            self?.handleFailure(reason)
        }
        tracker.onFullScreenChange = { [weak self] fullScreen in
            self?.onFullScreenChange?(fullScreen)
        }
        self.tracker = tracker
        tracker.start()
        TsundokuDiagnostics.shared.event(
            "reader_selected",
            [
                "reader": kind.rawValue,
                "pid": Int(app.processIdentifier),
                "reason": reason,
                "active": app.isActive,
            ])
    }

    private func stopTracker() {
        tracker?.stop()
        tracker = nil
        currentKind = nil
        lastRawSnapshot = nil
        onReaderKindChange?(nil)
        onSnapshot?(nil)
    }

    // MARK: - Emission

    private func emit(_ snapshot: ReaderSnapshot) {
        lastRawSnapshot = snapshot
        var adjusted = snapshot
        adjusted.focused = snapshot.focused && frontmostEligible
        onSnapshot?(adjusted)
    }

    private func emitLast() {
        guard let raw = lastRawSnapshot else {
            onSnapshot?(nil)
            return
        }
        emit(raw)
    }

    private func handleFailure(_ reason: String) {
        TsundokuDiagnostics.shared.event(
            "reader_tracking_failed",
            ["reader": currentKind?.rawValue ?? "", "reason": reason])
        lastRawSnapshot = nil
        onSnapshot?(nil)
    }

    private func refreshFrontmostEligibility() {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if bundle == Bundle.main.bundleIdentifier {
            // Tsundoku is eligible while the companion is the reading
            // surface, but not while its library, onboarding or menu window
            // is key. That is what hides the trigger when the library opens.
            frontmostEligible = !Self.otherKeyWindowExists()
            return
        }
        if let forcedKind {
            frontmostEligible = bundle == forcedKind.bundleID
            return
        }
        frontmostEligible = bundle.flatMap(ReaderKind.from(bundleID:)) != nil
    }

    private func refreshEligibilityAndEmit() {
        refreshFrontmostEligibility()
        emitLast()
    }

    /// Any key window that is not the companion itself means the reader is no
    /// longer the surface the user is looking at.
    private static func otherKeyWindowExists() -> Bool {
        NSApp.windows.contains {
            $0.isVisible && $0.isKeyWindow
                && !($0 is CompanionPanelWindow)
        }
    }

    // MARK: - Workspace events

    private func handleLaunch(_ app: NSRunningApplication) {
        guard let kind = app.bundleIdentifier.flatMap({
            ReaderKind.from(bundleID: $0)
        }) else { return }
        if let forcedKind, kind != forcedKind { return }
        if tracker == nil {
            start(kind: kind, reason: "did_launch")
        }
    }

    private func handleTerminate(_ app: NSRunningApplication) {
        guard let kind = app.bundleIdentifier.flatMap({
            ReaderKind.from(bundleID: $0)
        }) else { return }
        guard currentKind == kind else { return }
        TsundokuDiagnostics.shared.event(
            "reader_terminated", ["reader": kind.rawValue])
        stopTracker()
        selectInitial()
    }

    private func handleActivate(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else {
            // Without an identity we cannot claim the frontmost app is a
            // reader; hiding is the safe default.
            frontmostEligible = false
            emitLast()
            return
        }
        if bundleID == Bundle.main.bundleIdentifier {
            // Activating for the ask field keeps the panel; activating a
            // library or onboarding window must not keep the companion over it.
            frontmostEligible = !Self.otherKeyWindowExists()
            emitLast()
            return
        }
        if let kind = ReaderKind.from(bundleID: bundleID) {
            if let forcedKind, kind != forcedKind {
                frontmostEligible = false
                emitLast()
                return
            }
            frontmostEligible = true
            start(kind: kind, reason: "did_activate")
            emitLast()
            return
        }
        frontmostEligible = false
        emitLast()
    }
}
