import Foundation

/// How a finished run's `termination` should be read.
///
/// `termination` is the manifest's word for why a run stopped, and a normal
/// end carries one too ("endOfBook"). Showing that word with a warning icon
/// made every successful capture end in amber, which reads as a failure.
public enum CaptureTermination {
    /// A one-line note for the capture list, or nil when the run simply
    /// reached the end of the book and needs no note.
    public static func note(_ termination: String) -> String? {
        let value = termination.trimmingCharacters(in: .whitespaces)
        switch value {
        case "", "endOfBook": return nil
        case "pageLimit": return "Stopped at the page limit"
        case "cancelled": return "Cancelled"
        case "safetyCap": return "Stopped at the safety cap"
        default:
            if value.hasPrefix("failed:") {
                let reason = value.dropFirst("failed:".count)
                return reason.isEmpty ? "Failed" : "Failed: \(reason)"
            }
            return value
        }
    }

    /// Whether the note describes a problem rather than a choice.
    public static func isProblem(_ termination: String) -> Bool {
        let value = termination.trimmingCharacters(in: .whitespaces)
        switch value {
        case "", "endOfBook", "pageLimit": return false
        default: return true
        }
    }
}
