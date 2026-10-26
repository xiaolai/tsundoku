import Foundation

public struct CaptureReadinessInput: Sendable, Equatable {
    public let hasAccessibility: Bool
    public let hasScreenRecording: Bool
    public let isRunning: Bool
    public let isReading: Bool
    public let isMinimized: Bool
    public let isMainWindow: Bool
    public let bookMatches: Bool
    public let windowMatches: Bool
    public let pageMatches: Bool
    public let outputWritable: Bool
    public let captureBusy: Bool
    public let pageCountKnown: Bool

    public init(
        hasAccessibility: Bool, hasScreenRecording: Bool, isRunning: Bool,
        isReading: Bool, isMinimized: Bool, isMainWindow: Bool,
        bookMatches: Bool, windowMatches: Bool, pageMatches: Bool,
        outputWritable: Bool, captureBusy: Bool, pageCountKnown: Bool
    ) {
        self.hasAccessibility = hasAccessibility
        self.hasScreenRecording = hasScreenRecording
        self.isRunning = isRunning
        self.isReading = isReading
        self.isMinimized = isMinimized
        self.isMainWindow = isMainWindow
        self.bookMatches = bookMatches
        self.windowMatches = windowMatches
        self.pageMatches = pageMatches
        self.outputWritable = outputWritable
        self.captureBusy = captureBusy
        self.pageCountKnown = pageCountKnown
    }
}

public enum CaptureReadinessIssue: Sendable, Equatable {
    case permissions
    case notRunning
    case notReading(String)
    case minimized
    case notMainWindow
    case wrongBook
    case windowChanged
    case pageChanged
    case outputNotWritable
    case captureBusy
    case pageCountUnknown

    public var isBlocking: Bool {
        switch self {
        case .pageCountUnknown: false
        default: true
        }
    }

    public var message: String {
        switch self {
        case .permissions:
            "Kindle access is unavailable. Check permissions, then retry."
        case .notRunning:
            "Kindle is not running. Open the reader and try again."
        case .notReading(let state):
            "Kindle is showing \(state), not a reading page. Close search, "
                + "settings, or a dialog, then refresh."
        case .minimized:
            "Restore Kindle or keep it behind another window. A minimized "
                + "window cannot turn pages."
        case .notMainWindow:
            "Kindle's reading window is not ready to receive page turns. "
                + "Bring it forward once, then try again."
        case .wrongBook:
            "The open book or reading window changed. Refresh Preview."
        case .windowChanged:
            "Kindle's layout changed. Refresh Preview and check the crop."
        case .pageChanged:
            "The page changed since preview. Review the current page."
        case .outputNotWritable:
            "Choose a writable destination."
        case .captureBusy:
            "Another capture is using Kindle."
        case .pageCountUnknown:
            "Page count unavailable. Capture can continue; remaining time is "
                + "unknown."
        }
    }
}

public struct CaptureReadiness: Sendable, Equatable {
    public let issues: [CaptureReadinessIssue]

    public init(issues: [CaptureReadinessIssue]) {
        self.issues = issues
    }

    public var isReady: Bool {
        !issues.contains(where: \.isBlocking)
    }

    public var blockingIssue: CaptureReadinessIssue? {
        issues.first(where: \.isBlocking)
    }

    public var blockingMessage: String? {
        blockingIssue?.message
    }

    public var warnings: [CaptureReadinessIssue] {
        issues.filter { !$0.isBlocking }
    }
}

public enum CaptureReadinessChecker {
    public static func check(
        _ input: CaptureReadinessInput
    ) -> CaptureReadiness {
        var issues: [CaptureReadinessIssue] = []
        if !input.hasAccessibility || !input.hasScreenRecording {
            issues.append(.permissions)
        }
        if !input.isRunning { issues.append(.notRunning) }
        if !input.isReading { issues.append(.notReading("another surface")) }
        if input.isMinimized { issues.append(.minimized) }
        if !input.isMinimized, !input.isMainWindow {
            issues.append(.notMainWindow)
        }
        if !input.bookMatches { issues.append(.wrongBook) }
        if !input.windowMatches { issues.append(.windowChanged) }
        if !input.pageMatches { issues.append(.pageChanged) }
        if !input.outputWritable { issues.append(.outputNotWritable) }
        if input.captureBusy { issues.append(.captureBusy) }
        if !input.pageCountKnown { issues.append(.pageCountUnknown) }
        return CaptureReadiness(issues: issues)
    }
}
