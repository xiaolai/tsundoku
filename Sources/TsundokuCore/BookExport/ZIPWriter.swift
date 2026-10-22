import Compression
import Darwin
import Foundation

public enum ZIPError: Error, CustomStringConvertible, Sendable {
    case emptyDirectory(URL)
    case io(String)

    public var description: String {
        switch self {
        case .emptyDirectory(let url):
            "The EPUB directory has no files to archive: \(url.path)."
        case .io(let message):
            "The EPUB could not be archived: \(message)."
        }
    }
}

/// Minimal ZIP support for EPUB originals: a central-directory scan for the
/// DRM marker, and a stored (no compression) writer that preserves the EPUB
/// requirement that `mimetype` is the first entry.
public enum ZIPArchive {
    /// Whether a zipped EPUB contains `name` in its central directory.
    /// `nil` means the archive could not be inspected (ZIP64, unreadable or
    /// not a ZIP); callers must fail closed.
    public static func containsEntry(at url: URL, name: String) -> Bool? {
        switch lookupEntry(at: url, name: name) {
        case .found: return true
        case .absent: return false
        case .uninspectable: return nil
        }
    }

    /// Read one entry, capped before decompression. Store and deflate are
    /// supported; any other method or an inconsistent header returns nil.
    public static func readEntry(
        at url: URL, name: String, maxBytes: Int
    ) -> Data? {
        guard maxBytes > 0,
            case .found(let entry) = lookupEntry(at: url, name: name)
        else { return nil }
        guard entry.uncompressedSize <= UInt32(maxBytes),
            entry.compressedSize <= UInt32(maxBytes),
            entry.uncompressedSize != 0xFFFF_FFFF,
            entry.compressedSize != 0xFFFF_FFFF
        else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard
            (try? handle.seek(toOffset: UInt64(entry.localOffset))) != nil,
            let header = try? handle.read(upToCount: 30),
            header.count == 30,
            readUInt32(header, 0) == 0x0403_4B50
        else { return nil }
        let nameLength = Int(readUInt16(header, 26))
        let extraLength = Int(readUInt16(header, 28))
        let dataOffset = UInt64(entry.localOffset) + 30
            + UInt64(nameLength) + UInt64(extraLength)
        guard
            (try? handle.seek(toOffset: dataOffset)) != nil,
            let compressed = try? handle.read(
                upToCount: Int(entry.compressedSize)),
            compressed.count == Int(entry.compressedSize)
        else { return nil }
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else {
                return nil
            }
            return compressed
        case 8:
            var destination = Data(
                count: Int(entry.uncompressedSize))
            let decoded = compressed.withUnsafeBytes { source -> Int in
                destination.withUnsafeMutableBytes { target -> Int in
                    guard
                        let sourceBase = source.bindMemory(
                            to: UInt8.self).baseAddress,
                        let targetBase = target.bindMemory(
                            to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_decode_buffer(
                        targetBase, Int(entry.uncompressedSize),
                        sourceBase, compressed.count, nil,
                        COMPRESSION_ZLIB)
                }
            }
            guard decoded == Int(entry.uncompressedSize) else {
                return nil
            }
            return destination
        default:
            return nil
        }
    }

    private enum EntryLookup {
        case found(DirectoryEntry)
        case absent
        case uninspectable
    }

    private struct DirectoryEntry {
        let method: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localOffset: UInt32
    }

