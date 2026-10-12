import Foundation

/// The `.tex` fields WPE's combo pass reads: after `TEXVnnnn\0` and `TEXInnnn\0` come the format and the flags
/// (LE uint32), stored at Texture+0x18 and +0x1c by FUN_14015c760.
public struct WPEParityProgramTextureHeader: Sendable, Equatable {
    static let byteCount = 26

    /// TEXnFORMAT value; FUN_1400d2a20 decodes it (8 = RG8, 9 = R8).
    public let format: Int32
    /// Bit `0x100000 << i` turns on the sampler annotation's `components[i].combo` (FUN_14016c800).
    public let flags: UInt32

    public init(format: Int32, flags: UInt32) {
        self.format = format
        self.flags = flags
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= Self.byteCount, bytes[0 ..< 4].elementsEqual("TEXV".utf8), bytes[8] == 0,
              bytes[9 ..< 13].elementsEqual("TEXI".utf8), bytes[17] == 0 else { return nil }
        func uint32(at offset: Int) -> UInt32 {
            (0 ..< 4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        self.init(format: Int32(bitPattern: uint32(at: 18)), flags: uint32(at: 22))
    }
}

public extension WPEParityProgramAssets {
    /// `materials/<name>.tex` under the first root that has it; render targets and missing files give nil.
    func textureHeader(named name: String) -> WPEParityProgramTextureHeader? {
        guard let url = url("materials/\(name).tex"), let file = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? file.close() }
        let bytes = (try? file.read(upToCount: WPEParityProgramTextureHeader.byteCount)) ?? nil
        return bytes.flatMap { WPEParityProgramTextureHeader(bytes: Array($0)) }
    }
}
