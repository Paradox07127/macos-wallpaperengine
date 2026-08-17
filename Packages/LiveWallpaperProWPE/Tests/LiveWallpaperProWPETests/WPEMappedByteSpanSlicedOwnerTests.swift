import Foundation
import Testing
@testable import LiveWallpaperProWPE

/// `WPEMappedByteSpan.range` is buffer-relative, not `Data` index space.
/// Every current provider hands the span a whole-file mapping whose
/// `startIndex == 0`, where the two spaces coincide — so a regression to
/// `Data`-index arithmetic (e.g. `owner[range.lowerBound + offset]` or
/// `owner.subdata(in: range)`) would pass every whole-mapping test and only
/// misread once an owner with `startIndex != 0` appears. These tests pin the
/// contract on a sliced owner so that regression goes red immediately.
@Suite("WPEMappedByteSpan over a sliced owner")
struct WPEMappedByteSpanSlicedOwnerTests {

    /// Bytes 0..<64 so value == absolute file offset; slice drops the first 16.
    private let full = Data((0..<64).map { UInt8($0) })
    private var sliced: Data { full[16...] }

    @Test("Sliced owner has a non-zero startIndex (probe precondition)")
    func slicedOwnerHasNonZeroStartIndex() {
        #expect(sliced.startIndex == 16)
        #expect(sliced.count == 48)
    }

    @Test("byte(at:) reads buffer-relative offsets")
    func byteAtIsBufferRelative() {
        let span = WPEMappedByteSpan(owner: sliced, range: 4..<12)
        #expect(span.byte(at: 0) == 20)
        #expect(span.byte(at: 7) == 27)
    }

    @Test("withUnsafeBytes windows the slice, not the original file")
    func withUnsafeBytesIsBufferRelative() {
        let span = WPEMappedByteSpan(owner: sliced, range: 4..<12)
        span.withUnsafeBytes { buffer in
            #expect(buffer.count == 8)
            #expect(buffer.first == 20)
            #expect(buffer.last == 27)
        }
    }

    @Test("materializedData and prefix stay buffer-relative")
    func materializeAndPrefixAreBufferRelative() {
        let span = WPEMappedByteSpan(owner: sliced, range: 4..<12)
        #expect(span.materializedData() == Data([20, 21, 22, 23, 24, 25, 26, 27]))
        #expect(span.prefix(3).materializedData() == Data([20, 21, 22]))
    }

    @Test("init(data:) over a slice covers exactly the slice bytes")
    func initDataOverSliceCoversSliceBytes() {
        let span = WPEMappedByteSpan(data: sliced)
        #expect(span.count == 48)
        #expect(span.byte(at: 0) == 16)
        #expect(span.byte(at: 47) == 63)
    }

    @Test("Content equality holds across sliced and whole owners")
    func equalityAcrossSlicedAndWholeOwners() {
        let fromSlice = WPEMappedByteSpan(owner: sliced, range: 4..<8)
        let fromWhole = WPEMappedByteSpan(owner: full, range: 20..<24)
        #expect(fromSlice == fromWhole)
    }
}
