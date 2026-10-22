import CoreGraphics
import Foundation
import KindleAX
import Testing

@testable import TsundokuCore

@Suite("Page frame calibration")
struct PageFrameTests {
    private let window = CGRect(
        x: 100, y: 100, width: 763, height: 1050)

    private func node(
        _ role: String, _ frame: CGRect, children: [AXNode] = []
    ) -> AXNode {
        AXNode(
            role: role,
            frame: AXNode.Frame(
                x: frame.minX, y: frame.minY,
                width: frame.width, height: frame.height),
            children: children)
    }

    private func tree(_ children: [AXNode]) -> AXNode {
        node("AXWindow", window, children: children)
    }

    private var titleBar: AXNode {
        node(
            "AXTitleBar",
            CGRect(x: 100, y: 100, width: 763, height: 22))
    }

    private var pageText: CGRect {
        CGRect(x: 152, y: 154, width: 659, height: 942)
    }

    @Test("measured constants are confirmed by chrome and text")
    func confirmed() {
        let tree = tree([titleBar, node("AXStaticText", pageText)])
        let result = PageFrame.resolve(
            window: window, text: pageText, tree: tree)
        #expect(result.status == .confirmed)
        #expect(result.insets == .measured)
        #expect(result.chrome?.top == 22)
    }

    @Test("a box that does not clear chrome is derived when text allows")
    func derived() {
        let rightControl = node(
            "AXButton",
            CGRect(x: 800, y: 500, width: 63, height: 40))
        let text = CGRect(x: 200, y: 200, width: 400, height: 500)
        let tree = tree([titleBar, rightControl, node("AXStaticText", text)])
        let result = PageFrame.resolve(
            window: window, text: text, tree: tree)
        #expect(result.status == .derived)
        #expect(result.insets.left == 71)
        #expect(result.insets.right == 71)
        #expect(result.insets.top == 30)
    }

    @Test("a box that cannot fit chrome and text is refused")
    func refused() {
        let rightControl = node(
            "AXButton",
            CGRect(x: 800, y: 500, width: 63, height: 40))
        let text = CGRect(x: 120, y: 120, width: 700, height: 1000)
        let tree = tree([titleBar, rightControl, node("AXStaticText", text)])
        let result = PageFrame.resolve(
            window: window, text: text, tree: tree)
        #expect(result.status == .refused)
    }

    @Test("a tree with no measurable chrome is unverified")
    func unverified() {
        let tree = tree([node("AXGroup", window)])
        let result = PageFrame.resolve(
            window: window, text: pageText, tree: tree)
        #expect(result.status == .unverified)
        #expect(result.insets == .measured)
    }

    @Test("a tree for another window is unverified")
    func windowDrift() {
        let other = AXNode(
            role: "AXWindow",
            frame: AXNode.Frame(x: 0, y: 0, width: 500, height: 500))
        let result = PageFrame.resolve(
            window: window, text: pageText, tree: other)
        #expect(result.status == .unverified)
    }

    @Test("text headroom at the measured scrolled-page limit is refused")
    func scrolledPage() {
        let text = CGRect(x: 152, y: 119, width: 523, height: 742)
        let tree = tree([titleBar, node("AXStaticText", text)])
        let result = PageFrame.resolve(
            window: window, text: text, tree: tree)
        #expect(result.status == .refused)
    }
}
