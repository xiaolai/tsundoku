import CoreGraphics
import Foundation

public enum OriginalCopyError: Error, CustomStringConvertible, Sendable {
    case unavailable
    case protected(String)
    case directoryIsNotAnEPUB(URL)
    case destinationInsideSource
    case invalidDestination(String)
    case io(String)

    public var description: String {
        switch self {
        case .unavailable:
            "There is no DRM-free original to copy."
        case .protected(let reason):
            "The original is protected: \(reason)"
        case .directoryIsNotAnEPUB(let url):
            "The original directory is not an EPUB: \(url.path)."
        case .destinationInsideSource:
            "The destination is inside the original; refusing to copy it "
                + "onto itself."
        case .invalidDestination(let name):
            "The original's destination name is not safe: \(name)."
        case .io(let message):
            "The original could not be copied: \(message)."
        }
    }
}

public struct OriginalCopyResult: Sendable, Equatable {
    public let url: URL
    public let kind: OriginalKind
    public let bytes: Int

    public init(url: URL, kind: OriginalKind, bytes: Int) {
        self.url = url
        self.kind = kind
        self.bytes = bytes
    }
}

/// Copies a DRM-free original into an export directory. A Kindle file is
/// copied byte for byte; an unpacked EPUB is re-zipped with `mimetype` first.
/// The availability is revalidated at copy time: a source that became
/// protected after detection is refused, not exported.
public enum OriginalService {
    /// A case-insensitive, collision-free original filename. Existing files
    /// and caller-reserved names (the published PDF, fixed bundle files) are
    /// both avoided.
    public static func destinationName(
        for kind: OriginalKind, in directory: URL,
        reserving reserved: [String] = []
    ) -> String {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(
                atPath: directory.path)
        } catch let error as NSError
        where error.code == NSFileReadNoSuchFileError {
            names = []
        } catch {
            // Cannot list the directory: a fixed name could replace an
            // unknown existing file, so use a unique one.
            return "original-\(UUID().uuidString).\(kind.fileExtension)"
        }
        var used = Set(names.map { $0.lowercased() })
        used.formUnion(reserved.map { $0.lowercased() })
        var name = "original.\(kind.fileExtension)"
        if used.contains(name.lowercased()) {
            name = "original-book.\(kind.fileExtension)"
            var index = 2
            while used.contains(name.lowercased()) {
                name = "original-book-\(index).\(kind.fileExtension)"
                index += 1
            }
        }
        return name
    }

    public static func copy(
        _ availability: OriginalAvailability, into directory: URL,
        destinationName: String? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> OriginalCopyResult {
        try checkCancelled(isCancelled)
        let (kind, source) = try revalidated(availability)
        let name = (destinationName ?? "original.\(kind.fileExtension)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
            !name.contains("/"), !name.contains("\\")
        else {
            throw OriginalCopyError.invalidDestination(
                destinationName ?? "original.\(kind.fileExtension)")
        }
        let manager = FileManager.default
        let destination = directory.appendingPathComponent(name)
        // Resolve symlinks before creating anything: a symlinked output
        // directory must not smuggle the archive inside the source book.
        let sourceResolved = source.resolvingSymlinksInPath()
            .standardizedFileURL
        let destinationParentResolved = directory.resolvingSymlinksInPath()
            .standardizedFileURL
        let destinationResolved = destination.resolvingSymlinksInPath()
            .standardizedFileURL
        guard sourceResolved.path != destinationResolved.path,
            !(destinationParentResolved.path == sourceResolved.path
                || destinationParentResolved.path.hasPrefix(
                    sourceResolved.path + "/"))
        else {
            throw OriginalCopyError.destinationInsideSource
        }
        var isDirectory: ObjCBool = false
        guard
            manager.fileExists(
                atPath: source.path, isDirectory: &isDirectory)
        else {
            throw OriginalCopyError.io(
                "the original is missing: \(source.path)")
        }
        try checkCancelled(isCancelled)
        if isDirectory.boolValue {
            guard kind == .epub else {
                throw OriginalCopyError.directoryIsNotAnEPUB(source)
            }
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let partial = directory.appendingPathComponent(
                ".\(name).partial-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: partial) }
            do {
                try ZIPArchive.write(
                    directory: source, to: partial,
                    isCancelled: isCancelled)
                try checkCancelled(isCancelled)
                // Validate the bytes that will actually be published, not
                // the source directory a writer could have observed earlier.
                _ = try revalidated(
                    .available(kind: .epub, url: partial))
                try checkCancelled(isCancelled)
                try publish(partial, to: destination, manager: manager)
            } catch {
                throw Self.wrapped(error)
            }
        } else {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let partial = directory.appendingPathComponent(
                ".\(name).partial-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: partial) }
            do {
                // Copy the target of a source symlink, never the link, and
                // hold a no-follow descriptor so a swap cannot redirect it.
                let resolvedSource = source.resolvingSymlinksInPath()
                    .standardizedFileURL
                try streamCopy(
                    resolvedSource, to: partial,
                    isCancelled: isCancelled)
                try checkCancelled(isCancelled)
                _ = try revalidated(
                    .available(kind: kind, url: partial))
                try checkCancelled(isCancelled)
                try publish(partial, to: destination, manager: manager)
            } catch {
                throw Self.wrapped(error)
            }
        }
        let size =
            (try? manager.attributesOfItem(atPath: destination.path)[.size]
                as? NSNumber)?.intValue ?? 0
        return OriginalCopyResult(url: destination, kind: kind, bytes: size)
    }

    private static func checkCancelled(
        _ isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
    }

    /// Cancellation is not an I/O failure: callers must be able to tell a
    /// user stop from an unusable original.
    private static func wrapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let copyError = error as? OriginalCopyError { return copyError }
        return OriginalCopyError.io("\(error)")
    }

    /// Copy a file in bounded chunks so cancellation is honoured during a
    /// large original and a symlink swapped in after validation is refused.
    private static func streamCopy(
        _ source: URL, to destination: URL,
        isCancelled: @Sendable () -> Bool
    ) throws {
        guard let reader = BoundedFileReader.openNoFollow(source) else {
            throw OriginalCopyError.io(
                "the original could not be opened without following a "
                    + "symlink")
        }
        defer { try? reader.close() }
        let manager = FileManager.default
        guard manager.createFile(atPath: destination.path, contents: nil),
            let writer = try? FileHandle(forWritingTo: destination)
        else {
            throw OriginalCopyError.io(
                "the staged original could not be created")
        }
        defer { try? writer.close() }
        while true {
            try checkCancelled(isCancelled)
            guard let chunk = try reader.read(upToCount: 64 * 1024)
            else { break }
            if chunk.isEmpty { break }
            try writer.write(contentsOf: chunk)
        }
        try writer.synchronize()
        try writer.close()
        if let attributes = try? manager.attributesOfItem(
            atPath: source.path),
            let permissions = attributes[.posixPermissions]
        {
            try? manager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: destination.path)
        }
    }

    private static func publish(
        _ partial: URL, to destination: URL, manager: FileManager
    ) throws {
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(
                destination, withItemAt: partial)
        } else {
            try manager.moveItem(at: partial, to: destination)
        }
    }

    /// The `eBooks/<ASIN>` directory that contains `source`, when there is
    /// one. The ASIN directory is the child of a directory named `eBooks`.
    private static func kindleBookDirectory(for source: URL) -> URL? {
        var directory = source.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.deletingLastPathComponent().lastPathComponent
                == "eBooks"
            {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    /// Re-run the protection checks immediately before the copy. The plan's
    /// Kindle marker is the DRM voucher; EPUB and PDF are inspected by their
    /// own containers.
    private static func revalidated(
        _ availability: OriginalAvailability
    ) throws -> (OriginalKind, URL) {
        guard case .available(let kind, let source) = availability else {
            throw OriginalCopyError.unavailable
        }
        // A source evicted between detection and copy is no longer local.
        if BooksAsset.isDataless(source) {
            throw OriginalCopyError.unavailable
        }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard
            manager.fileExists(
                atPath: source.path, isDirectory: &isDirectory)
        else {
            throw OriginalCopyError.io(
                "the original is missing: \(source.path)")
        }
        if isDirectory.boolValue {
            guard kind == .epub else {
                throw OriginalCopyError.directoryIsNotAnEPUB(source)
            }
            switch EPUBEncryption.status(unpackedEPUB: source) {
            case .clear:
                break
            case .protected(let reason), .unknown(let reason):
                throw OriginalCopyError.protected(reason)
            }
            return (kind, source)
        }
        if let bookDirectory = kindleBookDirectory(for: source) {
            // Match the initial detector: a voucher anywhere under the ASIN
            // directory, not only beside the file. An unreadable subtree is
            // an unknown protection state and is refused.
            var enumerationError: Error?
            guard
                let enumerator = manager.enumerator(
                    at: bookDirectory,
                    includingPropertiesForKeys: nil,
                    options: [],
                    errorHandler: { _, error in
                        enumerationError = error
                        return false
                    })
            else {
                throw OriginalCopyError.protected(
                    "the Kindle book directory could not be inspected")
            }
            for case let entry as URL in enumerator {
                if entry.lastPathComponent.lowercased().hasPrefix(
                    "amzn1.drm-voucher")
                {
                    throw OriginalCopyError.protected(
                        "The Kindle download carries a DRM voucher.")
                }
            }
            if let enumerationError {
                throw OriginalCopyError.protected(
                    "the Kindle book directory could not be inspected: "
                        + "\(enumerationError)")
            }
        } else {
            // A file outside eBooks: check the nearest parents.
            var search = source.deletingLastPathComponent()
            for _ in 0..<3 {
                if let names = try? manager.contentsOfDirectory(
                    atPath: search.path),
                    names.contains(where: {
                        $0.lowercased().hasPrefix("amzn1.drm-voucher")
                    })
                {
                    throw OriginalCopyError.protected(
                        "The Kindle download carries a DRM voucher.")
                }
                let parent = search.deletingLastPathComponent()
                if parent.path == search.path { break }
                search = parent
            }
        }
        switch kind {
        case .epub:
            switch ZIPArchive.containsEntry(
                at: source, name: "META-INF/encryption.xml")
            {
            case .some(false):
                break
            case .none:
                throw OriginalCopyError.protected(
                    "The EPUB could not be inspected.")
            case .some(true):
                guard
                    let data = ZIPArchive.readEntry(
                        at: source, name: "META-INF/encryption.xml",
                        maxBytes: 1_000_000)
                else {
                    throw OriginalCopyError.protected(
                        "The EPUB encryption declaration is unreadable.")
                }
                switch EPUBEncryption.status(encryptionXML: data) {
                case .clear:
                    break
                case .protected(let reason), .unknown(let reason):
                    throw OriginalCopyError.protected(reason)
                }
            }
        case .pdf:
            guard let document = CGPDFDocument(source as CFURL) else {
                throw OriginalCopyError.protected(
                    "The PDF could not be opened.")
            }
            if document.isEncrypted {
                throw OriginalCopyError.protected(
                    "The PDF declares /Encrypt.")
            }
        case .azw, .kfx:
            switch KindleContainerProtection.status(
                of: source, kind: kind)
            {
            case .clear:
                break
            case .protected(let reason), .unverified(let reason):
                throw OriginalCopyError.protected(reason)
            }
        }
        return (kind, source)
    }
}
