import Foundation
import ImageIO

/// A capture directory whose manifest did not publish a PDF. These are the
/// folders a failed or interrupted run leaves behind; published captures are
/// never included.
public struct AbandonedCapture: Identifiable, Sendable, Equatable {
    public let directory: URL
    public let byteCount: Int64
    public let modifiedAt: Date
    /// Pages the failed run wrote. A resumable folder continues after them.
    public let pageCount: Int
    public let resumable: Bool

    public var id: String { directory.path }

    public init(
        directory: URL, byteCount: Int64, modifiedAt: Date,
        pageCount: Int = 0, resumable: Bool = false
    ) {
        self.directory = directory
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.pageCount = pageCount
        self.resumable = resumable
    }
}

public struct CaptureResumePlan: Sendable {
    public let directory: URL
    public let crop: CaptureCrop
    public let pageCount: Int
    /// The cropped image of the last stored page. A resumed run starts only
    /// when the reader shows this page, so the transcript cannot skip or
    /// duplicate a page across two runs.
    public let lastMark: PageMark
    public let title: String

    public init(
        directory: URL, crop: CaptureCrop, pageCount: Int,
        lastMark: PageMark, title: String
    ) {
        self.directory = directory
        self.crop = crop
        self.pageCount = pageCount
        self.lastMark = lastMark
        self.title = title
    }
}

public enum CaptureCleanup {
    /// What a failed folder needs to continue. A folder without a reviewed
    /// window-local crop (an older automated capture) or without pages is
    /// not resumable.
    public static func resumePlan(for directory: URL) -> CaptureResumePlan? {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            manifest["pdf"] == nil
        else { return nil }
        let crop = manifest["crop"] as? [String: Any]
        guard let cropObject = crop?["windowLocal"] as? [String: Any],
            let x = cropObject["x"] as? Double,
            let y = cropObject["y"] as? Double,
            let width = cropObject["width"] as? Double,
            let height = cropObject["height"] as? Double,
            width > 1, height > 1,
            let pages = manifest["pages"] as? [[String: Any]],
            !pages.isEmpty,
            let last = pages.last,
            let index = last["page"] as? Int
        else { return nil }
        let pageURL = directory.appendingPathComponent("pages")
            .appendingPathComponent(String(format: "page-%04d.png", index))
        guard
            let source = CGImageSourceCreateWithURL(pageURL as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return CaptureResumePlan(
            directory: directory,
            crop: CaptureCrop(
                rect: CGRect(x: x, y: y, width: width, height: height)),
            pageCount: pages.count,
            lastMark: PageMark(
                imageHash: ImageFingerprint.detailHash(image), text: ""),
            title: manifest["title"] as? String ?? "Book")
    }

    /// Pages already written to a capture folder. Zero means the run failed
    /// before it captured anything, so its shell holds nothing to recover.
    public static func capturedPageCount(in directory: URL) -> Int {
        let pages = directory.appendingPathComponent("pages")
        return ((try? FileManager.default.contentsOfDirectory(
            atPath: pages.path)) ?? []).filter {
                $0.hasPrefix("page-") && $0.hasSuffix(".png")
            }.count
    }

    /// Direct children of the export root that look like an unfinished
    /// capture: a manifest without a published PDF, or a `pages/` directory
    /// without a manifest. A finished manifest with a PDF is never listed.
    public static func abandoned(in root: URL) -> [AbandonedCapture] {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles])
        else { return [] }
        return entries.compactMap { url in
            guard
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
            else { return nil }
            let manifest = manifest(at: url)
            let pages = url.appendingPathComponent("pages")
            guard manifest != nil || manager.fileExists(atPath: pages.path)
            else { return nil }
            let state = manifest?["state"] as? String
            if state == "finished" { return nil }
            let pdf = manifest?["pdf"] as? String
            if state != "incomplete", let pdf, !pdf.isEmpty {
                return nil
            }
            let modified =
                (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let pageCount = capturedPageCount(in: url)
            let crop = manifest?["crop"] as? [String: Any]
            let hasCrop = crop?["windowLocal"] as? [String: Any] != nil
            return AbandonedCapture(
                directory: url, byteCount: size(of: url),
                modifiedAt: modified, pageCount: pageCount,
                resumable: pageCount > 0 && hasCrop && pdf == nil)
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public static func remove(_ captures: [AbandonedCapture]) throws {
        for capture in captures {
            try FileManager.default.removeItem(at: capture.directory)
        }
    }

    private static func manifest(at directory: URL) -> [String: Any]? {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return nil }
        return object
    }

    private static func size(of directory: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .fileSizeKey,
                ])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                let size = values?.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }
}
