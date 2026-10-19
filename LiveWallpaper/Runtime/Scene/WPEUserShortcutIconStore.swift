#if !LITE_BUILD
import CryptoKit
import Foundation
import Metal

struct WPEUserShortcutIconImage: Equatable, Sendable {
    /// Straight (non-premultiplied) sRGB-encoded RGBA8, `width * 4` bytes per row, top row first.
    let rgba: [UInt8]
    let width: Int
    let height: Int

    /// 1401702f0: the centred region of the slot aspect (width / height); the wider side becomes trunc(h·a) or trunc(w/a).
    static func cropRect(width: Int, height: Int, aspect: Float) -> (x: Int, y: Int, width: Int, height: Int) {
        if Float(width) / Float(height) > aspect {
            let cropped = Int(Float(height) * aspect)
            return ((width - cropped) >> 1, 0, cropped, height)
        }
        let cropped = Int(Float(width) / aspect)
        return (0, (height - cropped) >> 1, width, cropped)
    }

    /// 0x1401556e0.c:327-362: width/height are the transparent canvas of the slot aspect, x/y where the icon lands.
    static func padRect(width: Int, height: Int, aspect: Float) -> (x: Int, y: Int, width: Int, height: Int) {
        if Float(width) / Float(height) > aspect {
            let padded = Int(Float(width) / aspect)
            return (0, (padded - height) >> 1, width, padded)
        }
        let padded = Int(Float(height) * aspect)
        return ((padded - width) >> 1, 0, padded, height)
    }

    /// nil when the slot aspect leaves the image unchanged.
    func fitted(toAspect aspect: Float, pads: Bool) -> WPEUserShortcutIconImage? {
        let rect = pads ? Self.padRect(width: width, height: height, aspect: aspect)
            : Self.cropRect(width: width, height: height, aspect: aspect)
        guard rect.width != width || rect.height != height else { return nil }
        let rowBytes = width * 4
        guard pads else {
            let rows = (rect.y ..< rect.y + rect.height).flatMap { row in
                rgba[row * rowBytes + rect.x * 4 ..< row * rowBytes + (rect.x + rect.width) * 4]
            }
            return WPEUserShortcutIconImage(rgba: rows, width: rect.width, height: rect.height)
        }
        var canvas = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
        for row in 0 ..< height {
            let target = ((rect.y + row) * rect.width + rect.x) * 4
            canvas.replaceSubrange(target ..< target + rowBytes, with: rgba[row * rowBytes ..< (row + 1) * rowBytes])
        }
        return WPEUserShortcutIconImage(rgba: canvas, width: rect.width, height: rect.height)
    }
}

/// A texture slot a user image replaces.
struct WPEUserImageSlot: Hashable, Sendable {
    let key: String
    /// The slot aspect (width / height) the image is fitted to; nil binds it whole (keepaspect).
    let aspect: Float?
    /// Usershortcut icons pad to the aspect with transparent pixels; scene textures crop to it.
    let pads: Bool
}

/// Written on the main actor by `UserShortcutRendererLink`, read by the render thread mid-encode.
final class WPEUserShortcutIconStore: @unchecked Sendable { // NSLock guards all mutable state; an MTLTexture is read-only once built.
    private struct Icon {
        let digest: String
        let image: WPEUserShortcutIconImage
        let texture: MTLTexture
        var fitted: [Fit: MTLTexture] = [:]
    }

    /// Like the native cache name, round(aspect × 10) tells fitted variants apart.
    private struct Fit: Hashable {
        let tenths: Int
        let pads: Bool
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var icons: [String: Icon] = [:]
    private var videos: [String: URL] = [:]
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
            lock.withLock { icons[propertyKey] = Icon(digest: digest, image: image, texture: texture) }
            changed = true
        } else {
            changed = lock.withLock { icons.removeValue(forKey: propertyKey) != nil }
        }
        if changed {
            onChange?()
        }
        return changed
    }

    /// nil clears the key; returns false when `url` is already bound, so its player keeps running.
    @discardableResult
    func setVideo(_ url: URL?, forKey propertyKey: String) -> Bool {
        let changed = lock.withLock {
            guard videos[propertyKey] != url else { return false }
            videos[propertyKey] = url
            return true
        }
        if changed {
            onChange?()
        }
        return changed
    }

    /// Property key → the video file bound to that scene texture.
    var videoURLs: [String: URL] {
        lock.withLock { videos }
    }

    /// The image fitted to `slot`, built on first use and kept until `setIcon` replaces the key; nil = no image.
    func texture(for slot: WPEUserImageSlot) -> MTLTexture? {
        guard let icon = lock.withLock({ icons[slot.key] }) else { return nil }
        guard let aspect = slot.aspect else { return icon.texture }
        let fit = Fit(tenths: Int((aspect * 10).rounded()), pads: slot.pads)
        if let cached = icon.fitted[fit] {
            return cached
        }
        guard let image = icon.image.fitted(toAspect: aspect, pads: slot.pads) else { return icon.texture }
        guard let texture = Self.makeTexture(from: image, device: device) else { return nil }
        lock.withLock {
            if icons[slot.key]?.digest == icon.digest {
                icons[slot.key]?.fitted[fit] = texture
            }
        }
        return texture
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
    static func makeTexture(from image: WPEUserShortcutIconImage, device: MTLDevice) -> MTLTexture? {
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
        return texture
    }
}
#endif
