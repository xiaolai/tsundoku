import Foundation
import TsundokuCore

/// The panel's last resolved typography, so reopening it does not flash.
///
/// Opening the panel builds a new model, and the reader's type arrives from an
/// asynchronous sample a moment later. Between the two, the panel drew its
/// fallback size and then jumped to the sampled one — a re-render the reader
/// sees as a flicker on every open. The last resolved style is remembered per
/// reader and seeded into the new model before the first frame; the fresh
/// sample still runs, and replaces it when it differs.
/// Main-actor state: the panel it feeds is main-actor only, and
/// `CompanionTheme` holds a SwiftUI `Color`.
@MainActor
public struct StyleMemory {
    private var remembered: [ReaderKind: CompanionTextStyle] = [:]
    private var themes: [ReaderKind: CompanionTheme] = [:]

    public init() {}

    public mutating func remember(
        _ style: CompanionTextStyle?, theme: CompanionTheme?,
        for kind: ReaderKind
    ) {
        if let style { remembered[kind] = style }
        if let theme { themes[kind] = theme }
    }

    public func style(for kind: ReaderKind) -> CompanionTextStyle? {
        remembered[kind]
    }

    public func theme(for kind: ReaderKind) -> CompanionTheme? {
        themes[kind]
    }

    /// What a model created for this reader should draw before its sample
    /// lands.
    public func seed(for kind: ReaderKind) -> (
        style: CompanionTextStyle?, theme: CompanionTheme?
    ) {
        (remembered[kind], themes[kind])
    }
}
