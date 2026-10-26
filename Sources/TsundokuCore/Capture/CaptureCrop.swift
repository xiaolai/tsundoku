import CoreGraphics
import Foundation

/// A crop in window-local logical points, top-left origin. It matches the
/// coordinate space of AX frames and `SCWindow.frame`; the conversion to
/// screenshot pixels happens once, in `CropTransform`.
public struct CaptureCrop: Sendable, Equatable, Codable {
    public var rect: CGRect

    public init(rect: CGRect) {
        self.rect = rect
    }

    public static let a4Ratio: CGFloat = 595.28 / 841.89

    public var isUsable: Bool {
        rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 1 && rect.height > 1
    }

    public func clipped(to window: CGRect) -> CaptureCrop {
        let clipped = rect.intersection(window)
        return CaptureCrop(rect: clipped.isNull ? .zero : clipped)
    }

    /// The crop in global screen points, for page identity and manifests.
    public func global(in window: CGRect) -> CGRect {
        rect.offsetBy(dx: window.minX, dy: window.minY)
    }

    /// An A4 crop with the same centre, bounded by the window. The caller
    /// decides whether to use this suggestion; the UI never applies it
    /// silently.
    public func a4Locked(in window: CGRect) -> CaptureCrop {
        let ratio = Self.a4Ratio
        var height = rect.width / ratio
        var width = rect.width
        if height > window.height {
            height = window.height
            width = height * ratio
        }
        if width > window.width {
            width = window.width
            height = width / ratio
        }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var x = centre.x - width / 2
        var y = centre.y - height / 2
        x = min(max(x, window.minX), window.maxX - width)
        y = min(max(y, window.minY), window.maxY - height)
        return CaptureCrop(
            rect: CGRect(x: x, y: y, width: width, height: height))
    }
}

public enum CropTransformError: Error, CustomStringConvertible, Sendable {
    case invalidCrop
    case outsideWindow
    case emptyPixels

    public var description: String {
        switch self {
        case .invalidCrop:
            "The crop has no usable area."
        case .outsideWindow:
            "The crop is outside the captured window."
        case .emptyPixels:
            "The crop is smaller than one captured pixel."
        }
    }
}

/// The one conversion from a window-local crop to screenshot pixels.
///
/// The screenshot's `contentRect` can differ from the AX window frame by the
/// window frame or shadow, so the conversion subtracts the content origin;
/// it never subtracts a fixed title-bar height.
public enum CropTransform {
    public static func pixelRect(
        crop: CaptureCrop, windowFrame: CGRect, contentRect: CGRect,
        imageSize: CGSize
    ) throws -> CGRect {
        guard crop.isUsable else { throw CropTransformError.invalidCrop }
        guard windowFrame.width > 0, windowFrame.height > 0,
            contentRect.width > 0, contentRect.height > 0,
            imageSize.width > 0, imageSize.height > 0
        else { throw CropTransformError.invalidCrop }
        let global = crop.global(in: windowFrame)
        guard global.intersects(contentRect) else {
            throw CropTransformError.outsideWindow
        }
        let scaleX = imageSize.width / contentRect.width
        let scaleY = imageSize.height / contentRect.height
        let local = CGRect(
            x: (global.minX - contentRect.minX) * scaleX,
            y: (global.minY - contentRect.minY) * scaleY,
            width: global.width * scaleX,
            height: global.height * scaleY)
        let bounded = local.intersection(
            CGRect(origin: .zero, size: imageSize))
        let integral = bounded.integral
        guard integral.width >= 1, integral.height >= 1 else {
            throw CropTransformError.emptyPixels
        }
        return integral
    }

    /// The logical crop the pixels represent, after rounding. This is what a
    /// manifest and a preview label should show, not the requested rectangle.
    public static func resolvedCrop(
        crop: CaptureCrop, windowFrame: CGRect, contentRect: CGRect,
        imageSize: CGSize
    ) throws -> CaptureCrop {
        let pixels = try pixelRect(
            crop: crop, windowFrame: windowFrame, contentRect: contentRect,
            imageSize: imageSize)
        let scaleX = contentRect.width / imageSize.width
        let scaleY = contentRect.height / imageSize.height
        return CaptureCrop(
            rect: CGRect(
                x: contentRect.minX + pixels.minX * scaleX - windowFrame.minX,
                y: contentRect.minY + pixels.minY * scaleY - windowFrame.minY,
                width: pixels.width * scaleX,
                height: pixels.height * scaleY))
    }

    public static func croppedImage(
        _ image: CGImage, crop: CGRect
    ) throws -> CGImage {
        guard
            let cropped = image.cropping(
                to: crop.integral.intersection(
                    CGRect(x: 0, y: 0, width: image.width, height: image.height)))
        else { throw CropTransformError.emptyPixels }
        return cropped
    }
}
