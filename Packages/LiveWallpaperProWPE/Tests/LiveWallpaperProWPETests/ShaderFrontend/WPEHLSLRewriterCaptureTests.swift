import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class WPEHLSLRewriterCaptureTests: XCTestCase {
    func testShaderFrontendReproducesEveryCaptureByteForByte() throws {
        guard let dir = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set WPE_HLSL_CAPTURE_DIR to the hlsl-capture fixture directory (the one holding manifest.json)")
        }
        let fixture = try WPEHLSLCaptureFixture(root: URL(fileURLWithPath: dir))
        var exact = 0
        var mismatches: [String] = []
        for entry in fixture.entries {
            do {
                let (expected, actual) = try fixture.reproduce(entry)
                if expected == actual {
                    exact += 1
                } else {
                    mismatches.append("n=\(entry.n) \(entry.name): \(Self.firstDifference(expected, actual))")
                }
            } catch {
                mismatches.append("n=\(entry.n) \(entry.name): \(error)")
            }
        }
        print("exact \(exact)/\(fixture.entries.count)")
        for line in mismatches.prefix(10) {
            print(line)
        }
        XCTAssertEqual(fixture.entries.count, 145)
        XCTAssertEqual(exact, 145, mismatches.prefix(3).joined(separator: "\n"))
    }

    private static func firstDifference(_ expected: [UInt8], _ actual: [UInt8]) -> String {
        let want = expected.split(separator: Latin1.lf, omittingEmptySubsequences: false)
        let got = actual.split(separator: Latin1.lf, omittingEmptySubsequences: false)
        for i in 0 ..< max(want.count, got.count) {
            let a = i < want.count ? Latin1.string(want[i]) : "<EOF>"
            let b = i < got.count ? Latin1.string(got[i]) : "<EOF>"
            if a != b {
                return "L\(i + 1)\n    want \(a.debugDescription)\n    got  \(b.debugDescription)"
            }
        }
        return "same lines, bytes differ"
    }
}
