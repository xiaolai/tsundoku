import CoreGraphics
import Foundation

// MARK: - Reader snapshot

/// What the tracker saw, in the terms the companion state machine needs.
/// Everything here is pure data so the transition table is unit-testable
/// without a reader, a display, or an Accessibility connection.
public struct ReaderSnapshot: Equatable, Sendable {
    public var kind: ReaderKind
    public var pid: pid_t
    public var title: String
    public var frame: CGRect
    public var focused: Bool
    public var minimized: Bool
    public var fullScreen: Bool
    public var windowNumber: UInt32?

    public init(
        kind: ReaderKind,
        pid: pid_t,
        title: String = "",
        frame: CGRect,
        focused: Bool,
        minimized: Bool = false,
        fullScreen: Bool = false,
        windowNumber: UInt32? = nil
    ) {
        self.kind = kind
        self.pid = pid
        self.title = title
        self.frame = frame
        self.focused = focused
        self.minimized = minimized
        self.fullScreen = fullScreen
        self.windowNumber = windowNumber
    }
}

// MARK: - Output

public struct CompanionOutput: Equatable, Sendable {
    public enum Presentation: String, Equatable, Sendable {
        case hidden
        case trigger
        case panel
    }

    public let presentation: Presentation
    public let layout: CompanionLayout?

    public var isVisible: Bool { presentation != .hidden }

    public init(
        presentation: Presentation, layout: CompanionLayout?
    ) {
        self.presentation = presentation
        self.layout = layout
    }
}

// MARK: - State machine

/// The visibility rules from the plan, with no AppKit in sight.
///
/// Inputs are reader frame, focus and minimized state; outputs are which
/// surface is visible and the frames it occupies. The window layer only
/// renders this.
public struct CompanionStateMachine: Sendable {
    public private(set) var reader: ReaderSnapshot?
    public private(set) var panelOpen = false
    public var settings: CompanionSettings

    private var panelWasOpenBeforeMinimize = false

    public init(settings: CompanionSettings = .defaults) {
        self.settings = settings
    }

    /// Apply a tracker update and return the new presentation.
    ///
    /// - `nil` means no reader window was found: the companion hides and a
    ///   later reader starts at the trigger, never a panel.
    /// - A minimized reader hides everything but remembers an open panel, so
    ///   restoring the window restores the panel.
    /// - Losing focus (another app is frontmost) closes the panel for good;
    ///   returning to the reader shows only the trigger.
    public mutating func update(
        reader newReader: ReaderSnapshot?, visible: CGRect
    ) -> CompanionOutput {
        let previous = reader
        guard let newReader else {
            reader = nil
            panelOpen = false
            panelWasOpenBeforeMinimize = false
            return output(visible: visible)
        }

        reader = newReader

        let switchedReader = !Self.sameWindow(previous, newReader)
        if switchedReader {
            panelOpen = false
            panelWasOpenBeforeMinimize = false
        }

        guard !newReader.minimized, newReader.focused else {
            if newReader.minimized {
                if previous?.minimized != true {
                    panelWasOpenBeforeMinimize = panelOpen
                }
            } else {
                // A reader window that is not focused (library window, app
                // switch) is not the reading surface; closing is deliberate.
                panelWasOpenBeforeMinimize = false
            }
            panelOpen = false
            return output(visible: visible)
        }

        if previous?.minimized == true,
            panelWasOpenBeforeMinimize
        {
            panelOpen = true
        }
        panelWasOpenBeforeMinimize = false
        return output(visible: visible)
    }

    public mutating func openPanel(visible: CGRect) -> CompanionOutput {
        guard let reader, !reader.minimized, reader.focused else {
            return output(visible: visible)
        }
        panelOpen = true
        return output(visible: visible)
    }

    public mutating func closePanel(visible: CGRect) -> CompanionOutput {
        panelOpen = false
        panelWasOpenBeforeMinimize = false
        return output(visible: visible)
    }

    public mutating func togglePanel(visible: CGRect) -> CompanionOutput {
        if panelOpen {
            return closePanel(visible: visible)
        }
        return openPanel(visible: visible)
    }

    public func output(visible: CGRect) -> CompanionOutput {
        guard let reader, !reader.minimized, reader.focused else {
            return CompanionOutput(presentation: .hidden, layout: nil)
        }
        let layout = CompanionGeometry.layout(
            reader: reader.frame, visible: visible,
            panelPlacement: settings.panelPlacement,
            triggerPlacement: settings.triggerPlacement)
        return CompanionOutput(
            presentation: panelOpen ? .panel : .trigger,
            layout: layout)
    }

    /// Two windows of the same app must not inherit each other's panel state.
    /// A window number that only just became known is not a switch.
    private static func sameWindow(
        _ previous: ReaderSnapshot?, _ current: ReaderSnapshot
    ) -> Bool {
        guard let previous, previous.kind == current.kind,
            previous.pid == current.pid
        else { return false }
        // A different book title in the same window is a different reading
        // surface; the page model must not carry over.
        if !previous.title.isEmpty, !current.title.isEmpty,
            previous.title != current.title
        {
            return false
        }
        if let left = previous.windowNumber, let right = current.windowNumber {
            return left == right
        }
        return true
    }
}
