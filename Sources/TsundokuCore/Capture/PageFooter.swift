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
public enum PageFooter {
    /// Points from the bottom of the page to the top of the Books number.
    public static let booksPageNumberInset: CGFloat = 54

    /// Crop the Books footer, preserving the rest of the page. `crop` is the
    /// page rect in points; the image may be Retina-sized.
    public static func removingBooksPageNumber(
        from image: CGImage, crop: CGRect
    ) -> CGImage? {
        guard crop.height > 0 else { return nil }
        let scale = CGFloat(image.height) / crop.height
        let pixels = Int((booksPageNumberInset * scale).rounded())
        return croppingBottom(image, pixels: pixels)
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
