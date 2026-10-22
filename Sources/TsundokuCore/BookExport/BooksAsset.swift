import CoreGraphics
import Foundation

public enum BooksAssetContentType: String, Sendable, Equatable, CaseIterable {
    case epub
    case pdf
    case unknown

    /// `ZBKLIBRARYASSET.ZCONTENTTYPE`: 1 is an EPUB, 3 is a PDF.
    public init(databaseValue: Int) {
        switch databaseValue {
        case 1: self = .epub
        case 3: self = .pdf
        default: self = .unknown
        }
    }

    public var fileExtension: String? {
        switch self {
        case .epub: "epub"
        case .pdf: "pdf"
        case .unknown: nil
        }
    }
}

public enum BooksAssetPathKind: String, Sendable, Equatable {
    case file
    case unpackedEPUB
    case missing
}

public enum BooksDRMStatus: Sendable, Equatable {
    case clear
    case protected(reason: String)
    case unknown(reason: String)

    public var isProtected: Bool {
        switch self {
        case .protected: true
        case .clear, .unknown: false
        }
    }

    public var reason: String? {
        switch self {
        case .clear: nil
        case .protected(let reason), .unknown(let reason): reason
        }
    }
}

/// One Apple Books asset on disk. The reader is read-only and never looks at a
/// book's text; it reads the library row, the package metadata and the DRM
/// marker.
public struct BooksAsset: Sendable, Equatable {
    public let assetID: String
    public let path: URL?
    public let contentType: BooksAssetContentType
    public let pathKind: BooksAssetPathKind
    public let package: EPUBPackage?
    public let drm: BooksDRMStatus
    public let isDataless: Bool
    public let warnings: [String]

    public init(
        assetID: String,
        path: URL?,
        contentType: BooksAssetContentType,
        pathKind: BooksAssetPathKind,
        package: EPUBPackage?,
        drm: BooksDRMStatus,
        isDataless: Bool = false,
        warnings: [String] = []
    ) {
        self.assetID = assetID
        self.path = path
        self.contentType = contentType
        self.pathKind = pathKind
        self.package = package
        self.drm = drm
        self.isDataless = isDataless
        self.warnings = warnings
    }

    public var isAvailable: Bool {
        pathKind != .missing && path != nil && !isDataless
    }

    /// Read an asset from its path. `contentType` comes from the library row;
    /// the extension is only a fallback when the row is unknown.
    public static func load(
        assetID: String, path: URL?, contentType: BooksAssetContentType,
        resourceIsDataless: ((URL) -> Bool)? = nil
    ) -> BooksAsset {
        let id = assetID.uppercased()
        guard let path else {
            return BooksAsset(
                assetID: id, path: nil, contentType: contentType,
                pathKind: .missing, package: nil, drm: .unknown(
                    reason: "The library row has no local path."))
        }
        let url = path.standardizedFileURL
        let resolution = resolvePath(url, contentType: contentType)
        guard resolution.kind != .missing else {
            return BooksAsset(
                assetID: id, path: url, contentType: resolution.contentType,
                pathKind: .missing, package: nil,
                drm: .unknown(
                    reason: resolution.isDataless
                        ? "The iCloud asset is not downloaded."
                        : "The asset path does not exist."),
                isDataless: resolution.isDataless,
                warnings: resolution.isDataless
                    ? ["The iCloud asset is not downloaded."] : [])
        }
        var warnings: [String] = []
        var package: EPUBPackage?
        if resolution.kind == .unpackedEPUB {
            // Check every publication resource before reading the package or
            // encryption metadata: either read could hydrate a placeholder.
            let probe =
                resourceIsDataless ?? {
                    containsDatalessResource(in: $0)
                }
            if probe(url) {
                let warning =
                    "The EPUB has iCloud resources that are not downloaded."
                return BooksAsset(
                    assetID: id, path: url, contentType: .epub,
                    pathKind: .unpackedEPUB, package: nil,
                    drm: .unknown(reason: warning), isDataless: true,
                    warnings: [warning])
            }
            do {
                package = try EPUBPackage.load(fromEPUBDirectory: url)
            } catch {
                warnings.append("The EPUB package could not be read: \(error)")
            }
        }
        let drm = drmStatus(
            url: url, kind: resolution.kind,
            contentType: resolution.contentType)
        return BooksAsset(
            assetID: id, path: url,
            contentType: resolution.contentType, pathKind: resolution.kind,
            package: package, drm: drm,
            isDataless: resolution.isDataless, warnings: warnings)
    }

