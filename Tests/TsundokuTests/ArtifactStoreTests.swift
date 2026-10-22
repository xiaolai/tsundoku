import CoreGraphics
import Foundation
import Testing

@testable import TsundokuCore

@Suite("Capture artifact store")
struct ArtifactStoreTests {
    private func image() throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: 40, height: 60, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CaptureTestError.noImage }
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        guard let image = context.makeImage() else {
            throw CaptureTestError.noImage
        }
        return image
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a published capture directory is refused")
    func refusesCompletedArtifact() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureArtifactStore(output: directory)
        try store.writeManifest([
            "version": 2, "state": "finished", "pdf": "Book.pdf",
        ])
        #expect(throws: CaptureStoreError.self) {
            _ = try CaptureArtifactStore(output: directory)
        }
    }

    @Test("a page commit is visible before the final manifest")
    func commitAndFinish() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureArtifactStore(output: directory)
        let first = try store.commitPage(
            image: try image(), text: "alpha", source: "accessibility")
        let second = try store.commitPage(
            image: try image(), text: "", source: "none")
        try store.writeText()
        try store.writeManifest([
            "version": 2, "state": "running", "termination": "running",
        ])
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(store.pageURLs.count == 2)
        #expect(store.entries.count == 2)

        let data = try Data(
            contentsOf: directory.appendingPathComponent("manifest.json"))
        let running = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(running["state"] as? String == "running")
        #expect(running["pageCount"] as? Int == 2)
        let pages = try #require(running["pages"] as? [[String: Any]])
        #expect(pages[1]["source"] as? String == "none")

        try store.writeManifest([
            "version": 2, "state": "finished", "termination": "endOfBook",
        ])
        let finalData = try Data(
            contentsOf: directory.appendingPathComponent("manifest.json"))
        let final = try #require(
            JSONSerialization.jsonObject(with: finalData) as? [String: Any])
        #expect(final["state"] as? String == "finished")

        let partials = try FileManager.default.contentsOfDirectory(
            atPath: store.pagesDirectory.path
        ).filter { $0.contains(".partial") }
        #expect(partials.isEmpty)
    }

    @Test("an unwritable output fails before a page is committed")
    func unwritableOutput() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)
        #expect(throws: Error.self) {
            _ = try CaptureArtifactStore(output: file)
        }
    }
}

private enum CaptureTestError: Error {
    case noImage
}
