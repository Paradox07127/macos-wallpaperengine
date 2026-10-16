import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityAudioProviderTests: XCTestCase {
    private func sine(bin: Int) -> [Float] {
        (0 ..< 1392).map { Float(0.5 * sin(2 * Double.pi * Double(bin) * Double($0) / 2089)) }
    }

    private func argmax(_ values: ArraySlice<Float>) -> Int {
        values.indices.max { values[$0] < values[$1] }! - values.startIndex
    }

    func testFrameLayout() {
        for (rate, layout) in [(44100.0, [1920, 640, 1280]), (48000, [2089, 640, 1392]), (96000, [4179, 640, 2786])] {
            let provider = WPEParityAudioProvider(sampleRate: rate)
            XCTAssertEqual([provider.fftSize, provider.analyzedBins, provider.frameSamples], layout, "\(rate)")
        }
    }

    func testBandTable() {
        let table = WPEParityAudioProvider(sampleRate: 48000).bandOfBin
        XCTAssertEqual(table.count, 639)
        XCTAssertEqual(Array(table[0 ..< 30]), Array(0 ..< 30))
        XCTAssertEqual(table[30], 29)
        let firsts = (30 ..< 64).map { band in table.firstIndex(of: band) }
        XCTAssertEqual(firsts, [
            31, 36, 40, 46, 51, 58, 64, 72, 80, 89, 98, 108, 119, 131, 143, 157, 171,
            186, 203, 220, 239, 258, 279, 301, 324, 349, 375, 403, 432, 462, 494, 528, 563, 600,
        ])
    }

    func testImpulse() {
        var left = [Float](repeating: 0, count: 1392)
        left[1391] = 1
        let bins = WPEParityAudioProvider(sampleRate: 48000).bins(left: left, right: [Float](repeating: 0, count: 1392))
        XCTAssertEqual(bins.count, 128)
        XCTAssertEqual(bins[0], 0.003480066, accuracy: 2e-5)
        XCTAssertEqual(bins[29], 0.006702122, accuracy: 2e-5)
        XCTAssertEqual(bins[63], 0.0778169, accuracy: 2e-5)
        XCTAssertEqual(Array(bins[64...]), [Float](repeating: 0, count: 64))
    }

    func testBin100Sine() {
        let samples = sine(bin: 100)
        let bins = WPEParityAudioProvider(sampleRate: 48000).bins(left: samples, right: samples)
        XCTAssertEqual(argmax(bins[0 ..< 64]), 40)
        XCTAssertEqual(bins[40], 6.620, accuracy: 0.01)
        XCTAssertEqual(bins[39], 1.346, accuracy: 0.01)
        XCTAssertEqual(bins[41], 0.299, accuracy: 0.01)
        XCTAssertEqual(Array(bins[64...]), Array(bins[0 ..< 64]))
    }

    func testBin10Sine() {
        let samples = sine(bin: 10)
        let bins = WPEParityAudioProvider(sampleRate: 48000).bins(left: samples, right: samples)
        XCTAssertEqual(argmax(bins[0 ..< 64]), 9)
        XCTAssertEqual(bins[9], 1.336, accuracy: 0.01)
        XCTAssertEqual(bins[8], 0.564, accuracy: 0.01)
        XCTAssertEqual(bins[10], 0.572, accuracy: 0.01)
    }

    func testMinusOneZeroesChannel() {
        var left = sine(bin: 100)
        left[5] = -1
        let bins = WPEParityAudioProvider(sampleRate: 48000).bins(left: left, right: sine(bin: 100))
        XCTAssertEqual(Array(bins[0 ..< 64]), [Float](repeating: 0, count: 64))
        XCTAssertGreaterThan(bins[64 + 40], 1)
    }

    func testVolume() {
        let samples = sine(bin: 100)
        let provider = WPEParityAudioProvider(sampleRate: 48000)
        let unit = provider.bins(left: samples, right: samples)
        let doubled = provider.bins(left: samples, right: samples, volume: 2)
        for (base, scaled) in zip(unit, doubled) {
            XCTAssertEqual(scaled, 2 * base, accuracy: 1e-5 * max(abs(2 * base), 1e-30))
        }
    }
}
