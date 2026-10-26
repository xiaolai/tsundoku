import Foundation
import Testing

@testable import TsundokuCore
@testable import TsundokuUI

@Suite("Update check")
struct UpdateCheckTests {
    private let releaseJSON = """
        {
          "tag_name": "v1.3.0",
          "html_url": "https://github.com/xiaolai/tsundoku/releases/tag/v1.3.0",
          "published_at": "2026-10-27T10:00:00Z"
        }
        """.data(using: .utf8)!

    @Test("a newer dotted version is detected")
    func versionOrder() {
        #expect(UpdateCheck.isNewer("1.3.0", than: "1.2.1"))
        #expect(UpdateCheck.isNewer("1.2.2", than: "1.2.1"))
        #expect(UpdateCheck.isNewer("2.0.0", than: "1.99.99"))
        #expect(!UpdateCheck.isNewer("1.2.1", than: "1.2.1"))
        #expect(!UpdateCheck.isNewer("1.2.0", than: "1.2.1"))
        #expect(!UpdateCheck.isNewer("1.3", than: "1.2.1"))
        #expect(!UpdateCheck.isNewer("1.3.0-beta", than: "1.2.1"))
    }

    @Test("the latest-release payload parses")
    func parsing() throws {
        let release = try UpdateCheck.parse(releaseJSON)
        #expect(release.version == "1.3.0")
        #expect(release.url.absoluteString.hasSuffix("/v1.3.0"))
        #expect(release.publishedAt != nil)
    }

    @Test("a non-GitHub or non-release URL is refused")
    func unsafeURL() {
        let hostile = """
            {"tag_name":"v1.3.0","html_url":"https://example.com/payload"}
            """.data(using: .utf8)!
        #expect(throws: UpdateCheckError.self) {
            try UpdateCheck.parse(hostile)
        }
        let otherRepo = """
            {"tag_name":"v1.3.0","html_url":"https://github.com/xiaolai/elsewhere/releases/tag/v1.3.0"}
            """.data(using: .utf8)!
        #expect(throws: UpdateCheckError.self) {
            try UpdateCheck.parse(otherRepo)
        }
    }

    @Test("the release decision follows the current version")
    func decision() throws {
        let newer = try UpdateCheck.result(
            currentVersion: "1.2.1", data: releaseJSON)
        #expect(newer == .available(try UpdateCheck.parse(releaseJSON)))
        let same = try UpdateCheck.result(
            currentVersion: "1.3.0", data: releaseJSON)
        #expect(same == .upToDate("1.3.0"))
    }

    @Test("a failed response becomes a visible failure")
    func failedResponse() async {
        let result = await UpdateCheck.check(currentVersion: "1.2.1") {
            _ in
            let response = HTTPURLResponse(
                url: UpdateCheck.endpoint, statusCode: 500,
                httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        guard case .failed = result else {
            Issue.record("expected a failed update check")
            return
        }
    }

    @Test("a successful fetch reports the newer release")
    func successfulFetch() async throws {
        let data = releaseJSON
        let result = await UpdateCheck.check(currentVersion: "1.2.1") {
            _ in
            let response = HTTPURLResponse(
                url: UpdateCheck.endpoint, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        #expect(result == .available(try UpdateCheck.parse(data)))
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@MainActor
@Suite("Update controller")
struct UpdateControllerTests {
    private func defaults() -> UserDefaults {
        let suite = "tsundoku-updates-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("a manual check publishes the available release")
    func manualCheck() async {
        let defaults = self.defaults()
        let release = UpdateRelease(
            version: "1.3.0",
            url: URL(string: "https://github.com/xiaolai/tsundoku/releases/tag/v1.3.0")!,
            publishedAt: Date(timeIntervalSince1970: 1))
        let controller = UpdateController(
            defaults: defaults, currentVersion: "1.2.1",
            checker: { _ in .available(release) },
            now: { Date(timeIntervalSince1970: 100) })
        controller.check()
        await controller.awaitCheck()
        #expect(controller.state == .available(release))
        #expect(controller.availableRelease == release)
        #expect(controller.lastChecked == Date(timeIntervalSince1970: 100))
        #expect(controller.statusText.contains("1.3.0"))

        // A relaunch within the day restores the release, not "not checked".
        let restored = UpdateController(
            defaults: defaults, currentVersion: "1.2.1",
            checker: { _ in .upToDate("1.2.1") },
            now: { Date(timeIntervalSince1970: 200) })
        #expect(restored.state == .available(release))
        #expect(restored.availableRelease == release)
    }

    @Test("automatic checks are persisted and can be disabled")
    func preference() async {
        let defaults = self.defaults()
        let calls = CallCounter()
        let controller = UpdateController(
            defaults: defaults, currentVersion: "1.2.1",
            checker: { _ in
                calls.increment()
                return .upToDate("1.2.1")
            },
            now: { Date(timeIntervalSince1970: 100) })
        controller.automaticallyChecks = false
        controller.start()
        #expect(calls.value == 0)
        #expect(defaults.object(forKey: "updates.automatic") as? Bool == false)
        controller.automaticallyChecks = true
        await controller.awaitCheck()
        #expect(calls.value == 1)
        controller.start()
        #expect(calls.value == 1, "a completed check is not due again")
        #expect(controller.state == .upToDate("1.2.1"))
    }

    @Test("a development build is not checked")
    func developmentBuild() async {
        let controller = UpdateController(
            defaults: defaults(), currentVersion: nil,
            checker: { _ in
                Issue.record("a development build must not check")
                return .upToDate("dev")
            },
            now: Date.init)
        controller.start()
        #expect(controller.state == .unavailable)
    }
}
