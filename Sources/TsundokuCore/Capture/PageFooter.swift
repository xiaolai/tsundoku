import CoreGraphics
import Foundation
import Vision

/// Removes the reader's printed page-number footer from a captured page.
///
/// Books draws the number into the page image 54 points above the bottom, in
/// both the two-page spread and the A4 single-page layout (measured on
/// macmini-000). Kindle usually draws its number in chrome outside the page
/// crop; if a layout puts a number in the image, the detector below finds a
/// small centered numeric line in the bottom strip and crops above it.
public enum PageCropError: Error, CustomStringConvertible, Sendable {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// A configured page crop. Books uses 54 points as the default bottom (the
/// printed page number); Kindle uses 0, meaning automatic page-number
/// detection. Values are bounded to 0...200 points at the request boundary.
public struct PageCrop: Sendable, Equatable {
    public static let maximumPoints = 200

    public let top: Int
    public let bottom: Int
    public let automaticPageNumber: Bool

    private init(top: Int, bottom: Int, automaticPageNumber: Bool) {
        self.top = top
        self.bottom = bottom
        self.automaticPageNumber = automaticPageNumber
    }

    public static func books(top: Int, bottom: Int?) -> PageCrop {
        PageCrop(
            top: clamp(top),
            bottom: clamp(bottom ?? Int(PageFooter.booksPageNumberInset)),
            automaticPageNumber: false)
    }

    public static func kindle(top: Int, bottom: Int?) -> PageCrop {
        let bottom = clamp(bottom ?? 0)
        return PageCrop(
            top: clamp(top), bottom: bottom,
            automaticPageNumber: bottom == 0)
    }

    public static func books(_ request: PageSetupRequest) -> PageCrop {
        books(top: request.cropTop, bottom: request.cropBottom)
    }

    public static func kindle(_ request: PageSetupRequest) -> PageCrop {
        kindle(top: request.cropTop, bottom: request.cropBottom)
    }

    public var manifest: [String: Any] {
        [
            "top": top,
            "bottom": bottom,
            "automatic": automaticPageNumber,
        ]
    }

    public func validate(pageHeight: CGFloat) throws {
        guard pageHeight.isFinite, pageHeight > 0 else {
            throw PageCropError.invalid("The page height is invalid.")
        }
        guard CGFloat(top + bottom) <= pageHeight - 100 else {
            throw PageCropError.invalid(
                "Crop top \(top) plus bottom \(bottom) leaves no page: "
                    + "the page is \(pageHeight) points high.")
        }
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, 0), maximumPoints)
    }
}

public enum PageFooter {
    /// Points from the bottom of the page to the top of the Books number.
    public static let booksPageNumberInset: CGFloat = 54

    /// Crop the Books footer, preserving the rest of the page. `crop` is the
    /// page rect in points; the image may be Retina-sized.
    public static func removingBooksPageNumber(
        from image: CGImage, crop: CGRect
    ) throws -> CGImage? {
        try removingInsets(
            from: image, crop: crop, topPoints: 0,
            bottomPoints: booksPageNumberInset)
    }

    /// Trim configured top and bottom points from a captured page image.
    /// `crop` is the page rect in points; the image may be Retina-sized.
    /// Returns nil when both insets are zero; throws when the geometry would
    /// remove the page or cannot be represented.
    public static func removingInsets(
        from image: CGImage, crop: CGRect,
        topPoints: CGFloat, bottomPoints: CGFloat
    ) throws -> CGImage? {
        guard crop.height > 0, crop.height.isFinite,
            topPoints.isFinite, bottomPoints.isFinite,
            topPoints >= 0, bottomPoints >= 0
        else {
            throw PageCropError.invalid("The crop values are invalid.")
        }
        let scale = CGFloat(image.height) / crop.height
        guard scale.isFinite, scale > 0 else {
            throw PageCropError.invalid("The page scale is invalid.")
        }
        let topScaled = topPoints * scale
        let bottomScaled = bottomPoints * scale
        guard topScaled <= CGFloat(image.height),
            bottomScaled <= CGFloat(image.height)
        else {
            throw PageCropError.invalid("The crop is larger than the page.")
        }
        guard topScaled > 0 || bottomScaled > 0 else { return nil }
        let top = Int(topScaled.rounded())
        let bottom = Int(bottomScaled.rounded())
        guard top + bottom <= image.height - 100 else {
            throw PageCropError.invalid(
                "Crop top \(top)px plus bottom \(bottom)px leaves no page.")
        }
        guard
            let cropped = image.cropping(
                to: CGRect(
                    x: 0, y: top, width: image.width,
                    height: image.height - top - bottom))
        else {
            throw PageCropError.invalid("The page could not be cropped.")
        }
        return cropped
    }

