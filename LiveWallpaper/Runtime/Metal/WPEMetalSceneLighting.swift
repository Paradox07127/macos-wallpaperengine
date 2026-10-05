#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

/// Two float4 lanes per directional light; no Swift Array storage crosses Metal.
struct WPEMetalDirectionalLightUniforms: Equatable, Sendable {
    var direction: SIMD4<Float> = .zero
    var radiance: SIMD4<Float> = .zero
}

/// Immutable publication made from the same transforms as this frame's meshes.
/// Authored shadow requests are retained, even before atlas rendering exists.
struct WPESceneDirectionalLightingSnapshot: Equatable, Sendable {
    struct Light: Equatable, Sendable {
        let objectID: String
        let uniforms: WPEMetalDirectionalLightUniforms
        let castShadow: Bool
    }

    var lights: [Light] = []
    var unresolvedObjectIDs: [String] = []
    var unsupportedScriptFields: [String] = []
    static let empty = Self()
    var uniformPayload: [WPEMetalDirectionalLightUniforms] {
        lights.isEmpty ? [.init()] : lights.map(\.uniforms)
    }

    var metadata: SIMD4<UInt32> {
        SIMD4(UInt32(lights.count), UInt32(lights.filter(\.castShadow).count), 0, 0)
    }

    static func make(
        lights authored: [WPESceneLightObject],
        localTransforms: [String: WPERenderObjectTransform],
        parentByID: [String: String],
        ownVisibilityByID: [String: Bool],
        origins: [String: SIMD3<Double>] = [:],
        scales: [String: SIMD3<Double>] = [:],
        angles: [String: SIMD3<Double>] = [:],
        colors: [String: SIMD3<Double>] = [:],
        visibility: [String: Bool] = [:]
    ) -> Self {
        var transforms = localTransforms
        for light in authored {
            transforms[light.id] = WPERenderObjectTransform(
                origin: light.localOrigin, scale: light.localScale, angles: light.localAngles
            )
        }
        var resolver = WPEObjectModelMatrixResolver(localTransforms: transforms, parentByID: parentByID,
                                                    origins: origins, scales: scales, angles: angles)
        var result = Self()
        let supportedScriptFields: Set = ["origin", "scale", "angles", "color", "visible"]
        result.unsupportedScriptFields = authored.filter { $0.type == .directional }.flatMap { light in
            light.fieldBindings.compactMap { field, binding in
                binding.script != nil && !supportedScriptFields.contains(field) ? "\(light.id).\(field)" : nil
            }
        }.sorted()
        func visible(_ light: WPESceneLightObject) -> Bool {
            guard visibility[light.id] ?? ownVisibilityByID[light.id] ?? light.visible else { return false }
            return WPEMetalSceneRenderer.ancestorChainVisible(
                light.id, parentByID: parentByID, liveLayerVisibility: visibility,
                liveTextVisibility: [:], ownVisibilityByID: ownVisibilityByID
            )
        }
        for light in authored where light.type == .directional && visible(light) {
            guard let world = resolver.resolve(light.id, requiringCompleteHierarchy: true) else {
                result.unresolvedObjectIDs.append(light.id)
                continue
            }
            // The native directional CB is consumed as to-light (not ray travel).
            // WPE's directional local basis is -X; translation must not affect it.
            let vector = world * SIMD4<Double>(-1, 0, 0, 0)
            let direction = SIMD3<Double>(vector.x, vector.y, vector.z)
            let length = simd_length(direction)
            let radiance = (colors[light.id] ?? light.color) * light.intensity
            guard length.isFinite, length > 1e-8,
                  radiance.x.isFinite, radiance.y.isFinite, radiance.z.isFinite else {
                result.unresolvedObjectIDs.append(light.id)
                continue
            }
            let floatRadiance = SIMD3<Float>(radiance)
            guard floatRadiance.x.isFinite, floatRadiance.y.isFinite, floatRadiance.z.isFinite else {
                result.unresolvedObjectIDs.append(light.id)
                continue
            }
            result.lights.append(Light(objectID: light.id,
                                       uniforms: .init(direction: SIMD4<Float>(SIMD3<Float>(direction / length), 0),
                                                       radiance: SIMD4<Float>(floatRadiance, 0)),
                                       castShadow: light.castShadow))
        }
        return result
    }
}

extension WPESceneLightObject {
    /// Reuse the existing script collector and its radians → degrees → radians
    /// boundary. The returned transform seed is always in scene units.
    func transformScript(for field: String) -> WPESceneTransformScript? {
        guard let binding = fieldBindings[field], let script = binding.script else { return nil }
        let fallback: SIMD3<Double>
        switch field {
        case "origin": fallback = localOrigin
        case "scale": fallback = localScale
        case "angles": fallback = localAngles
        case "color": fallback = color
        default: return nil
        }
        return WPESceneTransformScript(script: script, scriptProperties: binding.scriptProperties, seed: fallback)
    }
}

extension WPEMetalRenderExecutor {
    func bindDirectionalLighting(to encoder: MTLRenderCommandEncoder) throws {
        let payload = currentDirectionalLighting.uniformPayload
        try payload.withUnsafeBytes { bytes in
            if bytes.count <= 4096 {
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 3)
            } else {
                guard let buffer = device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared) else {
                    throw NSError(domain: "WPEMetalDirectionalLighting", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Could not allocate directional lighting buffer"])
                }
                encoder.setFragmentBuffer(buffer, offset: 0, index: 3)
            }
        }
        var metadata = currentDirectionalLighting.metadata
        encoder.setFragmentBytes(&metadata, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 4)
    }
}
#endif
