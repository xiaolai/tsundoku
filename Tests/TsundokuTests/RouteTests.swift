import Foundation
import Testing

@testable import TsundokuCore
@testable import TsundokuUI

/// Every route into the library must bring its window forward. The companion
/// panel is nonactivating, so a route that only sets state changes nothing a
/// reader can see — which is what "Manage Chats" did until it called the
/// window closure.
@MainActor
@Suite("Library routes")
struct RouteTests {
    private func model() throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let model = AppModel(
            archiveURL: directory.appendingPathComponent("archive.sqlite"),
            recoverReaderSettings: false)
        return (model, directory)
    }

    private func book() -> Book {
        Book(
            asin: "B0ROUTE", title: "A Book", author: "Author",
            bookType: 10, readState: 0)
    }

    @Test("opening a book's chats brings the library forward")
    func openChats() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        var presented = 0
        model.openLibraryWindow = { presented += 1 }
        model.openChats(for: book())
        #expect(presented == 1)
        #expect(model.section == .library)
        #expect(model.bookWorkspaceSection == .chats)
    }

    @Test("showing a book's annotations brings the library forward")
    func showAnnotations() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        var presented = 0
        model.openLibraryWindow = { presented += 1 }
        model.showAnnotations(for: book())
        #expect(presented == 1)
        #expect(model.section == .highlights)
        #expect(model.annotationBookID == "B0ROUTE")
    }

    @Test("the capture exports route brings the library forward")
    func openCaptureExports() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        var presented = 0
        model.openLibraryWindow = { presented += 1 }
        model.openCaptureExports(bookID: nil, readerKind: .kindle)
        #expect(presented == 1)
        #expect(model.section == .exports)
    }

    @Test("returning to a capture after granting access brings the library forward")
    func returnToCapture() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        var presented = 0
        model.openLibraryWindow = { presented += 1 }
        model.returnToCapture()
        #expect(presented == 1)
        #expect(model.section == .exports)
    }

    @Test("access routes open Settings, not the library")
    func accessRoutes() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = 0
        var library = 0
        model.openSettingsWindow = { _ in settings += 1 }
        model.openLibraryWindow = { library += 1 }
        model.openAccess(focus: .library)
        #expect(settings == 1)
        model.requestCaptureAccess(pages: nil)
        #expect(settings == 2)
        #expect(library == 0)
    }
}
