import Foundation

/// Load-time localization of parsed strings into native, contiguous-UTF8 Swift
/// strings. Scene JSON is parsed with `JSONSerialization` and several builder
/// paths use `NSString` path APIs; both can hand back lazily-bridged NSStrings
/// (escape-containing or non-ASCII JSON scalars, `NSPathStore2` path results)
/// whose every per-frame hash/compare re-transcodes UTF-16
/// (`_foreignSubscript` / `_withNFCCodeUnits` in Release samples). One pass at
/// graph-build time makes every hot string cheap for the renderer.
@inline(__always)
public func wpeNativized(_ string: String) -> String {
    var value = string
    value.makeContiguousUTF8()
    return value
}

@inline(__always)
public func wpeNativized(_ string: String?) -> String? {
    guard var value = string else { return nil }
    value.makeContiguousUTF8()
    return value
}

private func nativizedKeys<Value>(_ dictionary: [String: Value]) -> [String: Value] {
    guard dictionary.keys.contains(where: { !$0.isContiguousUTF8 }) else { return dictionary }
    var result = [String: Value](minimumCapacity: dictionary.count)
    for (key, value) in dictionary {
        result[wpeNativized(key)] = value
    }
    return result
}

extension WPETextureReference {
    func nativized() -> WPETextureReference {
        switch self {
        case .image(let path): return .image(wpeNativized(path))
        case .asset(let path): return .asset(wpeNativized(path))
        case .fbo(let name): return .fbo(wpeNativized(name))
        case .previous: return .previous
        }
    }
}

extension WPERenderTarget {
    func nativized() -> WPERenderTarget {
        switch self {
        case .layerComposite(let name): return .layerComposite(name: wpeNativized(name))
        case .fbo(let name): return .fbo(name: wpeNativized(name))
        case .scene: return .scene
        }
    }
}

extension WPERenderFBO {
    func nativized() -> WPERenderFBO {
        WPERenderFBO(
            name: wpeNativized(name),
            scale: scale,
            fit: fit,
            format: wpeNativized(format),
            unique: unique,
            pixelSize: pixelSize
        )
    }
}

extension WPERenderPass {
    // Every copy passes ALL memberwise fields; a dropped field is caught by the
    // `nativized() == self` guard test (strings only change representation).
    public func nativized() -> WPERenderPass {
        WPERenderPass(
            id: wpeNativized(id),
            phase: phase,
            shader: wpeNativized(shader),
            source: source.nativized(),
            target: target.nativized(),
            textures: textures.mapValues { $0.nativized() },
            binds: binds.mapValues { $0.nativized() },
            constants: nativizedKeys(constants),
            combos: nativizedKeys(combos),
            userTextureBindings: userTextureBindings,
            blending: wpeNativized(blending),
            cullMode: wpeNativized(cullMode),
            depthTest: wpeNativized(depthTest),
            depthWrite: wpeNativized(depthWrite),
            constantScripts: nativizedKeys(constantScripts),
            visibilityGate: visibilityGate
        )
    }
}

extension WPERenderLayer {
    public func nativized() -> WPERenderLayer {
        WPERenderLayer(
            objectID: wpeNativized(objectID),
            objectName: wpeNativized(objectName),
            visible: visible,
            imagePath: wpeNativized(imagePath),
            materialPath: wpeNativized(materialPath),
            puppetPath: wpeNativized(puppetPath),
            parentObjectID: wpeNativized(parentObjectID),
            attachment: wpeNativized(attachment),
            animationLayers: animationLayers,
            geometry: geometry,
            localGeometry: localGeometry,
            compositeA: wpeNativized(compositeA),
            compositeB: wpeNativized(compositeB),
            localFBOs: localFBOs.map { $0.nativized() },
            passes: passes.map { $0.nativized() },
            groupRenderTarget: wpeNativized(groupRenderTarget),
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: wpeNativized(groupCompositeSource),
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }
}

extension WPERenderGraph {
    public func nativized() -> WPERenderGraph {
        WPERenderGraph(layers: layers.map { $0.nativized() })
    }
}
