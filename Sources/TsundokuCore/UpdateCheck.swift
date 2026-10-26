import Foundation

/// A published Tsundoku release, as read from GitHub's latest-release API.
public struct UpdateRelease: Equatable, Sendable {
    public let version: String
    public let url: URL
    public let publishedAt: Date?

    public init(version: String, url: URL, publishedAt: Date?) {
        self.version = version
        self.url = url
        self.publishedAt = publishedAt
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(String)
    case available(UpdateRelease)
    case failed(String)
}

/// Checks GitHub's latest release for a newer version.
///
/// The request carries only a generic `User-Agent` and the release endpoint:
/// no archive, reading data or version is sent. A release URL is accepted only
/// when it is an HTTPS GitHub URL under this repository.
public enum UpdateCheck {
    public static let endpoint = URL(
        string: "https://api.github.com/repos/xiaolai/tsundoku/releases/latest")!
    public static let releasePage = URL(
        string: "https://github.com/xiaolai/tsundoku/releases/latest")!
    static let maxResponseBytes = 1 << 20

    public typealias Fetcher = @Sendable (URLRequest) async throws
        -> (Data, URLResponse)

    /// A fetch seam for tests; production uses the shared URL session.
    public static func check(
        currentVersion: String,
        fetcher: Fetcher = { request in
            try await URLSession.shared.data(for: request)
        }
    ) async -> UpdateCheckResult {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Tsundoku", forHTTPHeaderField: "User-Agent")
        request.setValue(
            "application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await fetcher(request)
            guard data.count <= maxResponseBytes else {
                return .failed("The update response was too large.")
            }
            guard let http = response as? HTTPURLResponse,
                http.statusCode == 200
            else {
                return .failed("GitHub did not return a release.")
            }
            return try result(currentVersion: currentVersion, data: data)
        } catch let error as UpdateCheckError {
            return .failed(error.description)
        } catch {
            return .failed("Could not reach GitHub.")
        }
    }

    public static func result(
        currentVersion: String, data: Data
    ) throws -> UpdateCheckResult {
        let release = try parse(data)
        return isNewer(release.version, than: currentVersion)
            ? .available(release) : .upToDate(currentVersion)
    }

    public static func parse(_ data: Data) throws -> UpdateRelease {
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let rawTag = object["tag_name"] as? String,
            let version = versionNumber(rawTag),
            let rawURL = object["html_url"] as? String,
            let url = URL(string: rawURL),
            isAllowedReleaseURL(url)
        else { throw UpdateCheckError.invalidRelease }
        let publishedAt = (object["published_at"] as? String).flatMap {
            isoDate($0)
        }
        return UpdateRelease(
            version: version, url: url, publishedAt: publishedAt)
    }

    /// Only an HTTPS GitHub URL for this repository's releases may be opened.
    public static func isAllowedReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/xiaolai/tsundoku/releases/")
    }

    /// Compares dotted numeric versions, padding a missing component with 0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = numbers(candidate),
            let current = numbers(current)
        else { return false }
        return candidate.lexicographicallyPrecedes(current) == false
            && candidate != current
    }

    /// `v1.2.3` → `1.2.3`; a prerelease or malformed tag is rejected.
    public static func versionNumber(_ tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst()) : trimmed
        guard value.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression)
            != nil
        else { return nil }
        return value
    }

    private static func numbers(_ value: String) -> [Int]? {
        guard let version = versionNumber(value) else { return nil }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

public enum UpdateCheckError: Error, CustomStringConvertible, Sendable {
    case invalidRelease

    public var description: String {
        switch self {
        case .invalidRelease: "GitHub returned an unexpected release."
        }
    }
}
