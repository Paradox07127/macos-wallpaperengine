import Foundation

public enum WPEComboResolver: Sendable {
    public static func resolve(
        passJSONCombos: [WPEPassJSONCombo],
        blendingMode: Int32,
        vertexSource: String,
        fragmentSource: String,
        engineFlags: WPEEngineComboFlags,
        boundTextures: [Int32: WPEBoundComboTexture]
    ) -> [WPEShaderDefine] {
        resolve(passJSONCombos: passJSONCombos, blendingMode: blendingMode,
                annotations: WPEShaderAnnotationCombos(vertexSource: vertexSource, fragmentSource: fragmentSource),
                engineFlags: engineFlags, boundTextures: boundTextures)
    }

    public static func resolve(
        passJSONCombos: [WPEPassJSONCombo],
        blendingMode: Int32,
        annotations: WPEShaderAnnotationCombos,
        engineFlags: WPEEngineComboFlags,
        boundTextures: [Int32: WPEBoundComboTexture]
    ) -> [WPEShaderDefine] {
        var map = WPEMSVCUnorderedMap<String, Int32>()
        let sorted = passJSONCombos.enumerated().sorted {
            let left = Array($0.element.key.utf8), right = Array($1.element.key.utf8)
            return left == right ? $0.offset < $1.offset : left.lexicographicallyPrecedes(right)
        }
        for entry in sorted {
            // jsoncpp sorts original key bytes before WPE's bytewise toupper.
            let bytes = entry.element.key.utf8.map { (0x61 ... 0x7A).contains($0) ? $0 - 0x20 : $0 }
            let name = String(bytes: bytes, encoding: .utf8) ?? entry.element.key
            map.set(name, value: entry.element.value)
        }
        if blendingMode == 3 {
            map.set("ALPHATOCOVERAGE", value: 1)
        }
        if blendingMode == 2 {
            map.set("ADDITIVE", value: 1)
        }
        for entry in annotations.defaults.entries {
            map.setIfMissing(entry.key, value: entry.value)
        }
        insertEngineFlags(engineFlags, annotations: annotations, into: &map)
        var result = map.entries.map { WPEShaderDefine(name: $0.key, value: String($0.value)) }
        // FUN_14016c800: sampler order, then the flagged components of each bound texture.
        for entry in annotations.samplers.entries {
            guard let texture = boundTextures[entry.key] else { continue }
            let sampler = entry.value
            if !sampler.combo.isEmpty {
                result.append(WPEShaderDefine(name: sampler.combo, value: "1"))
            }
            let components = texture.componentCombos ?? sampler.componentCombos
            for (index, name) in components.prefix(12).enumerated()
                where texture.flags & (UInt32(0x100000) << index) != 0 && !name.isEmpty {
                result.append(WPEShaderDefine(name: name, value: "1"))
            }
        }
        return result
    }

    // FUN_1401a5c40: fixed insertion order, including zero-valued light counts.
    private static func insertEngineFlags(
        _ flags: WPEEngineComboFlags,
        annotations: WPEShaderAnnotationCombos,
        into map: inout WPEMSVCUnorderedMap<String, Int32>
    ) {
        if let lighting = map["LIGHTING"], lighting != 0 {
            map.set("LIGHTS_POINT", value: flags.pointLights)
            map.set("LIGHTS_SPOT", value: flags.spotLights)
            map.set("LIGHTS_TUBE", value: flags.tubeLights)
            map.set("LIGHTS_DIRECTIONAL", value: flags.directionalLights)
            let shadows = flags.shadowQuality != 0
            let spotShadowCookie = shadows ? flags.spotShadowCookieLights : 0
            let spotShadow = shadows ? flags.spotShadowLights : 0
            let directionalShadow = shadows ? flags.directionalShadowLights : 0
            let pointShadow = shadows ? flags.pointShadowLights : 0
            map.set("LIGHTS_SPOT_SHADOW_COOKIE", value: spotShadowCookie)
            map.set("LIGHTS_SPOT_SHADOW", value: spotShadow)
            map.set("LIGHTS_SPOT_COOKIE", value: flags.spotCookieLights)
            map.set("LIGHTS_DIRECTIONAL_SHADOW", value: directionalShadow)
            map.set("LIGHTS_POINT_SHADOW", value: pointShadow)
            if [spotShadowCookie, spotShadow, directionalShadow, pointShadow].contains(where: { $0 != 0 }) {
                map.set("LIGHTS_SHADOW_MAPPING", value: 1)
                map.set("LIGHTS_SHADOW_MAPPING_QUALITY", value: flags.shadowQuality)
            }
            if spotShadowCookie != 0 || flags.spotCookieLights != 0 {
                map.set("LIGHTS_COOKIE", value: 1)
            }
        }
        if flags.orthographicProjection {
            map.set("SCENE_ORTHO", value: 1)
        }
        if let fog = map["FOG"], fog != 0 {
            if flags.fogDistance {
                map.set("FOG_DIST", value: 1)
            }
            if flags.fogHeight {
                map.set("FOG_HEIGHT", value: 1)
            }
        }
        if flags.backbufferMSAA {
            map.set("BACKBUFFER_MS", value: 1)
        }
        if flags.hdr {
            map.set("HDR", value: 1)
        }
        map.set("REVERSEDEPTH", value: 1)
        for slot: Int32 in 0 ..< 10 {
            if annotations.samplers[slot]?.formatCombo == true, let format = flags.textureFormats[slot] {
                map.set("TEX\(slot)FORMAT", value: format)
            }
        }
    }
}
