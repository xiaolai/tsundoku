import CoreGraphics
import Foundation

/// Keeps an unattended capture awake and refuses to photograph a locked or
/// sleeping session. The lock predicate is injectable so the engine can be
/// tested without changing the machine's session.
public struct CaptureLifecycle: Sendable {
    private let locked: @Sendable () -> Bool

    public init(
        locked: @escaping @Sendable () -> Bool = CaptureLifecycle.screenIsLocked
    ) {
        self.locked = locked
    }

    public func checkReady() throws {
        if locked() { throw ReaderCaptureError.screenLocked }
    }

    public func begin() -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "Tsundoku PDF capture")
    }

    public func end(_ activity: NSObjectProtocol?) {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    public static func screenIsLocked() -> Bool {
        guard
            let session = CGSessionCopyCurrentDictionary()
                as? [String: Any]
        else { return false }
        // The public CGSession header does not expose a lock key; this is the
        // session-dictionary key macOS has used for the lock state. A missing
        // key is treated as unlocked, and the host acceptance test is the
        // proof, not this lookup alone.
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
