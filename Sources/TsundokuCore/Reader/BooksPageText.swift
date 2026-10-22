import CoreGraphics
import Foundation
import KindleAX

/// Extracts the visible page from a recorded Apple Books window.
///
/// Kept free of Accessibility calls so a recorded tree can be tested directly.
/// The rules come from the companion spike: text nodes inside `AXWebArea`
/// bounds, in tree order, joined with newlines.
public enum BooksPageText {
    public static let textRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXTextArea",
    ]

    public static func webAreaCount(in root: AXNode) -> Int {
        var count = 0
        walk(root) { node in
            if node.role == "AXWebArea" { count += 1 }
        }
        return count
    }

    public static func webAreaFrames(in root: AXNode) -> [CGRect] {
        var frames: [CGRect] = []
        walk(root) { node in
            if node.role == "AXWebArea", let frame = rect(node.frame) {
                frames.append(frame)
            }
        }
        return frames
    }

    /// The frames of the visible text nodes, in reading order. Global
    /// coordinates; the crop itself is measured from the window, because web
    /// area frames are content-relative and cannot be unioned.
    public static func textFrames(in root: AXNode) -> [AXNode.Frame] {
        let window = rect(root.frame)
        var frames: [AXNode.Frame] = []
        for webArea in topWebAreas(root) {
            let bounds = rect(webArea.frame)
            walk(webArea) { node in
                guard textRoles.contains(node.role), let frame = node.frame
                else { return }
                if let bounds, !verticallyInside(frame, bounds) { return }
                if let window, !insideWindow(frame, window) { return }
                frames.append(frame)
            }
        }
        return frames
    }

    public static func text(from root: AXNode) -> String {
        // Books reports the horizontal origin of a web area inconsistently:
        // during a page transition the web area sat at x = −1989 while its
        // text children stayed at x = 107…993, and that was still the visible
        // spread. Its vertical frames agreed. Compare only the vertical range
        // so offscreen preloaded lines are excluded without dropping the page
        // because of a horizontal scroll offset.
        let window = rect(root.frame)
        var parts: [String] = []
        func collect(_ node: AXNode, bounds: CGRect?) {
            if textRoles.contains(node.role) {
                let value = node.value?.asText ?? ""
                if !value.isEmpty {
                    if let bounds, let frame = node.frame,
                        !verticallyInside(frame, bounds)
                    {
                        return
                    }
                    if let window, let frame = node.frame,
                        !insideWindow(frame, window)
                    {
                        return
                    }
                    parts.append(value)
                    return
                }
            }
            for child in node.children {
                collect(child, bounds: bounds)
            }
        }
        for webArea in topWebAreas(root) {
            collect(webArea, bounds: rect(webArea.frame))
        }
        return parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func verticallyInside(
        _ frame: AXNode.Frame, _ bounds: CGRect
    ) -> Bool {
        let minimum = Double(bounds.minY)
        let maximum = Double(bounds.maxY)
        return frame.y + frame.height > minimum && frame.y < maximum
    }

    /// Text frames live in the window's content space even when the web area's
    /// own origin is scrolled away. A preloaded next spread sits beyond the
    /// window's width; a hidden page sits beyond its height.
    private static func insideWindow(
        _ frame: AXNode.Frame, _ window: CGRect
    ) -> Bool {
        let width = Double(window.width)
        let height = Double(window.height)
        return frame.x + frame.width > 0 && frame.x < width
            && frame.y + frame.height > 0 && frame.y < height
    }

    /// Only the outermost web areas: a nested one is already inside the
    /// first, and collecting both would duplicate its text.
    public static func topWebAreas(_ node: AXNode) -> [AXNode] {
        if node.role == "AXWebArea" { return [node] }
        return node.children.flatMap(topWebAreas)
    }

    /// The reader, not the library. The focused window wins when it is known:
    /// with two books open, web-area count and size can pick the wrong one.
    /// A window with no `AXWebArea` is chrome.
    public static func bestWindow(
        _ windows: [AXNode], preferredTitle: String? = nil,
        preferredFrame: CGRect? = nil
    ) -> AXNode? {
        let candidates = windows.filter { webAreaCount(in: $0) > 0 }
        func close(_ node: AXNode, to frame: CGRect) -> Bool {
            guard let own = rect(node.frame) else { return false }
            return abs(own.minX - frame.minX) <= 4
                && abs(own.minY - frame.minY) <= 4
                && abs(own.width - frame.width) <= 4
                && abs(own.height - frame.height) <= 4
        }
        func distance(_ node: AXNode, to frame: CGRect) -> CGFloat {
            guard let own = rect(node.frame) else { return .greatestFiniteMagnitude }
            return abs(own.minY - frame.minY) + abs(own.minX - frame.minX)
        }
        // The title identifies the book; the frame only disambiguates windows
        // that share a title. A title match therefore outranks a frame match
        // against a different book.
        if let preferredTitle, !preferredTitle.isEmpty {
            let titleMatches = candidates.filter { $0.title == preferredTitle }
            if let frame = preferredFrame, !titleMatches.isEmpty {
                return titleMatches.min { distance($0, to: frame) < distance($1, to: frame) }
            }
            if let first = titleMatches.first { return first }
        }
        if let preferredFrame,
            let focused = candidates.first(where: { close($0, to: preferredFrame) })
        {
            return focused
        }
        return candidates.max { left, right in
            let leftAreas = webAreaCount(in: left)
            let rightAreas = webAreaCount(in: right)
            if leftAreas != rightAreas { return leftAreas < rightAreas }
            return area(left.frame) < area(right.frame)
        }
    }

    public static func rect(_ frame: AXNode.Frame?) -> CGRect? {
        guard let frame else { return nil }
        return CGRect(
            x: frame.x, y: frame.y,
            width: frame.width, height: frame.height)
    }

    private static func area(_ frame: AXNode.Frame?) -> Double {
        guard let frame else { return 0 }
        return frame.width * frame.height
    }

    static func walk(_ node: AXNode, visit: (AXNode) -> Void) {
        visit(node)
        for child in node.children {
            walk(child, visit: visit)
        }
    }
}
