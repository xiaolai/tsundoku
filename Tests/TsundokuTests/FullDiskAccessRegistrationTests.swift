import Foundation
import Testing
@testable import TsundokuCore

struct FullDiskAccessRegistrationTests {
    @Test func requestPerformsBoundedReadWithoutModifyingContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture")
        let bytes = Data("Synthetic fixture data".utf8)
        try bytes.write(to: file)
        let result = FullDiskAccessRegistration.attempt(directoryURLs: [root], headerURLs: [file])
        #expect(result.directoriesRead == 1)
        #expect(result.headerBytesRead == 1)
        #expect(result.permissionDenials == 0)
        #expect(result.otherFailures == 0)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func enumerationRequiresARealDirectoryRead() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Fixture".utf8).write(to: root.appendingPathComponent("metadata-only"))
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? manager.removeItem(at: root)
        }
        #expect(FullDiskAccessRegistration.attempt(directoryURLs: [root], headerURLs: []).directoriesRead == 1)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        let denied = FullDiskAccessRegistration.attempt(directoryURLs: [root], headerURLs: [])
        #expect(denied.directoriesRead == 0)
        #expect(denied.permissionDenials == 1)
        #expect(denied.headerBytesRead == 0)
    }

    @Test func missingOrDeniedTargetDoesNotSkipOtherCandidates() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let denied = root.appendingPathComponent("denied")
        let readable = root.appendingPathComponent("readable")
        try Data().write(to: denied)
        try Data("SQLite fixture".utf8).write(to: readable)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path)
            try? manager.removeItem(at: root)
        }
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        let result = FullDiskAccessRegistration.attempt(directoryURLs: [], headerURLs: [root.appendingPathComponent("absent"), denied, readable])
        #expect(result.attempted == 3)
        #expect(result.headerBytesRead == 1)
        #expect(result.missingTargets == 1)
        #expect(result.permissionDenials == 1)
        #expect(result.otherFailures == 0)
    }
}
