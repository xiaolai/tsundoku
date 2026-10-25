import CoreGraphics
import Foundation

/// Line pitch read from a row-brightness profile of a page.
///
/// The profile is the mean luminance of each image row across the text
/// column. Text lines appear as runs whose mean departs from the page's
/// background — in either direction, so a light-on-dark theme reads the same
/// as dark-on-light. The profile is smoothed before banding: at 1× a line's
/// ascender and descender rows can be separated by a near-background row, and
/// a raw threshold would count one line as two.
public enum LinePitch {
    public struct Measurement: Equatable, Sendable {
        /// Baseline to baseline, in points.
        public let pitch: CGFloat
        public let bands: Int

        public init(pitch: CGFloat, bands: Int) {
            self.pitch = pitch
            self.bands = bands
        }
    }

    /// A line of type is between 8 and 70 points tall on a reading surface.
    static let pitchRange: ClosedRange<CGFloat> = 8...70
    /// A pitch this far from the median, in either direction, is a paragraph
    /// gap or an artefact rather than a line, and is discarded rather than
    /// averaged in.
    static let outlierFactor: CGFloat = 1.35

    /// `rowMeans` are in 0…255; `scale` converts image pixels to points.
    /// Returns nil rather than a guess when the profile has too little text:
    /// a chapter title page or an illustration is not a typography sample.
    public static func measure(rowMeans: [Double], scale: CGFloat)
        -> Measurement?
    {
        guard rowMeans.count >= 24, scale > 0 else { return nil }
        let radius = max(2, Int((scale * 1.5).rounded()))
        let smoothed = smooth(rowMeans, radius: radius)
        let background = backgroundLevel(smoothed)
        let bands = detectBands(smoothed, background: background)
        guard bands.count >= 5 else { return nil }

        let pitches = (1..<bands.count)
            .map { CGFloat(bands[$0].start - bands[$0 - 1].start) / scale }
            .filter { pitchRange.contains($0) }
        guard pitches.count >= 5 else { return nil }
        var median = medianValue(pitches)
        let refined = pitches.filter {
            $0 >= median / outlierFactor && $0 <= median * outlierFactor
        }
        guard refined.count >= max(3, pitches.count / 2) else { return nil }
        median = medianValue(refined)
        return Measurement(pitch: median, bands: bands.count)
    }

    private static func smooth(_ values: [Double], radius: Int) -> [Double] {
        guard radius > 0, values.count > 2 else { return values }
        let prefix = values.reduce(into: [Double]()) { result, value in
            result.append((result.last ?? 0) + value)
        }
        return (0..<values.count).map { index in
            let low = max(0, index - radius)
            let high = min(values.count - 1, index + radius)
            let sum = prefix[high] - (low > 0 ? prefix[low - 1] : 0)
            return sum / Double(high - low + 1)
        }
    }

    private static func detectBands(_ values: [Double], background: Double)
        -> [(start: Int, end: Int)]
    {
        let threshold = 0.06 * 255
        var bands: [(start: Int, end: Int)] = []
        var start: Int?
        for (index, mean) in values.enumerated() {
            let isText = abs(mean - background) > threshold
            if isText, start == nil { start = index }
            if !isText, let begin = start {
                if index - begin >= 2 { bands.append((begin, index - 1)) }
                start = nil
            }
        }
        if let begin = start, values.count - begin >= 2 {
            bands.append((begin, values.count - 1))
        }
        return bands
    }

    /// The page's own level: the most common row luminance, averaged within
    /// its bin. A percentile would follow the text on a dark page, where the
    /// rows carrying glyphs can outnumber the empty ones. The sampler reports
    /// it alongside a percentile so a profile can be read without guessing
    /// which direction is ink.
    public static func backgroundLevel(_ values: [Double]) -> Double {
        var counts: [Int: Int] = [:]
        for value in values { counts[Int(value / 4), default: 0] += 1 }
        guard let winning = counts.max(by: { $0.value < $1.value })?.key
        else { return 0 }
        let members = values.filter { Int($0 / 4) == winning }
        guard !members.isEmpty else { return 0 }
        return members.reduce(0, +) / Double(members.count)
    }

    static func medianValue(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}
