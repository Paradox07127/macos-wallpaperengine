/// A varying or uniform declaration as FUN_1400f4810 parses it.
struct WPEHLSLDecl: Sendable, Equatable {
    var type: Int
    var name: [UInt8]
    var arraySize = 0
    var packedFlag = false
    /// 0 = varying (or plain uniform), 1 = `in`, 2 = `out`.
    var direction = 0

    var isPacked: Bool {
        arraySize >= 1 && packedFlag
    }

    func with(direction: Int) -> Self {
        var copy = self
        copy.direction = direction
        return copy
    }
}

/// Per-stage text rewrite of FUN_1400f5cb0: declaration lines out, structs, textures and cbuffers in,
/// `main` wrapped with the stage signature.
enum WPEHLSLStageRewriter {
    private struct Collected {
        var text: [UInt8] = []
        var attributes: [Int] = []
        var varyings: [WPEHLSLDecl] = []
        var systemValues: [(decl: WPEHLSLDecl, type: Int, semantic: String)] = []
        var uniforms: [WPEHLSLDecl] = []
    }

    static func rewrite(
        _ text: [UInt8],
        stage: WPEHLSLStage,
        combos: WPEShaderMacros,
        link: inout [WPEHLSLDecl]
    ) throws -> [UInt8] {
        var collected = try collect(text, combos: combos)
        if stage == .vertex {
            collected.varyings.append(WPEHLSLDecl(type: WPEHLSLTables.float4Type, name: Latin1.bytes("gl_Position")))
        }
        let varyings = linkVaryings(stage, collected.varyings, link: &link)
        var extra: [UInt8] = []
        for value in collected.systemValues {
            extra += ",\(WPEHLSLTables.hlslTypes[value.type]) ".utf8
            extra += value.decl.name
            extra += ":\(value.semantic)".utf8
        }
        let (signature, epilogue, body) = mainSignature(
            stage, collected.text, extra: extra, varyings: varyings, uniforms: collected.uniforms
        )
        let wrapped = wrapMain(
            stage, body, signature: signature, epilogue: epilogue,
            attributes: collected.attributes, varyings: varyings, uniforms: collected.uniforms
        )
        let head = try header(
            stage, wrapped, attributes: collected.attributes, varyings: varyings,
            uniforms: collected.uniforms, combos: combos
        )
        return head + wrapped
    }

    // MARK: - Declaration lines

