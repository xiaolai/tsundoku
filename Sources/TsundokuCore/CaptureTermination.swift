import Foundation

/// How a finished run's `termination` should be read.
///
/// `termination` is the manifest's word for why a run stopped, and a normal
/// end carries one too ("endOfBook"). Showing that word with a warning icon
/// made every successful capture end in amber, which reads as a failure.
public enum CaptureTermination {
    public enum Outcome: Equatable, Sendable {
        /// The run reached the end of the book.
        case finished
        /// A choice, not a fault: a page limit was reached.
        case note(String)
        /// Something went wrong or was stopped early.
        case problem(String)
    }

    public static func outcome(_ termination: String?) -> Outcome? {
        guard let termination else { return nil }
        let value = termination.trimmingCharacters(in: .whitespaces)
        switch value {
        case "": return nil
        case "endOfBook": return .finished
        case "pageLimit": return .note("Stopped at the page limit")
        case "cancelled": return .problem("Cancelled")
        case "safetyCap": return .problem("Stopped at the safety cap")
        default:
            if value.hasPrefix("failed:") {
                let reason = value.dropFirst("failed:".count)
                return .problem(reason.isEmpty ? "Failed" : "Failed: \(reason)")
            }
            return .problem(value)
        }
    }

    /// A one-line note for the capture list, or nil when there is nothing
    /// worth a line.
    public static func note(_ termination: String) -> String? {
        switch outcome(termination) {
        case .finished: return "Finished."
        case .note(let text), .problem(let text): return text
        case nil: return nil
        }
    }

    /// Whether the run should raise a warning.
    public static func isProblem(_ termination: String) -> Bool {
        if case .problem = outcome(termination) { return true }
        return false
    }
}
