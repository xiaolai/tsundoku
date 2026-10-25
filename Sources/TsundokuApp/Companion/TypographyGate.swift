import AppKit
import ImageIO
import ScreenCaptureKit
import SwiftUI
import TsundokuCore
import TsundokuUI

/// `--typography-gate`: prove the measurer on a window whose type and colours
/// are known before the fact, then prove the panel paints each measured theme.
///
/// The page is drawn with 20 pt type on a 26 pt pitch, first black on white
/// then white on black; the capture path, the crop, the row profile and the
/// colour histogram are the same code the product runs. Each panel check hosts
/// the real `CompanionPanelView` with a measured theme under the opposite host
/// appearance and asserts the captured background, so a panel that ignores the
/// theme cannot pass. The gate exits non-zero unless every check passes.
@MainActor
enum TypographyGate {
    static let pointSize: CGFloat = 20
    static let linePitch: CGFloat = 26
    static let lineCount = 12

    static func run() {
        Task { @MainActor in
            let report = await measure()
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
        let panels: [PanelResult]
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
        let page: String
        let expectedRgb: [Int]
        let capturedRgb: [Int]
        let passed: Bool
        let note: String?
    }

    private static func measure() async -> GateReport {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Typography gate"
        let view = GatePageView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let light = await pageResult(
            window: window, view: view, page: "light",
            background: .white, ink: .black, dark: false)
        let dark = await pageResult(
            window: window, view: view, page: "dark",
            background: .black, ink: .white, dark: true)
        var panels: [PanelResult] = []
        let stamp = String(UUID().uuidString.prefix(8))
        if let theme = light.theme {
            panels.append(
                await panelCheck(
                    theme: theme, page: "light", dark: false, stamp: stamp))
        }
        if let theme = dark.theme {
            panels.append(
                await panelCheck(
                    theme: theme, page: "dark", dark: true, stamp: stamp))
        }
        let pass =
            light.result.passed && dark.result.passed
            && panels.count == 2 && panels.allSatisfy(\.passed)
        return GateReport(
            pages: [light.result, dark.result], panels: panels, pass: pass)
    }

    /// A measured page plus the raw theme the panel check needs.
    private static func pageResult(
        window: NSWindow, view: GatePageView, page: String,
        background: NSColor, ink: NSColor, dark: Bool
    ) async -> (result: GateResult, theme: ReaderTheme?) {
        view.background = background
        view.ink = ink
        view.needsDisplay = true
        window.display()
        try? await Task.sleep(for: .milliseconds(400))
        do {
            guard let window = try await shareableWindow(
                number: window.windowNumber)
            else {
                return (failure(page, "window_not_found"), nil)
            }
            let sample = try await WindowTextSampler.sample(of: window)
            let theme = sample.theme
            let pitch = sample.measurement?.pitch ?? 0
            let bands = sample.measurement?.bands ?? 0
            guard let theme else {
                return (failure(page, "no_theme"), nil)
            }
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
            return (
                GateResult(
                    page: page, pitch: Double(pitch), bands: bands,
                    share: theme.share, dark: theme.isDark, rgb: rgb,
                    passed: passed, note: nil),
                theme
            )
        } catch {
            return (failure(page, String(describing: error)), nil)
        }
    }

    private static func failure(_ page: String, _ note: String) -> GateResult {
        GateResult(
            page: page, pitch: 0, bands: 0, share: 0, dark: false,
            rgb: [0, 0, 0], passed: false, note: note)
    }

    /// Host the product's panel with the measured theme under the opposite
    /// host appearance, then compare the captured background with the measured
    /// colour. The screenshot is kept for the record; a failure to write it
    /// fails the check rather than leaving stale evidence behind.
    private static func panelCheck(
        theme: ReaderTheme, page: String, dark: Bool, stamp: String
    ) async -> PanelResult {
        let expected = [
            Int((theme.red * 255).rounded()),
            Int((theme.green * 255).rounded()),
            Int((theme.blue * 255).rounded()),
        ]
        let failure: (String) -> PanelResult = { note in
            PanelResult(
                page: page, expectedRgb: expected, capturedRgb: [],
                passed: false, note: note)
        }
        let model = AIPanelModel(app: nil)
        model.bookTitle = "Typography gate"
        model.provider = "Gate"
        model.pageText = String(
            repeating: "The quick brown fox jumps over the lazy dog. ", count: 20)
        model.turns = [
            AITurn(
                action: .explain, question: "",
                answer: """
                    The page measured near-black behind light type, so the \
                    panel takes the same background and switches its own text \
                    to the dark appearance. This paragraph exists to show the \
                    panel's contrast.
                    """,
                provider: "Gate", prompt: "")
        ]
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
        // The panel must follow the page, not the host: a dark page is proven
        // under a light appearance and a light page under a dark one.
        window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(800))

        do {
            guard let shareable = try await shareableWindow(
                number: window.windowNumber)
            else { return failure("panel_window_not_found") }
            let captured = try await WindowTextSampler.capture(shareable)
            guard let pixel = self.pixel(captured.image, x: captured.image.width / 2, y: 6)
            else { return failure("pixel_unreadable") }
            guard pixel.alpha >= 250 else {
                return failure("pixel_transparent")
            }
            let capturedRGB = [Int(pixel.red), Int(pixel.green), Int(pixel.blue)]
            // A fresh path per run: a failure can never leave the previous
            // run's screenshot looking like this run's evidence.
            let path = "/tmp/tsundoku-typography-panel-\(page)-\(stamp).png"
            guard save(captured.image, to: path) else {
                return failure("panel_screenshot_not_saved")
            }
            let matches = zip(expected, capturedRGB).allSatisfy {
                abs($0 - $1) <= 10
            }
            return PanelResult(
                page: page, expectedRgb: expected, capturedRgb: capturedRGB,
                passed: matches, note: path)
        } catch {
            return failure(String(describing: error))
        }
    }

    /// The pixel at a point, or nil when it cannot be read. Alpha is returned
    /// with the colour: a transparent pixel is not a background.
    private static func pixel(_ image: CGImage, x: Int, y: Int)
        -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)?
    {
        guard
            let cropped = image.cropping(
                to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    private static func save(_ image: CGImage, to path: String) -> Bool {
        guard
            let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString,
                1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
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
