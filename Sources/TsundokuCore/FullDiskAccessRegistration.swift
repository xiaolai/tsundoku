import Darwin
import Foundation

/// Gives macOS an attributable protected-access attempt before opening Settings.
/// TCC owns registration and approval; this never edits TCC or grants access.
public enum FullDiskAccessRegistration {
    public struct Result: Sendable {
        public let attempted: Int
        public let opened: Int
        public let errors: [Int32]
    }

    public static func request() -> Result {
        attempt(urls: [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail"),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
        ])
    }

    // Open and immediately close: no file bytes, directory entries or policy
    // records are read. An allowed open isn't evidence that FDA was granted.
    static func attempt(urls: [URL]) -> Result {
        var opened = 0
        var errors: [Int32] = []
        for url in urls {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
            if descriptor >= 0 {
                opened += 1
                Darwin.close(descriptor)
            } else {
                errors.append(errno)
            }
        }
        return Result(attempted: urls.count, opened: opened, errors: errors)
    }
}
