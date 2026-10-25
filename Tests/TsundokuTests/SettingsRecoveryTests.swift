import Foundation
import Testing
@testable import TsundokuCore
@testable import TsundokuUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SettingsRecoveryTests {
    @Test func captureReturnRestoresOnlyCaptureOptionsAndDoesNotStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(archiveURL: root.appendingPathComponent("archive.sqlite"),
            kindlePaths: KindlePaths(container: root.appendingPathComponent("none")),
            booksPaths: BooksPaths(container: root.appendingPathComponent("none")), recoverReaderSettings: false)
        var route: SettingsRoute?
        model.openSettingsWindow = { route = $0 }
        model.selectedBookID = "fixture-original"
        model.settings.captureCropTop = 45
        model.requestCaptureAccess(pages: 25)
        model.selectedBookID = "fixture-other"
        model.settings.captureCropTop = 100
        model.settings.language = "fixture-language"
        model.returnToCapture()
        #expect(route?.intent == .capture)
        #expect(model.selectedBookID == "fixture-original")
        #expect(model.capturePageLimit == 25)
        #expect(model.settings.captureCropTop == 45)
        #expect(model.settings.language == "fixture-language")
        #expect(model.section == .exports)
        #expect(model.capturePhase == .idle)
    }

    @Test func shortcutButtonDelegatesToTheSharedAction() {
        let settings = CompanionSettingsStore()
        var tests = 0
        settings.onTestShortcut = { tests += 1 }
        settings.testShortcut()
        #expect(tests == 1)
        #expect(settings.hotKeyTestNote.isEmpty, "Only the real action owns the result")
    }

    @Test func previousImportCannotFinishANewerAccessRequest() async {
        let defaults = UserDefaults(suiteName: "access-generation-\(UUID())")!
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: defaults)
        let oldGeneration = permissions.librarySetupGeneration
        permissions.requestLibraryAccess()
        for _ in 0..<100 where permissions.libraryRegistrationInProgress { await Task.yield() }
        permissions.completeLibrarySetup(importedSources: [.appleBooks], generation: oldGeneration)
        #expect(permissions.librarySetupPending)
        permissions.completeLibrarySetup(importedSources: [.appleBooks], generation: permissions.librarySetupGeneration)
        #expect(!permissions.librarySetupPending)
    }
    @Test func readableImportCommitsBeforeClearingSetupIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = root.appendingPathComponent("books/Documents/BKLibrary")
        let notes = root.appendingPathComponent("books/Documents/AEAnnotation")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try SQLiteDatabase(path: library.appendingPathComponent("BKLibrary-fixture.sqlite").path)
        try db.execute("CREATE TABLE ZBKLIBRARYASSET (ZASSETID TEXT,ZTITLE TEXT,ZAUTHOR TEXT,ZCONTENTTYPE INTEGER,ZREADINGPROGRESS REAL,ZLASTOPENDATE REAL,ZDATEFINISHED REAL,ZISFINISHED INTEGER,ZPATH TEXT)")
        try db.execute("INSERT INTO ZBKLIBRARYASSET VALUES ('FIXTURE','Fixture','Fixture',1,0,NULL,NULL,0,NULL)")
        let annotation = try SQLiteDatabase(path: notes.appendingPathComponent("AEAnnotation-fixture.sqlite").path)
        try annotation.execute("CREATE TABLE ZAEANNOTATION (Z_PK INTEGER,ZANNOTATIONUUID TEXT,ZANNOTATIONASSETID TEXT,ZANNOTATIONTYPE INTEGER,ZANNOTATIONSELECTEDTEXT TEXT,ZANNOTATIONNOTE TEXT,ZANNOTATIONLOCATION TEXT,ZANNOTATIONCREATIONDATE REAL,ZANNOTATIONMODIFICATIONDATE REAL,ZANNOTATIONDELETED INTEGER)")
        let model = AppModel(archiveURL: root.appendingPathComponent("archive.sqlite"),
            kindlePaths: KindlePaths(container: root.appendingPathComponent("absent")), booksPaths: BooksPaths(container: root.appendingPathComponent("books")), recoverReaderSettings: false)
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryAccessCheck: { LibraryAccessResult(readableSources: [.appleBooks], failures: []) },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true },
            setupDefaults: UserDefaults(suiteName: "commit-import-\(UUID())")!)
        model.permissions = permissions
        permissions.onLibraryAccessReady = { [weak model] in model?.requestLibraryImport() }
        permissions.requestLibraryAccess()
        for _ in 0..<100 where permissions.libraryRegistrationInProgress { await Task.yield() }
        await permissions.verifyLibraryAccess()
        // The import signals its own completion; a fixed 2 s budget was a
        // false-failure race under parallel load.
        await model.awaitImportCompletion()
        #expect(model.hasCompletedImport)
        #expect(try model.archive?.counts().books == 1)
        #expect(!permissions.librarySetupPending)
        #expect(!permissions.captureReady)
    }

    @Test func cancellingACompanionTaskDoesNotCancelLibraryWork() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(archiveURL: root.appendingPathComponent("archive.sqlite"), recoverReaderSettings: false)
        let permissions = PermissionsModel(accessibilityCheck: { false }, screenRecordingCheck: { false },
            libraryRegistrationRequest: {}, librarySettingsOpener: { true }, setupDefaults: UserDefaults(suiteName: "task-scope-\(UUID())")!)
        model.permissions = permissions
        permissions.requestLibraryAccess()
        for _ in 0..<100 where permissions.libraryRegistrationInProgress { await Task.yield() }
        model.cancelAccessTask(intent: .companion)
        #expect(permissions.librarySetupPending)
        model.cancelAccessTask(intent: .capture)
        #expect(permissions.librarySetupPending)
        model.cancelAccessTask(intent: .library)
        #expect(!permissions.librarySetupPending)
    }

    @Test func captureBookmarkRestoresOnceAcrossAnExplicitRestart() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = UserDefaults(suiteName: "capture-bookmark-\(UUID())")!
        func makeModel() -> AppModel {
            AppModel(archiveURL: root.appendingPathComponent("archive.sqlite"),
                recoverReaderSettings: false, accessDefaults: preferences)
        }
        let first = makeModel()
        first.selectedBookID = "fixture-original"
        first.settings.captureCropTop = 45
        first.requestCaptureAccess(pages: 25)
        first.persistCaptureAccessForRelaunch()
        let next = makeModel()
        next.settings.language = "fixture-language"
        next.returnToCapture()
        #expect(next.selectedBookID == "fixture-original")
        #expect(next.capturePageLimit == 25)
        #expect(next.settings.captureCropTop == 45)
        #expect(next.settings.language == "fixture-language")
        #expect(next.capturePhase == .idle)
        #expect(preferences.data(forKey: "settings.captureAccessResume") == nil)
        let again = makeModel()
        again.selectedBookID = "fixture-new"
        again.returnToCapture()
        #expect(again.selectedBookID == "fixture-new")
    }

    @Test func expiredCaptureBookmarkDoesNotRestoreAnOldBook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = UserDefaults(suiteName: "capture-expired-\(UUID())")!
        let first = AppModel(archiveURL: root.appendingPathComponent("archive.sqlite"), recoverReaderSettings: false, accessDefaults: preferences)
        first.selectedBookID = "fixture-old"
        first.requestCaptureAccess(pages: 25)
        first.persistCaptureAccessForRelaunch()
        let data = try #require(preferences.data(forKey: "settings.captureAccessResume"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["createdAt"] = -100.0
        preferences.set(try JSONSerialization.data(withJSONObject: json), forKey: "settings.captureAccessResume")
        let next = AppModel(archiveURL: root.appendingPathComponent("archive.sqlite"), recoverReaderSettings: false, accessDefaults: preferences)
        next.selectedBookID = "fixture-current"
        next.returnToCapture()
        #expect(next.selectedBookID == "fixture-current")
        #expect(preferences.data(forKey: "settings.captureAccessResume") == nil)
    }

}
