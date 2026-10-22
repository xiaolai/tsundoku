import Foundation

/// Reads at most `limit` bytes. Used on metadata files that must not be
/// allowed to allocate an unbounded buffer before a protection check.
public enum BoundedFileReader {
    /// Open a regular file without following a symlink. Used when a path is
    /// read after it was validated, so a swapped-in link cannot redirect it.
    public static func openNoFollow(_ url: URL) -> FileHandle? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public static func read(_ url: URL, limit: Int) -> Data? {
        guard limit > 0, let handle = openNoFollow(url) else { return nil }
        defer { try? handle.close() }
        return read(handle, limit: limit)
    }

    public static func read(_ handle: FileHandle, limit: Int) -> Data? {
        guard limit > 0,
            let data = try? handle.read(upToCount: limit + 1),
            data.count <= limit
        else { return nil }
        return data
    }
}

/// Opens paths under a resolved root without following a symlink in any
/// path component. A resource whose parent is swapped for an escaping link
/// after directory collection therefore cannot redirect the read.
public enum SafeFile {
    public static func openUnderRoot(
        _ root: URL, relativePath: String
    ) -> FileHandle? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            return nil
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        var directory = open(
            root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { return nil }
        for (index, component) in components.enumerated() {
            guard component != ".", component != ".." else {
                close(directory)
                return nil
            }
            let flags =
                index == components.count - 1
                ? O_RDONLY | O_NOFOLLOW
                : O_RDONLY | O_DIRECTORY | O_NOFOLLOW
            let descriptor = openat(directory, component, flags)
            close(directory)
            guard descriptor >= 0 else { return nil }
            directory = descriptor
        }
        return FileHandle(
            fileDescriptor: directory, closeOnDealloc: true)
    }
}
