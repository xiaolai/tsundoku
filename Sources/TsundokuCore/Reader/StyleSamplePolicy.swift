import CoreGraphics
import Foundation

/// What the sampler knows about the surface it would measure. Two samples
/// with equal keys are the same book in the same window at the same size, so
/// the type and theme cannot have changed.
public struct StyleSampleKey: Equatable, Sendable {
    public let kind: ReaderKind
    public let pid: Int32
    /// The window number when the tracker has it; two windows of one process
    /// can share a title and a size and still show different type.
    public let windowNumber: UInt32?
    public let width: Int
    public let height: Int
    public let title: String

    public init(
        kind: ReaderKind, pid: pid_t, windowNumber: UInt32?, frame: CGRect,
        title: String
    ) {
        self.kind = kind
        self.pid = pid
        self.windowNumber = windowNumber
        self.width = Int(frame.width.rounded())
        self.height = Int(frame.height.rounded())
        self.title = title
    }
}

public enum StyleSampleDecision: Equatable, Sendable {
    /// The cached sample is for this exact surface and is still fresh.
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
    /// A reader can change its font, size or theme without touching the
    /// window's title or dimensions, so a sample cannot live forever. After
    /// this long the surface is measured again; opening the panel forces the
    /// same refresh.
    public static let maximumAge: TimeInterval = 60

    /// Reuse applies only to the same, fresh surface. A different book, window
    /// or size is never shown the previous sample: within the interval it
    /// waits (the sampler then waits it out), after it, it samples.
    public static func decide(
        now: Date,
        lastAttempt: Date,
        key: StyleSampleKey,
        cachedKey: StyleSampleKey?,
        cachedAt: Date?,
        hasSample: Bool
    ) -> StyleSampleDecision {
        if hasSample, cachedKey == key, let cachedAt,
            now.timeIntervalSince(cachedAt) < maximumAge
        {
            return .reuse
        }
        if now.timeIntervalSince(lastAttempt) < minimumInterval {
            return .wait
        }
        return .sample
    }
}