    /// Kindle: an explicit bottom value replaces automatic detection; zero
    /// keeps detection on. The top value always trims the running header or
    /// margin.
    public static func removingKindleInsets(
        from image: CGImage, crop: CGRect,
        topPoints: CGFloat, bottomPoints: CGFloat
    ) throws -> CGImage? {
        if bottomPoints > 0 {
            return try removingInsets(
                from: image, crop: crop, topPoints: topPoints,
                bottomPoints: bottomPoints)
        }
        guard crop.height > 0, crop.height.isFinite,
            topPoints.isFinite, topPoints >= 0
        else {
            throw PageCropError.invalid("The crop values are invalid.")
        }
        let scale = crop.height > 0
            ? CGFloat(image.height) / crop.height : 1
        guard scale.isFinite, scale > 0 else {
            throw PageCropError.invalid("The page scale is invalid.")
        }
        let topScaled = topPoints * scale
        guard topScaled <= CGFloat(image.height) else {
            throw PageCropError.invalid("The crop is larger than the page.")
        }
        let top = Int(topScaled.rounded())
        guard image.height - top > 100 else {
            throw PageCropError.invalid(
                "Crop top \(top)px leaves no page.")
        }
        let trimmed: CGImage
        if top > 0 {
            guard
                let cropped = image.cropping(
                    to: CGRect(
                        x: 0, y: top, width: image.width,
                        height: image.height - top))
            else {
                throw PageCropError.invalid(
                    "The page could not be cropped.")
            }
            trimmed = cropped
        } else {
            trimmed = image
        }
        if let detected = removingDetectedPageNumber(from: trimmed) {
            return detected
        }
        return top > 0 ? trimmed : nil
    }

    /// Detect a page-number line in the bottom strip of a Kindle page. The
    /// number is small, centered, and numeric-only; body text is not cropped.
    public static func removingDetectedPageNumber(
        from image: CGImage,
        recognize: (CGImage) throws -> [(text: String, box: CGRect)] =
            recognizeText
    ) -> CGImage? {
        // Synthetic test images and thumbnails are not pages; do not run the
        // recognizer on them.
        guard image.width >= 400, image.height >= 500 else { return nil }
        let stripHeight = Int(CGFloat(image.height) * 0.18)
        guard stripHeight > 40,
            let strip = image.cropping(
                to: CGRect(
                    x: 0, y: image.height - stripHeight,
                    width: image.width, height: stripHeight))
        else { return nil }
        guard let observations = try? recognize(strip),
            let number = observations
                .filter({ isPageNumber($0.text, box: $0.box) })
                .max(by: { $0.box.minY < $1.box.minY })
        else { return nil }
        let topInStrip =
            CGFloat(stripHeight) * (1 - number.box.maxY)
        let top = CGFloat(image.height - stripHeight) + topInStrip
        // Keep a small margin above the glyphs and never crop into the body.
        let cut = Int(top.rounded()) - 4
        guard cut > image.height / 2 else { return nil }
        return croppingBottom(image, pixels: image.height - cut)
    }

    private static func croppingBottom(
        _ image: CGImage, pixels: Int
    ) -> CGImage? {
        guard pixels > 0, image.height - pixels > 100 else { return nil }
        return image.cropping(
            to: CGRect(
                x: 0, y: 0, width: image.width,
                height: image.height - pixels))
    }

    private static func isPageNumber(
        _ text: String, box: CGRect
    ) -> Bool {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        let pattern =
            "^(page\\s*|location\\s*)?\\d+(\\s*(of|/)\\s*\\d+)?$"
        guard trimmed.range(of: pattern, options: .regularExpression) != nil
        else { return false }
        // A number is a single short line near the horizontal centre and low
        // in the strip; a list number at the margin is body text.
        return box.height < 0.08
            && box.midX > 0.15 && box.midX < 0.85
            && box.minY < 0.5
    }

    public static func recognizeText(
        _ image: CGImage
    ) throws -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:])
            .perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first
            else { return nil }
            return (candidate.string, observation.boundingBox)
        }
    }
}
