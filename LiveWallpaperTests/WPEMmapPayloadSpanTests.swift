#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

@Suite("WPE mmap payload spans")
struct WPEMmapPayloadSpanTests {

    // MARK: - Span semantics

    @Test("Span windows the owner without copying")
    func spanWindowsOwnerWithoutCopy() {
        // >14 bytes: keep the owner heap-backed (inline small-Data storage
        // has no stable address, which would fail the aliasing assertion).
        let owner = Data((0..<64).map { UInt8($0) })
        let span = WPEMappedByteSpan(owner: owner, range: 2..<6)

        #expect(span.count == 4)
        #expect(span.byte(at: 0) == 2)
        #expect(span.byte(at: 3) == 5)
        #expect(span.materializedData() == Data([2, 3, 4, 5]))

        let ownerBase = owner.withUnsafeBytes { $0.baseAddress! }
        span.withUnsafeBytes { buffer in
            #expect(buffer.count == 4)
            #expect(buffer.baseAddress == ownerBase + 2)
        }
    }

    @Test("Span prefix clamps and stays within the window")
    func spanPrefixClamps() {
        let owner = Data([9, 8, 7, 6, 5])
        let span = WPEMappedByteSpan(owner: owner, range: 1..<4)
        #expect(span.prefix(2).materializedData() == Data([8, 7]))
        #expect(span.prefix(99).materializedData() == Data([8, 7, 6]))
        #expect(span.prefix(0).isEmpty)
    }

    @Test("Span equality is content equality")
    func spanEqualityIsContentEquality() {
        let a = WPEMappedByteSpan(owner: Data([0, 1, 2, 3]), range: 1..<3)
        let b = WPEMappedByteSpan(owner: Data([9, 1, 2]), range: 1..<3)
        let c = WPEMappedByteSpan(owner: Data([1, 2, 3]), range: 0..<3)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Decoder produces zero-copy spans

    @Test("Streaming payload mip spans alias the source container bytes")
    func streamingPayloadSpansAliasSourceBytes() throws {
        let raw = Data(repeating: 0x5A, count: 4 * 4 * 4)
        let container = makeStreamingTexContainer(width: 4, height: 4, payloads: [raw, raw])

        let payload = try WPETexDecoder().extractStreamingPayload(data: container).get()

        let containerBase = container.withUnsafeBytes { $0.baseAddress! }
        for image in payload.compressedImages {
            let mip = try #require(image.payloads.first)
            mip.compressedBytes.withUnsafeBytes { buffer in
                // Aliasing the container proves the parser did not copy the
                // compressed payload onto the heap (the P1.2 contract).
                #expect(buffer.baseAddress! >= containerBase)
                #expect(buffer.baseAddress! + buffer.count <= containerBase + container.count)
            }
        }
    }

    @Test("Windowed parse honors the entry end bound inside a larger owner")
    func windowedParseHonorsEndBound() throws {
        let raw = Data(repeating: 0x33, count: 2 * 2 * 4)
        let container = makeStreamingTexContainer(width: 2, height: 2, payloads: [raw])
        var packed = Data([0xDE, 0xAD])
        let start = packed.count
        packed.append(container)
        packed.append(Data([0xBE, 0xEF, 0xFE]))

        let window = WPEMappedByteSpan(owner: packed, range: start..<(start + container.count))
        let payload = try WPETexDecoder().extractStreamingPayload(span: window).get()
        #expect(payload.compressedImages.count == 1)

        // A short window must fail with truncation, not read the trailer.
        let shortWindow = WPEMappedByteSpan(owner: packed, range: start..<(start + container.count - 4))
        #expect(throws: (any Error).self) {
            try WPETexDecoder().extractStreamingPayload(span: shortWindow).get()
        }
    }

    // MARK: - Package provider windows

