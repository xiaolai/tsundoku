import Foundation
import Testing

@Suite("Capture import boundary")
struct ImportBoundaryTests {
    private let engineFiles = [
        "Capture.swift",
        "Capture/CaptureContracts.swift",
        "Capture/CaptureJobEngine.swift",
        "Capture/CaptureArtifactStore.swift",
        "Capture/ImageFingerprint.swift",
        "Capture/Verifier.swift",
        "Capture/CapturePublisher.swift",
        "Capture/PDFPublisher.swift",
        "Capture/Lifecycle.swift",
    ]

    private let forbidden = [
        "import AppKit",
        "import ApplicationServices",
        "import ScreenCaptureKit",
        "import Vision",
        "import KindleAX",
    ]

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TsundokuCore")
    }

    private func problems(in directory: URL, files: [String]) throws
        -> [String]
    {
        var found: [String] = []
        for file in files {
            let url = directory.appendingPathComponent(file)
            let text = try String(contentsOf: url, encoding: .utf8)
            for importLine in forbidden where text.contains(importLine) {
                found.append("\(file): \(importLine)")
            }
        }
        return found
    }

    @Test("engine files do not import reader or capture frameworks")
    func engineImports() throws {
        let found = try problems(in: sourceRoot, files: engineFiles)
        #expect(found.isEmpty, "\(found)")
    }

    @Test("a deliberate forbidden import is detected")
    func deliberateImport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "import ScreenCaptureKit\n".write(
            to: directory.appendingPathComponent("Fake.swift"),
            atomically: true, encoding: .utf8)
        let found = try problems(in: directory, files: ["Fake.swift"])
        #expect(found.count == 1)
    }
}
