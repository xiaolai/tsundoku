import Foundation

/// Menu enablement for the browser commands, derived only from the key window
/// and the browser model. Pure so it can be tested without AppKit state.
public struct BrowserMenuState: Equatable, Sendable {
    /// The key window belongs to the library, directly or through its child
    /// inspector. Only then do browser commands apply.
    public var browserActive = false
    /// The annotation list is showing: the global section, or a book workspace.
    public var annotations = false
    /// Search and the metadata inspector apply to Books and Annotations.
    public var libraryOrAnnotations = false
    public var canOpenBook = false
    public var canGoBack = false
    public var canImport = true

    public init() {}

    public static func make(
        keyWindowIdentifier: String?,
        mainWindowIdentifier: String?,
        section: AppModel.Section?,
        bookWorkspaceID: String?,
        selectedBookID: String?,
        isImporting: Bool
    ) -> BrowserMenuState {
        var state = BrowserMenuState()
        state.canImport = !isImporting
        let libraryKey = keyWindowIdentifier == TsundokuWindowIdentifier.library
        let inspectorKey = keyWindowIdentifier == TsundokuWindowIdentifier.inspector
            && mainWindowIdentifier == TsundokuWindowIdentifier.library
        state.browserActive = libraryKey || inspectorKey
        guard state.browserActive, let section else { return state }
        state.libraryOrAnnotations = section == .library || section == .highlights
        state.annotations = section == .highlights
            || (section == .library && bookWorkspaceID != nil)
        state.canOpenBook = section == .library
            && bookWorkspaceID == nil && selectedBookID != nil
        state.canGoBack = section == .library && bookWorkspaceID != nil
        return state
    }
}
