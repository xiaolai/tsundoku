import Foundation

/// What to do about Kindle's Popular Highlights marks while capturing.
public enum CleanPagePolicy: String, Sendable, Codable {
    /// Capture the page exactly as it is displayed.
    case asDisplayed
    /// Turn Popular Highlights off for the run and restore the setting after.
    case hidePopularHighlights

    public var hidesPopularHighlights: Bool {
        self == .hidePopularHighlights
    }
}

/// The panel the engine drives for one capture. Injected so the engine can be
/// tested without Kindle.
public struct CleanPageRequest: Sendable {
    public let policy: CleanPagePolicy
    public let panel: any PopularHighlightsPanel
    /// Injectable so a test never writes the real application-support journal.
    public let journal: CleanPageJournal

    public init(
        policy: CleanPagePolicy, panel: any PopularHighlightsPanel,
        journal: CleanPageJournal = CleanPageJournal()
    ) {
        self.policy = policy
        self.panel = panel
        self.journal = journal
    }
}

/// What the clean-page guard did, carried back to the caller.
public struct CleanPageSummary: Sendable, Equatable {
    public let policy: CleanPagePolicy
    public let original: Bool?
    public let final: Bool?
    public let changed: Bool
    public let restored: Bool
    public let reason: String?

    public init(
        policy: CleanPagePolicy, original: Bool?, final: Bool?,
        changed: Bool, restored: Bool, reason: String?
    ) {
        self.policy = policy
        self.original = original
        self.final = final
        self.changed = changed
        self.restored = restored
        self.reason = reason
    }

    public init(
        policy: CleanPagePolicy, begin: CleanPageOutcome,
        restore: CleanPageOutcome?
    ) {
        self.init(
            policy: policy, original: begin.original,
            // A restore that ran but could not read the final state must not
            // report the begin state as if it were observed afterwards.
            final: restore.map { $0.final } ?? begin.final,
            changed: begin.changed,
            restored: restore?.restored ?? !begin.changed,
            reason: restore?.reason ?? begin.reason)
    }
}

extension CleanPageSummary {
    /// The `cleanPage` object written into the capture manifest.
    public var manifest: [String: Any] {
        var object: [String: Any] = [
            "policy": policy.rawValue,
            "washRemoval": false,
            "restore": restored ? "ok" : "failed",
        ]
        switch (policy, changed, restored) {
        case (.asDisplayed, _, _):
            object["popularHighlights"] = "not-requested"
        case (_, false, _):
            object["popularHighlights"] = "already-off"
        case (_, true, true):
            object["popularHighlights"] = "turned-off-then-restored"
        case (_, true, false):
            object["popularHighlights"] = "turned-off-restore-failed"
        }
        object["original"] = original.map { $0 ? "on" : "off" } ?? NSNull()
        object["final"] = final.map { $0 ? "on" : "off" } ?? NSNull()
        object["reason"] = reason ?? NSNull()
        return object
    }

    /// A user-facing sentence for the Exports pane.
    public var note: String? {
        switch (policy, changed, restored) {
        case (.asDisplayed, _, _):
            return nil
        case (_, false, _):
            return "Popular Highlights: already off."
        case (_, true, true):
            return "Popular Highlights: turned off for the capture, then restored."
        case (_, true, false):
            return "Popular Highlights: turned off for the capture and could not "
                + "be restored"
                + (reason.map { ": \($0)." } ?? ".")
        }
    }
}
