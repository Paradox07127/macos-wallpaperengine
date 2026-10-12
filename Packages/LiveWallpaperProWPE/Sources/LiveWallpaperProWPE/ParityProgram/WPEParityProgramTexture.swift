import Foundation

/// The `.tex` fields WPE's combo pass reads: after `TEXVnnnn\0` and `TEXInnnn\0` come the format, the flags and the
/// texture and image sizes (LE uint32), stored at Texture+0x18, +0x1c, +0x20/+0x24 and +0x2c/+0x30 by FUN_14015c760.
public struct WPEParityProgramTextureHeader: Sendable, Equatable {
    static let byteCount = 42

    /// TEXnFORMAT value; FUN_1400d2a20 decodes it (8 = RG8, 9 = R8).
    public let format: Int32
    /// Bit `0x100000 << i` turns on the sampler annotation's `components[i].combo` (FUN_14016c800).
    public let flags: UInt32
    public let textureWidth: UInt32
    public let textureHeight: UInt32
    public let imageWidth: UInt32
    public let imageHeight: UInt32

    public init(format: Int32, flags: UInt32, textureWidth: UInt32 = 0, textureHeight: UInt32 = 0,
                imageWidth: UInt32 = 0, imageHeight: UInt32 = 0) {
        self.format = format
        self.flags = flags
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= Self.byteCount, bytes[0 ..< 4].elementsEqual("TEXV".utf8), bytes[8] == 0,
              bytes[9 ..< 13].elementsEqual("TEXI".utf8), bytes[17] == 0 else { return nil }
        func uint32(at offset: Int) -> UInt32 {
            (0 ..< 4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        self.init(format: Int32(bitPattern: uint32(at: 18)), flags: uint32(at: 22), textureWidth: uint32(at: 26),
                  textureHeight: uint32(at: 30), imageWidth: uint32(at: 34), imageHeight: uint32(at: 38))
    }
}

public extension WPEParityProgramAssets {
    /// `materials/<name>.tex` from the first source that has it; render targets and missing files give nil.
    func textureHeader(named name: String) -> WPEParityProgramTextureHeader? {
        data("materials/\(name).tex").flatMap {
            WPEParityProgramTextureHeader(bytes: Array($0.prefix(WPEParityProgramTextureHeader.byteCount)))
        }
    }
}
