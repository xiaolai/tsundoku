import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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

    @Test("a manual folder with pages can be resumed")
    func resumePlanReadsCropAndLastPage() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try folder(root, "manual")
        try writePNG(
            width: 40, height: 60,
            to: capture.appendingPathComponent("pages/page-0001.png"))
        try write(
            """
            {"state":"running","title":"A Book",
             "crop":{"source":"manual","windowLocal":
               {"x":2,"y":3,"width":20,"height":28}},
             "pages":[{"page":1,"characters":5,"source":"accessibility"}],
             "pageCount":1}
            """,
            to: capture.appendingPathComponent("manifest.json"))
        try write(
            #"{"page":1,"characters":5,"text":"alpha","source":"accessibility"}"#,
            to: capture.appendingPathComponent("text.jsonl"))

        let plan = try #require(CaptureCleanup.resumePlan(for: capture))
        #expect(plan.pageCount == 1)
        #expect(plan.title == "A Book")
        #expect(plan.crop.rect == CGRect(x: 2, y: 3, width: 20, height: 28))
        #expect(plan.lastMark.imageHash != 0)
        #expect(CaptureCleanup.abandoned(in: root).first?.resumable == true)
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test("a failed folder reports how many pages it already holds")
    func countsCapturedPages() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try folder(root, "empty")
        #expect(CaptureCleanup.capturedPageCount(in: empty) == 0)
        let started = try folder(root, "started")
        try write("page", to: started.appendingPathComponent(
            "pages/page-0001.png"))
        #expect(CaptureCleanup.capturedPageCount(in: started) == 1)
        #expect(
            CaptureCleanup.capturedPageCount(
                in: root.appendingPathComponent("missing")) == 0)
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
