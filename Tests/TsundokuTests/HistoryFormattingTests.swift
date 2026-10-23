import Foundation
import Testing

@testable import TsundokuCore

struct HistoryFormattingTests {
    @Test(arguments: [
        (0.0, "Less than 1 min"), (59.0, "Less than 1 min"), (60.0, "1 min"),
        (3600.0, "1h 0m"),
    ])
    func duration(_ input: (Double, String)) {
        let start = Date(timeIntervalSince1970: 100)
        let session = ReadingSession(
            id: 1, asin: "B", bookTitle: "Test", startedAt: start,
            endedAt: start.addingTimeInterval(input.0), pageCount: 1)
        #expect(session.durationLabel == input.1)
    }
}
