import Darwin
import Foundation
import Testing
@testable import TsundokuCore

struct FullDiskAccessRegistrationTests {
    @Test func requestDoesNotReadOrModifyFileContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture")
        let bytes = Data("Synthetic fixture data".utf8)
        try bytes.write(to: file)
        let result = FullDiskAccessRegistration.attempt(urls: [file])
        #expect(result.opened == 1)
        #expect(result.errors.isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func missingOrDeniedTargetDoesNotSkipOtherCandidates() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let denied = root.appendingPathComponent("denied")
        let readable = root.appendingPathComponent("readable")
        try Data().write(to: denied)
        try Data().write(to: readable)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path)
            try? manager.removeItem(at: root)
        }
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        let result = FullDiskAccessRegistration.attempt(urls: [root.appendingPathComponent("absent"), denied, readable])
        #expect(result.attempted == 3)
        #expect(result.opened == 1)
        #expect(result.errors.contains(ENOENT))
        #expect(result.errors.contains(EACCES))
    }
}
