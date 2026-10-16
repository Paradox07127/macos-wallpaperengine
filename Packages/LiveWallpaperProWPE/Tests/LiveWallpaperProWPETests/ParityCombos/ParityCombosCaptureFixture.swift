import Foundation
@testable import LiveWallpaperProWPE

struct ParityCombosCaptureFixture {
    struct Entry: Decodable {
        let n: Int
        let name: String
        let roots: [String]
        let hlsl: String
    }

    struct Inputs {
        let entry: Entry
        let expected: [WPEShaderDefine]
        let json: [WPEPassJSONCombo]
        let blending: Int32
        let vertex: String
        let fragment: String
        let flags: WPEEngineComboFlags
        let textures: [Int32: WPEBoundComboTexture]

        func resolve() -> [WPEShaderDefine] {
            WPEComboResolver.resolve(
                passJSONCombos: json, blendingMode: blending,
                vertexSource: vertex, fragmentSource: fragment,
                engineFlags: flags, boundTextures: textures
            )
        }
    }

    let inputs: [Inputs]

    init(root: URL) throws {
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let forced = try Self.materialKeys(root)
        inputs = try entries.map { try Self.rebuild($0, root: root, forced: forced[$0.n] ?? []) }
    }

    /// repro.py --jsrc uses these keys, then infers overrides from the observed block.
    private static func materialKeys(_ root: URL) throws -> [Int: Set<String>] {
        let table = try String(contentsOf: root.appendingPathComponent("r3/jsrc.tsv"), encoding: .utf8)
        var result: [Int: Set<String>] = [:]
        for line in table.components(separatedBy: .newlines) where !line.hasPrefix("#") && !line.isEmpty {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3, let number = Int(fields[0]) else { throw FixtureError.malformed("jsrc.tsv") }
            let keys = Set(fields[1].split(separator: " ").map(String.init))
            let path = fields[2].components(separatedBy: " (same in ")[0]
            let data = try Data(contentsOf: root.appendingPathComponent("scene-sources/" + path))
            guard let material = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let passes = material["passes"] as? [[String: Any]],
                  let combos = passes.first?["combos"] as? [String: Any], Set(combos.keys) == keys else {
                throw FixtureError.malformed("material keys for capture \(number)")
            }
            result[number] = keys
        }
        guard result.count == 14 else { throw FixtureError.malformed("expected 14 jsrc material sources") }
        return result
    }

    private static func rebuild(_ entry: Entry, root: URL, forced: Set<String>) throws -> Inputs {
        let expected = try block(root.appendingPathComponent(entry.hlsl))
        let name = String(entry.name.dropFirst("shaders/".count)).split(separator: ".").dropLast().joined(separator: ".")
        let vertex = try source(root: root, roots: entry.roots, name: name + ".vert")
        let fragment = try source(root: root, roots: entry.roots, name: name + ".frag")
        let annotations = WPEShaderAnnotationCombos(vertexSource: vertex, fragmentSource: fragment)
        let textureNames = Set(annotations.samplers.entries.flatMap { [$0.value.combo] + $0.value.componentCombos }.filter { !$0.isEmpty })
        var body = expected
        var tail: [WPEShaderDefine] = []
        while let last = body.last, textureNames.contains(last.name), last.value == "1" {
            tail.insert(body.removeLast(), at: 0)
        }
        let values = Dictionary(uniqueKeysWithValues: body.map { ($0.name, Int32($0.value) ?? 0) })
        let engineNames = Set([
            "LIGHTS_POINT", "LIGHTS_SPOT", "LIGHTS_TUBE", "LIGHTS_DIRECTIONAL", "LIGHTS_SPOT_SHADOW_COOKIE",
            "LIGHTS_SPOT_SHADOW", "LIGHTS_SPOT_COOKIE", "LIGHTS_DIRECTIONAL_SHADOW", "LIGHTS_POINT_SHADOW",
            "LIGHTS_SHADOW_MAPPING", "LIGHTS_SHADOW_MAPPING_QUALITY", "LIGHTS_COOKIE",
            "SCENE_ORTHO", "FOG_DIST", "FOG_HEIGHT", "BACKBUFFER_MS", "HDR", "REVERSEDEPTH",
        ]).union(annotations.samplers.entries.filter { $0.value.formatCombo && (0 ..< 10).contains($0.key) }
            .map { "TEX\($0.key)FORMAT" })
        let blendNames: Set = ["ALPHATOCOVERAGE", "ADDITIVE"]
        var defaults = Set(annotations.defaults.keys.filter { values[$0] != nil && !forced.contains($0) })
        var jsonNames = Set(values.keys).subtracting(engineNames).subtracting(blendNames).subtracting(defaults)
        for key in defaults where values[key] != annotations.defaults[key] && !engineNames.contains(key) {
            defaults.remove(key)
            jsonNames.insert(key)
        }
        let json = jsonNames.sorted().map { WPEPassJSONCombo(key: $0, value: values[$0] ?? 0) }
        let flags = engineFlags(values, samplers: annotations.samplers)
        let tailNames = Set(tail.map(\.name))
        var textures: [Int32: WPEBoundComboTexture] = [:]
        for sampler in annotations.samplers.entries {
            let info = sampler.value
            guard tailNames.contains(info.combo) || info.componentCombos.contains(where: { tailNames.contains($0) }) else { continue }
            var bits: UInt32 = 0
            for (index, combo) in info.componentCombos.prefix(12).enumerated() where tailNames.contains(combo) {
                bits |= UInt32(0x100000) << index
            }
            textures[sampler.key] = WPEBoundComboTexture(flags: bits)
        }
        return Inputs(
            entry: entry, expected: expected, json: json,
            blending: values["ALPHATOCOVERAGE"] != nil ? 3 : (values["ADDITIVE"] != nil ? 2 : 0),
            vertex: vertex, fragment: fragment, flags: flags, textures: textures
        )
    }

