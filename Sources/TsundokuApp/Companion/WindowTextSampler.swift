import AppKit
import CoreGraphics
import ScreenCaptureKit
import TsundokuCore

/// Captures one window and reads what the page looks like from its pixels:
/// the line pitch and the background colour.
///
/// Shared by the reader sampler and the typography gate, so the gate exercises
/// the same crop, sampling and measurement the product uses. The image is read
/// and discarded; nothing is written or sent.
@MainActor
enum WindowTextSampler {
    struct Sample: Sendable {
        let measurement: LinePitch.Measurement?
        let theme: ReaderTheme?
        let imageWidth: Int
        let imageHeight: Int
        let rows: Int
        let rowMin: Double
        let rowMax: Double
        let rowP75: Double
        let rowMode: Double
        let sampledPixels: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case drawFailed

        var description: String {
            switch self {
            case .drawFailed:
                "the captured image could not be drawn into a pixel buffer"
            }
        }
    }

    static func sample(of window: SCWindow) async throws -> Sample {
        let captured = try await capture(window)
        guard let drawn = draw(captured.image) else {
            throw Failure.drawFailed
        }
        let pointWidth = captured.pointWidth
        // The per-pixel pass is pure arithmetic over a copied buffer; running
        // it on the main actor would stall the panel for a large window.
        return await Task.detached(priority: .userInitiated) {
            scan(
                pixels: drawn.pixels, width: drawn.width, height: drawn.height,
                pointWidth: pointWidth)
        }.value
    }

    /// The window's own display scale decides the capture size, and the
    /// filter's content rect gives the point width the profile divides by.
    /// `NSScreen.main` describes whichever screen holds the focused window,
    /// which need not be the captured one.
    static func capture(_ window: SCWindow) async throws
        -> (image: CGImage, pointWidth: CGFloat)
    {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let rawScale = CGFloat(filter.pointPixelScale)
        let scale = rawScale > 0 ? rawScale : 1
        let content = filter.contentRect
        let configuration = SCStreamConfiguration()
        configuration.width = Int((content.width * scale).rounded())
        configuration.height = Int((content.height * scale).rounded())
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
        return (image, content.width)
    }

    /// Draws the image into an RGBA buffer. The context is created and used
    /// inside `withUnsafeMutableBytes`: handing `&pixels` to `CGContext` would
    /// leave the context writing through a pointer whose lifetime ended at the
    /// call.
    private static func draw(_ image: CGImage)
        -> (pixels: [UInt8], width: Int, height: Int)?
    {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(
                image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }

    /// The page's text column, minus the chrome bands at the top and bottom,
    /// reduced to one mean per row plus a colour histogram.
    nonisolated static func scan(
        pixels: [UInt8], width: Int, height: Int, pointWidth: CGFloat
    ) -> Sample {
        let empty = Sample(
            measurement: nil, theme: nil, imageWidth: width,
            imageHeight: height, rows: 0, rowMin: 0, rowMax: 0,
            rowP75: 0, rowMode: 0, sampledPixels: 0)
        guard width > 60, height > 60, pointWidth > 0 else { return empty }
        let x0 = width * 12 / 100
        let x1 = width * 88 / 100
        let y0 = height * 8 / 100
        let y1 = height * 92 / 100
        var rowMeans: [Double] = []
        rowMeans.reserveCapacity(y1 - y0)
        var histogram = ColourHistogram()
        var sampled = 0
        for y in y0..<y1 {
            var sum = 0.0
            var count = 0
            for x in stride(from: x0, to: x1, by: 2) {
                let index = (y * width + x) * 4
                let red = pixels[index]
                let green = pixels[index + 1]
                let blue = pixels[index + 2]
                sum +=
                    0.299 * Double(red)
                    + 0.587 * Double(green)
                    + 0.114 * Double(blue)
                count += 1
                histogram.add(red: red, green: green, blue: blue)
                sampled += 1
            }
            rowMeans.append(sum / Double(count))
        }
        let scale = CGFloat(width) / pointWidth
        let sorted = rowMeans.sorted()
        return Sample(
            measurement: LinePitch.measure(rowMeans: rowMeans, scale: scale),
            theme: histogram.theme(sampled: sampled),
            imageWidth: width,
            imageHeight: height,
            rows: rowMeans.count,
            rowMin: sorted.first ?? 0,
            rowMax: sorted.last ?? 0,
            rowP75: sorted[Int(Double(sorted.count) * 0.75)],
            rowMode: LinePitch.backgroundLevel(rowMeans),
            sampledPixels: sampled)
    }
}
