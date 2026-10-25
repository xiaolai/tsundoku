import CoreGraphics
import Foundation
import Testing
@testable import TsundokuCore

@Suite("Reader theme and sampling policy")
struct ReaderThemeTests {
    private func key(
        kind: ReaderKind = .appleBooks, pid: pid_t = 1,
        windowNumber: UInt32? = 7, width: CGFloat = 800,
        height: CGFloat = 600, title: String = "A Book"
    ) -> StyleSampleKey {
        StyleSampleKey(
            kind: kind, pid: pid, windowNumber: windowNumber,
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            title: title)
    }

    // MARK: Colour

    @Test func aWhitePageIsALightTheme() throws {
        var histogram = ColourHistogram()
        for _ in 0..<800 { histogram.add(red: 255, green: 255, blue: 255) }
        for _ in 0..<200 { histogram.add(red: 30, green: 30, blue: 30) }
        let theme = try #require(histogram.theme(sampled: 1000))
        #expect(abs(theme.share - 0.8) < 0.001)
        #expect(theme.isDark == false)
        #expect(theme.red > 0.99 && theme.green > 0.99 && theme.blue > 0.99)
    }

    @Test func aDarkPageIsADarkTheme() throws {
        var histogram = ColourHistogram()
        for _ in 0..<900 { histogram.add(red: 18, green: 18, blue: 20) }
        for _ in 0..<100 { histogram.add(red: 210, green: 210, blue: 210) }
        let theme = try #require(histogram.theme(sampled: 1000))
        #expect(theme.isDark)
        #expect(theme.share >= 0.89 && theme.share <= 0.91)
    }

    @Test func aSepiaPageKeepsItsColour() throws {
        var histogram = ColourHistogram()
        for _ in 0..<1000 {
            histogram.add(red: 244, green: 236, blue: 216)
        }
        let theme = try #require(histogram.theme(sampled: 1000))
        #expect(theme.isDark == false)
        #expect(abs(theme.red - 244.0 / 255) < 0.01)
        #expect(abs(theme.green - 236.0 / 255) < 0.01)
        #expect(abs(theme.blue - 216.0 / 255) < 0.01)
    }

    @Test func aBoundarySplitBackgroundStillReadsAsOneColour() throws {
        // 239 and 240 land on either side of a quantisation boundary; all
        // eight channel combinations must merge back into one theme.
        var histogram = ColourHistogram()
        for red in [UInt8(239), 240] {
            for green in [UInt8(239), 240] {
                for blue in [UInt8(239), 240] {
                    for _ in 0..<125 {
                        histogram.add(red: red, green: green, blue: blue)
                    }
                }
            }
        }
        let theme = try #require(histogram.theme(sampled: 1000))
        #expect(theme.share > 0.99)
        #expect(abs(theme.red - 239.5 / 255) < 0.01)
        #expect(theme.isDark == false)
    }

    @Test func aSplitBackgroundOutweighsASmallerDistantColour() throws {
        // 1,000 background pixels split across eight neighbouring bins, plus
        // 126 black pixels. No single bin wins, but the merged background does.
        var histogram = ColourHistogram()
        for red in [UInt8(239), 240] {
            for green in [UInt8(239), 240] {
                for blue in [UInt8(239), 240] {
                    for _ in 0..<125 {
                        histogram.add(red: red, green: green, blue: blue)
                    }
                }
            }
        }
        for _ in 0..<126 {
            histogram.add(red: 0, green: 0, blue: 0)
        }
        let theme = try #require(histogram.theme(sampled: 1126))
        #expect(theme.share > 0.88)
        #expect(abs(theme.red - 239.5 / 255) < 0.01)
        #expect(theme.isDark == false)
    }

    @Test func aBusyPictureHasNoTheme() {
        var histogram = ColourHistogram()
        for index in 0..<1000 {
            histogram.add(
                red: UInt8(index % 256),
                green: UInt8((index * 7) % 256),
                blue: UInt8((index * 13) % 256))
        }
        #expect(histogram.theme(sampled: 1000) == nil)
    }

    @Test func aTieBetweenDistantColoursIsNoTheme() {
        var histogram = ColourHistogram()
        for _ in 0..<500 { histogram.add(red: 0, green: 0, blue: 0) }
        for _ in 0..<500 { histogram.add(red: 255, green: 255, blue: 255) }
        #expect(histogram.theme(sampled: 1000) == nil)
    }

    @Test func aTinySampleIsRefused() {
        var histogram = ColourHistogram()
        for _ in 0..<500 { histogram.add(red: 255, green: 255, blue: 255) }
        #expect(histogram.theme(sampled: 500) == nil)
    }

    // MARK: Policy

    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func theSameFreshSurfaceReusesItsSample() {
        #expect(
            StyleSamplePolicy.decide(
                now: now,
                lastAttempt: now.addingTimeInterval(-0.5),
                key: key(), cachedKey: key(),
                cachedAt: now.addingTimeInterval(-5), hasSample: true)
                == .reuse)
    }

    @Test func anAgedSampleIsMeasuredAgain() {
        // A reader can change its font or theme without resizing the window.
        #expect(
            StyleSamplePolicy.decide(
                now: now,
                lastAttempt: now.addingTimeInterval(-120),
                key: key(), cachedKey: key(),
                cachedAt: now.addingTimeInterval(-61), hasSample: true)
                == .sample)
    }

    @Test func aDifferentBookWaitsOutTheInterval() {
        let cached = key(title: "A Book")
        let other = key(title: "Another Book")
        #expect(
            StyleSamplePolicy.decide(
                now: now, lastAttempt: now.addingTimeInterval(-0.5),
                key: other, cachedKey: cached,
                cachedAt: now.addingTimeInterval(-5), hasSample: true)
                == .wait)
        #expect(
            StyleSamplePolicy.decide(
                now: now, lastAttempt: now.addingTimeInterval(-0.75),
                key: other, cachedKey: cached,
                cachedAt: now.addingTimeInterval(-5), hasSample: true)
                == .sample)
    }

    @Test func aResizedOrReidentifiedWindowIsANewSurface() {
        #expect(key(width: 800) != key(width: 1000))
        #expect(key(windowNumber: 7) != key(windowNumber: 8))
        #expect(key(windowNumber: nil) != key(windowNumber: 7))
    }

    @Test func aMissingSampleIsNeverReused() {
        #expect(
            StyleSamplePolicy.decide(
                now: now, lastAttempt: now.addingTimeInterval(-0.1),
                key: key(), cachedKey: key(), cachedAt: nil, hasSample: false)
                == .wait)
    }

    @Test func theFirstAttemptSamples() {
        #expect(
            StyleSamplePolicy.decide(
                now: now, lastAttempt: .distantPast, key: key(),
                cachedKey: nil, cachedAt: nil, hasSample: false) == .sample)
    }

    @Test func aReaderSwitchIsANewSurface() {
        #expect(key(kind: .appleBooks) != key(kind: .kindle))
        #expect(key(pid: 1) != key(pid: 2))
    }
}
