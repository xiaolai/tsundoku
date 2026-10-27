import Foundation

/// A capture directory whose manifest did not publish a PDF. These are the
/// folders a failed or interrupted run leaves behind; published captures are
/// never included.
public struct AbandonedCapture: Identifiable, Sendable, Equatable {
    public let directory: URL
    public let byteCount: Int64
    public let modifiedAt: Date

    public var id: String { directory.path }

    public init(directory: URL, byteCount: Int64, modifiedAt: Date) {
        self.directory = directory
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public enum CaptureCleanup {
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
            return AbandonedCapture(
                directory: url, byteCount: size(of: url),
                modifiedAt: modified)
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
