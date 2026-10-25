import Foundation

/// One text run's face, as Books reports it through `AXFont`.
public struct AXFontSample: Equatable, Sendable {
    public let family: String
    public let size: CGFloat
    /// Characters this sample covers within the fetched excerpt.
    public let characters: Int

    /// Rejects a sample that cannot describe a rendered face: an empty family,
    /// a nonfinite or absurd size (the bucket key converts the size to an
    /// integer, which traps on NaN), or a run with no characters.
    public init?(family: String, size: CGFloat, characters: Int) {
        guard !family.isEmpty, size.isFinite, size >= 1, size <= 400,
            characters > 0
        else { return nil }
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
        func nonEmpty(_ value: Any?) -> String? {
            guard let text = value as? String, !text.isEmpty else { return nil }
            return text
        }
        guard
            let family =
                nonEmpty(font["AXFontName"])
                ?? nonEmpty(font["AXFontFamily"])
        else { return nil }
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
    ///
    /// Sizes are bucketed by their rounded value, and the bucket's exact size
    /// is the one covering the most characters — a one-character run cannot
    /// decide the size of a page. Ties go to the face that appeared first, so
    /// the result never depends on dictionary iteration order.
    public static func bodyFace(from samples: [AXFontSample])
        -> (family: String, size: CGFloat)?
    {
        struct Bucket {
            var family: String
            var total = 0
        }
        var bucketOrder: [String] = []
        var buckets: [String: Bucket] = [:]
        var sizeOrder: [String: [CGFloat]] = [:]
        var sizeWeights: [String: [CGFloat: Int]] = [:]
        for sample in samples {
            let bucket = "\(sample.family)|\(Int(sample.size.rounded()))"
            if buckets[bucket] == nil {
                bucketOrder.append(bucket)
                buckets[bucket] = Bucket(family: sample.family)
                sizeOrder[bucket] = []
                sizeWeights[bucket] = [:]
            }
            buckets[bucket]?.total += sample.characters
            var weights = sizeWeights[bucket] ?? [:]
            if weights[sample.size] == nil {
                sizeOrder[bucket]?.append(sample.size)
            }
            weights[sample.size, default: 0] += sample.characters
            sizeWeights[bucket] = weights
        }
        var bestBucket: String?
        for bucket in bucketOrder {
            let total = buckets[bucket]?.total ?? 0
            if let current = bestBucket,
                let currentTotal = buckets[current]?.total,
                currentTotal >= total
            {
                continue
            }
            bestBucket = bucket
        }
        guard let bestBucket, let family = buckets[bestBucket]?.family
        else { return nil }
        var bestSize: CGFloat?
        for size in sizeOrder[bestBucket] ?? [] {
            let weight = sizeWeights[bestBucket]?[size] ?? 0
            let bestWeight =
                bestSize.flatMap { sizeWeights[bestBucket]?[$0] } ?? 0
            if weight > bestWeight { bestSize = size }
        }
        guard let bestSize else { return nil }
        return (family, bestSize)
    }
}
