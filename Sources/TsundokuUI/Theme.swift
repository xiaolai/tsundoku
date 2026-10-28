import AppKit
import Foundation
import SwiftUI

/// Shared, presentation-neutral formatting helpers.
public enum TsundokuFormat {
    public static func annotationDate(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .omitted) ?? "Date unavailable"
    }

    public static func date(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    public static func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    public static func number(_ value: Int) -> String {
        value.formatted()
    }
}

/// Colours with a job. `.orange` at caption size on a light background is
/// about 2.8:1, under the 4.5:1 a warning needs to be read.
public enum Theme {
    public static let warning = Color.warningTint
    public static let warningBackground = Color.warningTint.opacity(0.12)
}

extension Color {
    /// A warning colour that holds contrast in both appearances: a deep
    /// amber in light, a light amber in dark.
    static var warningTint: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 1.0, green: 0.78, blue: 0.35, alpha: 1)
                : NSColor(red: 0.55, green: 0.33, blue: 0.0, alpha: 1)
        })
    }
}