    private static func engineFlags(
        _ values: [String: Int32], samplers: WPEMSVCUnorderedMap<Int32, WPEShaderSamplerCombos>
    ) -> WPEEngineComboFlags {
        var result = WPEEngineComboFlags()
        result.orthographicProjection = values["SCENE_ORTHO"] != nil
        result.fogDistance = values["FOG_DIST"] != nil
        result.fogHeight = values["FOG_HEIGHT"] != nil
        result.backbufferMSAA = values["BACKBUFFER_MS"] != nil
        result.hdr = values["HDR"] != nil
        result.pointLights = values["LIGHTS_POINT"] ?? 0
        result.spotLights = values["LIGHTS_SPOT"] ?? 0
        result.tubeLights = values["LIGHTS_TUBE"] ?? 0
        result.directionalLights = values["LIGHTS_DIRECTIONAL"] ?? 0
        result.spotShadowCookieLights = values["LIGHTS_SPOT_SHADOW_COOKIE"] ?? 0
        result.spotShadowLights = values["LIGHTS_SPOT_SHADOW"] ?? 0
        result.spotCookieLights = values["LIGHTS_SPOT_COOKIE"] ?? 0
        result.directionalShadowLights = values["LIGHTS_DIRECTIONAL_SHADOW"] ?? 0
        result.pointShadowLights = values["LIGHTS_POINT_SHADOW"] ?? 0
        result.shadowQuality = values["LIGHTS_SHADOW_MAPPING_QUALITY"] ?? 0
        for sampler in samplers.entries where sampler.value.formatCombo {
            result.textureFormats[sampler.key] = values["TEX\(sampler.key)FORMAT"]
        }
        return result
    }

    private static func block(_ url: URL) throws -> [WPEShaderDefine] {
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        guard let prefix = lines.firstIndex(of: "#define HLSL_SM40 1") else { throw FixtureError.malformed(url.path) }
        var start = prefix + 1
        if start < lines.count, lines[start] == "#define GS_ENABLED 1" {
            start += 1
        }
        var result: [WPEShaderDefine] = []
        for line in lines.dropFirst(start) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "#define", Int32(parts[2]) != nil else { break }
            result.append(WPEShaderDefine(name: String(parts[1]), value: String(parts[2])))
        }
        return result
    }

    private static func source(root: URL, roots: [String], name: String) throws -> String {
        var seen: Set<String> = []
        return try load(root: root, roots: roots, name: name, seen: &seen) ?? ""
    }

    private static func load(root: URL, roots: [String], name: String, seen: inout Set<String>) throws -> String? {
        guard let url = roots.map({ root.appendingPathComponent($0).appendingPathComponent(name) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        let raw = try Latin1.string(Array(Data(contentsOf: url)))
        var result: [String] = []
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("#include") {
                let pieces = line.components(separatedBy: "\"")
                if pieces.count >= 3, seen.insert(pieces[1]).inserted,
                   let included = try load(root: root, roots: roots, name: pieces[1], seen: &seen) {
                    result.append(included)
                } else {
                    result.append("")
                }
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    enum FixtureError: Error {
        case malformed(String)
    }
}
