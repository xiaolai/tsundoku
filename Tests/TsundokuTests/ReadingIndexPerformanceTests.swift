import Foundation
import Testing

@testable import TsundokuCore

@Suite("Reading index performance")
struct ReadingIndexPerformanceTests {
    @Test("a 300-page capture resolves cold under 1 s and warm under 150 ms")
    func captureCost() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var lines: [String] = []
        var target = ""
        for page in 1...300 {
            let words = (1...180).map { "word\(page)x\($0)" }
            let text = words.joined(separator: " ")
            if page == 150 { target = text }
            let object: [String: Any] = [
                "page": page, "text": text, "source": "accessibility",
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            lines.append(String(decoding: data, as: UTF8.self))
        }
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("text.jsonl"),
            atomically: true, encoding: .utf8)
        let record = CaptureRecord(
            id: 1, asin: "B0PERF0001", title: "Performance",
            directory: directory.path, pageCount: 300, pdfPath: nil,
            createdAt: Date(), state: "complete", source: "kindle",
            identityConfidence: "exact")

        let clock = ContinuousClock()
        let cold = clock.measure {
            let result = ReadingContextResolver.resolve(
                pageText: target, kind: .kindle, title: "Kindle",
                captures: [record])
            #expect(result?.pageNumber == 150)
        }
        var warm: [Duration] = []
        for _ in 1...5 {
            warm.append(
                clock.measure {
                    _ = ReadingContextResolver.resolve(
                        pageText: target, kind: .kindle, title: "Kindle",
                        captures: [record])
                })
        }
        let median = warm.sorted()[warm.count / 2]
        print(
            "300-page capture: cold \(cold.milliseconds) ms, "
                + "warm median \(median.milliseconds) ms")
        #expect(cold < .seconds(1), "cold \(cold)")
        #expect(median < .milliseconds(150), "warm \(median)")
    }
}

extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
