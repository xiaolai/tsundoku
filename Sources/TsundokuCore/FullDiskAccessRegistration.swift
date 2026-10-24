import Darwin
import Foundation

/// Performs real protected reads attributed to the app before opening Settings.
/// macOS owns listing and approval; no TCC records are queried or modified.
public enum FullDiskAccessRegistration {
    public struct Result: Sendable {
        public let attempted: Int
        public let directoriesRead: Int
        public let headerBytesRead: Int
        public let permissionDenials: Int
        public let missingTargets: Int
        public let otherFailures: Int
    }

    public static func request() -> Result {
        let systemPolicy = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC", isDirectory: true)
        let userPolicy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC", isDirectory: true)
        return attempt(directoryURLs: [systemPolicy, userPolicy],
            headerURLs: [systemPolicy.appendingPathComponent("TCC.db"), userPolicy.appendingPathComponent("TCC.db")])
    }

    static func attempt(directoryURLs: [URL], headerURLs: [URL]) -> Result {
        var directoriesRead = 0
        var headerBytesRead = 0
        var permissionDenials = 0
        var missingTargets = 0
        var otherFailures = 0

        func record(_ error: any Error) {
            let error = error as NSError
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            let posix = error.domain == NSPOSIXErrorDomain ? error : underlying
            let posixCode = posix?.domain == NSPOSIXErrorDomain ? posix?.code : nil
            if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
                || posixCode == Int(EPERM) || posixCode == Int(EACCES) {
                permissionDenials += 1
            } else if (error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
                || posixCode == Int(ENOENT) {
                missingTargets += 1
            } else {
                otherFailures += 1
            }
        }

        // The same Foundation enumeration used by Sonovo's project scanner.
        // Discard the names immediately; never log or retain directory entries.
        for url in directoryURLs {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
                directoriesRead += 1
            } catch { record(error) }
        }

        // Opening a descriptor alone need not exercise a protected data read.
        // Request one SQLite-header byte, discard it and close the handle.
        // This never reads a permission record or interprets a policy decision.
        for url in headerURLs {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                headerBytesRead += try handle.read(upToCount: 1)?.count ?? 0
            } catch { record(error) }
        }
        return Result(attempted: directoryURLs.count + headerURLs.count,
            directoriesRead: directoriesRead, headerBytesRead: headerBytesRead,
            permissionDenials: permissionDenials, missingTargets: missingTargets, otherFailures: otherFailures)
    }
}
