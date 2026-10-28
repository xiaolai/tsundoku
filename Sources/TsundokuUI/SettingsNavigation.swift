import Foundation
import SwiftUI

public enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", companion = "Companion", access = "Access",
         ai = "AI Provider", data = "Library & Storage", about = "About"
    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .companion: "eyeglasses"
        case .access: "lock.shield"
        case .ai: "sparkles"
        case .data: "books.vertical"
        case .about: "info.circle"
        }
    }
}

public enum AccessFocus: String, Hashable { case library, accessibility, screenRecording }
public enum AccessIntent: String, Equatable { case library, companion, capture }
public struct SettingsRoute {
    public var pane: SettingsPane
    public var focus: AccessFocus?
    public var intent: AccessIntent?
    public init(pane: SettingsPane, focus: AccessFocus? = nil, intent: AccessIntent? = nil) {
        self.pane = pane; self.focus = focus; self.intent = intent
    }
}

/// Presentation is independent of authorization/import lifetime. Hiding a view
/// never cancels pending work. Recovery navigation does not replace the user's
/// ordinary pane preference.
@MainActor public final class SettingsNavigation: ObservableObject {
    @Published public private(set) var selectedPane: SettingsPane
    @Published public private(set) var focus: AccessFocus?
    @Published public private(set) var intent: AccessIntent?
    @Published public private(set) var intentID: UUID?
    @Published public private(set) var closeOnReturn = false
    public var onReturnToTask: ((AccessIntent, Bool) -> Void)?
    public var onCancelSetup: ((AccessIntent?) -> Void)?
    public var onIntentReplaced: ((AccessIntent) -> Void)?
    private let defaults: UserDefaults
    private var ordinaryPane: SettingsPane

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A first-time reader opening Settings is usually fixing setup; the
        // companion's placement controls are not the place to start.
        let pane = defaults.string(forKey: "settings.lastPane").flatMap(SettingsPane.init(rawValue:)) ?? .access
        selectedPane = pane; ordinaryPane = pane
    }
    public func open(_ route: SettingsRoute?, wasVisible: Bool) {
        guard let route else {
            if !wasVisible { selectedPane = ordinaryPane; focus = nil }
            closeOnReturn = false
            return
        }
        selectedPane = route.pane; focus = route.focus
        if let next = route.intent {
            if let previous = intent, previous != next { onIntentReplaced?(previous) }
            closeOnReturn = !wasVisible || (intent != nil && closeOnReturn)
            intent = next; intentID = UUID()
        }
    }
    public func select(_ pane: SettingsPane) {
        selectedPane = pane; ordinaryPane = pane
        defaults.set(pane.rawValue, forKey: "settings.lastPane")
    }
    public func windowClosed() { /* Pending work is deliberately untouched. */ }
    public func cancelIntent() {
        let cancelled = intent
        intent = nil; intentID = nil; closeOnReturn = false
        onCancelSetup?(cancelled)
    }
    @discardableResult public func finishIntent(id: UUID?) -> Bool {
        guard let id, id == intentID else { return false }
        intent = nil; intentID = nil; closeOnReturn = false
        return true
    }
    public func returnToTask() {
        guard let task = intent else { return }
        let close = closeOnReturn
        guard finishIntent(id: intentID) else { return }
        onReturnToTask?(task, close)
    }
}

public enum SettingsLaunchPolicy {
    public static func shouldPresentLibrary(firstUse: Bool, arguments: [String], isLoginLaunch: Bool = false) -> Bool {
        let legacy = arguments.firstIndex(of: "--section").map { arguments.indices.contains($0 + 1) && arguments[$0 + 1] == "settings" } ?? false
        return firstUse && !isLoginLaunch && !arguments.contains(where: { ["--shell-only", "--open-settings", "--open-library", "--show-onboarding"].contains($0) }) && !legacy
    }
    public static func relaunchArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var skip = false
        for argument in arguments {
            if skip { skip = false; continue }
            if ["--settings-pane", "--section"].contains(argument) { skip = true; continue }
            if ["--open-settings", "--open-library", "--show-onboarding"].contains(argument) { continue }
            result.append(argument)
        }
        return result
    }
}
