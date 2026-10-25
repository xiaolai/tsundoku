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
    struct Sample {
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

    static func sample(of window: SCWindow) async throws -> Sample {
        let image = try await capture(window)
        return profile(image, pointWidth: window.frame.width)
    }

    static func capture(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
    }

    /// The page's text column, minus the chrome bands at the top and bottom,
    /// reduced to one mean per row plus a colour histogram.
    static func profile(_ image: CGImage, pointWidth: CGFloat) -> Sample {
        let width = image.width
        let height = image.height
        let empty = Sample(
            measurement: nil, theme: nil, imageWidth: width,
            imageHeight: height, rows: 0, rowMin: 0, rowMax: 0,
            rowP75: 0, rowMode: 0, sampledPixels: 0)
        guard width > 60, height > 60, pointWidth > 0 else { return empty }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return empty }
        context.draw(
            image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let x0 = width * 12 / 100
        let x1 = width * 88 / 100
        let y0 = height * 8 / 100
        let y1 = height * 92 / 100
        guard x1 > x0, y1 > y0 else { return empty }
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
            rowMeans.append(count == 0 ? 0 : sum / Double(count))
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
