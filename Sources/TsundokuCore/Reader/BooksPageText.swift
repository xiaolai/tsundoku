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

    public static func text(from root: AXNode) -> String {
        // Text can live under one web area while its frame overlaps another
        // (Books exposes three on a reader page), so the visible viewport is
        // the union of every web area frame, clipped to the reader window.
        let window = rect(root.frame)
        let rawFrames = webAreaFrames(in: root)
        var pageFrames = rawFrames
        if let window {
            pageFrames = rawFrames.compactMap {
                let clipped = $0.intersection(window)
                return clipped.isNull ? nil : clipped
            }
            // Web areas exist but none is on screen: this is not a page at
            // all. Returning text here would present off-screen content as
            // the current page; let OCR or the caller decide instead.
            if !rawFrames.isEmpty && pageFrames.isEmpty {
                return ""
            }
        }
        var parts: [String] = []
        let hasViewport = !pageFrames.isEmpty
        func collect(_ node: AXNode) {
            if textRoles.contains(node.role) {
                let value = node.value?.asText ?? ""
                if !value.isEmpty {
                    if hasViewport {
                        // A text node with no frame, or one outside every web
                        // area, cannot be proved visible.
                        guard let frame = rect(node.frame),
                            pageFrames.contains(where: {
                                $0.intersects(frame)
                            })
                        else { return }
                    }
                    parts.append(value)
                    return
                }
                // A container with no value of its own may still have
                // readable children; do not discard them.
            }
            for child in node.children {
                collect(child)
            }
        }
        for webArea in topWebAreas(root) {
            collect(webArea)
        }
        return parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func walk(_ node: AXNode, visit: (AXNode) -> Void) {
        visit(node)
        for child in node.children {
            walk(child, visit: visit)
        }
    }
}
