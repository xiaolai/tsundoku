import CoreGraphics
import Foundation

/// What the sampler knows about the surface it would measure. Two samples
/// with equal keys are the same book in the same window at the same size, so
/// the type and theme cannot have changed.
public struct StyleSampleKey: Equatable, Sendable {
    public let kind: ReaderKind
    public let pid: Int32
    public let width: Int
    public let height: Int
    public let title: String

    public init(
        kind: ReaderKind, pid: pid_t, frame: CGRect, title: String
    ) {
        self.kind = kind
        self.pid = pid
        self.width = Int(frame.width.rounded())
        self.height = Int(frame.height.rounded())
        self.title = title
    }
}

public enum StyleSampleDecision: Equatable, Sendable {
    /// The cached sample is for this exact surface.
    case reuse
    /// Too soon to sample again; show nothing rather than another book's type.
    case wait
    case sample
}

/// The sampler's cache policy, kept pure so the rule can be tested without a
/// reader, a screen or a clock.
public enum StyleSamplePolicy {
    /// Sampling costs a screen capture; a burst of window events must not
    /// become a burst of captures.
    public static let minimumInterval: TimeInterval = 0.75

    /// Reuse applies only to the same surface. A different book, window or
    /// size is never shown the previous sample: within the interval it waits
    /// (the panel keeps its own styling), after it, it samples.
    public static func decide(
        now: Date,
        lastAttempt: Date,
        key: StyleSampleKey,
        cachedKey: StyleSampleKey?,
        hasSample: Bool
    ) -> StyleSampleDecision {
        if hasSample, cachedKey == key { return .reuse }
        if now.timeIntervalSince(lastAttempt) < minimumInterval {
            return .wait
        }
        return .sample
    }
}
