/// An already rasterised FreeType bitmap; rows are tightly packed, top row first.
public struct WPEParityGlyphBitmap: Equatable, Sendable {
    /// rgba is already native-channel field data; it must never pass through the BGRA colour swizzle.
    public enum PixelMode: Equatable, Sendable { case gray, bgra, rgba }

    public var width: Int
    public var rows: Int
    public var pixelMode: PixelMode
    public var pixels: [UInt8]

    public init(width: Int, rows: Int, pixelMode: PixelMode, pixels: [UInt8]) {
        self.width = width
        self.rows = rows
        self.pixelMode = pixelMode
        self.pixels = pixels
    }
}

public enum WPEParityGlyphAtlasFormat: Equatable, Sendable {
    case r8, rgba8

    public var bytesPerPixel: Int {
        self == .r8 ? 1 : 4
    }
}

public struct WPEParityGlyphAtlasEntry: Equatable, Sendable {
    public let key: UInt32
    /// (u0, v0, u1, v1) of the bitmap without its gap; v grows with bitmap rows (WPE entry +0x10..+0x1c).
    public internal(set) var uv: SIMD4<Float>
    public let x0: Int
    public let y0: Int
    public let x1: Int
    public let y1: Int
    public internal(set) var references: Int
}

/// WPE 2.8.42 shelf glyph atlas (FUN_1401ae080) over a CPU pixel buffer that is uploaded whole when dirty.
public struct WPEParityGlyphAtlas: Sendable {
    public static let initialSize = 512

    public static func entryKey(faceIndex: Int, glyphID: UInt32) -> UInt32 {
        UInt32(truncatingIfNeeded: faceIndex) << 24 | glyphID
    }

    public let format: WPEParityGlyphAtlasFormat
    public private(set) var width = initialSize
    public private(set) var height = initialSize
    public private(set) var pixels: [UInt8]
    public private(set) var isDirty = false
    /// Bumped on every doubling: meshes built on an older generation hold stale UVs.
    public private(set) var generation = 0
    /// Pixel-buffer version. Uploaders publish a new immutable GPU texture when this changes.
    public private(set) var contentGeneration: UInt64 = 0
    /// References from before a reset no longer own entries, even if the same glyph key is inserted again.
    public private(set) var resetGeneration: UInt64 = 0

    private struct Shelf {
        var height: Int
        var freeWidth: Int
        var keys: [UInt32]
    }

    private var shelves: [Shelf] = []
    private var entries: [UInt32: WPEParityGlyphAtlasEntry] = [:]
    /// Eviction scan order. Keys keep their place across eviction and reset, like WPE's map nodes.
    private var keyOrder: [UInt32] = []
    private var orderedKeys: Set<UInt32> = []

    public init(format: WPEParityGlyphAtlasFormat) {
        self.format = format
        pixels = Array(repeating: 0, count: Self.initialSize * Self.initialSize * format.bytesPerPixel)
    }

    public func entry(forKey key: UInt32) -> WPEParityGlyphAtlasEntry? {
        entries[key]
    }

    /// Returns nil when the atlas is full (WPE result 2): nothing fits, nothing is evictable and width > 4095.
    public mutating func insert(key: UInt32, bitmap: WPEParityGlyphBitmap) -> WPEParityGlyphAtlasEntry? {
        precondition((bitmap.pixelMode != .gray) == (format == .rgba8), "Four-channel glyphs go to the RGBA8 atlas")
        if let existing = entries[key] {
            return existing
        }
        let width = bitmap.width
        let height = bitmap.rows
        while !(fitOnShelf(key: key, width: width, height: height) || openShelf(key: key, width: width, height: height)) {
            if evictOne(width: width, height: height) {
                continue
            }
            if self.width > 4095 {
                return nil
            }
            grow()
        }
        if orderedKeys.insert(key).inserted {
            keyOrder.append(key)
        }
        let entry = entries[key]!
        copy(bitmap, to: entry)
        clearGap(around: entry)
        isDirty = true
        contentGeneration &+= 1
        return entry
    }

    public mutating func retain(_ keys: some Sequence<UInt32>) {
        for key in keys {
            entries[key]?.references += 1
        }
    }

    public mutating func release(_ keys: some Sequence<UInt32>) {
        for key in keys {
            entries[key]?.references -= 1
        }
    }

    /// The caller's first answer to a full atlas (FUN_1401b0410): forget every entry and shelf,
    /// keep the size and the pixels, then repack.
    public mutating func reset() {
        shelves.removeAll()
        entries.removeAll()
        resetGeneration &+= 1
    }

    public mutating func takeDirty() -> Bool {
        defer { isDirty = false }
        return isDirty
    }

