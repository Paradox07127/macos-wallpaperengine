import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityShaderCacheTests: XCTestCase {
    private let program = WPEHLSLProgram(vertex: [0, 255, 1], geometry: [2], fragment: [3, 4])

    private func key(program: WPEHLSLProgram? = nil, identity: String = "DXC 1.8; MSC 4.0.1",
                     options: WPEParityShaderCompileOptions = .init(), abi: Int = 1, format: Int = 1) -> WPEParityShaderKey {
        .init(program: program ?? self.program, compilerIdentity: identity, options: options,
              bindingABIVersion: abi, keyFormatVersion: format)
    }

    func testStableLowercaseSHA256() {
        XCTAssertEqual(key(), key())
        // Retain the independent old encoding vector with its original, explicitly unchecked option.
        XCTAssertEqual(key(options: .init(boundsCheck: false)).rawValue,
                       "a0360743b954956a2bbe3093e4d2dd917c927438f0341917803f93c96aea3a38")
        XCTAssertEqual(key().rawValue.count, 64)
        XCTAssertTrue(key().rawValue.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testEveryStageByteAndPresenceChangesKey() {
        var changed = program
        changed.vertex = [0, 255, 2]
        XCTAssertNotEqual(key(), key(program: changed))
        changed = program
        changed.fragment = [3, 5]
        XCTAssertNotEqual(key(), key(program: changed))
        changed = program
        changed.geometry = [3]
        XCTAssertNotEqual(key(), key(program: changed))
        for stage in WPEParityShaderKey.Stage.allCases {
            var absent = program
            var empty = program
            switch stage {
            case .vertex: absent.vertex = nil; empty.vertex = []
            case .fragment: absent.fragment = nil; empty.fragment = []
            case .geometry: absent.geometry = nil; empty.geometry = []
            }
            XCTAssertNotEqual(key(), key(program: absent))
            XCTAssertNotEqual(key(program: absent), key(program: empty))
        }
    }

    func testStageNamesAndLengthPrefixesDistinguishInputs() {
        XCTAssertNotEqual(key(program: .init(vertex: [1])), key(program: .init(fragment: [1])))
        XCTAssertNotEqual(key(program: .init(vertex: [1], fragment: [2, 3])),
                          key(program: .init(vertex: [1, 2], fragment: [3])))
        XCTAssertNotEqual(key(identity: "ab", options: .init(hlslVersion: "c")),
                          key(identity: "a", options: .init(hlslVersion: "bc")))
    }

    func testBothCompilerVersionsChangeKey() {
        XCTAssertNotEqual(key(), key(identity: "DXC 1.9; MSC 4.0.1"))
        XCTAssertNotEqual(key(), key(identity: "DXC 1.8; MSC 4.0.2"))
    }

    func testEachCompileOptionChangesKey() {
        XCTAssertNotEqual(key(), key(options: .init(hlslVersion: "2021")))
        XCTAssertNotEqual(key(), key(options: .init(minimumMacOS: "15.0.0")))
        XCTAssertTrue(WPEParityShaderCompileOptions().boundsCheck)
        XCTAssertNotEqual(key(), key(options: .init(boundsCheck: false)))
    }

    func testBothVersionsChangeKey() {
        XCTAssertNotEqual(key(), key(abi: 2))
        XCTAssertNotEqual(key(), key(format: 2))
    }

    func testManifestRoundTrip() throws {
        let record = WPEParityShaderCacheManifest.FileRecord(data: Data("abc".utf8))
        XCTAssertEqual(record.byteCount, 3)
        XCTAssertEqual(record.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let manifest = WPEParityShaderCacheManifest(
            key: key(), stages: [.vertex, .fragment, .geometry],
            files: ["vertex.metallib": record, "vertex.json": .init(data: Data())],
            createdAt: Date(timeIntervalSince1970: 123_456)
        )
        let decoded = try JSONDecoder().decode(WPEParityShaderCacheManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
    }
}
