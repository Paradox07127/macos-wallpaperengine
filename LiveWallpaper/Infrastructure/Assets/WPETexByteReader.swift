#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Lightweight cursor over an immutable `Data` slice. Used by the `.tex`
/// decoder to read little-endian integers and 8-byte ASCII block magics
/// without allocating intermediate `String` / `NSData` wrappers.
///
/// Block magics in WPE `.tex` files always come as a NUL-terminated 8-byte
/// ASCII run (`TEXV0005\0`, `TEXI0001\0`, …). The reader strips the NUL
/// terminator and returns the canonical 8-character form so the decoder
/// can prefix-match (`hasPrefix("TEXV")`).
struct WPETexByteReader {
    let data: Data
    private(set) var cursor: Int
    /// Exclusive end bound (buffer-relative). Lets the reader walk a window of
    /// a larger mapping (a `scene.pkg` entry) without slicing a new `Data`.
    let endBound: Int

    init(data: Data, cursor: Int = 0, endBound: Int? = nil) {
        self.data = data
        self.cursor = cursor
        self.endBound = min(endBound ?? data.count, data.count)
    }

    init(span: WPEMappedByteSpan) {
        self.init(data: span.owner, cursor: span.range.lowerBound, endBound: span.range.upperBound)
    }

    var isAtEnd: Bool { cursor >= endBound }

    mutating func readUInt32(blockName: String = "?") throws -> UInt32 {
        try ensure(byteCount: 4, blockName: blockName)
        let value = data.withUnsafeBytes { buffer -> UInt32 in
            buffer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
        }
        cursor += 4
        return UInt32(littleEndian: value)
    }

    mutating func readInt32(blockName: String = "?") throws -> Int32 {
        try ensure(byteCount: 4, blockName: blockName)
        let value = data.withUnsafeBytes { buffer -> Int32 in
            buffer.loadUnaligned(fromByteOffset: cursor, as: Int32.self)
        }
        cursor += 4
        return Int32(littleEndian: value)
    }

    /// Little-endian IEEE-754 float used by `TEXS` blocks for per-frame timing and atlas UVs.
    mutating func readFloat32(blockName: String = "?") throws -> Float {
        let bits = try readUInt32(blockName: blockName)
        return Float(bitPattern: bits)
    }

    mutating func readMagic() throws -> String {
        try ensure(byteCount: 9, blockName: "magic")
        let start = data.startIndex + cursor
        let raw = data.subdata(in: start..<(start + 9))
        cursor += 9
        let trimmed = raw.prefix { $0 != 0 }
        guard let asciiString = String(data: Data(trimmed), encoding: .ascii),
              !asciiString.isEmpty else {
            throw WPETexDecodeError.truncatedBlock(block: "magic", offset: cursor)
        }
        return asciiString
    }

    /// Zero-copy view of the next `count` bytes; the span keeps `data` alive.
    mutating func readSpan(count: Int, blockName: String) throws -> WPEMappedByteSpan {
        try ensure(byteCount: count, blockName: blockName)
        let span = WPEMappedByteSpan(owner: data, range: cursor..<(cursor + count))
        cursor += count
        return span
    }

    /// Reads a NUL-terminated ASCII run, advancing past the terminator.
    /// Used by `TEXB` v4 to surface the `v4Condition` string into the IR
    /// for dump fidelity (older code path discarded it via skip-only).
    mutating func readNullTerminatedString(blockName: String) throws -> String {
        let absoluteCursor = data.startIndex + cursor
        let absoluteEnd = data.startIndex + endBound
        guard absoluteCursor <= absoluteEnd else {
            throw WPETexDecodeError.truncatedBlock(block: blockName, offset: cursor)
        }
        guard let terminator = data[absoluteCursor..<absoluteEnd].firstIndex(of: 0) else {
            throw WPETexDecodeError.truncatedBlock(block: blockName, offset: cursor)
        }
        let slice = data.subdata(in: absoluteCursor..<terminator)
        cursor = (terminator - data.startIndex) + 1
        return String(data: slice, encoding: .ascii) ?? ""
    }

    private func ensure(byteCount: Int, blockName: String) throws {
        guard byteCount >= 0, cursor + byteCount <= endBound else {
            throw WPETexDecodeError.truncatedBlock(block: blockName, offset: cursor)
        }
    }
}
#endif
