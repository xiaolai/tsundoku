import Foundation
import Testing

@testable import TsundokuCore

@Suite("Capture cleanup")
struct CaptureCleanupTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func folder(
        _ root: URL, _ name: String
    ) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("only unfinished capture folders are listed")
    func listsOnlyUnfinished() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }

        let published = try folder(root, "published")
        try write(#"{"state":"finished","pdf":"book.pdf"}"#,
                  to: published.appendingPathComponent("manifest.json"))

        let incomplete = try folder(root, "incomplete")
        try write(#"{"state":"incomplete"}"#,
                  to: incomplete.appendingPathComponent("manifest.json"))
        try write("page", to: incomplete.appendingPathComponent(
            "pages/page-0001.png"))

        let pagesOnly = try folder(root, "pages-only")
        try write("page", to: pagesOnly.appendingPathComponent(
            "pages/page-0001.png"))

        _ = try folder(root, "unrelated")
        let hidden = try folder(root, ".hidden")
        try write(#"{"state":"incomplete"}"#,
                  to: hidden.appendingPathComponent("manifest.json"))

        let found = CaptureCleanup.abandoned(in: root)
        #expect(
            found.map(\.directory.lastPathComponent).sorted()
                == ["incomplete", "pages-only"])
        #expect(found.allSatisfy { $0.byteCount > 0 })

        try CaptureCleanup.remove(found)
        #expect(!FileManager.default.fileExists(atPath: incomplete.path))
        #expect(!FileManager.default.fileExists(atPath: pagesOnly.path))
        #expect(FileManager.default.fileExists(atPath: published.path))
    }

    @Test("deleting a capture removes its archive row")
    func deletesCaptureRecord() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive(
            path: root.appendingPathComponent("archive.sqlite"))
        let id = try archive.recordCapture(
            asin: "B000000001", title: "A Book",
            directory: root.appendingPathComponent("capture").path,
            pageCount: 2, pdfPath: nil, state: "incomplete")
        #expect(try archive.captures().count == 1)
        try archive.deleteCapture(id: id)
        #expect(try archive.captures().isEmpty)
    }
}
