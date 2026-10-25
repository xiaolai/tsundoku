import AppKit
import CoreGraphics
import ScreenCaptureKit
import TsundokuCore

/// Samples the reader's typography and colours for the companion panel.
///
/// Books publishes its font through Accessibility; Kindle publishes nothing,
/// so its size and rhythm are measured from a capture of the reading window.
/// The image is read for row brightness and colour and discarded — never
/// written, never sent.
@MainActor
final class ReaderStyleSampler {
    private var cachedKey: StyleSampleKey?
    private var cached: ReaderSample?
    private var cachedAt: Date?
    private var lastAttempt = Date.distantPast

    /// The reader's sample, cached per window and surface. Nil when nothing
    /// could be read or measured; the panel then keeps its own styling.
    ///
    /// A request inside the rate limit waits the limit out rather than being
    /// dropped: a resize burst ends with one last request, and that request
    /// must be the one that samples. `force` discards the cached sample so the
    /// panel can pick up a font or theme change that did not resize anything.
    func sample(for reader: ReaderSnapshot, force: Bool = false) async
        -> ReaderSample?
    {
        let key = StyleSampleKey(
            kind: reader.kind, pid: reader.pid,
            windowNumber: reader.windowNumber, frame: reader.frame,
            title: reader.title)
        if force {
            cachedKey = nil
            cached = nil
            cachedAt = nil
        }
        while !Task.isCancelled {
            switch StyleSamplePolicy.decide(
                now: Date(), lastAttempt: lastAttempt, key: key,
                cachedKey: cachedKey, cachedAt: cachedAt,
                hasSample: cached != nil)
            {
            case .reuse:
                return cached
            case .wait:
                let remaining =
                    StyleSamplePolicy.minimumInterval
                    - Date().timeIntervalSince(lastAttempt)
                if remaining > 0 {
                    try? await Task.sleep(
                        for: .milliseconds(
                            Int((remaining * 1000).rounded(.up))))
                }
            case .sample:
                lastAttempt = Date()
                let sampled = await takeSample(for: reader)
                if let sampled {
                    cachedKey = key
                    cached = sampled
                    cachedAt = Date()
                }
                return sampled
            }
        }
        return nil
    }

    private func takeSample(for reader: ReaderSnapshot) async -> ReaderSample? {
        if reader.kind == .kindle, !kindleChromeIsHidden() { return nil }

        var style: ReaderStyle?
        var theme: ReaderTheme?
        if reader.kind == .appleBooks,
            let face = await BooksLive.liveBodyFace()
        {
            let captured = await captureSample(for: reader)
            theme = captured?.theme
            let pitch =
                captured?.measurement?.pitch
                ?? face.size * MeasuredType.assumedLineHeight
            style = ReaderStyle(
                family: face.family, pointSize: face.size, linePitch: pitch,
                origin: .accessibilityFont)
        } else if let captured = await captureSample(for: reader) {
            theme = captured.theme
            if let measurement = captured.measurement {
                style = ReaderStyle(
                    family: nil,
                    pointSize: MeasuredType.pointSize(
                        forPitch: measurement.pitch),
                    linePitch: measurement.pitch, origin: .measuredPixels)
            }
        }
        guard style != nil || theme != nil else { return nil }
        return ReaderSample(style: style, theme: theme)
    }

    // MARK: - Kindle chrome

    /// A capture is only valid with the Kindle toolbar hidden: the toolbar
    /// changes the text column and would corrupt the profile. The tree walk is
    /// the same one a page load performs, and a sample is rare enough to pay
    /// for it.
    private func kindleChromeIsHidden() -> Bool {
        do {
            let page = try KindleLive.currentPage()
            guard page.isReading else {
                TsundokuDiagnostics.shared.event(
                    "reader_style_capture_skipped",
                    ["reason": "chrome_visible", "state": page.state])
                return false
            }
            return true
        } catch {
            TsundokuDiagnostics.shared.event(
                "reader_style_capture_skipped",
                ["reason": "state_unavailable", "detail": String(describing: error)])
            return false
        }
    }

    // MARK: - Capture

    private func captureSample(for reader: ReaderSnapshot)
        async -> WindowTextSampler.Sample?
    {
        // Never prompt from a background sample: without Screen Recording the
        // panel simply keeps its own styling.
        guard CGPreflightScreenCaptureAccess() else {
            TsundokuDiagnostics.shared.event(
                "reader_style_capture_skipped", ["reason": "no_permission"])
            return nil
        }
        do {
            let content = try await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = matchingWindow(in: content, for: reader),
                window.frame.width > 120, window.frame.height > 120
            else {
                TsundokuDiagnostics.shared.event(
                    "reader_style_capture_skipped",
                    [
                        "reason": "no_window",
                        "windows": content.windows.count,
                        "window_number": Int(reader.windowNumber ?? 0),
                    ])
                return nil
            }
            let sampled = try await WindowTextSampler.sample(of: window)
            var fields: [String: Any] = [
                "image_width": sampled.imageWidth,
                "image_height": sampled.imageHeight,
                "pitch": sampled.measurement.map { Double($0.pitch) } ?? 0,
                "bands": sampled.measurement?.bands ?? 0,
                "rows": sampled.rows,
                "row_min": sampled.rowMin,
                "row_mode": sampled.rowMode,
                "row_p75": sampled.rowP75,
                "row_max": sampled.rowMax,
            ]
            if let theme = sampled.theme {
                fields["theme_red"] = (theme.red * 255).rounded()
                fields["theme_green"] = (theme.green * 255).rounded()
                fields["theme_blue"] = (theme.blue * 255).rounded()
                fields["theme_share"] = theme.share
                fields["theme_dark"] = theme.isDark
            }
            TsundokuDiagnostics.shared.event("reader_style_capture", fields)
            return sampled
        } catch {
            TsundokuDiagnostics.shared.event(
                "reader_style_capture_skipped",
                ["reason": "error", "detail": String(describing: error)])
            return nil
        }
    }

    /// The reader's frame is stored in AppKit coordinates (origin bottom-left
    /// of the primary display); `SCWindow.frame` uses the display coordinate
    /// space (origin top-left). Comparing them directly fails every window
    /// that is not at the top of the primary display.
    private func displayRect(_ appKit: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: appKit.minX, y: top - appKit.maxY, width: appKit.width,
            height: appKit.height)
    }

    private func matchingWindow(
        in content: SCShareableContent, for reader: ReaderSnapshot
    ) -> SCWindow? {
        if let number = reader.windowNumber,
            let exact = content.windows.first(where: {
                $0.windowID == number
            })
        {
            return exact
        }
        // The window number can lag a new scene; fall back to the reader's
        // process and a frame that agrees within a few points.
        let target = displayRect(reader.frame)
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == reader.pid
                && abs($0.frame.minX - target.minX) < 4
                && abs($0.frame.minY - target.minY) < 4
                && abs($0.frame.width - target.width) < 8
                && abs($0.frame.height - target.height) < 8
        }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}
