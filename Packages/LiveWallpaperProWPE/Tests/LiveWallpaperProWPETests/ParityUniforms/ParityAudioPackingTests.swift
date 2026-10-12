@testable import LiveWallpaperProWPE
import XCTest

final class ParityAudioPackingTests: XCTestCase {
    func testSixUniformsPackAsFourEightAndSixteenFloat4Elements() throws {
        let left: [Float] = Array(repeating: [0.1, 0.4, 0.2, 1, 0.3, 0.9, 0.6, 0.5], count: 8).flatMap(\.self)
        let right = Array(left.reversed())
        var spectrum = WPEParityAudioSpectrum()
        spectrum.advance(left: left, right: right, dt: 1, silence: false)
        let expected: [(String, [Float])] = [
            ("g_AudioSpectrum16Left", Array(repeating: [Float(1), 0.9], count: 8).flatMap(\.self)),
            ("g_AudioSpectrum16Right", Array(repeating: [Float(0.9), 1], count: 8).flatMap(\.self)),
            ("g_AudioSpectrum32Left", Array(repeating: [Float(0.4), 1, 0.9, 0.6], count: 8).flatMap(\.self)),
            ("g_AudioSpectrum32Right", Array(repeating: [Float(0.6), 0.9, 1, 0.4], count: 8).flatMap(\.self)),
            ("g_AudioSpectrum64Left", left),
            ("g_AudioSpectrum64Right", right),
        ]
        var offset = 0
        let variables = expected.map { name, bands in
            defer { offset += bands.count * 4 }
            return WPEStageReflection.CBuffer.Variable(
                name: name, offset: offset, size: bands.count * 4, baseType: .float, class: .vector,
                rows: 1, columns: 4, elements: bands.count / 4, used: true
            )
        }
        let layout = try WPECBufferLayout(.init(name: "g_bufDynamic", register: 1, space: 0,
                                                size: offset, variables: variables))
        var packer = WPECBufferPacker(layout: layout)
        let uniforms = spectrum.uniforms()
        XCTAssertEqual(Set(uniforms.keys), Set(expected.map(\.0)))
        for (name, bands) in expected {
            let value = try XCTUnwrap(uniforms[name])
            guard case let .array(elements) = value else {
                return XCTFail("Expected float4 array for \(name)")
            }
            XCTAssertEqual(elements.count, bands.count / 4)
            for element in elements {
                guard case let .vector(vector) = element else {
                    return XCTFail("Expected float4 for \(name)")
                }
                XCTAssertEqual(vector.count, 4)
            }
            try packer.write(value, to: name)
            let variable = try XCTUnwrap(layout[name])
            for (index, magnitude) in bands.enumerated() {
                let byteOffset = variable.offset + index * 4
                let word = (0 ..< 4).reduce(UInt32(0)) {
                    $0 | UInt32(packer.bytes[byteOffset + $1]) << ($1 * 8)
                }
                XCTAssertEqual(word, magnitude.bitPattern, "\(name)[\(index)]")
            }
            XCTAssertThrowsError(try packer.write(.vector([1, 2, 3, 4]), to: name))
            XCTAssertThrowsError(try packer.write(.array([.float(1)]), to: name))
        }
    }
}
