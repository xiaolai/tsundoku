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
                return nil
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
            fetch: { _ in data })
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
                return nil
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
                return data
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