    private static func collect(_ text: [UInt8], combos: WPEShaderMacros) throws -> Collected {
        var collected = Collected()
        var lines = text.split(separator: Latin1.lf, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        for slice in lines {
            let line = Array(slice)
            if line.starts(with: "attribute".utf8) {
                if let index = attributeIndex(line) {
                    collected.attributes.append(index)
                }
            } else if line.starts(with: "varying".utf8) || line.starts(with: "in".utf8) || line.starts(with: "out".utf8) {
                if let decl = try parseDecl(line, combos: combos) {
                    if let value = WPEHLSLTables.systemValue(decl.name) {
                        collected.systemValues.append((decl, value.type, value.semantic))
                    } else {
                        collected.varyings.append(decl)
                    }
                }
            } else if line.starts(with: "uniform".utf8) {
                if let decl = try parseDecl(line, combos: combos) {
                    collected.uniforms.append(decl)
                }
            } else {
                collected.text += line
                collected.text.append(Latin1.lf)
            }
        }
        return collected
    }

    /// FUN_1400f4810: the first type (table order) for which `(\w+)\s+TYPE\s+(\w+)(\[[\d\w]+\])?` occurs.
    static func parseDecl(_ line: [UInt8], combos: WPEShaderMacros) throws -> WPEHLSLDecl? {
        for (type, literal) in WPEHLSLTables.glslTypes.enumerated() {
            guard let match = matchDecl(line, literal) else { continue }
            var decl = WPEHLSLDecl(type: type, name: Array(line[match.name]))
            let qualifier = Array(line[match.qualifier])
            decl.direction = qualifier == Latin1.bytes("in") ? 1 : (qualifier == Latin1.bytes("out") ? 2 : 0)
            if let array = match.array {
                let inner = Array(line[(array.lowerBound + 1) ..< (array.upperBound - 1)])
                if Latin1.isDigit(inner[0]) {
                    decl.arraySize = inner.prefix(while: Latin1.isASCIIDigit).reduce(0) { $0 &* 10 &+ Int($1 - 0x30) }
                } else if let value = combos[inner] {
                    guard let size = Latin1.pythonInt(value) else {
                        throw WPEHLSLRewriteError.nonIntegerDefine(name: Latin1.string(inner), value: Latin1.string(value))
                    }
                    decl.arraySize = size
                }
                if WPEHLSLTables.packableTypes.contains(type) {
                    decl.packedFlag = true
                }
            }
            return decl
        }
        return nil
    }

    private static func matchDecl(
        _ line: [UInt8],
        _ literal: [UInt8]
    ) -> (qualifier: Range<Int>, name: Range<Int>, array: Range<Int>?)? {
        let n = line.count
        var s = 0
        while s < n {
            guard Latin1.isWord(line[s]) else {
                s += 1
                continue
            }
            var e = s
            while e < n, Latin1.isWord(line[e]) {
                e += 1
            }
            // Any start inside this word run continues identically, so one attempt per run suffices.
            defer { s = e }
            var k = e
            while k < n, Latin1.isSpace(line[k]) {
                k += 1
            }
            guard k > e, k + literal.count <= n, line[k ..< k + literal.count].elementsEqual(literal) else { continue }
            k += literal.count
            let afterType = k
            while k < n, Latin1.isSpace(line[k]) {
                k += 1
            }
            guard k > afterType else { continue }
            let nameStart = k
            while k < n, Latin1.isWord(line[k]) {
                k += 1
            }
            guard k > nameStart else { continue }
            var array: Range<Int>?
            if k < n, line[k] == 0x5B {
                var m = k + 1
                while m < n, Latin1.isWord(line[m]) {
                    m += 1
                }
                if m > k + 1, m < n, line[m] == 0x5D {
                    array = k ..< m + 1
                }
            }
            return (s ..< e, nameStart ..< k, array)
        }
        return nil
    }

    /// FUN_1400f4460: the first table entry that occurs as an ASCII whole word anywhere in the line.
    private static func attributeIndex(_ line: [UInt8]) -> Int? {
        for (index, attribute) in WPEHLSLTables.attributes.enumerated() {
            var start = 0
            while let p = line.firstIndex(ofBytes: attribute.name, from: start) {
                let e = p + attribute.name.count
                let leftOK = p == 0 || !Latin1.isIdent(line[p - 1])
                let rightOK = e == line.count || !Latin1.isIdent(line[e])
                if leftOK, rightOK {
                    return index
                }
                start = e
            }
        }
        return nil
    }

    /// The varying list flows VS -> GS -> PS: the VS fills it, a GS reads it as inputs and replaces it with
    /// its `out` declarations, and the PS uses it in place of its own declarations.
    private static func linkVaryings(
        _ stage: WPEHLSLStage,
        _ varyings: [WPEHLSLDecl],
        link: inout [WPEHLSLDecl]
    ) -> [WPEHLSLDecl] {
        switch stage {
        case .vertex:
            link = varyings
            return varyings
        case .geometry:
            var result = link.map { $0.with(direction: 1) }
            link = []
            for decl in varyings where decl.direction == 2 {
                result.append(decl)
                link.append(decl.with(direction: 0))
            }
            return result
        case .fragment:
            return link
        }
    }

    // MARK: - main

    private static func accessCount(_ decl: WPEHLSLDecl) -> Int {
        let isVec2 = decl.type == WPEHLSLTables.float2Type
        let n = isVec2 ? decl.arraySize * 2 : decl.arraySize
        let n4 = floorDiv(n, 4) * 4 + (floorMod(n, 4) != 0 ? 4 : 0)
        return floorDiv(n4, isVec2 ? 2 : 1)
    }

    /// FUN_1400f5940 (`source` nil: zero-initialised) / FUN_1400f5680 (`source` = `IN.` or empty).
    private static func accessDecls(_ decls: [WPEHLSLDecl], source: String?) -> [UInt8] {
        var out: [UInt8] = []
        for decl in decls where decl.arraySize != 0 && decl.packedFlag {
            let type = WPEHLSLTables.hlslTypes[decl.type]
            let count = accessCount(decl)
            out += "\(type) accessArray".utf8
            out += decl.name
            out += "[\(count)] = (\(type)[\(count)])".utf8
            if let source {
                out += source.utf8
                out += decl.name
                out += ";\n".utf8
            } else {
                out += "0;\n".utf8
            }
        }
        return out
    }

    private static func mainSignature(
        _ stage: WPEHLSLStage,
        _ text: [UInt8],
        extra: [UInt8],
        varyings: [WPEHLSLDecl],
        uniforms: [WPEHLSLDecl]
    ) -> (signature: [UInt8], epilogue: [UInt8], text: [UInt8]) {
        var text = text
        var signature: [UInt8] = []
        var epilogue: [UInt8] = []
        switch stage {
        case .vertex:
            signature += "VS_OUTPUT main(VS_INPUT IN".utf8
            signature += extra
            signature += ")\n{\n\tVS_OUTPUT OUT;\n".utf8
            signature += accessDecls(varyings, source: nil) + accessDecls(uniforms, source: "")
            for decl in varyings where decl.arraySize != 0 && decl.packedFlag {
                epilogue += "OUT.".utf8 + decl.name + " = accessArray".utf8 + decl.name + ";\n".utf8
            }
        case .geometry:
            let marker = Latin1.bytes("[input:triangles]")
            if let k = text.firstIndex(ofBytes: marker) {
                text.removeSubrange(k ..< k + marker.count)
                signature += "void main(triangle VS_OUTPUT IN[3], inout TriangleStream<PS_INPUT> OUT".utf8
            } else {
                signature += "void main(point VS_OUTPUT IN[1], inout TriangleStream<PS_INPUT> OUT".utf8
            }
            signature += extra
            signature += ")\n{\n\t".utf8
        case .fragment:
            signature += "PS_OUTPUT main(VS_OUTPUT IN".utf8
            signature += extra
            signature += ")\n{\n\tPS_OUTPUT OUT;\n".utf8
            signature += accessDecls(varyings, source: "IN.") + accessDecls(uniforms, source: "")
        }
        return (signature, epilogue, text)
    }

    /// Every `\bvoid\s+main\s*\(\s*\)\s*\{` replaced by `signature`.
    private static func replaceMainDeclarations(_ text: [UInt8], with signature: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var copied = 0
        var i = 0
        while i < text.count {
            if let end = matchVoidMain(text, at: i) {
                out += text[copied ..< i]
                out += signature
                i = end
                copied = end
            } else {
                i += 1
            }
        }
        out += text[copied...]
        return out
    }

    private static func matchVoidMain(_ text: [UInt8], at start: Int) -> Int? {
        guard start == 0 || !Latin1.isWord(text[start - 1]) else { return nil }
        var k = start
        func literal(_ s: String) -> Bool {
            let bytes = Latin1.bytes(s)
            guard k + bytes.count <= text.count, text[k ..< k + bytes.count].elementsEqual(bytes) else { return false }
            k += bytes.count
            return true
        }
        func spaces() -> Int {
            let from = k
            while k < text.count, Latin1.isSpace(text[k]) {
                k += 1
            }
            return k - from
        }
        guard literal("void"), spaces() > 0, literal("main") else { return nil }
        _ = spaces()
        guard literal("(") else { return nil }
        _ = spaces()
        guard literal(")") else { return nil }
        _ = spaces()
        guard literal("{") else { return nil }
        return k
    }

    private static func wrapMain(
        _ stage: WPEHLSLStage,
        _ text: [UInt8],
        signature: [UInt8],
        epilogue: [UInt8],
        attributes: [Int],
        varyings: [WPEHLSLDecl],
        uniforms: [WPEHLSLDecl]
    ) -> [UInt8] {
        let replaced = replaceMainDeclarations(text, with: signature)
        let mainCall = Latin1.bytes("main(")
        guard replaced.contains(bytes: mainCall) else { return replaced }
        let cut = replaced.firstIndex(ofBytes: signature).map { $0 + signature.count } ?? 0
        var mapping: [[UInt8]: [UInt8]] = [:]
        if stage == .vertex {
            for index in attributes {
                let name = WPEHLSLTables.attributes[index].name
                mapping[name] = Latin1.bytes("IN.") + name
            }
        }
        if stage != .geometry {
            let prefix = Latin1.bytes(stage == .vertex ? "OUT." : "IN.")
            for decl in varyings {
                mapping[decl.name] = (decl.isPacked ? Latin1.bytes("accessArray") : prefix) + decl.name
            }
            if stage == .fragment {
                mapping[Latin1.bytes("gl_FragColor")] = Latin1.bytes("OUT.gl_FragColor")
            }
        }
        for decl in uniforms where decl.isPacked {
            mapping[decl.name] = Latin1.bytes("accessArray") + decl.name
        }
        var body = Array(replaced[cut...])
        if !mapping.isEmpty {
            body = replaceIdentifiers(body, mapping)
        }
        var result = staticConst(replaced[..<cut]) + body
        if stage != .geometry, let mainPos = result.firstIndex(ofBytes: mainCall),
           let brace = result.lastIndex(of: 0x7D), mainPos < brace {
            result.insert(contentsOf: epilogue + Latin1.bytes("\treturn OUT;\n"), at: brace)
        }
        return result
    }

    /// FUN_1400f3ea0: `static ` before a line-leading `const` keyword in the text before `main`.
    private static func staticConst(_ head: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        for (index, segment) in head.split(separator: Latin1.lf, omittingEmptySubsequences: false).enumerated() {
            if index > 0 {
                out.append(Latin1.lf)
            }
            var k = segment.startIndex
            while k < segment.endIndex, segment[k] == Latin1.space || segment[k] == Latin1.tab {
                k += 1
            }
            let isConst = segment.endIndex - k >= 5 && segment[k ..< k + 5].elementsEqual("const".utf8)
                && (k + 5 == segment.endIndex || !(Latin1.isAlnum(segment[k + 5]) || segment[k + 5] == Latin1.underscore))
            if isConst {
                out += segment[segment.startIndex ..< k]
                out += "static ".utf8
                out += segment[k...]
            } else {
                out += segment
            }
        }
        return out
    }

    /// Maximal `[A-Za-z0-9_]` runs looked up in `mapping`, comments and strings included.
    private static func replaceIdentifiers(_ body: [UInt8], _ mapping: [[UInt8]: [UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(body.count)
        let n = body.count
        var i = 0
        while i < n {
            guard Latin1.isIdent(body[i]) else {
                out.append(body[i])
                i += 1
                continue
            }
            var j = i
            while j < n, Latin1.isIdent(body[j]) {
                j += 1
            }
            let token = Array(body[i ..< j])
            out += mapping[token] ?? token
            i = j
        }
        return out
    }

    // MARK: - Header

    /// FUN_1400f52e0.
    private static func structVaryings(_ decls: [WPEHLSLDecl], direction: Int) -> [UInt8] {
        var out = Latin1.bytes(direction == 2 ? "struct PS_INPUT\n{\n" : "struct VS_OUTPUT\n{\n")
        var texcoord = 0
        for decl in decls where decl.direction == direction {
            let type = decl.isPacked ? WPEHLSLTables.float4Type : decl.type
            out += "\(WPEHLSLTables.hlslTypes[type]) ".utf8
            out += decl.name
            var count = 1
            if decl.arraySize > 0, decl.arraySize * (decl.type + 1) > 4 {
                let divisor = decl.type == WPEHLSLTables.float2Type ? 2 : 4
                count = decl.arraySize / divisor + (decl.arraySize % divisor != 0 ? 1 : 0)
                out += "[\(count)]".utf8
            }
            out += " : ".utf8
            if decl.name == Latin1.bytes("gl_Position") {
                out += "SV_POSITION".utf8
            } else if decl.name == Latin1.bytes("gl_ViewportIndex") {
                out += "SV_ViewportArrayIndex".utf8
            } else {
                out += "TEXCOORD\(texcoord)".utf8
                texcoord += count
            }
            out += ";\n".utf8
        }
        return out + Latin1.bytes("};\n\n")
    }

    private static func textureDecl(_ decl: WPEHLSLDecl, code: Int, combos: WPEShaderMacros) -> [UInt8] {
        let reg = code - WPEHLSLTables.firstTextureCode
        let name = Latin1.string(decl.name)
        if decl.type == WPEHLSLTables.backBufferSamplerType {
            if combos[Latin1.bytes("BACKBUFFER_MS")] != nil {
                return Latin1.bytes("Texture2DMS<float4> \(name):register(t\(reg));\n")
            }
            return Latin1.bytes("Texture2D \(name):register(t\(reg));\nSamplerState \(name)SamplerState:register(s\(reg));\n")
        }
        let texture = decl.type == WPEHLSLTables.sampler3DType ? "Texture3D" : "Texture2D"
        let sampler = decl.type == WPEHLSLTables.comparisonSamplerType ? "SamplerComparisonState" : "SamplerState"
        return Latin1.bytes("\(texture) \(name):register(t\(reg));\n\(sampler) \(name)\(sampler):register(s\(reg));\n")
    }

    private static func header(
        _ stage: WPEHLSLStage,
        _ text: [UInt8],
        attributes: [Int],
        varyings: [WPEHLSLDecl],
        uniforms: [WPEHLSLDecl],
        combos: WPEShaderMacros
    ) throws -> [UInt8] {
        var out = WPEHLSLTables.prelude
        out += combos[Latin1.bytes("BACKBUFFER_MS")] != nil ? WPEHLSLTables.backBufferMSLine : WPEHLSLTables.backBufferLine
        switch stage {
        case .vertex:
            out += "struct VS_INPUT\n{\n".utf8
            for index in attributes {
                let attribute = WPEHLSLTables.attributes[index]
                out += "\(WPEHLSLTables.hlslTypes[attribute.hlslType]) ".utf8
                out += attribute.name
                out += " : \(WPEHLSLTables.semantics[attribute.semantic])\(attribute.semanticIndex);\n".utf8
            }
            out += "};\n\n".utf8
            out += structVaryings(varyings, direction: 0)
        case .geometry:
            out += structVaryings(varyings, direction: 1) + structVaryings(varyings, direction: 2)
        case .fragment:
            if text.contains(bytes: Latin1.bytes("gl_FragColor")) {
                out += "struct PS_OUTPUT\n{\nfloat4 gl_FragColor : SV_TARGET;\n};\n".utf8
            } else {
                out += "struct PS_OUTPUT {};\n".utf8
            }
            out += structVaryings(varyings, direction: 0)
        }
        var textures: [UInt8] = []
        var staticBuffer: [UInt8] = []
        var dynamicBuffer: [UInt8] = []
        var hasAnimation = false
        var hasLights = false
        for decl in uniforms {
            let code = WPEHLSLTables.uniformCodes[decl.name]
            let bucket = WPEHLSLTables.uniformBucket(code)
            switch bucket {
            case .texture:
                textures += textureDecl(decl, code: code ?? 0, combos: combos)
            case .staticBuffer, .dynamicBuffer:
                let type = decl.isPacked ? WPEHLSLTables.packedTypes[decl.type] : decl.type
                var line = Latin1.bytes("const \(WPEHLSLTables.hlslTypes[type]) ") + decl.name
                if decl.arraySize > 0 {
                    var count = decl.arraySize
                    if decl.packedFlag {
                        count = (count >> 2) + 1 - (count % 4 == 0 ? 1 : 0)
                    }
                    line += "[\(count)]".utf8
                }
                line += ";\n".utf8
                if bucket == .staticBuffer {
                    staticBuffer += line
                } else {
                    dynamicBuffer += line
                }
            case .animationBuffer:
                hasAnimation = true
            case .lightsBuffer:
                hasLights = true
            case .dropped:
                break
            }
        }
        out += textures
        if !staticBuffer.isEmpty {
            out += "cbuffer g_bufStatic:register(b0)\n{\n".utf8 + staticBuffer + "}\n".utf8
        }
        if !dynamicBuffer.isEmpty {
            out += "cbuffer g_bufDynamic:register(b1)\n{\n".utf8 + dynamicBuffer + "}\n".utf8
        }
        if hasAnimation {
            guard let bones = combos[Latin1.bytes("BONECOUNT")] else {
                throw WPEHLSLRewriteError.missingDefine("BONECOUNT")
            }
            out += "cbuffer g_bufAnimation:register(b2)\n{\nconst float4x3 g_Bones[".utf8 + bones + "];\n}\n".utf8
        }
        if hasLights {
            out += "cbuffer g_bufLights:register(b3)\n{\n".utf8 + lightsCBuffer(combos) + "}\n".utf8
        }
        return out
    }

    private static func lightsCBuffer(_ combos: WPEShaderMacros) -> [UInt8] {
        func count(_ key: String) -> Int {
            combos[Latin1.bytes(key)].flatMap(Latin1.pythonInt) ?? 0
        }
        var s = ""
        var n = count("LIGHTS_POINT")
        if n != 0 {
            s += "const float4 g_LPoint_Color[\(n)];\nconst float4 g_LPoint_Origin[\(n)];\n"
        }
        n = count("LIGHTS_SPOT")
        if n != 0 {
            s += "const float4 g_LSpot_Color[\(n)];\nconst float4 g_LSpot_Origin[\(n)];\n"
                + "const float4 g_LSpot_Direction[\(n)];\nconst float4 g_LSpot_Exponent[\(n)];\n"
        }
        n = count("LIGHTS_TUBE")
        if n != 0 {
            s += "const float4 g_LTube_Color[\(n)];\nconst float4 g_LTube_OriginA[\(n)];\n"
                + "const float3 g_LTube_OriginB[\(n)];\n"
        }
        n = count("LIGHTS_DIRECTIONAL")
        if n != 0 {
            s += "const float4 g_LDirectional_Color[\(n)];\nconst float3 g_LDirectional_Direction[\(n)];\n"
        }
        n = count("LIGHTS_DIRECTIONAL_SHADOW") * 3 + count("LIGHTS_SPOT_COOKIE") + count("LIGHTS_SPOT_SHADOW")
            + count("LIGHTS_SPOT_SHADOW_COOKIE")
        if n != 0 {
            s += "const float4x4 g_LFeature_ShadowProjection[\(n)];\n"
                + "const float4 g_LFeature_ShadowProjectionTransform[\(n)];\n"
        }
        n = count("LIGHTS_POINT_SHADOW")
        if n != 0 {
            s += "const float4 g_LFeature_ShadowPointProjection[\(n)];\n"
                + "const float4 g_LFeature_ShadowPointProjectionTransform[\(n)];\n"
        }
        return Latin1.bytes(s)
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func floorMod(_ a: Int, _ b: Int) -> Int {
        a - floorDiv(a, b) * b
    }
}
