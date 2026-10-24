import Testing
@testable import TsundokuUI

struct BrowserMenuStateTests {
    private func state(
        key: String? = TsundokuWindowIdentifier.library,
        main: String? = TsundokuWindowIdentifier.library,
        section: AppModel.Section? = .library,
        workspace: String? = nil,
        selected: String? = "book-1",
        importing: Bool = false
    ) -> BrowserMenuState {
        BrowserMenuState.make(
            keyWindowIdentifier: key,
            mainWindowIdentifier: main,
            section: section,
            bookWorkspaceID: workspace,
            selectedBookID: selected,
            isImporting: importing)
    }

    private func expect(
        _ state: BrowserMenuState,
        active: Bool,
        annotations: Bool,
        libraryOrAnnotations: Bool,
        canOpenBook: Bool,
        canGoBack: Bool,
        canImport: Bool = true
    ) {
        #expect(state.browserActive == active)
        #expect(state.annotations == annotations)
        #expect(state.libraryOrAnnotations == libraryOrAnnotations)
        #expect(state.canOpenBook == canOpenBook)
        #expect(state.canGoBack == canGoBack)
        #expect(state.canImport == canImport)
    }

    @Test func booksWithoutSelectionOnlyAllowsSearchAndInspector() {
        expect(
            state(selected: nil),
            active: true, annotations: false, libraryOrAnnotations: true,
            canOpenBook: false, canGoBack: false)
    }

    @Test func booksWithSelectionAllowsOpen() {
        expect(
            state(),
            active: true, annotations: false, libraryOrAnnotations: true,
            canOpenBook: true, canGoBack: false)
    }

    @Test func bookWorkspaceAllowsBackAndExport() {
        expect(
            state(workspace: "book-1"),
            active: true, annotations: true, libraryOrAnnotations: true,
            canOpenBook: false, canGoBack: true)
    }

    @Test func annotationsSectionAllowsCardsListAndExport() {
        expect(
            state(section: .highlights, selected: nil),
            active: true, annotations: true, libraryOrAnnotations: true,
            canOpenBook: false, canGoBack: false)
    }

    @Test func historyAndExportsDisableBrowserCommands() {
        for section in [AppModel.Section.history, .exports] {
            expect(
                state(section: section, selected: nil),
                active: true, annotations: false, libraryOrAnnotations: false,
                canOpenBook: false, canGoBack: false)
        }
    }

    @Test func inspectorIsActiveOnlyOverTheLibrary() {
        expect(
            state(
                key: TsundokuWindowIdentifier.inspector,
                main: TsundokuWindowIdentifier.library),
            active: true, annotations: false, libraryOrAnnotations: true,
            canOpenBook: true, canGoBack: false)
        expect(
            state(
                key: TsundokuWindowIdentifier.inspector,
                main: TsundokuWindowIdentifier.settings),
            active: false, annotations: false, libraryOrAnnotations: false,
            canOpenBook: false, canGoBack: false)
    }

    @Test func anotherKeyWindowDisablesEveryBrowserCommand() {
        for key in [TsundokuWindowIdentifier.settings, "OtherWindow", nil] {
            expect(
                state(key: key),
                active: false, annotations: false, libraryOrAnnotations: false,
                canOpenBook: false, canGoBack: false)
        }
    }

    @Test func missingModelStillDisablesSectionCommands() {
        expect(
            state(section: nil),
            active: true, annotations: false, libraryOrAnnotations: false,
            canOpenBook: false, canGoBack: false)
    }

    @Test func importFollowsModelStateWithoutABrowserWindow() {
        expect(
            state(key: nil, importing: true),
            active: false, annotations: false, libraryOrAnnotations: false,
            canOpenBook: false, canGoBack: false, canImport: false)
        expect(
            state(key: nil, importing: false),
            active: false, annotations: false, libraryOrAnnotations: false,
            canOpenBook: false, canGoBack: false, canImport: true)
    }
}
