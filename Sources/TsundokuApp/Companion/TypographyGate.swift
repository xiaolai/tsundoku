import AppKit
import ImageIO
import ScreenCaptureKit
import SwiftUI
import TsundokuCore
import TsundokuUI

/// `--typography-gate`: prove the measurer on a window whose type and colours
/// are known before the fact, then prove the panel paints the measured theme.
///
/// The page is drawn with 20 pt type on a 26 pt pitch, first black on white
/// then white on black; the capture path, the crop, the row profile and the
/// colour histogram are the same code the product runs. The panel check hosts
/// the real `CompanionPanelView` with the measured dark theme and asserts the
/// captured background. The gate exits non-zero unless every check passes.
@MainActor
enum TypographyGate {
    static let pointSize: CGFloat = 20
    static let linePitch: CGFloat = 26
    static let lineCount = 12
    /// Where the panel screenshot lands, for the record beside the numbers.
    static let panelPath = "/tmp/tsundoku-typography-panel.png"

    static func run() {
        Task { @MainActor in
            let (pages, panel) = await measure()
            let report = GateReport(
                pages: pages, panel: panel,
                pass: pages.allSatisfy(\.passed) && panel.passed)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(report),
                let text = String(data: data, encoding: .utf8)
            {
                print(text)
            }
            exit(report.pass ? 0 : 1)
        }
    }

    private struct GateReport: Encodable {
        let pages: [GateResult]
        let panel: PanelResult
        let pass: Bool
    }

    private struct GateResult: Encodable {
        let page: String
        let pitch: Double
        let bands: Int
        let share: Double
        let dark: Bool
        let rgb: [Int]
        let passed: Bool
        let note: String?
    }

    private struct PanelResult: Encodable {
        let expectedDark: Bool
        let capturedDark: Bool
        let passed: Bool
        let note: String?
    }

    private static func measure() async -> ([GateResult], PanelResult) {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Typography gate"
        let view = GatePageView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let light = await capture(
            window: window, view: view, page: "light",
            background: .white, ink: .black, dark: false)
        let darkSample = await sample(
            window: window, view: view,
            background: .black, ink: .white)
        let dark = result(
            page: "dark", sample: darkSample, dark: true)
        let panel = await panelCheck(from: darkSample?.theme)
        return ([light, dark], panel)
    }

    private static func capture(
        window: NSWindow, view: GatePageView, page: String,
        background: NSColor, ink: NSColor, dark: Bool
    ) async -> GateResult {
        let sampled = await sample(
            window: window, view: view, background: background, ink: ink)
        return result(page: page, sample: sampled, dark: dark)
    }

    private static func sample(
        window: NSWindow, view: GatePageView,
        background: NSColor, ink: NSColor
    ) async -> WindowTextSampler.Sample? {
        view.background = background
        view.ink = ink
        view.needsDisplay = true
        window.display()
        try? await Task.sleep(for: .milliseconds(400))
        do {
            guard let window = try await shareableWindow(
                number: window.windowNumber)
            else { return nil }
            return try await WindowTextSampler.sample(of: window)
        } catch {
            return nil
        }
    }

    private static func result(
        page: String, sample: WindowTextSampler.Sample?, dark: Bool
    ) -> GateResult {
        let failure: (String) -> GateResult = { note in
            GateResult(
                page: page, pitch: 0, bands: 0, share: 0, dark: false,
                rgb: [0, 0, 0], passed: false, note: note)
        }
        guard let sample else { return failure("window_or_capture_failed") }
        let pitch = sample.measurement?.pitch ?? 0
        let bands = sample.measurement?.bands ?? 0
        guard let theme = sample.theme else { return failure("no_theme") }
        let rgb = [
            Int((theme.red * 255).rounded()),
            Int((theme.green * 255).rounded()),
            Int((theme.blue * 255).rounded()),
        ]
        let colourMatches = dark
            ? rgb.allSatisfy { $0 <= 38 }
            : rgb.allSatisfy { $0 >= 217 }
        let passed =
            abs(pitch - linePitch) <= 1
            && bands >= 10
            && theme.share >= 0.5
            && theme.isDark == dark
            && colourMatches
        return GateResult(
            page: page, pitch: Double(pitch), bands: bands,
            share: theme.share, dark: theme.isDark, rgb: rgb,
            passed: passed, note: nil)
    }

    /// Host the product's panel with the measured dark theme and check that
    /// the captured background is dark. The screenshot is kept for the record.
    private static func panelCheck(from theme: ReaderTheme?) async -> PanelResult {
        guard let theme, theme.isDark else {
            return PanelResult(
                expectedDark: true, capturedDark: false, passed: false,
                note: "no_dark_theme_measured")
        }
        let model = AIPanelModel(app: nil)
        model.bookTitle = "Typography gate"
        model.provider = "Gate"
        model.pageText = String(
            repeating: "The quick brown fox jumps over the lazy dog. ", count: 20)
        model.answer = """
            The page measured near-black behind light type, so the panel \
            takes the same background and switches its own text to the dark \
            appearance. This paragraph exists to show the panel's contrast.
            """
        model.readerKind = .kindle
        model.theme = CompanionTheme(theme)
        model.phase = .ready

        let host = NSHostingView(
            rootView: CompanionPanelView(
                model: model, compact: false, onActivate: {}, onClose: {}))
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(800))

        do {
            guard let shareable = try await shareableWindow(
                number: window.windowNumber)
            else {
                return PanelResult(
                    expectedDark: true, capturedDark: false, passed: false,
                    note: "panel_window_not_found")
            }
            let image = try await WindowTextSampler.capture(shareable)
            save(image, to: panelPath)
            let corner = pixel(image, x: image.width / 2, y: 6)
            let luminance =
                0.299 * Double(corner.0) / 255
                + 0.587 * Double(corner.1) / 255
                + 0.114 * Double(corner.2) / 255
            let capturedDark = luminance < ReaderTheme.darkThreshold
            return PanelResult(
                expectedDark: true, capturedDark: capturedDark,
                passed: capturedDark, note: panelPath)
        } catch {
            return PanelResult(
                expectedDark: true, capturedDark: false, passed: false,
                note: String(describing: error))
        }
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int)
        -> (UInt8, UInt8, UInt8)
    {
        // CGImage pixel space has its origin at the top left, matching the
        // screen coordinates the gate samples elsewhere.
        guard
            let cropped = image.cropping(
                to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return (0, 0, 0) }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard
            let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (0, 0, 0) }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }

    private static func save(_ image: CGImage, to path: String) {
        guard
            let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString,
                1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func shareableWindow(number: Int) async throws -> SCWindow? {
        for _ in 0..<4 {
            let content = try await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let match = content.windows.first(where: {
                $0.windowID == UInt32(number)
            }) {
                return match
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        return nil
    }
}

/// The gate page: identical lines on a known pitch, drawn top-left in a
/// flipped view so each line's box starts exactly `linePitch` below the last.
private final class GatePageView: NSView {
    var background: NSColor = .white
    var ink: NSColor = .black

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: TypographyGate.pointSize),
            .foregroundColor: ink,
        ]
        let line = "The quick brown fox jumps over the lazy dog 0123456789"
        for index in 0..<TypographyGate.lineCount {
            (line as NSString).draw(
                at: NSPoint(
                    x: 40,
                    y: 40 + CGFloat(index) * TypographyGate.linePitch),
                withAttributes: attributes)
        }
    }
}
