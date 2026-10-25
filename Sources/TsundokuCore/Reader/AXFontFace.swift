import Foundation

/// One text run's face, as Books reports it through `AXFont`.
public struct AXFontSample: Equatable, Sendable {
    public let family: String
    public let size: CGFloat
    public let characters: Int

    public init(family: String, size: CGFloat, characters: Int) {
        self.family = family
        self.size = size
        self.characters = characters
    }
}

public enum AXFontFace {
    /// Reads `kAXFontTextAttribute`, a dictionary on an attributed run. Books
    /// reports a display name ("Charter Roman") and a rendered point size.
    public static func parse(font: [String: Any])
        -> (family: String, size: CGFloat)?
    {
        let family =
            (font["AXFontName"] as? String)
            ?? (font["AXFontFamily"] as? String)
        guard let family, !family.isEmpty else { return nil }
        let size: CGFloat?
        if let number = font["AXFontSize"] as? NSNumber {
            size = CGFloat(number.doubleValue)
        } else if let text = font["AXFontSize"] as? String {
            size = CGFloat(Double(text) ?? 0)
        } else {
            size = nil
        }
        guard let size, size >= 6, size <= 96 else { return nil }
        return (family, size)
    }

    /// The face covering the most characters. Headings and code runs are
    /// outvoted rather than filtered, so no role or style knowledge is needed.
    public static func bodyFace(from samples: [AXFontSample])
        -> (family: String, size: CGFloat)?
    {
        var weights: [String: Int] = [:]
        var faces: [String: (family: String, size: CGFloat)] = [:]
        for sample in samples where sample.characters > 0 {
            let key = "\(sample.family)|\(Int(sample.size.rounded()))"
            weights[key, default: 0] += sample.characters
            faces[key] = (sample.family, sample.size)
        }
        guard let best = weights.max(by: { $0.value < $1.value }),
            let face = faces[best.key]
        else { return nil }
        return face
    }
}
