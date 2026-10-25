import AppKit
import CoreGraphics
import ScreenCaptureKit
import TsundokuCore

/// Samples the reader's typography for the companion panel.
///
/// Books publishes its font through Accessibility; Kindle publishes nothing,
/// so its size and rhythm are measured from a capture of the reading window.
/// The image is read for row brightness and discarded — never written, never
/// sent.
@MainActor
final class ReaderStyleSampler {
    private var cachedKey: String?
    private var cached: ReaderStyle?
    private var lastAttempt = Date.distantPast
    private let minimumInterval: TimeInterval = 0.75

    /// The reader's style, cached per book window and size. Nil when nothing
    /// could be read or measured; the panel then keeps its own styling.
    func style(for reader: ReaderSnapshot) async -> ReaderStyle? {
        let key = cacheKey(for: reader)
        if key == cachedKey, let cached { return cached }
        guard Date().timeIntervalSince(lastAttempt) >= minimumInterval
        else { return cached }
        lastAttempt = Date()

        if reader.kind == .appleBooks,
            let window = try? BooksLive.readerWindow(),
            let face = BooksLive.bodyFace(in: window)
        {
            let pitch =
                await measuredPitch(for: reader)?.pitch
                ?? face.size * MeasuredType.assumedLineHeight
            let style = ReaderStyle(
                family: face.family, pointSize: face.size, linePitch: pitch,
                origin: .accessibilityFont)
            cachedKey = key
            cached = style
            return style
        }

        guard let measurement = await measuredPitch(for: reader) else {
            return cached
        }
        let style = ReaderStyle(
            family: nil,
            pointSize: MeasuredType.pointSize(forPitch: measurement.pitch),
            linePitch: measurement.pitch, origin: .measuredPixels)
        cachedKey = key
        cached = style
        return style
    }

    /// A new book or a resized window invalidates the sample; a page turn does
    /// not change the type.
    private func cacheKey(for reader: ReaderSnapshot) -> String {
        [
            reader.kind.rawValue,
            String(reader.pid),
            "\(Int(reader.frame.width.rounded()))x\(Int(reader.frame.height.rounded()))",
            reader.title,
        ].joined(separator: "|")
    }

    // MARK: - Capture

    private func measuredPitch(for reader: ReaderSnapshot)
        async -> LinePitch.Measurement?
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
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            let measurement = profile(image, pointWidth: window.frame.width)
            TsundokuDiagnostics.shared.event(
                "reader_style_capture",
                [
                    "image_width": image.width,
                    "image_height": image.height,
                    "pitch": measurement.map { Double($0.pitch) } ?? 0,
                    "bands": measurement?.bands ?? 0,
                ])
            return measurement
        } catch {
            TsundokuDiagnostics.shared.event(
                "reader_style_capture_skipped",
                ["reason": "error", "detail": String(describing: error)])
            return nil
        }
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
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == reader.pid
                && abs($0.frame.minX - reader.frame.minX) < 4
                && abs($0.frame.minY - reader.frame.minY) < 4
                && abs($0.frame.width - reader.frame.width) < 8
                && abs($0.frame.height - reader.frame.height) < 8
        }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The page's text column, minus the chrome bands at the top and bottom,
    /// reduced to one mean per row.
    private func profile(_ image: CGImage, pointWidth: CGFloat)
        -> LinePitch.Measurement?
    {
        let width = image.width
        let height = image.height
        guard width > 60, height > 60, pointWidth > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(
            image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let x0 = width * 12 / 100
        let x1 = width * 88 / 100
        let y0 = height * 8 / 100
        let y1 = height * 92 / 100
        guard x1 > x0, y1 > y0 else { return nil }
        var rowMeans: [Double] = []
        rowMeans.reserveCapacity(y1 - y0)
        for y in y0..<y1 {
            var sum = 0.0
            var count = 0
            for x in stride(from: x0, to: x1, by: 2) {
                let index = (y * width + x) * 4
                sum +=
                    0.299 * Double(pixels[index])
                    + 0.587 * Double(pixels[index + 1])
                    + 0.114 * Double(pixels[index + 2])
                count += 1
            }
            rowMeans.append(count == 0 ? 0 : sum / Double(count))
        }
        let scale = CGFloat(width) / pointWidth
        let sorted = rowMeans.sorted()
        TsundokuDiagnostics.shared.event(
            "reader_style_profile",
            [
                "rows": rowMeans.count,
                "min": sorted.first ?? 0,
                "row_mode": LinePitch.backgroundLevel(rowMeans),
                "row_p75": sorted[Int(Double(sorted.count) * 0.75)],
                "max": sorted.last ?? 0,
            ])
        return LinePitch.measure(rowMeans: rowMeans, scale: scale)
    }
}
