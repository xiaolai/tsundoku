import CoreGraphics
import Foundation

public enum OriginalKind: String, Codable, CaseIterable, Sendable {
    case epub
    case pdf
    case azw
    case kfx

    public var displayName: String { rawValue.uppercased() }

    public var fileExtension: String {
        switch self {
        case .epub: "epub"
        case .pdf: "pdf"
        case .azw: "azw"
        case .kfx: "kfx"
        }
    }
}

/// Whether a DRM-free original of the book can be offered, and where it is.
/// A protected asset is never called an original and is never converted.
public enum OriginalAvailability: Sendable, Equatable {
    case available(kind: OriginalKind, url: URL)
    case protected(reason: String)
    case missing

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var kind: OriginalKind? {
        if case .available(let kind, _) = self { return kind }
        return nil
    }

    public var url: URL? {
        if case .available(_, let url) = self { return url }
        return nil
    }

    /// The Exports-pane warning. The wording is part of the plan.
    public var warning: String? {
        guard case .available = self else { return nil }
        return "This book is DRM-free; export the original instead — real "
            + "text, images and layout."
    }

    public var manifest: [String: Any] {
        switch self {
        case .available(let kind, let url):
            return [
                "available": true,
                "kind": kind.rawValue,
                "path": url.path,
            ]
        case .protected(let reason):
            return [
                "available": false,
                "protected": true,
                "reason": reason,
            ]
        case .missing:
            return [
                "available": false,
                "missing": true,
            ]
        }
    }
}

public enum OriginalDetector {
    /// Kindle keeps each downloaded book under `eBooks/<ASIN>/`. A DRM voucher
    /// anywhere under that directory marks the download protected; its format
    /// is the extension of the book file itself.
    public static func kindle(
        asin: String, paths: KindlePaths
    ) -> OriginalAvailability {
        let identifier = BookIdentity.normalize(asin)
        guard !identifier.isEmpty, isSafeIdentifier(identifier) else {
            return .missing
        }
        let manager = FileManager.default
        var directory = paths.ebooks.appendingPathComponent(identifier)
        var isDirectory: ObjCBool = false
        if !manager.fileExists(
            atPath: directory.path, isDirectory: &isDirectory)
        {
            // ASINs are usually uppercase; a caller may supply the lower-case
            // form. Try the canonical spelling before reporting it missing.
            let canonical = paths.ebooks.appendingPathComponent(
                identifier.uppercased())
            if manager.fileExists(
                atPath: canonical.path, isDirectory: &isDirectory)
            {
                directory = canonical
            }
        }
        guard
            manager.fileExists(
                atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return .missing }
        let root = paths.ebooks.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let files: [URL]
        switch regularFiles(in: directory) {
        case .success(let found):
            files = found.filter { file in
                file.resolvingSymlinksInPath().standardizedFileURL.path
                    .hasPrefix(root + "/")
            }
        case .failure(let error):
            return .protected(
                reason: "The Kindle book directory could not be inspected: "
                    + "\(error)")
        }
        if files.contains(where: { file in
            file.lastPathComponent.lowercased().hasPrefix(
                "amzn1.drm-voucher")
        }) {
            return .protected(
                reason: "The Kindle download carries a DRM voucher.")
        }
        let ranked: [(OriginalKind, Set<String>)] = [
            (.epub, ["epub"]),
            (.pdf, ["pdf"]),
            (.kfx, ["kfx"]),
            (.azw, ["azw", "azw3"]),
        ]
        for (kind, extensions) in ranked {
            let match = files
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first
            if let match {
                return protection(for: match, kind: kind)
            }
        }
        // A directory with no recognisable book file is not an original we can
        // copy; it is not protected either, so report it as missing.
        return .missing
    }

    /// The plan's Kindle marker is a single safe identifier under `eBooks`.
    /// A traversal component would otherwise scan outside the library.
    private static func isSafeIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_"))
        return !value.isEmpty
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// EPUB and PDF files can be protected without a sibling voucher; inspect
    /// them. AZW/KFX rely on the voucher marker the plan measured.
    private static func protection(
        for url: URL, kind: OriginalKind
    ) -> OriginalAvailability {
        switch kind {
        case .pdf:
            guard let document = CGPDFDocument(url as CFURL) else {
                return .protected(
                    reason: "The PDF could not be opened; its protection "
                        + "state is unknown.")
            }
            return document.isEncrypted
                ? .protected(reason: "The PDF declares /Encrypt.")
                : .available(kind: kind, url: url)
        case .epub:
            switch ZIPArchive.containsEntry(
                at: url, name: "META-INF/encryption.xml")
            {
            case .some(false):
                return .available(kind: kind, url: url)
            case .none:
                return .protected(
                    reason: "The EPUB could not be inspected; refusing to "
                        + "call it an original.")
            case .some(true):
                guard
                    let data = ZIPArchive.readEntry(
                        at: url, name: "META-INF/encryption.xml",
                        maxBytes: 1_000_000)
                else {
                    return .protected(
                        reason: "The EPUB encryption declaration is "
                            + "unreadable.")
                }
                switch EPUBEncryption.status(encryptionXML: data) {
                case .clear:
                    return .available(kind: kind, url: url)
                case .protected(let reason), .unknown(let reason):
                    return .protected(reason: reason)
                }
            }
        case .azw, .kfx:
            switch KindleContainerProtection.status(of: url, kind: kind) {
            case .clear:
                return .available(kind: kind, url: url)
            case .protected(let reason), .unverified(let reason):
                return .protected(reason: reason)
            }
        }
    }

    public static func books(asset: BooksAsset?) -> OriginalAvailability {
        guard let asset else { return .missing }
        guard asset.isAvailable, let url = asset.path else {
            return .missing
        }
        switch asset.drm {
        case .protected(let reason):
            return .protected(reason: reason)
        case .unknown(let reason):
            // Fail closed: an unverified asset is not offered as an original.
            return .protected(reason: reason)
        case .clear:
            break
        }
        // The asset may have been evicted after it was loaded. A cloud-only
        // book is not a local original; an unpacked EPUB must also have all
        // of its publication resources downloaded.
        if BooksAsset.isDataless(url) { return .missing }
        switch asset.contentType {
        case .epub:
            return .available(kind: .epub, url: url)
        case .pdf:
            return .available(kind: .pdf, url: url)
        case .unknown:
            return .protected(
                reason: "The asset type is unknown; refusing to call it an "
                    + "original.")
        }
    }

    private static func regularFiles(
        in directory: URL
    ) -> Result<[URL], Error> {
        var enumerationError: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                })
        else {
            return .failure(
                CocoaError(
                    .fileReadUnknown,
                    userInfo: [
                        NSFilePathErrorKey: directory.path
                    ]))
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey])
                if values.isRegularFile == true {
                    files.append(url)
                }
            } catch {
                return .failure(error)
            }
        }
        if let enumerationError { return .failure(enumerationError) }
        return .success(files)
    }
}
