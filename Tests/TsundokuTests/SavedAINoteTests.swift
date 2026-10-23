import Foundation
import Testing

@testable import TsundokuCore

@Suite("Saved AI notes")
struct SavedAINoteTests {
    @Test func legacyMigrationAndNewNotes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("archive.sqlite")
        let db = try SQLiteDatabase(path: url.path)
        try db.execute(
            "CREATE TABLE ai_notes (id INTEGER PRIMARY KEY, asin TEXT, position TEXT, kind TEXT NOT NULL, prompt TEXT NOT NULL, answer TEXT NOT NULL, provider TEXT NOT NULL, created_at REAL NOT NULL)"
        )
        try db.execute(
            "INSERT INTO ai_notes VALUES (1, NULL, NULL, 'explain', 'prompt', 'Old answer', 'old provider', 100)"
        )
        let archive = try Archive(path: url)
        try archive.saveAISNote(
            asin: "A1", position: "Chapter 2", kind: "ask", prompt: "Question",
            answer: "New answer",
            provider: "test", source: .appleBooks)
        let notes = try archive.aiNotes()
        #expect(notes.count == 2)
        #expect(notes.first?.bookSource == .appleBooks)
        #expect(notes.last?.bookSource == nil)
        #expect(try archive.aiNotes(asin: "A1").count == 1)
        #expect(try archive.annotations().isEmpty)
        #expect(try Archive(path: url).aiNotes().count == 2)
    }
}
