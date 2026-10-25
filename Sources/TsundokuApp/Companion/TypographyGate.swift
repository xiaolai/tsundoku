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
            let rgb = rgb(theme)
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

    private static func rgb(_ theme: ReaderTheme) -> [Int] {
        [
            Int((theme.red * 255).rounded()),
            Int((theme.green * 255).rounded()),
            Int((theme.blue * 255).rounded()),
        ]
    }

    /// The panel model the gate renders. Built once so the assertion flow in
    /// `panelCheck` stays about the capture, not about fixture details.
    private static func fixtureModel(theme: ReaderTheme) -> AIPanelModel {
        let model = AIPanelModel(app: nil)
        model.bookTitle = "Typography gate"
        model.provider = "Gate"
        model.pageText = String(
            repeating: "The quick brown fox jumps over the lazy dog. ",
            count: 20)
        model.turns = [
            AITurn(
                action: .explain, question: "",
                answer: """
                    The page measured near-black behind light type, so the \
                    panel takes the same background and switches its own text \
                    to the dark appearance. This paragraph exists to show the \
                    panel's contrast.
                    """,
                provider: "Gate", prompt: "",
                context: AIContext(
                    bookTitle: "Gate", reader: .kindle,
                    pageNumber: 12, pageCount: 320,
                    excerpt: model.pageText))
        ]
        model.context = AIContext(
            bookTitle: "Gate", reader: .kindle, pageNumber: 12,
            pageCount: 320, excerpt: model.pageText)
        model.readerKind = .kindle
        model.theme = CompanionTheme(theme)
        model.phase = .ready
        return model
    }

    /// Host the product's panel with the measured theme under the opposite
    /// host appearance, then compare the captured background with the measured
    /// colour. The screenshot is kept for the record; a failure to write it
    /// fails the check rather than leaving stale evidence behind.
    private static func panelCheck(
        theme: ReaderTheme, page: String, dark: Bool, stamp: String
    ) async -> PanelResult {
        let expected = rgb(theme)
        let failure: (String) -> PanelResult = { note in
            PanelResult(
                page: page, expectedRgb: expected, capturedRgb: [],
                passed: false, note: note)
        }
        let panel: HostedPanel
        switch await capturePanel(theme: theme, dark: dark) {
        case .failed(let note):
            return failure(note)
        case .captured(let captured):
            panel = captured
        }
        defer { panel.window.orderOut(nil) }
        guard
            let pixel = self.pixel(
                panel.image, x: panel.image.width / 2, y: 6)
        else { return failure("pixel_unreadable") }
        guard pixel.alpha >= 250 else {
            return failure("pixel_transparent")
        }
        let capturedRGB = [Int(pixel.red), Int(pixel.green), Int(pixel.blue)]
        // A fresh path per run: a failure can never leave the previous
        // run's screenshot looking like this run's evidence.
        let path = "/tmp/tsundoku-typography-panel-\(page)-\(stamp).png"
        guard save(panel.image, to: path) else {
            return failure("panel_screenshot_not_saved")
        }
        // A background that follows the theme is not enough: text that kept
        // the host appearance would be unreadable while the colour check
        // above still passed. Require neutral text pixels with a readable
        // contrast against that background.
        guard let contrast = textContrast(
            panel.image, background: capturedRGB),
            contrast >= 4.5
        else { return failure("text_contrast_low") }
        let matches = zip(expected, capturedRGB).allSatisfy {
            abs($0 - $1) <= 10
        }
        return PanelResult(
            page: page, expectedRgb: expected, capturedRgb: capturedRGB,
            passed: matches, note: path)
    }

    private struct HostedPanel {
        let window: NSWindow
        let image: CGImage
    }

    private enum PanelCapture {
        case captured(HostedPanel)
        case failed(String)
    }

    /// Host the panel under the opposite appearance and capture it. Window
    /// setup and capture live together; the caller owns only the assertions.
    private static func capturePanel(
        theme: ReaderTheme, dark: Bool
    ) async -> PanelCapture {
        let model = fixtureModel(theme: theme)
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
        do {
            try await Task.sleep(for: .milliseconds(800))
            guard
                let shareable = try await shareableWindow(
                    number: window.windowNumber)
            else {
                window.orderOut(nil)
                return .failed("panel_window_not_found")
            }
            let captured = try await WindowTextSampler.capture(shareable)
            return .captured(HostedPanel(window: window, image: captured.image))
        } catch {
            window.orderOut(nil)
            return .failed(String(describing: error))
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

    /// The best WCAG contrast ratio between the measured background and a
    /// neutral (text-like) pixel in the panel's middle band. Accent fills are
    /// excluded by chroma so a coloured button cannot stand in for text.
    private static func textContrast(
        _ image: CGImage, background: [Int]
    ) -> Double? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
            background.count == 3,
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(
            image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let backgroundLuminance = luminance(
            Double(background[0]) / 255, Double(background[1]) / 255,
            Double(background[2]) / 255)
        var best = 0.0
        var qualifying = 0
        var rows = Set<Int>()
        for y in stride(from: height / 4, to: height * 3 / 4, by: 2) {
            for x in stride(from: width / 8, to: width * 7 / 8, by: 2) {
                let offset = y * context.bytesPerRow + x * 4
                let red = bytes[offset]
                let green = bytes[offset + 1]
                let blue = bytes[offset + 2]
                let alpha = bytes[offset + 3]
                guard alpha >= 250 else { continue }
                let spread =
                    Int(max(red, max(green, blue)))
                    - Int(min(red, min(green, blue)))
                guard spread <= 16 else { continue }
                let value = luminance(
                    Double(red) / 255, Double(green) / 255,
                    Double(blue) / 255)
                let ratio =
                    (max(backgroundLuminance, value) + 0.05)
                    / (min(backgroundLuminance, value) + 0.05)
                best = max(best, ratio)
                if ratio >= 4.5 {
                    qualifying += 1
                    rows.insert(y)
                }
            }
        }
        // One icon, border or stray pixel is not readable text: require a
        // body of high-contrast neutral pixels spread over several lines.
        guard qualifying >= 50, rows.count >= 3 else { return 0 }
        return best
    }

    private static func luminance(
        _ red: Double, _ green: Double, _ blue: Double
    ) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green)
            + 0.0722 * channel(blue)
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
