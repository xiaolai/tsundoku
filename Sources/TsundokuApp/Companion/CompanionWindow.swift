import AppKit
import SwiftUI
import TsundokuCore

// MARK: - Window

final class CompanionPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Hit testing

enum CompanionHitShape {
    case circle
    case roundedRect(radius: CGFloat)

    func contains(_ point: CGPoint, in bounds: CGRect) -> Bool {
        switch self {
        case .circle:
            let radius = min(bounds.width, bounds.height) / 2
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            let dx = point.x - centre.x
            let dy = point.y - centre.y
            return dx * dx + dy * dy <= radius * radius
        case .roundedRect(let radius):
            let path = NSBezierPath(
                roundedRect: bounds, xRadius: radius, yRadius: radius)
            return path.contains(point)
        }
    }
}

/// The window content is one transparent shape. A point outside that shape
/// must reach the reader underneath, not this window: the trigger is a circle
/// and the corners of its bounding box are empty.
final class CompanionHitView: NSView {
    var hitShape: CompanionHitShape = .roundedRect(
        radius: CompanionMetrics.cornerRadius)
    /// While the window grows as a drawer, the hosted content keeps its final
    /// size and stays pinned to this edge, so the window reveals it instead of
    /// reflowing it.
    var contentAnchor: CompanionDrawer.Anchor?
    var contentSize: CGSize?

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        layoutContent()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }

    private func layoutContent() {
        guard let hosting = subviews.first else { return }
        guard let anchor = contentAnchor, let size = contentSize else {
            hosting.frame = bounds
            return
        }
        hosting.frame = CGRect(
            x: anchor == .trailing ? bounds.width - size.width : 0,
            y: anchor == .top ? bounds.height - size.height : 0,
            width: size.width, height: size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local: NSPoint
        if let superview {
            local = convert(point, from: superview)
        } else {
            local = point
        }
        guard hitShape.contains(local, in: bounds) else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - Window owner

@MainActor
final class CompanionWindow {
    let window: CompanionPanelWindow
    private let container: CompanionHitView
    private let hosting: NSHostingView<AnyView>

    init() {
        window = CompanionPanelWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: CompanionMetrics.triggerSize,
                height: CompanionMetrics.triggerSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        // Native reader windows cast the standard window shadow; the
        // companion uses the same system shadow, following the opaque rounded
        // content and the transparent corners.
        window.hasShadow = true
        // The placement decides the level; `setLevel` is called before every
        // show. A drawer beside the reader belongs to the normal layer, an
        // overlay that crosses the reader's window must stay above it.
        window.level = .normal
        window.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
        ]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.becomesKeyOnlyIfNeeded = true
        window.acceptsMouseMovedEvents = false
        window.animationBehavior = .none

        container = CompanionHitView(
            frame: NSRect(
                x: 0, y: 0,
                width: CompanionMetrics.triggerSize,
                height: CompanionMetrics.triggerSize))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.frame = container.bounds
        container.addSubview(hosting)
        window.contentView = container
        clearBackgrounds()
    }

    var frame: CGRect { window.frame }

    var isVisible: Bool { window.isVisible }

    /// **The level is the layer.** macOS has no cross-process window tree: a
    /// window is ordered by its level and whether its app is active. A drawer
    /// that sits outside the reader's frame is put in the normal layer, so
    /// whatever covers the reader covers it too; an overlay or corner trigger
    /// crosses the reader's window and must float above it, where the reader's
    /// focus-gated visibility is what keeps it off other apps.
    func setLevel(_ level: NSWindow.Level) {
        guard window.level != level else { return }
        window.level = level
    }

    func setContent(_ content: AnyView, shape: CompanionHitShape) {
        container.hitShape = shape
        hosting.rootView = content
        clearBackgrounds()
        window.invalidateShadow()
    }

    func setFrame(_ frame: CGRect, animated: Bool, reduceMotion: Bool) {
        let shouldAnimate = animated && !reduceMotion
        guard shouldAnimate else {
            window.setFrame(frame, display: true)
            window.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(
                name: .easeOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            // AppKit runs the completion on the main thread when the
            // animation ends; the closure itself carries no actor annotation.
            MainActor.assumeIsolated { self?.window.invalidateShadow() }
        }
    }

    // MARK: - Drawer

    private static let animationDuration: TimeInterval = 0.2

    private static func timingFunction(_ curve: CompanionDrawer.Motion.Curve)
        -> CAMediaTimingFunction
    {
        switch curve {
        case .easeOut: CAMediaTimingFunction(name: .easeOut)
        case .easeInEaseOut: CAMediaTimingFunction(name: .easeInEaseOut)
        }
    }

    /// Opens the panel from its reader-facing edge: the window starts as a
    /// sliver on that edge and grows to the panel while the hosted content
    /// keeps its final layout, so the panel is revealed rather than reflowed.
    /// Reduce Motion jumps straight to the panel.
    func openDrawer(
        to panel: CGRect, anchor: CompanionDrawer.Anchor, animated: Bool,
        reduceMotion: Bool
    ) {
        setDrawerAnchor(anchor, contentSize: panel.size)
        window.setFrame(
            CompanionDrawer.start(of: panel, anchor: anchor), display: true)
        window.invalidateShadow()
        guard animated, !reduceMotion else {
            window.setFrame(panel, display: true)
            window.invalidateShadow()
            return
        }
        let motion = CompanionDrawer.motion(for: anchor)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.duration
            context.timingFunction = Self.timingFunction(motion.curve)
            window.animator().setFrame(panel, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.window.invalidateShadow() }
        }
    }

    /// Closes the panel into its reader-facing edge with the panel content
    /// still in place, then runs `completion` so the caller can swap in the
    /// trigger at its own frame.
    func collapseDrawer(
        anchor: CompanionDrawer.Anchor, reduceMotion: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        let start = CompanionDrawer.start(of: window.frame, anchor: anchor)
        guard !reduceMotion else {
            window.setFrame(start, display: true)
            window.invalidateShadow()
            completion()
            return
        }
        let motion = CompanionDrawer.motion(for: anchor)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.duration
            context.timingFunction = Self.timingFunction(motion.curve)
            window.animator().setFrame(start, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.window.invalidateShadow()
                completion()
            }
        }
    }

    private func setDrawerAnchor(
        _ anchor: CompanionDrawer.Anchor, contentSize: CGSize
    ) {
        container.contentAnchor = anchor
        container.contentSize = contentSize
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
    }

    /// Restores the normal layout, where the content fills the window.
    func clearDrawerAnchor() {
        guard container.contentAnchor != nil else { return }
        container.contentAnchor = nil
        container.contentSize = nil
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
    }

    func show() {
        clearBackgrounds()
        window.alphaValue = 1
        window.orderFrontRegardless()
        window.invalidateShadow()
    }

    /// Fades the trigger in after the drawer collapses, instead of popping it
    /// into place at the edge.
    func fadeIn() {
        clearBackgrounds()
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    /// SwiftUI and AppKit can each paint an opaque backing behind a borderless
    /// window. The glass shape needs everything outside it to stay clear, so
    /// the window, the hit container and the hosting view are re-cleared after
    /// every content swap and every order-front.
    private func clearBackgrounds() {
        window.isOpaque = false
        window.backgroundColor = .clear
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
    }

    func hide() {
        window.orderOut(nil)
    }

    func makeKey() {
        window.makeKey()
    }

    func orderFront() {
        window.orderFrontRegardless()
    }

    /// Whether the window server currently lists the companion on screen.
    var isOnScreen: Bool {
        guard window.isVisible else { return false }
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] ?? []
        let number = window.windowNumber
        return list.contains {
            ($0[kCGWindowNumber as String] as? Int) == number
        }
    }
}
