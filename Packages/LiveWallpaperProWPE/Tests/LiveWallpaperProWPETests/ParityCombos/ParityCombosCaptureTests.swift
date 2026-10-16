import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityCombosCaptureTests: XCTestCase {
    func testEveryCapture() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing manifest.json and r3/jsrc.tsv")
        }
        let fixture = try ParityCombosCaptureFixture(root: URL(fileURLWithPath: directory))
        var matched = 0
        var mismatches: [String] = []
        for input in fixture.inputs {
            let result = input.resolve()
            if result == input.expected {
                matched += 1
            } else {
                mismatches.append("n=\(input.entry.n) \(input.entry.name)\nexpected: \(input.expected)\nactual: \(result)")
            }
        }
        XCTAssertEqual(fixture.inputs.count, 145)
        XCTAssertEqual(matched, 145, mismatches.prefix(3).joined(separator: "\n"))
    }
}
