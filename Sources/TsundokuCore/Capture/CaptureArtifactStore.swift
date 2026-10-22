import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CaptureStoreError: Error, CustomStringConvertible, Sendable {
    case completedArtifact(URL)
    case io(String)

    public var description: String {
        switch self {
        case .completedArtifact(let url):
            "The output directory already holds a published capture: "
                + url.path
        case .io(let message):
            "The capture store could not write: \(message)"
        }
    }
}

/// Owns the on-disk capture directory. Each page is staged, moved into place,
/// then appended to `text.jsonl` and recorded in a running manifest before the
/// next page. A crash therefore leaves a state a resume can inspect, not a
/// manifest that already claims the whole book.
public final class CaptureArtifactStore {
    public let output: URL
    public let pagesDirectory: URL
    public private(set) var pageURLs: [URL] = []
    public private(set) var entries: [[String: Any]] = []

    public init(output: URL) throws {
        self.output = output
        self.pagesDirectory = output.appendingPathComponent("pages")
        // Writing into a published capture would replace its manifest with a
        // failure and orphan the PDF. Refuse before anything is written.
        let manifest = output.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifest),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            object["pdf"] != nil
        {
            throw CaptureStoreError.completedArtifact(output)
        }
        try FileManager.default.createDirectory(
            at: pagesDirectory, withIntermediateDirectories: true)
    }

    public func commitPage(
        image: CGImage, text: String, source: String
    ) throws -> URL {
        let index = pageURLs.count + 1
        let final = pagesDirectory.appendingPathComponent(
            String(format: "page-%04d.png", index))
        let partial = pagesDirectory.appendingPathComponent(
            ".page-\(index)-\(UUID().uuidString).partial.png")
        defer { try? FileManager.default.removeItem(at: partial) }
        try Self.writePNG(image, to: partial)
        try move(partial, to: final)
        pageURLs.append(final)
        let entry: [String: Any] = [
            "page": index,
            "characters": text.count,
            "text": text,
            "source": source,
        ]
        entries.append(entry)
        try appendText(entry)
        return final
    }

    /// Rewrite `text.jsonl` from the in-memory entries. Each page is already
    /// appended on commit; this is the final, gap-free copy.
    public func writeText() throws {
        var lines: [String] = []
        for entry in entries {
            let data = try JSONSerialization.data(
                withJSONObject: entry, options: [.sortedKeys])
            lines.append(String(decoding: data, as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: output.appendingPathComponent("text.jsonl"),
            atomically: true, encoding: .utf8)
    }

    public func writeManifest(_ base: [String: Any]) throws {
        var manifest = base
        // The page text lives in text.jsonl. Embedding it here made the
        // running manifest quadratic in the book's length.
        manifest["pages"] = entries.map { entry -> [String: Any] in
            var page = entry
            page.removeValue(forKey: "text")
            return page
        }
        manifest["pageCount"] = entries.count
        let data = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: output.appendingPathComponent("manifest.json"),
            options: .atomic)
    }

    private func appendText(_ entry: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: entry, options: [.sortedKeys])
        let url = output.appendingPathComponent("text.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(
                atPath: url.path, contents: nil)
            else {
                throw CaptureStoreError.io("could not create text.jsonl")
            }
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw CaptureStoreError.io("could not open text.jsonl: \(error)")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            throw CaptureStoreError.io("could not append text.jsonl: \(error)")
        }
    }

    private func move(_ from: URL, to: URL) throws {
        do {
            try FileManager.default.moveItem(at: from, to: to)
        } catch {
            throw CaptureStoreError.io(
                "could not move \(from.lastPathComponent): \(error)")
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw CaptureStoreError.io(
                "could not create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureStoreError.io(
                "could not write \(url.lastPathComponent)")
        }
    }
}
