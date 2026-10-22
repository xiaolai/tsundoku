import AppKit
import ApplicationServices
import Foundation
import KindleAX
import TsundokuCore

/// Tracks one reader window through AX notifications and a 0.25 s fallback.
///
/// The timer only exists while a reader app is tracked, per the plan's energy
/// rule. Window selection is re-run when focus changes so two Books readers
/// and the Books library cannot be confused with each other.
final class ReaderTracker: @unchecked Sendable {
    let kind: ReaderKind
    let pid: pid_t

    var onUpdate: ((ReaderSnapshot) -> Void)?
    var onFailure: ((String) -> Void)?
    var onFullScreenChange: ((Bool) -> Void)?

    private let source = LiveAXSource()
    private var appElement: AXUIElement?
    private var windowElement: AXUIElement?
    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?
    private var last: ReaderSnapshot?
    private var lastFullScreen: Bool?
    private var validatedAt: Date?
    private var observerNotifications: Set<String> = []

    private let windowNotifications: [String] = [
        kAXWindowMovedNotification as String,
        kAXWindowResizedNotification as String,
        kAXWindowMiniaturizedNotification as String,
        kAXWindowDeminiaturizedNotification as String,
        kAXUIElementDestroyedNotification as String,
    ]

    init(kind: ReaderKind, pid: pid_t) {
        self.kind = kind
        self.pid = pid
    }

