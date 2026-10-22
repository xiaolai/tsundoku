import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A typographic fallback cover. It is deliberately deterministic: no date,
/// no random color, so the same book yields the same bytes.
public enum GeneratedCover {
    public static let pixelSize = CGSize(width: 1200, height: 1800)

    public static func image(
        title: String, author: String?, identifier: String?
    ) -> CGImage? {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)
                    ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(
            CGColor(srgbRed: 0.10, green: 0.13, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(
            CGColor(srgbRed: 0.62, green: 0.48, blue: 0.32, alpha: 1))
        context.fill(CGRect(x: 100, y: 220, width: 8, height: 1400))

        let margin: CGFloat = 160
        let contentWidth = CGFloat(width) - margin - 100
        var top = CGFloat(height) - 220
        let titleText = title.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
            ? "Untitled" : title
        top = draw(
            titleText,
            font: CTFontCreateWithName(
                "Helvetica-Bold" as CFString, 76, nil),
            color: CGColor(
                srgbRed: 0.96, green: 0.93, blue: 0.87, alpha: 1),
            in: CGRect(
                x: margin, y: 0, width: contentWidth, height: top),
            top: top, context: context).nextTop

        if let author, !author.isEmpty {
            top = draw(
                author,
                font: CTFontCreateWithName("Helvetica" as CFString, 40, nil),
                color: CGColor(
                    srgbRed: 0.72, green: 0.78, blue: 0.85, alpha: 1),
                in: CGRect(
                    x: margin, y: 0, width: contentWidth, height: top),
                top: top - 30, context: context).nextTop
        }

        if let identifier, !identifier.isEmpty {
            _ = draw(
                identifier,
                font: CTFontCreateWithName("Helvetica" as CFString, 28, nil),
                color: CGColor(
                    srgbRed: 0.55, green: 0.60, blue: 0.66, alpha: 1),
                in: CGRect(
                    x: margin, y: 70, width: contentWidth, height: 120),
                top: nil, context: context)
        }
        return context.makeImage()
    }

    public static func jpegData(
        title: String, author: String?, identifier: String?,
        quality: CGFloat = 0.9
    ) -> Data? {
        guard let image = image(title: title, author: author,
                                identifier: identifier)
        else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality]
                as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Draw one block from `top` (or pin it to `rect` when `top` is nil) and
    /// return the next top edge.
    private static func draw(
        _ text: String, font: CTFont, color: CGColor, in rect: CGRect,
        top: CGFloat?, context: CGContext
    ) -> (height: CGFloat, nextTop: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                color,
        ]
        let attributed = NSAttributedString(
            string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(
            width: rect.width, height: .greatestFiniteMagnitude)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil, constraint, nil)
        let height = ceil(measured.height) + 4
        let originY = top.map { $0 - height } ?? rect.minY
        let drawRect = CGRect(
            x: rect.minX, y: originY, width: rect.width, height: height)
        let path = CGPath(rect: drawRect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRangeMake(0, 0), path, nil)
        context.saveGState()
        CTFrameDraw(frame, context)
        context.restoreGState()
        return (height, originY)
    }
}