    private static func lookupEntry(
        at url: URL, name: String
    ) -> EntryLookup {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .uninspectable
        }
        defer { try? handle.close() }
        guard let size = fileSize(handle), size >= 22 else {
            return .uninspectable
        }
        let tailLength = Int(min(size, 65_557))
        guard
            (try? handle.seek(toOffset: size - UInt64(tailLength))) != nil,
            let tail = try? handle.read(upToCount: tailLength),
            tail.count >= 22
        else { return .uninspectable }
        guard let eocd = findEOCD(in: tail), eocd + 22 <= tail.count
        else { return .uninspectable }
        let diskNumber = readUInt16(tail, eocd + 4)
        let centralDisk = readUInt16(tail, eocd + 6)
        let diskEntryCount = readUInt16(tail, eocd + 8)
        let entryCount = readUInt16(tail, eocd + 10)
        let centralSize = readUInt32(tail, eocd + 12)
        let centralOffset = readUInt32(tail, eocd + 16)
        guard diskNumber == 0, centralDisk == 0,
            diskEntryCount == entryCount,
            entryCount != 0xFFFF, centralOffset != 0xFFFF_FFFF,
            centralSize != 0xFFFF_FFFF
        else { return .uninspectable }
        let eocdFileOffset =
            size - UInt64(tailLength) + UInt64(eocd)
        guard centralSize <= 64 * 1024 * 1024,
            centralOffset <= size,
            UInt64(centralOffset) + UInt64(centralSize) == eocdFileOffset,
            (try? handle.seek(toOffset: UInt64(centralOffset))) != nil,
            let directory = try? handle.read(upToCount: Int(centralSize)),
            directory.count == Int(centralSize)
        else { return .uninspectable }
        var index = 0
        var remaining = Int(entryCount)
        var exact: DirectoryEntry?
        var sawCaseVariant = false
        var matches = 0
        while remaining > 0 {
            guard index + 46 <= directory.count,
                readUInt32(directory, index) == 0x0201_4B50
            else { return .uninspectable }
            let nameLength = Int(readUInt16(directory, index + 28))
            let extraLength = Int(readUInt16(directory, index + 30))
            let commentLength = Int(readUInt16(directory, index + 32))
            let start = index + 46
            guard start + nameLength <= directory.count,
                start + nameLength + extraLength <= directory.count,
                start + nameLength + extraLength + commentLength
                    <= directory.count
            else { return .uninspectable }
            let entryName = String(
                decoding: directory[start..<(start + nameLength)],
                as: UTF8.self)
            if entryName == name {
                matches += 1
                exact = DirectoryEntry(
                    method: readUInt16(directory, index + 10),
                    compressedSize: readUInt32(directory, index + 20),
                    uncompressedSize: readUInt32(directory, index + 24),
                    localOffset: readUInt32(directory, index + 42))
            } else if entryName.caseInsensitiveCompare(name)
                == .orderedSame
            {
                matches += 1
                sawCaseVariant = true
            }
            index = start + nameLength + extraLength + commentLength
            remaining -= 1
        }
        if index < directory.count {
            guard index + 6 <= directory.count,
                readUInt32(directory, index) == 0x0505_4B50
            else { return .uninspectable }
            let signatureLength = Int(readUInt16(directory, index + 4))
            guard index + 6 + signatureLength == directory.count else {
                return .uninspectable
            }
        }
        // A duplicate or a case-variant spelling is ambiguous: readers may
        // select a different entry than this scan. Fail closed.
        guard matches == 0 || (matches == 1 && !sawCaseVariant) else {
            return .uninspectable
        }
        if let exact { return .found(exact) }
        return .absent
    }

    /// Write an unpacked directory as a stored ZIP. `mimetype` is written
    /// first, as EPUB requires. Internal symlinks are archived at their
    /// targets; the source directory is never modified.
    public static func write(
        directory: URL, to destination: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws {
        let root = directory.standardizedFileURL
        let rootResolved = root.resolvingSymlinksInPath()
            .standardizedFileURL
        let files = try archivableFiles(
            in: root, rootResolved: rootResolved,
            isCancelled: isCancelled)
        guard !files.isEmpty else {
            throw ZIPError.emptyDirectory(directory)
        }
        // 0xFFFF is the ZIP64 sentinel that the inspector treats as
        // uninspectable; stay below it in both directions.
        guard files.count < 0xFFFF else {
            throw ZIPError.io(
                "the EPUB has 65,535 or more entries")
        }
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(
            at: parent, withIntermediateDirectories: true)
        let partial = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: partial) }
        guard manager.createFile(atPath: partial.path, contents: nil) else {
            throw ZIPError.io("could not create \(partial.lastPathComponent)")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partial)
        } catch {
            throw ZIPError.io("could not open \(partial.lastPathComponent)")
        }
        do {
            var central: [CentralEntry] = []
            var offset: UInt64 = 0
            for file in files {
                try checkCancelled(isCancelled)
                let nameData = Data(file.name.utf8)
                guard nameData.count <= 0xFFFF else {
                    throw ZIPError.io(
                        "an EPUB entry name is longer than 65,535 bytes")
                }
                // The descriptor is pinned before the size check, so the
                // bytes inspected are the bytes archived even if the path
                // is replaced afterwards.
                guard
                    let reader = SafeFile.openUnderRoot(
                        rootResolved, relativePath: file.openPath)
                else {
                    throw ZIPError.io(
                        "could not open \(file.name) without following a "
                            + "symlink")
                }
                defer { try? reader.close() }
                var info = stat()
                guard fstat(reader.fileDescriptor, &info) == 0,
                    info.st_mode & S_IFMT == S_IFREG
                else {
                    throw ZIPError.io(
                        "\(file.name) is not a regular file")
                }
                let size = UInt64(info.st_size)
                guard size <= UInt64(UInt32.max) else {
                    throw ZIPError.io(
                        "\(file.name) is larger than the ZIP32 limit")
                }
                let crc = try CRC32.checksum(
                    reader: reader, limit: size, isCancelled: isCancelled)
                try reader.seek(toOffset: 0)
                var local = Data()
                local.appendLE(UInt32(0x0403_4B50))
                local.appendLE(UInt16(20))
                local.appendLE(UInt16(0x0800))
                local.appendLE(UInt16(0))
                local.appendLE(UInt16(0))
                local.appendLE(UInt16(0x0021))
                local.appendLE(crc)
                local.appendLE(UInt32(size))
                local.appendLE(UInt32(size))
                local.appendLE(UInt16(nameData.count))
                local.appendLE(UInt16(0))
                local.append(nameData)
                guard offset + UInt64(local.count) + size
                    <= UInt64(UInt32.max)
                else {
                    throw ZIPError.io("the EPUB is too large for ZIP32")
                }
                try handle.write(contentsOf: local)
                try writeFileContents(
                    reader: reader, limit: size, to: handle,
                    isCancelled: isCancelled)
                central.append(
                    CentralEntry(
                        name: nameData, crc: crc, size: UInt32(size),
                        offset: UInt32(offset)))
                offset += UInt64(local.count) + size
            }
            guard offset <= UInt64(UInt32.max) else {
                throw ZIPError.io("the EPUB is too large for ZIP32")
            }
            let centralStart = offset
            var centralData = Data()
            for entry in central {
                centralData.appendLE(UInt32(0x0201_4B50))
                centralData.appendLE(UInt16(20))
                centralData.appendLE(UInt16(20))
                centralData.appendLE(UInt16(0x0800))
                centralData.appendLE(UInt16(0))
                centralData.appendLE(UInt16(0))
                centralData.appendLE(UInt16(0x0021))
                centralData.appendLE(entry.crc)
                centralData.appendLE(entry.size)
                centralData.appendLE(entry.size)
                centralData.appendLE(UInt16(entry.name.count))
                centralData.appendLE(UInt16(0))
                centralData.appendLE(UInt16(0))
                centralData.appendLE(UInt16(0))
                centralData.appendLE(UInt16(0))
                centralData.appendLE(UInt32(0))
                centralData.appendLE(entry.offset)
                centralData.append(entry.name)
            }
            guard centralData.count <= Int(UInt32.max) else {
                throw ZIPError.io("the EPUB central directory is too large")
            }
            try handle.write(contentsOf: centralData)
            var end = Data()
            end.appendLE(UInt32(0x0605_4B50))
            end.appendLE(UInt16(0))
            end.appendLE(UInt16(0))
            end.appendLE(UInt16(central.count))
            end.appendLE(UInt16(central.count))
            end.appendLE(UInt32(centralData.count))
            end.appendLE(UInt32(centralStart))
            end.appendLE(UInt16(0))
            try handle.write(contentsOf: end)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            if error is CancellationError { throw error }
            throw error is ZIPError
                ? error : ZIPError.io("\(error)")
        }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try manager.moveItem(at: partial, to: destination)
        }
    }

    private static func writeFileContents(
        reader: FileHandle, limit: UInt64, to handle: FileHandle,
        isCancelled: @Sendable () -> Bool
    ) throws {
        var remaining = limit
        while remaining > 0 {
            try checkCancelled(isCancelled)
            let chunkSize = Int(min(remaining, 64 * 1024))
            guard
                let chunk = try reader.read(upToCount: chunkSize),
                !chunk.isEmpty
            else {
                throw ZIPError.io(
                    "a file ended before its declared size")
            }
            try handle.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    private struct ArchivableFile {
        /// The entry's name inside the archive.
        let name: String
        /// The file's path relative to the resolved root; the target path
        /// for a symlinked resource, the resource path otherwise.
        let openPath: String
    }

    private struct CentralEntry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private static func archivableFiles(
        in root: URL, rootResolved: URL,
        isCancelled: @Sendable () -> Bool
    ) throws -> [ArchivableFile] {
        let rootResolvedPath = rootResolved.path
        var enumerationError: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                ],
                // Hidden publication resources are legal in EPUB. Skip only
                // the archive's own noise explicitly.
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                })
        else {
            throw ZIPError.io("could not enumerate \(root.path)")
        }
        var files: [ArchivableFile] = []
        for case let url as URL in enumerator {
            try checkCancelled(isCancelled)
            let name = url.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") {
                continue
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                throw ZIPError.io(
                    "could not inspect \(url.lastPathComponent): \(error)")
            }
            if values.isSymbolicLink == true {
                // Preserve a referenced resource under the symlink's own
                // name, but only when its target is a file inside the book.
                let resolved = url.resolvingSymlinksInPath()
                    .standardizedFileURL
                guard resolved.path.hasPrefix(rootResolvedPath + "/") else {
                    throw ZIPError.io(
                        "an EPUB symlink points outside the book: "
                            + url.lastPathComponent)
                }
                let target: URLResourceValues
                do {
                    target = try resolved.resourceValues(
                        forKeys: [.isRegularFileKey])
                } catch {
                    throw ZIPError.io(
                        "a symlink target could not be read: \(error)")
                }
                guard target.isRegularFile == true else {
                    throw ZIPError.io(
                        "an EPUB symlink does not point to a file: "
                            + url.lastPathComponent)
                }
                let path = url.standardizedFileURL.path
                let prefix = root.path.hasSuffix("/")
                    ? root.path : root.path + "/"
                guard path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                let openPath = String(
                    resolved.path.dropFirst(rootResolvedPath.count + 1))
                files.append(
                    ArchivableFile(name: relative, openPath: openPath))
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let prefix = root.path.hasSuffix("/")
                ? root.path : root.path + "/"
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            if relative == "__MACOSX"
                || relative.hasPrefix("__MACOSX/")
                || relative.contains("/__MACOSX/")
            {
                continue
            }
            files.append(
                ArchivableFile(name: relative, openPath: relative))
        }
        if let enumerationError {
            throw ZIPError.io(
                "could not read a directory: \(enumerationError)")
        }
        guard let mimetype = files.first(where: { $0.name == "mimetype" })
        else {
            throw ZIPError.io("the EPUB has no mimetype entry")
        }
        let expected = Data("application/epub+zip".utf8)
        // Read no more than the exact expected length plus one byte; a
        // multi-gigabyte "mimetype" must fail closed, not allocate.
        guard
            let mimetypeHandle = SafeFile.openUnderRoot(
                rootResolved, relativePath: mimetype.openPath)
        else {
            throw ZIPError.io("the mimetype entry is unreadable")
        }
        defer { try? mimetypeHandle.close() }
        guard
            let mimetypeData = BoundedFileReader.read(
                mimetypeHandle, limit: expected.count)
        else {
            throw ZIPError.io(
                "the mimetype entry is unreadable or too large")
        }
        // EPUB requires exactly these bytes, with no trailing newline.
        guard mimetypeData == expected else {
            throw ZIPError.io(
                "the mimetype entry is not exactly application/epub+zip")
        }
        return files.sorted { left, right in
            if left.name == "mimetype" { return true }
            if right.name == "mimetype" { return false }
            return left.name < right.name
        }
    }

    private static func checkCancelled(
        _ isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
    }

    /// Open a regular file without following a symlink, so a resource
    /// replaced after directory collection cannot redirect the archive
    /// outside the book.
    private static func fileSize(_ handle: FileHandle) -> UInt64? {
        try? handle.seekToEnd()
    }

    private static func findEOCD(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let start = max(0, data.count - 65_557)
        var index = data.count - 22
        while index >= start {
            if readUInt32(data, index) == 0x0605_4B50 {
                let commentLength = Int(readUInt16(data, index + 20))
                if index + 22 + commentLength == data.count {
                    return index
                }
            }
            if index == 0 { break }
            index -= 1
        }
        return nil
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1
                ? (0xEDB8_8320 ^ (crc >> 1))
                : (crc >> 1)
        }
        return crc
    }

    static func checksum(
        reader: FileHandle, limit: UInt64,
        isCancelled: @Sendable () -> Bool
    ) throws -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        var remaining = limit
        while remaining > 0 {
            if isCancelled() { throw CancellationError() }
            let chunkSize = Int(min(remaining, 64 * 1024))
            guard
                let chunk = try reader.read(upToCount: chunkSize),
                !chunk.isEmpty
            else {
                throw ZIPError.io(
                    "a file ended before its declared size")
            }
            for byte in chunk {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            remaining -= UInt64(chunk.count)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
