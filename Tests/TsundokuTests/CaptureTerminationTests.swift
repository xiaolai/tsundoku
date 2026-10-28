import Foundation
import Testing

@testable import TsundokuCore

@Suite("Capture termination wording")
struct CaptureTerminationTests {
    @Test("a clean end carries no note and no warning")
    func cleanEnd() {
        #expect(CaptureTermination.note("endOfBook") == nil)
        #expect(!CaptureTermination.isProblem("endOfBook"))
        #expect(CaptureTermination.note("") == nil)
    }

    @Test("a page limit is a choice, not a failure")
    func pageLimit() {
        #expect(CaptureTermination.note("pageLimit") == "Stopped at the page limit")
        #expect(!CaptureTermination.isProblem("pageLimit"))
    }

    @Test("cancellation and the safety cap say so")
    func stops() {
        #expect(CaptureTermination.note("cancelled") == "Cancelled")
        #expect(CaptureTermination.isProblem("cancelled"))
        #expect(
            CaptureTermination.note("safetyCap")
                == "Stopped at the safety cap")
        #expect(CaptureTermination.isProblem("safetyCap"))
    }

    @Test("a failure keeps its reason")
    func failure() {
        #expect(
            CaptureTermination.note("failed:the page did not turn")
                == "Failed: the page did not turn")
        #expect(CaptureTermination.isProblem("failed:anything"))
        #expect(CaptureTermination.note("failed:") == "Failed")
    }
}
