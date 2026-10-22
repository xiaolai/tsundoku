import Foundation

/// One row from Kindle's `BookMetadataCache/metadata.json`. The cache carries
/// only what the store display needs: the title and the cover identity.
public struct KindleMetadataEntry: Sendable, Equatable {
    public let asin: String
    public let title: String?
    public let coverPhysicalID: String?
    public let coverAltText: String?
    public let coverFileExtension: String?

    public init(
        asin: String,
        title: String?,
        coverPhysicalID: String?,
        coverAltText: String?,
        coverFileExtension: String?
    ) {
        self.asin = asin
        self.title = title
        self.coverPhysicalID = coverPhysicalID
        self.coverAltText = coverAltText
        self.coverFileExtension = coverFileExtension
    }
}

/// A read-only view of Kindle's metadata cache. A missing or malformed cache is
/// empty, not fatal: metadata degrades to the archive's own fields.
public struct KindleMetadataCache: Sendable {
    public let entries: [String: KindleMetadataEntry]

    public init(entries: [String: KindleMetadataEntry] = [:]) {
        self.entries = entries
    }

    public func entry(for asin: String) -> KindleMetadataEntry? {
        let normalized = BookIdentity.normalize(asin).uppercased()
        return entries[normalized]
    }

    public static func load(paths: KindlePaths) -> KindleMetadataCache {
        load(path: paths.metadataCache)
    }

    /// Parse the cache file. Every bad row is skipped; a bad file returns an
    /// empty cache. This is display metadata, never a reason to fail a
    /// capture.
    public static func load(path: URL) -> KindleMetadataCache {
        guard let data = try? Data(contentsOf: path),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let rawEntries = object["entries"] as? [Any]
        else { return KindleMetadataCache() }
        var entries: [String: KindleMetadataEntry] = [:]
        for item in rawEntries {
            guard let raw = item as? [String: Any],
                let asin = nonEmpty(raw["asin"] as? String)
            else {
                continue
            }
            let cover = raw["coverImage"] as? [String: Any]
            let key = BookIdentity.normalize(asin).uppercased()
            entries[key] = KindleMetadataEntry(
                asin: key,
                title: nonEmpty(raw["title"] as? String),
                coverPhysicalID: nonEmpty(
                    cover?["physicalId"] as? String),
                coverAltText: nonEmpty(cover?["altText"] as? String),
                coverFileExtension: nonEmpty(
                    cover?["fileExtension"] as? String))
        }
        return KindleMetadataCache(entries: entries)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
