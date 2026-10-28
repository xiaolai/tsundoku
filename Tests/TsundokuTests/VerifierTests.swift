import CoreGraphics
import Foundation
import Testing

@testable import TsundokuCore

@Suite("Capture verifier")
struct VerifierTests {
    private func image() throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: 40, height: 60, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw VerifierTestError.noImage }
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        guard let image = context.makeImage() else {
            throw VerifierTestError.noImage
        }
        return image
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(
        _ directory: URL, texts: [String]
    ) throws -> CaptureArtifactStore {
        let store = try CaptureArtifactStore(output: directory)
        for text in texts {
            _ = try store.commitPage(
                image: try image(), text: text, source: "accessibility")
        }
        try store.writeText()
        return store
    }

    private func publish(
        _ store: CaptureArtifactStore, texts: [String], in directory: URL
    ) throws -> String {
        let artifact = CaptureArtifact(
            directory: directory, pageURLs: store.pageURLs, texts: texts,
            metadata: CaptureMetadata(
                title: "A Book", author: nil, identifier: nil,
                source: "Kindle"),
            // The verifier counts the index from the manifest; these tests
            // pin the book's own pagination, so they publish without one.
            termination: .endOfBook, includePageIndex: false)
        return try PDFPublisher().publish(artifact).url.lastPathComponent
    }

    @Test("a complete capture verifies structurally and as a whole book")
    func completeCapture() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let texts = ["alpha", "beta"]
        let store = try store(directory, texts: texts)
        let pdf = try publish(store, texts: texts, in: directory)
        try store.writeManifest([
            "version": 2, "termination": "endOfBook", "startPage": 1,
            "pdf": pdf,
            "complete": [
                "requestedRange": true, "structural": true,
                "wholeBook": true,
            ],
        ])
        let report = try CaptureVerifier.verify(directory: directory)
        #expect(report.structural)
        #expect(report.requestedRange)
        #expect(report.wholeBook)
        #expect(report.faults.isEmpty)
    }

    @Test("ending at the book end is not whole-book if capture began midway")
    func wholeBookRequiresStart() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let texts = ["alpha", "omega"]
        let store = try store(directory, texts: texts)
        let pdf = try publish(store, texts: texts, in: directory)
        try store.writeManifest([
            "version": 2, "termination": "endOfBook", "startPage": 50,
            "pdf": pdf,
        ])
        let report = try CaptureVerifier.verify(directory: directory)
        #expect(report.structural)
        #expect(report.requestedRange)
        #expect(!report.wholeBook)
    }

    @Test("a missing published PDF is a structural fault")
    func missingPDF() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(directory, texts: ["alpha"])
        let artifact = CaptureArtifact(
            directory: directory, pageURLs: store.pageURLs,
            texts: ["alpha"],
            metadata: CaptureMetadata(
                title: "A Book", author: nil, identifier: nil,
                source: "Kindle"),
            termination: .endOfBook, includePageIndex: false)
        let published = try PDFPublisher().publish(artifact)
        try store.writeManifest([
            "version": 2, "termination": "endOfBook", "startPage": 1,
            "pdf": published.url.lastPathComponent,
        ])
        #expect(try CaptureVerifier.verify(directory: directory).structural)
        try FileManager.default.removeItem(at: published.url)
        let after = try CaptureVerifier.verify(directory: directory)
        #expect(!after.structural)
    }

    @Test("a missing middle page is a structural fault")
    func missingPage() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(directory, texts: ["a", "b", "c"])
        try FileManager.default.removeItem(at: store.pageURLs[1])
        try store.writeManifest([
            "version": 2, "termination": "endOfBook",
        ])
        let report = try CaptureVerifier.verify(directory: directory)
        #expect(!report.structural)
        #expect(report.faults.contains { $0.contains("missing") })
        #expect(!report.wholeBook)
    }

    @Test("a suffix is not a whole book")
    func partialSuffix() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pages = directory.appendingPathComponent("pages")
        try FileManager.default.createDirectory(
            at: pages, withIntermediateDirectories: true)
        let sourceStore = try CaptureArtifactStore(
            output: directory.appendingPathComponent("source"))
        let sourceURL = try sourceStore.commitPage(
            image: try image(), text: "", source: "none")
        let data = try Data(contentsOf: sourceURL)
        for index in [2, 3] {
            let url = pages.appendingPathComponent(
                String(format: "page-%04d.png", index))
            try data.write(to: url)
        }
        let manifest: [String: Any] = [
            "version": 2, "pageCount": 2, "termination": "pageLimit",
            "pages": [
                ["page": 2, "text": "two"],
                ["page": 3, "text": "three"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: directory.appendingPathComponent("manifest.json"))
        let report = try CaptureVerifier.verify(directory: directory)
        #expect(!report.structural)
        #expect(!report.wholeBook)
    }

    @Test("a mid-sentence seam is a candidate, not a fatal fault")
    func seamCandidate() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let texts = ["The quick brown", "fox jumps."]
        let store = try store(directory, texts: texts)
        let pdf = try publish(store, texts: texts, in: directory)
        try store.writeManifest([
            "version": 2, "termination": "endOfBook", "startPage": 1,
            "pdf": pdf,
        ])
        let report = try CaptureVerifier.verify(directory: directory)
        #expect(report.structural)
        #expect(report.seamCandidates.count == 1)
        #expect(report.seamCandidates[0].leftPage == 1)
        #expect(report.seamCandidates[0].rightPage == 2)
    }

    @Test("an empty manifest is not structurally complete")
    func emptyManifest() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONSerialization.data(withJSONObject: [
            "version": 2, "pageCount": 0, "termination": "endOfBook",
            "pages": [],
        ]).write(
            to: directory.appendingPathComponent("manifest.json"))
        let report = try CaptureVerifier.verify(directory: directory)
        #expect(!report.structural)
        #expect(!report.wholeBook)
    }

    @Test("a malformed manifest is refused")
    func malformedManifest() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("manifest.json"))
        #expect(throws: VerifierError.self) {
            _ = try CaptureVerifier.verify(directory: directory)
        }
    }

}

private enum VerifierTestError: Error {
    case noImage
}
