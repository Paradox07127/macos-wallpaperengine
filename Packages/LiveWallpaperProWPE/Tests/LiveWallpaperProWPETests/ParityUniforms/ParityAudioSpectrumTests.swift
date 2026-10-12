@testable import LiveWallpaperProWPE
import XCTest

final class ParityAudioSpectrumTests: XCTestCase {
    private func bins(_ value: Float) -> [Float] {
        [Float](repeating: value, count: 64)
    }

    private func bands(_ spectrum: WPEParityAudioSpectrum, _ name: String) throws -> [Float] {
        let value = try XCTUnwrap(spectrum.uniforms()[name])
        guard case let .array(elements) = value else {
            XCTFail("Expected float4 array")
            return []
        }
        return elements.flatMap { element -> [Float] in
            guard case let .vector(vector) = element else {
                XCTFail("Expected float4 element")
                return []
            }
            XCTAssertEqual(vector.count, 4)
            return vector
        }
    }

    func testEightBinGroupingUsesMaxWithoutReplacingIndividualBins() {
        var input = bins(0)
        input[0] = 0.2
        input[7] = 0.8
        var spectrum = WPEParityAudioSpectrum()
        spectrum.advance(left: input, right: bins(0), dt: 1, silence: false)
        XCTAssertEqual(spectrum.left64[0], 0.2 / 0.9, accuracy: 0.000001)
        XCTAssertEqual(spectrum.left64[7], 0.8 / 0.9, accuracy: 0.000001)
        XCTAssertEqual(spectrum.left64[1], 0)

        input[7] = 0
        input[8] = 0.8
        var control = WPEParityAudioSpectrum()
        control.advance(left: input, right: bins(0), dt: 1, silence: false)
        XCTAssertEqual(control.left64[0], 0.2 / 0.6332, accuracy: 0.000001)
        XCTAssertEqual(control.left64[8], 0.8 / 0.9, accuracy: 0.000001)
    }

    func testGroupedFloorUsesGlobalMaximumAcrossBothChannels() {
        var left = bins(0)
        var right = bins(0)
        left[0] = 0.1
        right[63] = 1
        var spectrum = WPEParityAudioSpectrum()
        spectrum.advance(left: left, right: right, dt: 1, silence: false)
        XCTAssertEqual(spectrum.left64[0], 0.1 / 0.6665, accuracy: 0.000001)
        XCTAssertEqual(spectrum.right64[63], 1)

        right[63] = 0.2
        var control = WPEParityAudioSpectrum()
        control.advance(left: left, right: right, dt: 1, silence: false)
        XCTAssertEqual(control.left64[0], 0.1 / 0.55, accuracy: 0.000001)
    }

    func testPeakBootstrapRiseFallAndStepLimit() {
        var seeded = WPEParityAudioSpectrum()
        seeded.advance(left: bins(0.5), right: bins(0.5), dt: 1, silence: false)
        XCTAssertEqual(seeded.left64[0], 2.0 / 3, accuracy: 0.000001)

        // Starting peak is 0.75; only the target changes between these branches.
        for (input, peak): (Float, Float) in [(0.9, 0.85), (0.7, 0.725), (0.1, 0.7), (0.75, 0.75)] {
            var spectrum = seeded
            spectrum.advance(left: bins(input), right: bins(input), dt: 0.1, silence: false)
            XCTAssertEqual(spectrum.left64[0], input / peak, accuracy: 0.000001)
            XCTAssertEqual(spectrum.right64[0], input / peak, accuracy: 0.000001)
        }
    }

    func testNormalizationUsesPointZeroZeroOneFloor() {
        for (input, expected): (Float, Float) in [(0.0005, 0.5), (0.002, 1)] {
            var spectrum = WPEParityAudioSpectrum()
            for _ in 0 ..< 32 {
                spectrum.advance(left: bins(input), right: bins(input), dt: 1, silence: false)
            }
            XCTAssertEqual(spectrum.left64[0], expected, accuracy: 0.000001)
        }
    }

    func testSmoothingAtSixtyFramesPerSecond() {
        var seeded = WPEParityAudioSpectrum()
        seeded.advance(left: bins(1), right: bins(1), dt: 1, silence: false)
        for (input, expected): (Float, Float) in [(0.3, 23.0 / 30), (0.6, 13.0 / 15)] {
            var left = bins(1)
            left[0] = input
            var spectrum = seeded
            spectrum.advance(left: left, right: bins(1), dt: 1.0 / 60, silence: false)
            XCTAssertEqual(spectrum.left64[0], expected, accuracy: 0.000001)
            XCTAssertEqual(spectrum.left64[1], 1)
        }
    }

    func testSmoothingCoefficientSaturatesAtPointOneSeconds() {
        var seeded = WPEParityAudioSpectrum()
        seeded.advance(left: bins(1), right: bins(1), dt: 1, silence: false)
        var left = bins(1)
        left[0] = 0.3
        for (dt, expected): (Float, Float) in [(0.1, 0.3), (0.025, 0.65)] {
            var spectrum = seeded
            spectrum.advance(left: left, right: bins(1), dt: dt, silence: false)
            XCTAssertEqual(spectrum.left64[0], expected, accuracy: 0.000001)
        }
    }

    func testRateLimitRiseAndUnsaturatedControl() {
        var left = bins(0)
        left[1] = 1
        var seeded = WPEParityAudioSpectrum()
        seeded.advance(left: left, right: bins(0), dt: 1, silence: false)
        for (input, expected): (Float, Float) in [(100, 0.4), (1, 0.2)] {
            left[0] = input
            var spectrum = seeded
            spectrum.advance(left: left, right: bins(0), dt: 0.01, silence: false)
            XCTAssertEqual(spectrum.left64[0], expected, accuracy: 0.000001)
        }
    }