    /// An iCloud placeholder is not a local original until Books (or the
    /// system) materialises its bytes.
    public static func dataless(
        isUbiquitous: Bool,
        downloadingStatus: URLUbiquitousItemDownloadingStatus?
    ) -> Bool {
        isUbiquitous
            && (downloadingStatus == .notDownloaded
                || downloadingStatus == nil)
    }

    /// A file is dataless when it is an iCloud item that is not downloaded.
    public static func isDataless(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .isDirectoryKey,
        ])
        if dataless(
            isUbiquitous: values?.isUbiquitousItem == true,
            downloadingStatus: values?.ubiquitousItemDownloadingStatus)
        {
            return true
        }
        guard values?.isDirectory == true else { return false }
        return containsDatalessResource(in: url)
    }

    /// True when any regular file under `directory` is an undownloaded iCloud
    /// placeholder. An unreadable subtree is treated as dataless (fail
    /// closed) because its resources cannot be confirmed local.
    public static func containsDatalessResource(
        in directory: URL,
        placeholder: (URL, URLResourceValues) -> Bool = { _, values in
            BooksAsset.dataless(
                isUbiquitous: values.isUbiquitousItem == true,
                downloadingStatus: values.ubiquitousItemDownloadingStatus)
        }
    ) -> Bool {
        var enumerationFailed = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isUbiquitousItemKey,
                    .ubiquitousItemDownloadingStatusKey,
                ],
                options: [],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                })
        else { return true }
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isUbiquitousItemKey,
                    .ubiquitousItemDownloadingStatusKey,
                ])
            else { return true }
            if values.isRegularFile == true, placeholder(url, values) {
                return true
            }
        }
        return enumerationFailed
    }

    private struct PathResolution {
        let kind: BooksAssetPathKind
        let contentType: BooksAssetContentType
        let isDataless: Bool
    }

    private static func resolvePath(
        _ url: URL, contentType: BooksAssetContentType
    ) -> PathResolution {
        let manager = FileManager.default
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        let ubiquitous = values?.isUbiquitousItem == true
        let status = values?.ubiquitousItemDownloadingStatus
        let dataless = Self.dataless(
            isUbiquitous: ubiquitous, downloadingStatus: status)
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(
            atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            return PathResolution(
                kind: .missing, contentType: contentType,
                isDataless: dataless || ubiquitous)
        }
        // A placeholder that exists on disk but is not materialised is still
        // not a local original.
        if dataless {
            return PathResolution(
                kind: .missing, contentType: contentType,
                isDataless: true)
        }
        if isDirectory.boolValue {
            let hasContainer = manager.fileExists(
                atPath: url.appendingPathComponent(
                    "META-INF/container.xml").path)
            let hasPackage = manager.fileExists(
                atPath: url.appendingPathComponent("OEBPS/content.opf").path)
            guard hasContainer || hasPackage else {
                return PathResolution(
                    kind: .missing, contentType: contentType,
                    isDataless: false)
            }
            return PathResolution(
                kind: .unpackedEPUB, contentType: .epub, isDataless: false)
        }
        let resolvedType: BooksAssetContentType
        if contentType == .unknown {
            switch url.pathExtension.lowercased() {
            case "epub": resolvedType = .epub
            case "pdf": resolvedType = .pdf
            default: resolvedType = .unknown
            }
        } else {
            resolvedType = contentType
        }
        return PathResolution(
            kind: .file, contentType: resolvedType, isDataless: false)
    }

    private static func drmStatus(
        url: URL, kind: BooksAssetPathKind,
        contentType: BooksAssetContentType
    ) -> BooksDRMStatus {
        switch contentType {
        case .epub:
            if kind == .unpackedEPUB {
                return EPUBEncryption.status(unpackedEPUB: url)
            }
            switch ZIPArchive.containsEntry(
                at: url, name: "META-INF/encryption.xml")
            {
            case .some(false):
                return .clear
            case .none:
                return .unknown(
                    reason: "The EPUB could not be inspected for a DRM "
                        + "marker; refusing to call it an original.")
            case .some(true):
                guard
                    let data = ZIPArchive.readEntry(
                        at: url, name: "META-INF/encryption.xml",
                        maxBytes: 1_000_000)
                else {
                    return .unknown(
                        reason: "The EPUB encryption declaration is "
                            + "unreadable.")
                }
                return EPUBEncryption.status(encryptionXML: data)
            }
        case .pdf:
            guard let document = CGPDFDocument(url as CFURL) else {
                return .unknown(
                    reason: "The PDF could not be opened; its DRM status is "
                        + "unknown.")
            }
            return document.isEncrypted
                ? .protected(reason: "The PDF declares /Encrypt.")
                : .clear
        case .unknown:
            return .unknown(
                reason: "The asset type is unknown; refusing to call it an "
                    + "original.")
        }
    }
}

