import CoreGraphics
import Foundation
import Testing
@testable import TsundokuCore

@Suite("Reader theme and sampling policy")
struct ReaderThemeTests {
    private func key(
        kind: ReaderKind = .appleBooks, pid: pid_t = 1, width: CGFloat = 800,
        height: CGFloat = 600, title: String = "A Book"
    ) -> StyleSampleKey {
        StyleSampleKey(
            kind: kind, pid: pid,
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

    @Test func aTinySampleIsRefused() {
        var histogram = ColourHistogram()
        for _ in 0..<500 { histogram.add(red: 255, green: 255, blue: 255) }
        #expect(histogram.theme(sampled: 500) == nil)
    }

    // MARK: Policy

    @Test func theSameSurfaceReusesItsSample() {
        #expect(
            StyleSamplePolicy.decide(
                now: Date(timeIntervalSince1970: 100),
                lastAttempt: Date(timeIntervalSince1970: 99.5),
                key: key(), cachedKey: key(), hasSample: true) == .reuse)
    }

    @Test func aDifferentBookWaitsOutTheInterval() {
        let cached = key(title: "A Book")
        let other = key(title: "Another Book")
        #expect(
            StyleSamplePolicy.decide(
                now: Date(timeIntervalSince1970: 100),
                lastAttempt: Date(timeIntervalSince1970: 99.5),
                key: other, cachedKey: cached, hasSample: true) == .wait)
        #expect(
            StyleSamplePolicy.decide(
                now: Date(timeIntervalSince1970: 100.75),
                lastAttempt: Date(timeIntervalSince1970: 99.5),
                key: other, cachedKey: cached, hasSample: true) == .sample)
    }

    @Test func aResizedWindowIsANewSurface() {
        let cached = key(width: 800)
        #expect(cached != key(width: 1000))
    }

    @Test func aMissingSampleIsNeverReused() {
        #expect(
            StyleSamplePolicy.decide(
                now: Date(timeIntervalSince1970: 100),
                lastAttempt: Date(timeIntervalSince1970: 99.9),
                key: key(), cachedKey: key(), hasSample: false) == .wait)
    }

    @Test func theFirstAttemptSamples() {
        #expect(
            StyleSamplePolicy.decide(
                now: Date(timeIntervalSince1970: 100),
                lastAttempt: .distantPast, key: key(), cachedKey: nil,
                hasSample: false) == .sample)
    }

    @Test func aReaderSwitchIsANewSurface() {
        #expect(key(kind: .appleBooks) != key(kind: .kindle))
        #expect(key(pid: 1) != key(pid: 2))
    }
}
