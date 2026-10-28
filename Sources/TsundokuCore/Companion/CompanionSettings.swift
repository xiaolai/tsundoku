import Foundation

// MARK: - Hot key

/// The modifiers of a global shortcut, independent of Carbon or AppKit.
public struct CompanionHotKeyModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = CompanionHotKeyModifiers(rawValue: 1 << 0)
    public static let option = CompanionHotKeyModifiers(rawValue: 1 << 1)
    public static let control = CompanionHotKeyModifiers(rawValue: 1 << 2)
    public static let shift = CompanionHotKeyModifiers(rawValue: 1 << 3)

    /// Ordered the way macOS prints shortcuts: ⌃⌥⇧⌘.
    public var displayName: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

extension CompanionHotKeyModifiers: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt32.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CompanionHotKey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: CompanionHotKeyModifiers

    public init(
        keyCode: UInt32, modifiers: CompanionHotKeyModifiers
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌥⌘K, the one combination the spike registered. The spike also proved
    /// that a second app can register the same combination, so this is a
    /// default, not a guarantee of exclusivity.
    public static let defaultShortcut = CompanionHotKey(
        keyCode: 40, modifiers: [.command, .option])

    /// A shortcut needs a real activation modifier. Shift alone would fire
    /// during ordinary uppercase typing in the reader.
    public var isValid: Bool {
        keyCode <= 255
            && !modifiers.intersection(Self.requiredModifiers).isEmpty
    }

    public static let requiredModifiers: CompanionHotKeyModifiers = [
        .command, .option, .control,
    ]

    public static let knownModifiers: CompanionHotKeyModifiers = [
        .command, .option, .control, .shift,
    ]

    public var displayName: String {
        modifiers.displayName + CompanionHotKey.keyName(for: keyCode)
    }

    // The Carbon virtual key codes for the keys a shortcut is likely to use.
    // An unknown code falls back to a numbered label rather than guessing.
    private static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 36: "↩"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 48: "⇥"
        case 49: "Space"
        case 50: "`"
        case 51: "⌫"
        case 53: "⎋"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "Key \(keyCode)"
        }
    }
}

// MARK: - Settings

/// What the companion answers about. The reader's selection is optional; a
/// page with no selection still has a page.
public enum CompanionScope: String, Codable, CaseIterable, Identifiable,
    Sendable
{
    case currentPage
    case currentChapter
    case wholeBook
    case selection

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .currentPage: "Current page"
        case .currentChapter: "Current chapter"
        case .wholeBook: "Whole book"
        case .selection: "Selection"
        }
    }

    /// A short name for the composer's scope control, where “Current page”
    /// next to Send would crowd the row.
    public var shortName: String {
        switch self {
        case .currentPage: "Page"
        case .currentChapter: "Chapter"
        case .wholeBook: "Book"
        case .selection: "Selection"
        }
    }

    public var symbolName: String {
        switch self {
        case .currentPage: "doc.text"
        case .currentChapter: "list.bullet.rectangle"
        case .wholeBook: "book.closed"
        case .selection: "text.cursor"
        }
    }
}

public struct CompanionSettings: Codable, Equatable, Sendable {
    public enum PanelPlacement: String, Codable, CaseIterable, Sendable {
        case auto
        case side
        case bottom

        public var displayName: String {
            switch self {
            case .auto: "Automatic"
            case .side: "Side drawer"
            case .bottom: "Bottom drawer"
            }
        }
    }

    public enum TriggerPlacement: String, Codable, CaseIterable, Sendable {
        case auto
        case outside
        case inside

        public var displayName: String {
            switch self {
            case .auto: "Automatic"
            case .outside: "Outside the reader edge"
            case .inside: "Inside the reader edge"
            }
        }
    }

    /// How the panel appears and disappears. The direction is never part of
    /// this choice: a drawer always opens from the edge nearest the reader.
    public enum PanelAnimation: String, Codable, CaseIterable, Sendable {
        /// Full height (or width) opens outward from the reader-facing edge.
        case outward
        /// The window grows from the trigger's frame to the panel's frame.
        case fromTrigger
        case none

        public var displayName: String {
            switch self {
            case .outward: "Grow from the edge"
            case .fromTrigger: "Grow from the button"
            case .none: "None"
            }
        }
    }

    public var panelPlacement: PanelPlacement
    public var triggerPlacement: TriggerPlacement
    public var launchAtLogin: Bool
    public var hotKey: CompanionHotKey
    /// How the panel opens and closes; the direction follows its placement.
    public var panelAnimation: PanelAnimation
    /// Follow the reading surface's type in the panel's answer text. Off
    /// keeps the panel's own body style.
    public var matchReaderTypography: Bool
    /// Take the reading surface's background colour into the panel. Off keeps
    /// the system window background.
    public var matchReaderTheme: Bool
    /// The actions offered by the Send button's menu, in this order. Empty
    /// means the menu has nothing but its explanation.
    public var quickActions: [AIAction]

    public init(
        panelPlacement: PanelPlacement = .auto,
        triggerPlacement: TriggerPlacement = .auto,
        launchAtLogin: Bool = false,
        hotKey: CompanionHotKey = .defaultShortcut,
        panelAnimation: PanelAnimation = .outward,
        matchReaderTypography: Bool = true,
        matchReaderTheme: Bool = true,
        quickActions: [AIAction] = AIAction.quickActionCases
    ) {
        self.panelPlacement = panelPlacement
        self.triggerPlacement = triggerPlacement
        self.launchAtLogin = launchAtLogin
        self.hotKey = hotKey
        self.panelAnimation = panelAnimation
        self.matchReaderTypography = matchReaderTypography
        self.matchReaderTheme = matchReaderTheme
        self.quickActions = quickActions
    }

    private enum CodingKeys: String, CodingKey {
        case panelPlacement, triggerPlacement, launchAtLogin, hotKey
        case panelAnimation
        case matchReaderTypography
        case matchReaderTheme
        case quickActions
    }

    /// Decodes every missing field to its default, so a blob written before a
    /// setting existed does not reset the others.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CompanionSettings()
        panelPlacement =
            try container.decodeIfPresent(
                PanelPlacement.self, forKey: .panelPlacement)
            ?? defaults.panelPlacement
        triggerPlacement =
            try container.decodeIfPresent(
                TriggerPlacement.self, forKey: .triggerPlacement)
            ?? defaults.triggerPlacement
        launchAtLogin =
            try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
            ?? defaults.launchAtLogin
        hotKey =
            try container.decodeIfPresent(
                CompanionHotKey.self, forKey: .hotKey)
            ?? defaults.hotKey
        panelAnimation =
            try container.decodeIfPresent(
                PanelAnimation.self, forKey: .panelAnimation)
            ?? defaults.panelAnimation
        matchReaderTypography =
            try container.decodeIfPresent(
                Bool.self, forKey: .matchReaderTypography)
            ?? defaults.matchReaderTypography
        matchReaderTheme =
            try container.decodeIfPresent(
                Bool.self, forKey: .matchReaderTheme)
            ?? defaults.matchReaderTheme
        quickActions =
            try container.decodeIfPresent(
                [AIAction].self, forKey: .quickActions)
            ?? defaults.quickActions
    }

    public static let defaults = CompanionSettings()

    public static let storageKey = "companion.settings"

    public static func load(from defaults: UserDefaults = .standard)
        -> CompanionSettings
    {
        guard
            let data = defaults.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(
                CompanionSettings.self, from: data)
        else { return .defaults }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
