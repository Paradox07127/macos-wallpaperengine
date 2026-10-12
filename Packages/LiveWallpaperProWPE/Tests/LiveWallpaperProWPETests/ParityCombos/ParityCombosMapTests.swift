@testable import LiveWallpaperProWPE
import XCTest

final class ParityCombosMapTests: XCTestCase {
    func testEmptyBucketTailAndCollisionFrontInsertion() {
        var map = WPEMSVCUnorderedMap<String, Int32>()
        // Low three hash bits: a/i/q = 4, b = 5, c = 2.
        for (index, key) in ["a", "b", "i", "c", "q"].enumerated() {
            map.set(key, value: Int32(index))
        }
        XCTAssertEqual(map.keys, ["q", "i", "a", "b", "c"])
        map.set("i", value: 99)
        map.setIfMissing("i", value: 0)
        XCTAssertEqual(map.keys, ["q", "i", "a", "b", "c"])
        XCTAssertEqual(map["i"], 99)
        XCTAssertEqual(map.bucketCount, 8)
    }

    func testCopyReversesEachBucketWithoutMovingBucketGroups() {
        var map = WPEMSVCUnorderedMap<String, Int32>()
        for key in ["a", "b", "i", "c", "q"] {
            map.set(key, value: 1)
        }
        let copy = map.copyAssigned()
        XCTAssertEqual(copy.keys, ["a", "i", "q", "b", "c"])
        XCTAssertEqual(copy.copyAssigned().keys, map.keys)
        XCTAssertEqual(map.keys, ["q", "i", "a", "b", "c"])
        var disabled = WPEMSVCUnorderedMap<String, Int32>(copyReversalEnabled: false)
        for key in ["a", "b", "i", "c", "q"] {
            disabled.set(key, value: 1)
        }
        XCTAssertEqual(disabled.copyAssigned().keys, ["q", "i", "a", "b", "c"])
    }

    func testGrowthAtEightAndSixtyFourThenPowerOfTwoGrowth() {
        var map = WPEMSVCUnorderedMap<Int32, Int32>()
        // Four-byte LE FNV hashes of 0...7, 0...63, and 0...64 occupy distinct buckets
        // at 8, 64, and 512 respectively, so every insertion below appends.
        for key: Int32 in 0 ..< 8 {
            map.set(key, value: key)
        }
        XCTAssertEqual(map.bucketCount, 8)
        XCTAssertEqual(map.keys, Array(Int32(0) ..< 8))
        map.set(7, value: -1)
        XCTAssertEqual(map.bucketCount, 8)
        map.set(8, value: 8)
        XCTAssertEqual(map.bucketCount, 64)
        XCTAssertEqual(map.keys, Array(Int32(0) ... 8))
        for key: Int32 in 9 ..< 64 {
            map.set(key, value: key)
        }
        XCTAssertEqual(map.bucketCount, 64)
        XCTAssertEqual(map.keys, Array(Int32(0) ..< 64))
        map.set(64, value: 64)
        XCTAssertEqual(map.bucketCount, 512)
        XCTAssertEqual(map.keys, Array(Int32(0) ... 64))
        for key: Int32 in 65 ..< 512 {
            map.set(key, value: key)
        }
        XCTAssertEqual(map.bucketCount, 512)
        map.set(512, value: 512)
        XCTAssertEqual(map.bucketCount, 1024)
        XCTAssertEqual(Set(map.keys), Set(Int32(0) ... 512))
    }

    func testPythonReferenceStringOrders() {
        // Hard-coded umap.py outputs, including a growth rehash.
        var map = WPEMSVCUnorderedMap<String, Int32>()
        for key in ["FOG", "LIGHTING", "REFLECTION", "TINTMASKALPHA", "HDR", "BACKBUFFER_MS", "REVERSEDEPTH"] {
            map.set(key, value: 0)
        }
        XCTAssertEqual(map.keys, ["FOG", "HDR", "LIGHTING", "REFLECTION", "TINTMASKALPHA", "BACKBUFFER_MS", "REVERSEDEPTH"])
        XCTAssertEqual(map.copyAssigned().keys, ["FOG", "LIGHTING", "HDR", "REFLECTION", "TINTMASKALPHA", "BACKBUFFER_MS", "REVERSEDEPTH"])
        var grown = WPEMSVCUnorderedMap<String, Int32>()
        for key in "abcdefghi" {
            grown.set(String(key), value: 1)
        }
        XCTAssertEqual(grown.keys, Array("abcdefghi").map(String.init))
        XCTAssertEqual(grown.copyAssigned().keys, Array("abcdefghi").map(String.init))
        // std::string compares bytes, while Swift String equality normalizes Unicode.
        var byteKeys = WPEMSVCUnorderedMap<String, Int32>()
        byteKeys.set("\u{E9}", value: 1)
        byteKeys.set("e\u{301}", value: 2)
        XCTAssertEqual(byteKeys.keys.count, 2)
        XCTAssertEqual(byteKeys["\u{E9}"], 1)
        XCTAssertEqual(byteKeys["e\u{301}"], 2)
    }

    func testPythonReferenceSignedInt32Orders() {
        var map = WPEMSVCUnorderedMap<Int32, Int32>()
        for key: Int32 in [-1, 0, 1, 8, 16] {
            map.set(key, value: key)
        }
        XCTAssertEqual(map.keys, [-1, 16, 8, 0, 1])
        XCTAssertEqual(map.copyAssigned().keys, [-1, 0, 8, 16, 1])
        XCTAssertEqual(map.copyAssigned().copyAssigned().keys, [-1, 16, 8, 0, 1])
        XCTAssertEqual(map[-1], -1)
    }
}