    @Test("Package provider vends entry windows out of one shared mapping")
    func packageProviderVendsSharedMappingWindows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmap-span-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let texBytes = makeStreamingTexContainer(
            width: 2, height: 2, payloads: [Data(repeating: 0x44, count: 16)]
        )
        let sceneJSON = #"{"k":"v"}"#.data(using: .utf8)!
        let pkg = makePackageData([
            (name: "scene.json", data: sceneJSON),
            (name: "materials/a.tex", data: texBytes)
        ])
        let pkgURL = dir.appendingPathComponent("scene.pkg")
        try pkg.write(to: pkgURL)

        let provider = try WPEPackageSceneAssetProvider(packageURL: pkgURL)

        let texWindow = try provider.mappedWindow(atRelativePath: "materials/a.tex")
        #expect(texWindow.materializedData() == texBytes)

        let jsonWindow = try provider.mappedWindow(atRelativePath: "scene.json")
        #expect(jsonWindow.materializedData() == sceneJSON)

        // Both windows share one package mapping (single owner allocation).
        let texBase = texWindow.owner.withUnsafeBytes { $0.baseAddress! }
        let jsonBase = jsonWindow.owner.withUnsafeBytes { $0.baseAddress! }
        #expect(texBase == jsonBase)

        // The window decodes end-to-end.
        let payload = try WPETexDecoder().extractStreamingPayload(span: texWindow).get()
        #expect(payload.compressedImages.count == 1)

        #expect(throws: WPESceneAssetProviderError.self) {
            _ = try provider.mappedWindow(atRelativePath: "missing.tex")
        }
    }

    @Test("Directory provider default window wraps the mapped file")
    func directoryProviderDefaultWindow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmap-span-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data((0..<64).map { UInt8($0) })
        try bytes.write(to: dir.appendingPathComponent("materials.tex"))

        let provider = WPEDirectorySceneAssetProvider(rootURL: dir)
        let window = try provider.mappedWindow(atRelativePath: "materials.tex")
        #expect(window.count == bytes.count)
        #expect(window.materializedData() == bytes)
    }

    // MARK: - Fixtures

    private func makePackageData(_ entries: [(name: String, data: Data)]) -> Data {
        func u32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        var header = Data()
        let magic = "PKGV0001"
        header.append(u32(UInt32(magic.utf8.count)))
        header.append(contentsOf: magic.utf8)
        header.append(u32(UInt32(entries.count)))
        var blob = Data()
        var offset: UInt32 = 0
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            header.append(u32(UInt32(nameBytes.count)))
            header.append(contentsOf: nameBytes)
            header.append(u32(offset))
            header.append(u32(UInt32(entry.data.count)))
            blob.append(entry.data)
            offset += UInt32(entry.data.count)
        }
        return header + blob
    }

    /// Minimal TEXV0005 container: TEXB0004 with N uncompressed RGBA8888
    /// images + a TEXS0002 schedule (multi-frame ⇒ streaming-extractable).
    private func makeStreamingTexContainer(width: Int, height: Int, payloads: [Data]) -> Data {
        var buffer = Data()
        func magic(_ value: String) {
            buffer.append(contentsOf: value.utf8)
            buffer.append(0x00)
        }
        func i32(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { buffer.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { buffer.append(contentsOf: $0) }
        }
        func f32(_ value: Float) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
        }

        magic("TEXV0005")
        magic("TEXI0001")
        i32(Int32(WPETexFormat.rgba8888.rawValue))
        u32(0)
        i32(Int32(width))
        i32(Int32(height))
        i32(Int32(width))
        i32(Int32(height))
        i32(0)

        magic("TEXB0004")
        i32(Int32(payloads.count))
        i32(-1)
        i32(0)
        for payload in payloads {
            i32(1) // mip count
            i32(Int32(width))
            i32(Int32(height))
            u32(0) // not LZ4
            u32(UInt32(payload.count))
            u32(UInt32(payload.count))
            buffer.append(payload)
        }

        magic("TEXS0002")
        i32(Int32(payloads.count))
        for imageID in payloads.indices {
            i32(Int32(imageID))
            f32(0.1)
            f32(0)
            f32(0)
            f32(Float(width))
            f32(0)
            f32(0)
            f32(Float(height))
        }
        return buffer
    }
}
#endif