/// Anything that can answer "what is the Books asset for this identifier".
public protocol BooksAssetProviding: Sendable {
    func asset(for asin: String) throws -> BooksAsset?
}

/// A one-shot reader over a Books snapshot. The snapshot copies only the two
/// SQLite stores; asset files are read in place and never modified.
public struct BooksAssetReader: BooksAssetProviding, Sendable {
    public let paths: BooksPaths

    public init(paths: BooksPaths = .standard()) {
        self.paths = paths
    }

    public func assets() throws -> [BooksAsset] {
        let snapshot = try BooksLibrarySnapshot.capture(paths)
        defer { snapshot.cleanup() }
        return try BooksReader.readAssets(snapshot)
    }

    public func asset(for asin: String) throws -> BooksAsset? {
        let snapshot = try BooksLibrarySnapshot.capture(paths)
        defer { snapshot.cleanup() }
        return try BooksReader.asset(for: asin, in: snapshot)
    }
}

public extension BooksReader {
    static func readAssets(_ snapshot: BooksLibrarySnapshot) throws
        -> [BooksAsset]
    {
        try readAssets(at: snapshot.bookLibrary)
    }

    static func readAssets(_ snapshot: BooksSnapshot) throws
        -> [BooksAsset]
    {
        try readAssets(at: snapshot.bookLibrary)
    }

    static func asset(
        for asin: String, in snapshot: BooksLibrarySnapshot
    ) throws -> BooksAsset? {
        try asset(for: asin, at: snapshot.bookLibrary)
    }

    static func asset(
        for asin: String, in snapshot: BooksSnapshot
    ) throws -> BooksAsset? {
        try asset(for: asin, at: snapshot.bookLibrary)
    }

    private static func readAssets(at library: URL) throws -> [BooksAsset] {
        let database = try SQLiteDatabase(
            path: library.path, readOnly: true)
        let rows = try database.query(
            """
            SELECT ZASSETID, ZCONTENTTYPE, ZPATH
            FROM ZBKLIBRARYASSET
            """)
        return rows.compactMap { row in
            guard let raw = row.string("ZASSETID") else { return nil }
            let identifier = raw.trimmingCharacters(
                in: .whitespacesAndNewlines).uppercased()
            guard !identifier.isEmpty else { return nil }
            let path = row.string("ZPATH").flatMap { value -> URL? in
                let trimmed = value.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? nil : URL(fileURLWithPath: trimmed)
            }
            return BooksAsset.load(
                assetID: identifier, path: path,
                contentType: BooksAssetContentType(
                    databaseValue: Int(row.int("ZCONTENTTYPE") ?? 0)))
        }
    }

    private static func asset(
        for asin: String, at library: URL
    ) throws -> BooksAsset? {
        let wanted = asin.trimmingCharacters(
            in: .whitespacesAndNewlines).uppercased()
        guard !wanted.isEmpty else { return nil }
        let database = try SQLiteDatabase(
            path: library.path, readOnly: true)
        let rows = try database.query(
            """
            SELECT ZASSETID, ZCONTENTTYPE, ZPATH
            FROM ZBKLIBRARYASSET
            WHERE UPPER(ZASSETID) = ?
            LIMIT 1
            """, [.text(wanted)])
        guard let row = rows.first, let raw = row.string("ZASSETID") else {
            return nil
        }
        let identifier = raw.trimmingCharacters(
            in: .whitespacesAndNewlines).uppercased()
        let path = row.string("ZPATH").flatMap { value -> URL? in
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
        }
        return BooksAsset.load(
            assetID: identifier, path: path,
            contentType: BooksAssetContentType(
                databaseValue: Int(row.int("ZCONTENTTYPE") ?? 0)))
    }
}
