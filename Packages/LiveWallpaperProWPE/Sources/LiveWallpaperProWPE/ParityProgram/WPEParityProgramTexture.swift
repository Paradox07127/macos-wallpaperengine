import Foundation

/// The six TEX info words used by both program combos and image decoding (14015c760).
/// TEXV4 embeds them after its container magic; TEXV5 precedes them with a TEXI magic (14015e580).
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

    /// One field order for the package's header probe and the app's bounded TEX reader. The latter retains its
    /// typed truncation errors and reads conditional depth/versioned tail fields after these six words.
    public init(readUInt32: () throws -> UInt32) rethrows {
        let format = try readUInt32()
        let flags = try readUInt32()
        let textureWidth = try readUInt32()
        let textureHeight = try readUInt32()
        let imageWidth = try readUInt32()
        let imageHeight = try readUInt32()
        self.init(format: Int32(bitPattern: format), flags: flags, textureWidth: textureWidth,
                  textureHeight: textureHeight, imageWidth: imageWidth, imageHeight: imageHeight)
    }

    public static func containerVersion(for magic: String) -> Int? {
        switch magic {
        case "TEXV0004": 4
        case "TEXV0005": 5
        default: nil
        }
    }

    public static func infoVersion(for magic: String) -> Int? {
        switch magic {
        case "TEXI0000": 0
        case "TEXI0001": 1
        default: nil
        }
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 9, bytes[8] == 0,
              let magic = String(bytes: bytes[0 ..< 8], encoding: .utf8),
              let container = Self.containerVersion(for: magic)
        else { return nil }
        var cursor = 9
        if container == 5 {
            guard bytes.count >= 18, bytes[17] == 0,
                  let infoMagic = String(bytes: bytes[9 ..< 17], encoding: .utf8),
                  Self.infoVersion(for: infoMagic) != nil
            else { return nil }
            cursor = 18
        }
        guard bytes.count >= cursor + 24 else { return nil }
        self.init(readUInt32: {
            defer { cursor += 4 }
            return (0 ..< 4).reduce(0) { $0 | UInt32(bytes[cursor + $1]) << (8 * $1) }
        })
    }
}

public extension WPEParityProgramAssets {
    /// `materials/<name>.tex` from the first source that has it; render targets and missing files give nil.
    func textureHeader(named name: String) -> WPEParityProgramTextureHeader? {
        memoizedTextureHeader(name) {
            data("materials/\(name).tex").flatMap {
                WPEParityProgramTextureHeader(bytes: Array($0.prefix(WPEParityProgramTextureHeader.byteCount)))
            }
        }
    }
}
