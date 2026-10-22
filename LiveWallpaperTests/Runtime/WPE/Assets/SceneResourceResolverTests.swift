import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LiveWallpaper

@Suite("SceneResourceResolver")
struct SceneResourceResolverTests {

    @Test("Path traversal via .. is rejected")
    func pathTraversalRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("secret".utf8).write(to: fixture.root.appendingPathComponent("secret.png"))

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            try resolver.data(relativePath: "../secret.png")
        }
    }

    @Test("Absolute path is rejected")
    func absolutePathRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            try resolver.data(relativePath: "/etc/passwd")
        }
    }

    @Test("Symlink that escapes cache root is rejected after resolution")
    func symlinkEscapeRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secret = fixture.root.appendingPathComponent("secret.png")
        try writePNG(at: secret)
        let symlinkURL = fixture.cacheRoot.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: secret)

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            try resolver.data(relativePath: "escape.png")
        }
    }

    @Test("Workshop raw image references exist when stored as converted material tex")
    func workshopRawImageReferenceExistsWhenStoredAsConvertedTex() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stored = fixture.cacheRoot
            .appendingPathComponent("materials/workshop/2328851328/particle", isDirectory: true)
            .appendingPathComponent("雪花.jpg.tex")
        try FileManager.default.createDirectory(at: stored.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeRGBA8888Tex(at: stored)

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        #expect(resolver.exists(relativePath: "workshop/2328851328/particle/雪花.jpg"))
    }

    @Test("Missing file throws fileMissing")
    func missingFileThrows() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        #expect(throws: SceneResourceResolver.ResolveError.fileMissing) {
            try resolver.data(relativePath: "missing.png")
        }
    }

    // MARK: - Fixture helpers

    private struct Fixture {
        let root: URL
        let cacheRoot: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneResourceResolverTests-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return Fixture(root: root, cacheRoot: cacheRoot)
    }

    private func writeRGBA8888Tex(
        at url: URL,
        width: Int = 4,
        height: Int = 4,
        payload: Data? = nil
    ) throws {
        var data = Data()
        func appendMagic(_ s: String) {
            data.append(contentsOf: s.utf8)
            data.append(0x00)
        }
        func appendInt32(_ v: Int32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        appendMagic("TEXV0005")
        appendMagic("TEXI0001")
        appendInt32(0)
        appendUInt32(0)
        appendInt32(Int32(width))
        appendInt32(Int32(height))
        appendInt32(Int32(width))
        appendInt32(Int32(height))
        appendInt32(0)
        appendMagic("TEXB0003")
        appendInt32(1)
        appendInt32(-1)
        appendInt32(1)
        appendInt32(Int32(width))
        appendInt32(Int32(height))
        appendUInt32(0)
        let pixels = payload ?? Data(repeating: 0xFF, count: width * height * 4)
        appendUInt32(UInt32(pixels.count))
        appendUInt32(UInt32(pixels.count))
        data.append(pixels)
        try data.write(to: url)
    }

    private func writePNG(at url: URL, width: Int = 4, height: Int = 4) throws {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("Failed to allocate CGContext for fixture PNG")
            return
        }
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            Issue.record("Failed to render fixture PNG")
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            Issue.record("Failed to open PNG destination for fixture")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            Issue.record("Failed to finalize fixture PNG")
        }
    }
}
