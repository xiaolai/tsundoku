import Foundation

/// Stable window identifiers used by menu enablement, diagnostics and the
/// search responder. SwiftUI scenes do not expose these, so the window host
/// assigns them once the scene's window exists.
public enum TsundokuWindowIdentifier {
    public static let library = "TsundokuLibrary"
    public static let inspector = "TsundokuInspector"
    public static let settings = "TsundokuSettings"
}