    func start() {
        let application = AXUIElementCreateApplication(pid)
        appElement = application
        installObserver(application)
        refresh(source: "start")
        let timer = Timer(timeInterval: 0.25, repeats: true) {
            [weak self] _ in
            self?.refresh(source: "timer")
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        TsundokuDiagnostics.shared.event(
            "tracker_start",
            [
                "reader": kind.rawValue, "reader_pid": Int(pid),
                "poll_interval": 0.25,
            ])
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer {
            if let windowElement {
                for name in observerNotifications {
                    AXObserverRemoveNotification(
                        observer, windowElement, name as CFString)
                }
            }
            if let appElement {
                AXObserverRemoveNotification(
                    observer, appElement,
                    kAXFocusedWindowChangedNotification as CFString)
                AXObserverRemoveNotification(
                    observer, appElement,
                    kAXWindowCreatedNotification as CFString)
            }
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        observer = nil
        runLoopSource = nil
        appElement = nil
        windowElement = nil
        observerNotifications.removeAll()
        last = nil
        lastFullScreen = nil
        TsundokuDiagnostics.shared.event(
            "tracker_stop", ["reader": kind.rawValue])
    }

    func refresh(source reason: String) {
        guard let appElement else { return }
        var window = windowElement
        if window == nil || frame(window!) == nil {
            window = readerWindow(application: appElement)
        }
        // A missed focus notification must not leave the tracker on another
        // valid window of the same app.
        if let focused = element(
            attribute(appElement, kAXFocusedWindowAttribute)),
            let current = window, !CFEqual(focused, current),
            isEligibleWindow(focused)
        {
            window = focused
        }
        guard let window else {
            last = nil
            lastFullScreen = nil
            onFailure?("no_window")
            return
        }
        adoptWindow(window)
        // A window can turn into a library in place (Kindle closing its book).
        // Revalidate at a slower cadence than the tracking timer so that is
        // noticed without capturing the tree four times a second.
        if Date().timeIntervalSince(validatedAt ?? .distantPast) > 2 {
            if !isEligibleWindow(window) {
                detachWindow()
                last = nil
                lastFullScreen = nil
                onFailure?("not_reader")
                return
            }
            validatedAt = Date()
        }
        guard
            let axFrame = frame(window),
            let snapshot = snapshot(window: window, axFrame: axFrame)
        else {
            last = nil
            lastFullScreen = nil
            onFailure?("unreadable_window")
            return
        }
        let changed =
            last?.frame != snapshot.frame
            || last?.focused != snapshot.focused
            || last?.minimized != snapshot.minimized
            || last?.fullScreen != snapshot.fullScreen
            || last?.windowNumber != snapshot.windowNumber
            || last?.title != snapshot.title
        if let lastFullScreen, lastFullScreen != snapshot.fullScreen {
            onFullScreenChange?(snapshot.fullScreen)
        }
        lastFullScreen = snapshot.fullScreen
        guard changed else { return }
        last = snapshot
        TsundokuDiagnostics.shared.event(
            "reader_frame",
            [
                "source": reason,
                "reader": kind.rawValue,
                "reader_pid": Int(pid),
                "frame": rectDictionary(snapshot.frame),
                "ax_frame": rectDictionary(axFrame),
                "minimized": snapshot.minimized,
                "fullscreen": snapshot.fullScreen,
                "focused": snapshot.focused,
                "window_number": snapshot.windowNumber.map { Int($0) } ?? -1,
            ])
        onUpdate?(snapshot)
    }

    // MARK: - Window selection

    private func readerWindow(application: AXUIElement) -> AXUIElement? {
        let all = (attribute(application, kAXWindowsAttribute) as? [AXUIElement])
            ?? []
        let standard = all.filter {
            string($0, kAXRoleAttribute) == (kAXWindowRole as String)
        }
        let windows = standard.isEmpty ? all : standard
        guard !windows.isEmpty else { return nil }
        let focused = element(
            attribute(application, kAXFocusedWindowAttribute))

        switch kind {
        case .appleBooks:
            // The reader is the window that carries a web area. Choosing by
            // web-area count alone picked the wrong window when two books
            // were open; the focused window wins first when it qualifies.
            let scored = windows.map {
                (window: $0, areas: webAreaCount($0), area: area($0))
            }
            if let focused,
                scored.contains(where: {
                    CFEqual($0.window, focused) && $0.areas > 0
                })
            {
                return focused
            }
            // No web area means no reader: never anchor to the library.
            return scored.filter { $0.areas > 0 }.max {
                if $0.areas != $1.areas { return $0.areas < $1.areas }
                return $0.area < $1.area
            }?.window
        case .kindle:
            if let focused,
                windows.contains(where: { CFEqual($0, focused) }),
                let frame = frame(focused),
                frame.width >= 300, frame.height >= 300,
                isKindleReader(focused)
            {
                return focused
            }
            let candidates = windows.sorted { area($0) > area($1) }
            return candidates.first(where: isKindleReader)
        }
    }

    private func isEligibleWindow(_ window: AXUIElement) -> Bool {
        switch kind {
        case .appleBooks:
            return webAreaCount(window) > 0
        case .kindle:
            return isKindleReader(window)
        }
    }

    /// Positive identification, not merely a large window: Kindle's library
    /// is a large window too. `ReaderState` says whether a book is open.
    private func isKindleReader(_ window: AXUIElement) -> Bool {
        guard
            let tree = try? AXRecorder(
                source: source, maxDepth: 12, maxNodes: 4_000
            ).capture(window)
        else { return false }
        return tree.readerState != .notReading
    }

    private func adoptWindow(_ window: AXUIElement) {
        if let windowElement, CFEqual(windowElement, window) { return }
        detachWindow()
        windowElement = window
        validatedAt = Date()
        for name in windowNotifications {
            addNotification(window, name)
        }
        TsundokuDiagnostics.shared.event(
            "reader_window_selected",
            [
                "reader": kind.rawValue,
                "title": string(window, kAXTitleAttribute) ?? "",
                "frame": rectDictionary(
                    frame(window).map(appKitRect) ?? .zero),
            ])
    }

    // MARK: - Observer

    private func installObserver(_ application: AXUIElement) {
        var created: AXObserver?
        let error = AXObserverCreate(
            pid,
            { _, element, notification, refcon in
                guard let refcon else { return }
                let tracker = Unmanaged<ReaderTracker>
                    .fromOpaque(refcon).takeUnretainedValue()
                tracker.handle(notification as String, element: element)
            }, &created)
        guard error == .success, let created else {
            TsundokuDiagnostics.shared.event(
                "observer_create_failed",
                ["reader": kind.rawValue, "ax_error": Int(error.rawValue)])
            return
        }
        observer = created
        let source = AXObserverGetRunLoopSource(created)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
        addNotification(
            application, kAXFocusedWindowChangedNotification as String)
        addNotification(
            application, kAXWindowCreatedNotification as String)
        if let window = readerWindow(application: application) {
            adoptWindow(window)
        }
    }

    private func addNotification(
        _ element: AXUIElement, _ name: String
    ) {
        guard let observer else { return }
        let error = AXObserverAddNotification(
            observer, element, name as CFString,
            Unmanaged.passUnretained(self).toOpaque())
        if error == .success || error == .notificationAlreadyRegistered {
            observerNotifications.insert(name)
        } else {
            TsundokuDiagnostics.shared.event(
                "observer_add_failed",
                [
                    "reader": kind.rawValue, "notification": name,
                    "ax_error": Int(error.rawValue),
                ])
        }
    }

    /// Remove this window's notifications before forgetting it. Clearing the
    /// element alone would leave the observer subscribed to the old window.
    private func detachWindow() {
        if let old = windowElement, let observer {
            for name in windowNotifications {
                AXObserverRemoveNotification(
                    observer, old, name as CFString)
            }
        }
        windowElement = nil
        validatedAt = nil
    }

    private func handle(_ name: String, element: AXUIElement) {
        if name == (kAXFocusedWindowChangedNotification as String)
            || name == (kAXWindowCreatedNotification as String)
            || name == (kAXUIElementDestroyedNotification as String)
        {
            if let appElement,
                let window = readerWindow(application: appElement)
            {
                adoptWindow(window)
            }
        }
        refresh(source: "observer")
    }

    // MARK: - Snapshot

    private func snapshot(
        window: AXUIElement, axFrame: CGRect
    ) -> ReaderSnapshot? {
        let application = appElement
        let focusedWindow = application.flatMap {
            element(attribute($0, kAXFocusedWindowAttribute))
        }
        let isFocused = focusedWindow.map { CFEqual($0, window) } ?? false
        let title = string(window, kAXTitleAttribute) ?? ""
        let minimized = bool(window, kAXMinimizedAttribute)
        let fullScreen = bool(window, "AXFullScreen")
        let record = CGWindowMatcher.match(
            ownerPID: pid, bounds: axFrame)
        return ReaderSnapshot(
            kind: kind,
            pid: pid,
            title: title,
            frame: appKitRect(axFrame),
            focused: isFocused,
            minimized: minimized,
            fullScreen: fullScreen,
            windowNumber: record)
    }

    // MARK: - AX reads

    private func attribute(_ element: AXUIElement, _ name: String)
        -> CFTypeRef?
    {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func bool(_ element: AXUIElement, _ name: String) -> Bool {
        guard let value = attribute(element, name) else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard
            let position = attribute(
                element, kAXPositionAttribute),
            CFGetTypeID(position) == AXValueGetTypeID(),
            let size = attribute(element, kAXSizeAttribute),
            CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var value = CGSize.zero
        guard
            AXValueGetValue(position as! AXValue, .cgPoint, &point),
            AXValueGetValue(size as! AXValue, .cgSize, &value)
        else { return nil }
        return CGRect(origin: point, size: value)
    }

    private func area(_ element: AXUIElement) -> CGFloat {
        guard let frame = frame(element) else { return 0 }
        return frame.width * frame.height
    }

    private func webAreaCount(_ window: AXUIElement) -> Int {
        guard
            let tree = try? AXRecorder(
                source: source, maxDepth: 12, maxNodes: 4_000
            ).capture(window)
        else { return 0 }
        var count = 0
        func walk(_ node: AXNode) {
            if node.role == "AXWebArea" { count += 1 }
            for child in node.children { walk(child) }
        }
        walk(tree)
        return count
    }

    // MARK: - Geometry

    private func appKitRect(_ ax: CGRect) -> CGRect {
        let origin = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: ax.origin.x, y: origin - ax.origin.y - ax.height,
            width: ax.width, height: ax.height)
    }

    private func rectDictionary(_ rect: CGRect) -> [String: Double] {
        [
            "x": rect.origin.x, "y": rect.origin.y,
            "width": rect.width, "height": rect.height,
        ]
    }
}

/// The on-screen window number for an AX frame, so diagnostics and clicks can
/// refer to the same window the reader sees.
enum CGWindowMatcher {
    static func match(ownerPID: pid_t, bounds: CGRect) -> UInt32? {
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID)
        guard let list = raw as? [[String: Any]] else { return nil }
        var best: (number: UInt32, distance: CGFloat)?
        for entry in list {
            guard
                let pid = entry[kCGWindowOwnerPID as String] as? Int,
                pid == Int(ownerPID),
                let number = entry[kCGWindowNumber as String] as? UInt32,
                let layer = entry[kCGWindowLayer as String] as? Int,
                layer == 0,
                let dictionary = entry[kCGWindowBounds as String]
                    as? [String: Any],
                let rect = CGRect(
                    dictionaryRepresentation: dictionary as CFDictionary)
            else { continue }
            let distance =
                abs(rect.origin.x - bounds.origin.x)
                + abs(rect.origin.y - bounds.origin.y)
                + abs(rect.width - bounds.width)
                + abs(rect.height - bounds.height)
            if best == nil || distance < best!.distance {
                best = (number, distance)
            }
        }
        guard let best, best.distance <= 8 else { return nil }
        return best.number
    }
}
