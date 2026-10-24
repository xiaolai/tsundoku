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

    override var isOpaque: Bool { false }

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
        window.level = .floating
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
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(
                equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        clearBackgrounds()
    }

    var frame: CGRect { window.frame }

    var isVisible: Bool { window.isVisible }

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
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(
                name: .easeOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            // AppKit runs the completion on the main thread when the
            // animation ends; the closure itself carries no actor annotation.
            MainActor.assumeIsolated { self?.window.invalidateShadow() }
        }
    }

    func show() {
        clearBackgrounds()
        window.orderFrontRegardless()
        window.invalidateShadow()
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