    func testRateLimitSaturatesAtOneInBothDirections() {
        var spectrum = WPEParityAudioSpectrum()
        spectrum.advance(left: bins(100), right: bins(100), dt: 1, silence: false)
        XCTAssertEqual(spectrum.left64[0], 1)
        spectrum.advance(left: bins(100), right: bins(100), dt: 1, silence: false)
        XCTAssertEqual(spectrum.left64[0], 2)
        spectrum.advance(left: bins(0), right: bins(0), dt: 0.1, silence: false)
        XCTAssertEqual(spectrum.left64[0], 1)
        spectrum.advance(left: bins(0), right: bins(0), dt: 0.01, silence: false)
        XCTAssertEqual(spectrum.left64[0], 0.6, accuracy: 0.000001)

        var control = WPEParityAudioSpectrum()
        control.advance(left: bins(0.25), right: bins(0.25), dt: 1, silence: false)
        XCTAssertEqual(control.left64[0], 0.4, accuracy: 0.000001)
        control.advance(left: bins(0), right: bins(0), dt: 0.1, silence: false)
        XCTAssertEqual(control.left64[0], 0)
    }

    func testSmoothingHistoryIsIndependentOfRateLimitedHistory() {
        for (input, expected): (Float, Float) in [(100, 1.4), (1, 0.8)] {
            var spectrum = WPEParityAudioSpectrum()
            spectrum.advance(left: bins(input), right: bins(input), dt: 1, silence: false)
            XCTAssertEqual(spectrum.left64[0], 1)
            spectrum.advance(left: bins(0), right: bins(0), dt: 0.01, silence: false)
            XCTAssertEqual(spectrum.left64[0], expected, accuracy: 0.000001)
        }
    }

    func testSilenceClearsUniformsAndRetainsHistory() throws {
        var spectrum = WPEParityAudioSpectrum()
        spectrum.advance(left: bins(0.5), right: bins(0.5), dt: 1, silence: false)
        XCTAssertEqual(spectrum.left64[0], 2.0 / 3, accuracy: 0.000001)
        var control = spectrum
        spectrum.advance(left: bins(0), right: bins(0), dt: 0, silence: true)
        for name in spectrum.uniforms().keys {
            XCTAssertTrue(try bands(spectrum, name).allSatisfy { $0 == 0 })
        }
        control.advance(left: bins(0), right: bins(0), dt: 0, silence: false)
        XCTAssertEqual(control.left64[0], 2.0 / 3, accuracy: 0.000001)
        spectrum.advance(left: bins(0), right: bins(0), dt: 0.1, silence: true)
        spectrum.advance(left: bins(0.5), right: bins(0.5), dt: 0, silence: false)
        XCTAssertEqual(spectrum.left64[0], 2.0 / 3, accuracy: 0.000001)
        spectrum.advance(left: bins(0.5), right: bins(0.5), dt: 0.1, silence: false)
        XCTAssertEqual(spectrum.left64[0], 10.0 / 13, accuracy: 0.000001)
    }

    func testPoolingToThirtyTwoAndSixteenBands() throws {
        let pattern: [Float] = [0.1, 0.4, 0.2, 1, 0.3, 0.9, 0.6, 0.5]
        let left = Array(repeating: pattern, count: 8).flatMap(\.self)
        let right = Array(left.reversed())
        var spectrum = WPEParityAudioSpectrum()
        spectrum.advance(left: left, right: right, dt: 1, silence: false)
        XCTAssertEqual(try bands(spectrum, "g_AudioSpectrum32Left"),
                       Array(repeating: [Float(0.4), 1, 0.9, 0.6], count: 8).flatMap(\.self))
        XCTAssertEqual(try bands(spectrum, "g_AudioSpectrum16Left"),
                       Array(repeating: [Float(1), 0.9], count: 8).flatMap(\.self))
        XCTAssertEqual(try bands(spectrum, "g_AudioSpectrum32Right"),
                       Array(repeating: [Float(0.6), 0.9, 1, 0.4], count: 8).flatMap(\.self))
        XCTAssertEqual(try bands(spectrum, "g_AudioSpectrum16Right"),
                       Array(repeating: [Float(0.9), 1], count: 8).flatMap(\.self))

        var controlInput = left
        controlInput.swapAt(1, 3)
        var control = WPEParityAudioSpectrum()
        control.advance(left: controlInput, right: right, dt: 1, silence: false)
        XCTAssertEqual(try bands(control, "g_AudioSpectrum32Left").prefix(2), [1, 0.4])
        XCTAssertEqual(try bands(control, "g_AudioSpectrum16Left").prefix(2), [1, 0.9])
        controlInput = left
        controlInput.swapAt(3, 7)
        control = WPEParityAudioSpectrum()
        control.advance(left: controlInput, right: right, dt: 1, silence: false)
        XCTAssertEqual(try bands(control, "g_AudioSpectrum16Left").prefix(2), [0.5, 1])
    }

    func testValuesAboveOneSurviveAllUniformResolutions() throws {
        var seeded = WPEParityAudioSpectrum()
        seeded.advance(left: bins(0.5), right: bins(0.5), dt: 1, silence: false)
        var spectrum = seeded
        spectrum.advance(left: bins(2), right: bins(2), dt: 0.1, silence: false)
        for name in spectrum.uniforms().keys {
            for value in try bands(spectrum, name) {
                XCTAssertEqual(value, 5.0 / 3, accuracy: 0.000001)
            }
        }
        var control = seeded
        control.advance(left: bins(0.5), right: bins(0.5), dt: 0.1, silence: false)
        XCTAssertEqual(control.left64[0], 5.0 / 7, accuracy: 0.000001)
    }
}