    private mutating func fitOnShelf(key: UInt32, width: Int, height: Int) -> Bool {
        var y = 0
        for index in shelves.indices {
            let shelf = shelves[index]
            if index == shelves.count - 1 || height + 1 <= shelf.height, width + 1 <= shelf.freeWidth {
                if self.height < y + height + 1 {
                    return false
                }
                var cursor = 0
                for (slot, cellKey) in shelf.keys.enumerated() {
                    let cell = entries[cellKey]!
                    var insertAt: Int?
                    if width + 1 <= cell.x0 - cursor {
                        insertAt = slot
                    } else {
                        cursor = cell.x1 + 1
                        let room = slot == shelf.keys.count - 1
                            ? self.width - cursor
                            : entries[shelf.keys[slot + 1]]!.x0 - cell.x1
                        if width <= room {
                            insertAt = slot + 1
                        }
                    }
                    guard let insertAt else { continue }
                    shelves[index].height = max(shelf.height, height)
                    shelves[index].keys.insert(key, at: insertAt)
                    addEntry(key: key, x: cursor, y: y, width: width, height: height)
                    shelves[index].freeWidth = widestGap(in: shelves[index])
                    return true
                }
            }
            y += shelf.height + 1
        }
        return false
    }

    private mutating func openShelf(key: UInt32, width: Int, height: Int) -> Bool {
        let used = shelves.reduce(0) { $0 + $1.height + 1 }
        guard height + 1 <= self.height - used, width + 1 <= self.width else { return false }
        shelves.append(Shelf(height: height, freeWidth: self.width - (width + 1), keys: [key]))
        addEntry(key: key, x: 0, y: used, width: width, height: height)
        return true
    }

    private func widestGap(in shelf: Shelf) -> Int {
        var widest = 0
        var previousEnd = 0
        for key in shelf.keys {
            let cell = entries[key]!
            widest = max(widest, cell.x0 - previousEnd)
            previousEnd = cell.x1
        }
        widest = max(widest, width - previousEnd)
        return widest < 2 ? 0 : widest
    }

    /// Drops the first unreferenced entry whose cell holds the bitmap; true when it left a shelf.
    private mutating func evictOne(width: Int, height: Int) -> Bool {
        for key in keyOrder {
            guard let cell = entries[key], cell.references == 0,
                  width <= cell.x1 - cell.x0, height <= cell.y1 - cell.y0 else { continue }
            entries[key] = nil
            var removed = false
            for index in shelves.indices {
                guard let slot = shelves[index].keys.firstIndex(of: key) else { continue }
                shelves[index].keys.remove(at: slot)
                shelves[index].freeWidth = max(shelves[index].freeWidth, cell.x1 - cell.x0 + 1)
                removed = true
            }
            if removed {
                return true
            }
        }
        return false
    }

    private mutating func grow() {
        let bytesPerPixel = format.bytesPerPixel
        let oldWidth = width
        let oldHeight = height
        let oldRowBytes = oldWidth * bytesPerPixel
        width *= 2
        height *= 2
        var grown = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let rowBytes = width * bytesPerPixel
        for row in 0 ..< oldHeight {
            grown[row * rowBytes ..< row * rowBytes + oldRowBytes] =
                pixels[row * oldRowBytes ..< (row + 1) * oldRowBytes]
        }
        pixels = grown
        entries = entries.mapValues { entry in
            var entry = entry
            entry.uv *= 0.5
            return entry
        }
        for index in shelves.indices {
            shelves[index].freeWidth = oldWidth
        }
        generation += 1
        isDirty = true
        contentGeneration &+= 1
    }

    private mutating func addEntry(key: UInt32, x: Int, y: Int, width: Int, height: Int) {
        let uv = SIMD4<Float>(
            Float(x) / Float(self.width),
            Float(y) / Float(self.height),
            Float(x + width) / Float(self.width),
            Float(y + height) / Float(self.height)
        )
        entries[key] = WPEParityGlyphAtlasEntry(
            key: key, uv: uv, x0: x, y0: y, x1: x + width, y1: y + height, references: 0
        )
    }

    private mutating func copy(_ bitmap: WPEParityGlyphBitmap, to entry: WPEParityGlyphAtlasEntry) {
        let bytesPerPixel = format.bytesPerPixel
        let rowBytes = bitmap.width * bytesPerPixel
        for row in 0 ..< bitmap.rows {
            let start = ((entry.y0 + row) * width + entry.x0) * bytesPerPixel
            pixels[start ..< start + rowBytes] = bitmap.pixels[row * rowBytes ..< (row + 1) * rowBytes]
            guard bitmap.pixelMode == .bgra else { continue }
            for offset in stride(from: start, to: start + rowBytes, by: 4) {
                pixels.swapAt(offset, offset + 2)
            }
        }
    }

    /// Zeroes the row above and below and the column left and right of the cell; WPE wraps row/column -1
    /// to the far edge and takes x1 and y1 modulo the atlas size, so an edge cell can clear a neighbour.
    private mutating func clearGap(around entry: WPEParityGlyphAtlasEntry) {
        let bytesPerPixel = format.bytesPerPixel
        let rowBytes = (entry.x1 - entry.x0) * bytesPerPixel
        for row in [(entry.y0 == 0 ? height : entry.y0) - 1, entry.y1 % height] {
            let start = (row * width + entry.x0) * bytesPerPixel
            pixels.replaceSubrange(start ..< start + rowBytes, with: repeatElement(0, count: rowBytes))
        }
        let left = (entry.x0 == 0 ? width : entry.x0) - 1
        let right = entry.x1 % width
        for row in entry.y0 ..< entry.y1 {
            for column in [left, right] {
                let start = (row * width + column) * bytesPerPixel
                for offset in start ..< start + bytesPerPixel {
                    pixels[offset] = 0
                }
            }
        }
    }
}
