import AppKit
import Foundation
import Testing
@testable import TsundokuCore

@Suite("Reader typography")
struct ReaderStyleTests {
    // MARK: Line pitch

    /// A synthetic page: `background`, text bands of `band` rows every
    /// `pitch` rows, and optional noise.
    private func profile(
        rows: Int = 400, pitch: Int = 20, band: Int = 8,
        background: Double = 245, text: Double = 60, noise: Double = 0
    ) -> [Double] {
        var values = [Double](repeating: background, count: rows)
        var row = 30
        while row + band < rows {
            for y in row..<(row + band) { values[y] = text }
            row += pitch
        }
        guard noise > 0 else { return values }
        var generator = SystemRandomNumberGenerator()
        return values.map {
            $0 + Double.random(in: -noise...noise, using: &generator)
        }
    }

    @Test func lightPagePitchIsTheLineSpacing() throws {
        let measurement = try #require(
            LinePitch.measure(rowMeans: profile(), scale: 1))
        #expect(measurement.pitch == 20)
    }

    @Test func darkPageReadsTheSameAsLight() throws {
        let dark = profile(background: 25, text: 210)
        let measurement = try #require(
            LinePitch.measure(rowMeans: dark, scale: 1))
        #expect(measurement.pitch == 20)
    }

    @Test func retinaScaleConvertsPixelsToPoints() throws {
        let measurement = try #require(
            LinePitch.measure(rowMeans: profile(pitch: 40, band: 16), scale: 2))
        #expect(measurement.pitch == 20)
    }

    @Test func noiseAndParagraphGapsKeepTheModalPitch() throws {
        var values = profile(noise: 4)
        // A paragraph gap: blank out one band.
        for y in 190..<210 { values[y] = 245 }
        let measurement = try #require(
            LinePitch.measure(rowMeans: values, scale: 1))
        #expect(measurement.pitch == 20)
    }

    @Test func aSubBandGapDoesNotSplitALine() throws {
        // At 1× a line's ascender and descender rows can be separated by a
        // near-background row; smoothing must keep it one line.
        var values = profile(rows: 400, pitch: 20, band: 10)
        for start in stride(from: 30, to: 380, by: 20) { values[start + 5] = 245 }
        let measurement = try #require(
            LinePitch.measure(rowMeans: values, scale: 1))
        #expect(measurement.pitch == 20)
    }

    @Test func aGapBeyondTheOutlierFactorIsDiscarded() throws {
        // Pitches 20, 21, 22, 23, 40, 40: the two paragraph gaps must not pull
        // the median up. A window of ±35 % around 23 rejects them, leaving 22.
        var values = [Double](repeating: 245, count: 400)
        for start in [10, 30, 51, 73, 96, 136, 176] {
            for y in start..<(min(start + 8, 400)) { values[y] = 60 }
        }
        let measurement = try #require(
            LinePitch.measure(rowMeans: values, scale: 1))
        #expect(measurement.pitch == 22)
    }

    @Test func tooLittleTextIsNotASample() {
        // A title page: four bands, no reliable rhythm.
        #expect(LinePitch.measure(rowMeans: profile(rows: 120), scale: 1) == nil)
        #expect(LinePitch.measure(rowMeans: [Double](repeating: 240, count: 400), scale: 1) == nil)
    }

    // MARK: Mapping

    @Test func booksSizedBodyBecomesAPanelStyle() {
        let style = CompanionTypography.style(
            from: ReaderStyle(
                family: "Charter Roman", pointSize: 23.12, linePitch: 36,
                origin: .accessibilityFont))
        #expect(style.family == "Charter Roman")
        #expect(style.size >= 13 && style.size <= 20)
        #expect(style.lineSpacing >= 0 && style.lineSpacing <= 12)
    }

    @Test func absurdMeasurementsAreClamped() {
        let tiny = CompanionTypography.style(
            from: ReaderStyle(
                family: nil, pointSize: 4, linePitch: 4,
                origin: .measuredPixels))
        #expect(tiny.size == 13)
        #expect(tiny.lineSpacing == 0)
        let huge = CompanionTypography.style(
            from: ReaderStyle(
                family: nil, pointSize: 80, linePitch: 200,
                origin: .measuredPixels))
        #expect(huge.size == 20)
        #expect(huge.lineSpacing == 12)
    }

    @Test func kindlePitchBecomesAPointSize() {
        // A 28 pt pitch divided by the assumed 1.5 leading.
        #expect(MeasuredType.pointSize(forPitch: 28) == CGFloat(28) / 1.5)
        #expect(MeasuredType.pointSize(forPitch: 4) == 12)
        #expect(MeasuredType.pointSize(forPitch: 100) == 28)
    }

    // MARK: AXFont

    @Test func axFontIsReadByItsDocumentedKeys() {
        let parsed = AXFontFace.parse(font: [
            "AXFontName": "Charter Roman",
            "AXFontFamily": "Charter",
            "AXFontSize": NSNumber(value: 23.12),
        ])
        #expect(parsed?.family == "Charter Roman")
        #expect(parsed?.size == 23.12)
        #expect(AXFontFace.parse(font: ["AXFontFamily": "Georgia", "AXFontSize": 17])?.family == "Georgia")
        #expect(AXFontFace.parse(font: ["AXFontName": "X"]) == nil)
        #expect(AXFontFace.parse(font: ["AXFontName": "X", "AXFontSize": 500]) == nil)
    }

    @Test func anEmptyFontNameFallsBackToTheFamily() {
        let parsed = AXFontFace.parse(font: [
            "AXFontName": "", "AXFontFamily": "Georgia", "AXFontSize": 17,
        ])
        #expect(parsed?.family == "Georgia")
    }

    @Test func implausibleSamplesAreRejected() {
        #expect(
            AXFontSample(family: "X", size: .nan, characters: 10) == nil)
        #expect(
            AXFontSample(family: "X", size: .infinity, characters: 10) == nil)
        #expect(AXFontSample(family: "X", size: 1_000, characters: 10) == nil)
        #expect(AXFontSample(family: "", size: 12, characters: 10) == nil)
        #expect(AXFontSample(family: "X", size: 12, characters: 0) == nil)
    }

    @Test func theBodyFaceIsTheOneCoveringMostCharacters() throws {
        let bold = try #require(
            AXFontSample(family: "Charter Bold", size: 34.68, characters: 40))
        let roman = try #require(
            AXFontSample(family: "Charter Roman", size: 23.12, characters: 3200))
        let menlo = try #require(
            AXFontSample(family: "Menlo Regular", size: 15.23, characters: 180))
        let face = AXFontFace.bodyFace(from: [bold, roman, menlo])
        #expect(face?.family == "Charter Roman")
        #expect(face?.size == 23.12)
        #expect(AXFontFace.bodyFace(from: []) == nil)
    }

    @Test func aRoundedBucketKeepsTheDominantExactSize() throws {
        let common = try #require(
            AXFontSample(family: "Georgia", size: 17.92, characters: 3_000))
        let outlier = try #require(
            AXFontSample(family: "Georgia", size: 18.4, characters: 1))
        let face = AXFontFace.bodyFace(from: [outlier, common])
        #expect(face?.size == 17.92)
    }

    @Test func equalWeightsResolveByFirstAppearance() throws {
        let first = try #require(
            AXFontSample(family: "Georgia", size: 17, characters: 500))
        let second = try #require(
            AXFontSample(family: "Georgia", size: 17.92, characters: 500))
        #expect(
            AXFontFace.bodyFace(from: [first, second])?.size == 17)
        #expect(
            AXFontFace.bodyFace(from: [second, first])?.size == 17.92)
    }

    // MARK: Settings

    @Test func anOldSettingsBlobKeepsTypographyMatchingOn() throws {
        let encoded = try JSONEncoder().encode(
            CompanionSettings(panelPlacement: .side))
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any])
        object.removeValue(forKey: "matchReaderTypography")
        object.removeValue(forKey: "matchReaderTheme")
        object.removeValue(forKey: "panelAnimation")
        object.removeValue(forKey: "quickActions")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            CompanionSettings.self, from: legacy)
        #expect(decoded.panelPlacement == .side)
        #expect(decoded.matchReaderTypography)
        #expect(decoded.matchReaderTheme)
        #expect(decoded.panelAnimation == .outward)
        #expect(decoded.quickActions == AIAction.quickActionCases)
    }
}
