#if !LITE_BUILD
import CryptoKit
import Foundation
import Metal

struct WPEUserShortcutIconImage: Equatable, Sendable {
    /// Straight (non-premultiplied) sRGB-encoded RGBA8, `width * 4` bytes per row, top row first.
    let rgba: [UInt8]
    let width: Int
    let height: Int
}

/// Written on the main actor by `UserShortcutRendererLink`, read by the render thread mid-encode.
final class WPEUserShortcutIconStore: @unchecked Sendable { // NSLock guards all mutable state; an MTLTexture is read-only once built.
    private struct Icon {
        let digest: String
        let texture: MTLTexture
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var icons: [String: Icon] = [:]
    /// passID → texture slot → user-shortcut property key; replaced on every scene load.
    private var slotsByPassID: [String: [Int: String]] = [:]
    private var changeHandler: (@Sendable () -> Void)?

    init(device: MTLDevice) {
        self.device = device
    }

    /// Called after `setIcon` actually swapped a texture.
    var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    func setDeclarations(_ byPassID: [String: [Int: String]]) {
        lock.withLock { slotsByPassID = byPassID }
    }

    /// nil when this pass declares no user-shortcut slot.
    func declarations(forPassID passID: String) -> [Int: String]? {
        lock.withLock { slotsByPassID[passID] }
    }

    /// nil clears the key; returns false when the bytes match the current icon, so nothing is rebuilt.
    @discardableResult
    func setIcon(_ image: WPEUserShortcutIconImage?, forKey propertyKey: String) -> Bool {
        let changed: Bool
        if let image {
            let digest = Self.digest(of: image)
            if lock.withLock({ icons[propertyKey]?.digest == digest }) {
                return false
            }
            guard let texture = Self.makeTexture(from: image, device: device) else {
                return setIcon(nil, forKey: propertyKey)
            }
            lock.withLock { icons[propertyKey] = Icon(digest: digest, texture: texture) }
            changed = true
        } else {
            changed = lock.withLock { icons.removeValue(forKey: propertyKey) != nil }
        }
        if changed {
            onChange?()
        }
        return changed
    }

    /// authored is returned for undeclared slots and for declared keys with no icon.
    func substituting(_ authored: MTLTexture?, slot: Int, declarations: [Int: String]) -> MTLTexture? {
        guard let key = declarations[slot] else { return authored }
        return lock.withLock { icons[key]?.texture } ?? authored
    }

    private static func digest(of image: WPEUserShortcutIconImage) -> String {
        var hasher = SHA256()
        withUnsafeBytes(of: Int64(image.width)) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: Int64(image.height)) { hasher.update(bufferPointer: $0) }
        image.rgba.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Raw UNORM like authored textures: shaders get the sRGB-encoded bytes and present decodes once.
    private static func makeTexture(from image: WPEUserShortcutIconImage, device: MTLDevice) -> MTLTexture? {
        let bytesPerRow = image.width * 4
        guard image.width > 0, image.height > 0, image.rgba.count == bytesPerRow * image.height else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: image.width,
            height: image.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        image.rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture, semantics: .straightColor)
        return texture
    }
}
#endif
