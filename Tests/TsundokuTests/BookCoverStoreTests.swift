import AppKit
import Foundation
import Testing

@testable import TsundokuCore

/// Covers are the one part of the library that reaches outside the machine.
/// These exercise the parts that must not depend on a network: the disk the
/// export pipeline already fills, the memory that stops a scroll from asking
/// twice, and the rule that a failure is not retried.
@Suite("Book covers")
struct BookCoverStoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func jpeg(_ size: Int = 64) throws -> Data {
        let image = NSImage(
            size: NSSize(width: size, height: size * 3 / 2))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let rep = try #require(
            NSBitmapImageRep(
                data: image.tiffRepresentation ?? Data()))
        return try #require(
            rep.representation(using: .jpeg, properties: [:]))
    }

    private func book(_ asin: String, _ source: BookSource = .kindle) -> Book {
        Book(asin: asin, title: "A Book", author: "A", bookType: 10,
             readState: 0, source: source)
    }

    @Test("a cover an export already resolved is read from disk")
    func cachedCover() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = BookCoverService.cacheKey(for: "B0CACHED", source: .kindle)
        try jpeg().write(to: directory.appendingPathComponent(key + ".jpg"))
        let counter = Counter()
        let store = BookCoverStore(
            cacheDirectory: directory, booksPaths: .standard(),
            fetch: { _ in
                counter.bump()
                return .failed
            })
        let image = await store.thumbnail(for: book("B0CACHED"))
        #expect(image != nil)
        #expect(
            counter.value == 0, "a cached cover must not touch the network")
    }

    @Test("a fetched cover is kept where an export will find it")
    func fetchedCoverIsCached() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try jpeg()
        let store = BookCoverStore(
            cacheDirectory: directory, booksPaths: .standard(),
            fetch: { _ in .data(data) })
        let image = await store.thumbnail(for: book("B0FETCHED"))
        #expect(image != nil)
        let key = BookCoverService.cacheKey(
            for: "B0FETCHED", source: .kindle)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(key + ".jpg").path))
    }

    @Test("a missing cover is asked for once")
    func missingIsRemembered() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = Counter()
        let store = BookCoverStore(
            cacheDirectory: directory, booksPaths: .standard(),
            fetch: { _ in
                counter.bump()
                return .absent
            })
        #expect(await store.thumbnail(for: book("B0MISSING")) == nil)
        #expect(await store.thumbnail(for: book("B0MISSING")) == nil)
        #expect(counter.value == 1, "a missing cover is not a retryable error")
    }

    @Test("a second ask for the same book does not fetch again")
    func memoryAnswers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try jpeg()
        let counter = Counter()
        let store = BookCoverStore(
            cacheDirectory: directory, booksPaths: .standard(),
            fetch: { _ in
                counter.bump()
                return .data(data)
            })
        _ = await store.thumbnail(for: book("B0ONCE"))
        _ = await store.thumbnail(for: book("B0ONCE"))
        #expect(counter.value == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// A fetch that fails is not a book without a cover. The distinction is what
/// keeps a blink in the network from leaving a shelf blank for the session.
@Suite("Book cover outcomes")
struct BookCoverOutcomeTests {
    private func book(_ asin: String) -> Book {
        Book(asin: asin, title: "A Book", author: "A", bookType: 10,
             readState: 0, source: .kindle)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-outcome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a transient failure is retried on the next ask")
    func transientFailureRetries() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = Counter()
        let store = BookCoverStore(
            cacheDirectory: directory, booksPaths: .standard(),
            fetch: { _ in
                counter.bump()
                return .failed
            })
        _ = await store.thumbnail(for: book("B0FLAKY"))
        _ = await store.thumbnail(for: book("B0FLAKY"))
        #expect(counter.value == 2, "a timeout must not be remembered")
    }

    @Test("a cover the service does not have is asked for once")
    func absenceIsFinal() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = Counter()
        let store = BookCoverStore(
            cacheDirectory: directory, booksPaths: .standard(),
            fetch: { _ in
                counter.bump()
                return .absent
            })
        _ = await store.thumbnail(for: book("B0NONE"))
        _ = await store.thumbnail(for: book("B0NONE"))
        #expect(counter.value == 1, "an absence is final")
    }

    @Test("two rows asking for the same book share one fetch")
    func concurrentAsksCoalesce() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = Counter()
        let store = BookCoverStore(
            cacheDirectory: directory, booksPaths: .standard(),
            fetch: { _ in
                counter.bump()
                try? await Task.sleep(for: .milliseconds(40))
                return .absent
            })
        async let first = store.thumbnail(for: book("B0SHARED"))
        async let second = store.thumbnail(for: book("B0SHARED"))
        _ = await (first, second)
        #expect(counter.value == 1)
    }

    @Test("a Kindle and a Books book with one identifier get their own keys")
    func keysAreSourceQualified() {
        let kindle = Book(
            asin: "X1", title: "T", author: "A", bookType: 10,
            readState: 0, source: .kindle)
        let books = Book(
            asin: "X1", title: "T", author: "A", bookType: 10,
            readState: 0, source: .appleBooks)
        #expect(
            BookCoverStore.cacheKey(for: kindle)
                != BookCoverStore.cacheKey(for: books))
    }
}

/// A row that scrolls away must stop costing a permit, and a server error
/// served with a 200 must not be remembered as "this book has no cover".
@Suite("Cover resolution under pressure")
struct CoverPressureTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-pressure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func book(_ asin: String) -> Book {
        Book(asin: asin, title: "T", author: "A", bookType: 10,
             readState: 0, source: .kindle)
    }

    private func jpeg() -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 48))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())
        return rep?.representation(using: .jpeg, properties: [:]) ?? Data()
    }

    @Test("a cancelled row does not keep downloading")
    func cancelledRowStops() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = FetchState()
        let store = BookCoverStore(
            cacheDirectory: directory, booksPaths: .standard(),
            parallelism: 1,
            fetch: { _ in
                state.bump()
                try? await Task.sleep(for: .milliseconds(300))
                return .absent
            })
        // Occupy the only permit, then cancel a queued row.
        let first = Task { await store.thumbnail(for: book("B0BLOCK")) }
        try await Task.sleep(for: .milliseconds(40))
        let second = Task { await store.thumbnail(for: book("B0QUEUED")) }
        try await Task.sleep(for: .milliseconds(40))
        second.cancel()
        _ = await first.value
        _ = await second.value
        // The cancelled row must not have reached the fetch: two fetches
        // would mean it downloaded anyway.
        #expect(state.value == 1, "a cancelled row fetched anyway")
    }

    @Test("a 200 that is not an image is retried, not remembered")
    func htmlErrorPageRetries() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = FetchState()
        let store = BookCoverStore(
            cacheDirectory: directory, booksPaths: .standard(),
            fetch: { _ in
                let attempt = state.bump()
                if attempt == 1 {
                    return .data(Data("<html>captive portal</html>".utf8))
                }
                return .data(self.jpeg())
            })
        #expect(await store.thumbnail(for: book("B0HTML")) == nil)
        #expect(
            await store.thumbnail(for: book("B0HTML")) != nil,
            "an error page is not an absence")
    }
}

private final class FetchState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
