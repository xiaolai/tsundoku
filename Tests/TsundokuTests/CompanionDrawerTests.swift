import CoreGraphics
import Foundation
import Testing
@testable import TsundokuCore

@Suite("Companion drawer")
struct CompanionDrawerTests {
    private let reader = CGRect(x: 8, y: 222, width: 1024, height: 768)

    @Test func aPanelRightOfTheReaderOpensFromItsLeftEdge() {
        let panel = CGRect(x: 1040, y: 222, width: 400, height: 768)
        let anchor = CompanionDrawer.anchor(panel: panel, reader: reader)
        #expect(anchor == .leading)
        #expect(
            CompanionDrawer.start(of: panel, anchor: anchor)
                == CGRect(x: 1040, y: 222, width: 1, height: 768))
    }

    @Test func aPanelLeftOfTheReaderOpensFromItsRightEdge() {
        let panel = CGRect(x: 92, y: 222, width: 400, height: 768)
        let anchor = CompanionDrawer.anchor(panel: panel, reader: reader)
        #expect(anchor == .trailing)
        #expect(
            CompanionDrawer.start(of: panel, anchor: anchor)
                == CGRect(x: 491, y: 222, width: 1, height: 768))
    }

    @Test func aPanelBelowTheReaderOpensDownwardFromItsTopEdge() {
        let panel = CGRect(x: 8, y: -86, width: 1024, height: 300)
        let anchor = CompanionDrawer.anchor(panel: panel, reader: reader)
        #expect(anchor == .top)
        // The top edge (maxY) stays at 214; the window grows downward.
        #expect(
            CompanionDrawer.start(of: panel, anchor: anchor)
                == CGRect(x: 8, y: 213, width: 1024, height: 1))
    }

    @Test func aPanelAboveTheReaderOpensUpwardFromItsBottomEdge() {
        let panel = CGRect(x: 8, y: 998, width: 1024, height: 300)
        let anchor = CompanionDrawer.anchor(panel: panel, reader: reader)
        #expect(anchor == .bottom)
        #expect(
            CompanionDrawer.start(of: panel, anchor: anchor)
                == CGRect(x: 8, y: 998, width: 1024, height: 1))
    }

    @Test func anOverlayOpensFromTheReadersRightEdge() {
        let panel = CGRect(x: 632, y: 222, width: 400, height: 768)
        let anchor = CompanionDrawer.anchor(panel: panel, reader: reader)
        #expect(anchor == .trailing)
        #expect(
            CompanionDrawer.start(of: panel, anchor: anchor)
                == CGRect(x: 1031, y: 222, width: 1, height: 768))
    }

    @Test func theDrawerStartsFromAThinSliverNotAZeroRect() {
        let panel = CGRect(x: 1040, y: 222, width: 400, height: 768)
        let start = CompanionDrawer.start(of: panel, anchor: .leading)
        #expect(start.width > 0)
        #expect(start.height == panel.height)
    }

    @Test func aSideDrawerUsesAShortEaseOut() {
        #expect(
            CompanionDrawer.motion(for: .leading)
                == CompanionDrawer.Motion(duration: 0.2, curve: .easeOut))
        #expect(CompanionDrawer.motion(for: .trailing).curve == .easeOut)
    }

    @Test func aVerticalDrawerGetsMoreTimeAndAnEaseInOut() {
        let vertical = CompanionDrawer.motion(for: .top)
        #expect(vertical.curve == .easeInEaseOut)
        #expect(vertical.duration > CompanionDrawer.motion(for: .leading).duration)
        #expect(
            CompanionDrawer.motion(for: .bottom).curve == .easeInEaseOut)
    }
}
