/// The reading page's own colours, measured from the same capture that
/// supplies the pitch.
///
/// Only the background is taken. The panel tints itself with it and switches
/// its semantic colours to match, so the answer reads as part of the page
/// instead of as a white card beside a dark one. `share` is the evidence: a
/// photographed or illustrated page has no dominant background, and a theme
/// built on it would be a guess.
public struct ReaderTheme: Equatable, Sendable {
    /// The dominant background colour, 0…1 per channel.
    public let red: Double
    public let green: Double
    public let blue: Double
    /// The fraction of sampled pixels that colour covers.
    public let share: Double
    /// True for a page whose background carries light-on-dark text.
    public let isDark: Bool

    /// Below this luminance the page is a dark theme. sRGB grey 0.45 sits
    /// between every light theme measured (above 0.85) and every dark one
    /// (below 0.2), so the exact value is not load-bearing.
    public static let darkThreshold: Double = 0.45

    public init(red: Double, green: Double, blue: Double, share: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.share = share
        isDark =
            0.299 * red + 0.587 * green + 0.114 * blue < Self.darkThreshold
    }
}

/// Counts quantised pixel colours until one colour clearly wins.
///
/// The quantisation is five bits per channel: enough to tell white, sepia and
/// black apart, coarse enough that antialiasing and dithering stay in one bin.
/// Dominance is judged on each bin merged with its immediate neighbours, not
/// on the raw bins: a background sitting on a quantisation boundary (239 and
/// 240 land in different bins) splits into equal parts that no single bin
/// wins. A tie between merged colours that are not neighbours is no theme at
/// all: the page has no dominant level.
public struct ColourHistogram: Sendable {
    private struct Bin {
        var count = 0
        var red = 0
        var green = 0
        var blue = 0
    }

    private var bins: [Int: Bin] = [:]
    /// The share the winning colour must hold for the page to have a theme.
    public static let minimumShare = 0.35
    /// A sample this small cannot establish a dominant colour.
    public static let minimumPixels = 1_000

    public init() {}

    public mutating func add(red: UInt8, green: UInt8, blue: UInt8) {
        let key = ColourHistogram.key(red: red, green: green, blue: blue)
        var bin = bins[key] ?? Bin()
        bin.count += 1
        bin.red += Int(red)
        bin.green += Int(green)
        bin.blue += Int(blue)
        bins[key] = bin
    }

    static func key(red: UInt8, green: UInt8, blue: UInt8) -> Int {
        (Int(red) >> 3) << 10 | (Int(green) >> 3) << 5 | (Int(blue) >> 3)
    }

    static func components(_ key: Int) -> (red: Int, green: Int, blue: Int) {
        ((key >> 10) & 31, (key >> 5) & 31, key & 31)
    }

    /// The dominant colour as a theme, or nil when no colour dominates.
    public func theme(sampled: Int) -> ReaderTheme? {
        guard sampled >= Self.minimumPixels, !bins.isEmpty else { return nil }
        // For every cell of the quantised cube, the total of the occupied bins
        // within one index on each channel. One pass over the bins fills the
        // 27 cells each bin belongs to; no quadratic scan over bins.
        var counts: [Int: Int] = [:]
        var sums: [Int: (red: Int, green: Int, blue: Int)] = [:]
        for (key, bin) in bins {
            let parts = ColourHistogram.components(key)
            for redOffset in -1...1 {
                let red = parts.red + redOffset
                guard (0..<32).contains(red) else { continue }
                for greenOffset in -1...1 {
                    let green = parts.green + greenOffset
                    guard (0..<32).contains(green) else { continue }
                    for blueOffset in -1...1 {
                        let blue = parts.blue + blueOffset
                        guard (0..<32).contains(blue) else { continue }
                        let cell = red << 10 | green << 5 | blue
                        counts[cell, default: 0] += bin.count
                        var sum = sums[cell] ?? (0, 0, 0)
                        sum.red += bin.red
                        sum.green += bin.green
                        sum.blue += bin.blue
                        sums[cell] = sum
                    }
                }
            }
        }
        guard let bestCount = counts.values.max() else { return nil }
        let winners = counts.filter { $0.value == bestCount }
        guard let first = winners.min(by: { $0.key < $1.key }) else {
            return nil
        }
        // Cells two indices apart still share at least one neighbour, so all
        // of a single colour's winning cells are the same colour. A tie
        // between colours further apart means there is no dominant level, and
        // letting hashing decide would make the panel's appearance unstable.
        let center = ColourHistogram.components(first.key)
        for key in winners.keys {
            let parts = ColourHistogram.components(key)
            guard abs(parts.red - center.red) <= 2,
                abs(parts.green - center.green) <= 2,
                abs(parts.blue - center.blue) <= 2
            else { return nil }
        }
        let share = Double(bestCount) / Double(sampled)
        guard share >= Self.minimumShare, let sum = sums[first.key] else {
            return nil
        }
        let count = Double(bestCount)
        return ReaderTheme(
            red: Double(sum.red) / count / 255,
            green: Double(sum.green) / count / 255,
            blue: Double(sum.blue) / count / 255,
            share: share)
    }
}
