import Foundation

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
        let key =
            (Int(red) >> 3) << 10 | (Int(green) >> 3) << 5 | (Int(blue) >> 3)
        var bin = bins[key] ?? Bin()
        bin.count += 1
        bin.red += Int(red)
        bin.green += Int(green)
        bin.blue += Int(blue)
        bins[key] = bin
    }

    /// The dominant colour as a theme, or nil when no colour dominates.
    public func theme(sampled: Int) -> ReaderTheme? {
        guard sampled >= Self.minimumPixels,
            let winner = bins.max(by: { $0.value.count < $1.value.count })?.value
        else { return nil }
        let share = Double(winner.count) / Double(sampled)
        guard share >= Self.minimumShare else { return nil }
        let count = Double(winner.count)
        return ReaderTheme(
            red: Double(winner.red) / count / 255,
            green: Double(winner.green) / count / 255,
            blue: Double(winner.blue) / count / 255,
            share: share)
    }
}
