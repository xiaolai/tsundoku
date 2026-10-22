import Foundation

/// Shared, presentation-neutral formatting helpers.
public enum TsundokuFormat {
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
