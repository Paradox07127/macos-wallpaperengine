import Foundation
@testable import LiveWallpaperProWPE

/// The D3DCompile capture fixture: manifest.json entries plus the GLSL trees and captured HLSL they point at.
/// Grouping, define-block parsing and the recompile input guess mirror the capture's check.py.
struct WPEHLSLCaptureFixture {
    struct Entry: Decodable {
        let n: Int
        let name: String
        let target: String
        let glsl: String
        let roots: [String]
        let hlsl: String
    }

    struct Define: Equatable {
        let name: String
        let value: String
    }

    let root: URL
    let entries: [Entry]
    private let byNumber: [Int: Entry]

    init(root: URL) throws {
        self.root = root
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        entries = try JSONDecoder().decode([Entry].self, from: data)
        byNumber = Dictionary(uniqueKeysWithValues: entries.map { ($0.n, $0) })
    }

    func captured(_ entry: Entry) throws -> [UInt8] {
        try Array(Data(contentsOf: root.appendingPathComponent(entry.hlsl)))
    }

    /// Returns the expected bytes and the rewriter's bytes for one capture.
    func reproduce(_ entry: Entry) throws -> (expected: [UInt8], actual: [UInt8]) {
        let (wanted, members, recompile) = try group(entry)
        let expected = try captured(entry)
        guard let block = Self.defineBlock(expected) else { throw FixtureError.noDefineBlock(entry.n) }
        let defines = block.filter { !["HLSL", "HLSL_SM40", "GS_ENABLED"].contains($0.name) }
            .map { WPEShaderDefine(name: $0.name, value: $0.value) }
        let gsEnabled = block.contains { $0.name == "GS_ENABLED" }

        var roots: [String] = []
        var stageFiles: [String: URL] = [:]
        let order: [WPEShaderStage] = [.vertex, .geometry, .fragment]
        for stage in order {
            guard let member = members[stage] else { continue }
            if let first = member.roots.first, !roots.contains(first) {
                roots.append(first)
            }
            stageFiles[member.name] = root.appendingPathComponent(member.glsl)
        }
        for stage in order {
            for extra in members[stage]?.roots ?? [] where !roots.contains(extra) {
                roots.append(extra)
            }
        }

        // The engine translates VS -> GS -> PS and the wanted stage only depends on the ones before it.
        let upTo = order.firstIndex(of: wanted) ?? 0
        let included = Set(order[...upTo])
        let sources = WPEHLSLProgramSources(
            vertex: included.contains(.vertex) ? members[.vertex]?.name : nil,
            geometry: included.contains(.geometry) ? members[.geometry]?.name : nil,
            fragment: included.contains(.fragment) ? members[.fragment]?.name : nil
        )
        let vfs = FixtureSources(stageFiles: stageFiles, roots: roots.map { root.appendingPathComponent($0) })
        let program = try WPEHLSLRewriter(sources: vfs).rewrite(
            sources, defines: defines, geometryShadersEnabled: gsEnabled
        )
        let output: [UInt8]? = switch wanted {
        case .vertex: program.vertex
        case .geometry: program.geometry
        case .fragment: program.fragment
        }
        guard var actual = output else { throw FixtureError.noOutput(entry.n) }
        if recompile {
            actual = WPEHLSLRewriter.pruningVertexInputs(actual, unusedSemantics: Self.guessUnusedInputs(actual)) ?? actual
        }
        return (expected, actual)
    }

    private func stage(_ entry: Entry?) -> WPEShaderStage? {
        switch entry?.target {
        case "vs_5_0": .vertex
        case "gs_5_0": .geometry
        case "ps_5_0": .fragment
        default: nil
        }
    }

    /// check.py `group`: a PS takes the VS (or VS+GS) right before it; a VS right after its own
    /// VS[,GS],PS group with the same define block is the second compile of that VS.
    private func group(_ entry: Entry) throws -> (WPEShaderStage, [WPEShaderStage: Entry], Bool) {
        let n = entry.n
        guard let own = stage(entry) else { throw FixtureError.unknownTarget(entry.target) }
        let p1 = byNumber[n - 1], p2 = byNumber[n - 2], p3 = byNumber[n - 3]
        var members: [WPEShaderStage: Entry] = [own: entry]
        switch own {
        case .fragment:
            if stage(p1) == .geometry, let p1, let p2 {
                members[.geometry] = p1
                members[.vertex] = p2
            } else if stage(p1) == .vertex, let p1 {
                members[.vertex] = p1
            }
            return (own, members, false)
        case .geometry:
            if let p1 {
                members[.vertex] = p1
            }
            return (own, members, false)
        case .vertex:
            if stage(p1) == .fragment, stage(p2) == .vertex, let p1, let p2, p2.name == entry.name,
               try sameDefines(p2, entry) {
                return (own, [.vertex: p2, .fragment: p1], true)
            }
            if stage(p1) == .fragment, stage(p2) == .geometry, stage(p3) == .vertex, let p1, let p2, let p3,
               p3.name == entry.name, try sameDefines(p3, entry) {
                return (own, [.vertex: p3, .geometry: p2, .fragment: p1], true)
            }
            return (own, members, false)
        }
    }

    private func sameDefines(_ a: Entry, _ b: Entry) throws -> Bool {
        try Self.defineBlock(captured(a)) == Self.defineBlock(captured(b))
    }

    /// check.py `defines_from_capture`: the `#define NAME digits` lines from `#define HLSL 1` on.
    static func defineBlock(_ hlsl: [UInt8]) -> [Define]? {
        guard let start = hlsl.firstIndex(ofBytes: Latin1.bytes("#define HLSL 1\n#define HLSL_SM40 1\n")) else {
            return nil
        }
        var block: [Define] = []
        let prefix = Latin1.bytes("#define ")
        for line in hlsl[start...].split(separator: Latin1.lf, omittingEmptySubsequences: false) {
            let line = Array(line)
            guard line.starts(with: prefix) else { break }
            let rest = line[prefix.count...]
            guard let space = rest.firstIndex(of: Latin1.space) else { break }
            let name = rest[..<space]
            let value = rest[(space + 1)...]
            guard !name.isEmpty, name.allSatisfy(Latin1.isWord),
                  !value.isEmpty, value.allSatisfy(Latin1.isASCIIDigit) else { break }
            block.append(Define(name: Latin1.string(name), value: Latin1.string(value)))
        }
        return block
    }

    /// Stand-in for FXC reflection (ReadWriteMask == 0): VS_INPUT members never referenced as `IN.<name>`
    /// after `VS_OUTPUT main(`.
    static func guessUnusedInputs(_ hlsl: [UInt8]) -> [String] {
        let open = Latin1.bytes("struct VS_INPUT\n{\n")
        var members: ArraySlice<UInt8> = []
        if let s = hlsl.firstIndex(ofBytes: open),
           let e = hlsl.firstIndex(ofBytes: Latin1.bytes("};"), from: s + open.count) {
            members = hlsl[(s + open.count) ..< e]
        }
        let mainAt = hlsl.firstIndex(ofBytes: Latin1.bytes("VS_OUTPUT main(")) ?? (hlsl.count - 1)
        let body = Array(hlsl[max(0, mainAt)...])
        var unused: [String] = []
        for line in members.split(separator: Latin1.lf, omittingEmptySubsequences: false) {
            // `^\w+ (\w+) : (\w+);$`
            let parts = line.split(separator: Latin1.space, omittingEmptySubsequences: false)
            guard parts.count == 4, parts[2].elementsEqual([0x3A]), let semicolon = parts[3].last, semicolon == 0x3B
            else { continue }
            let name = Array(parts[1])
            let semantic = parts[3].dropLast()
            guard [parts[0], parts[1], semantic].allSatisfy({ !$0.isEmpty && $0.allSatisfy(Latin1.isWord) })
            else { continue }
            if Latin1.firstWholeWord(Latin1.bytes("IN.") + name, in: body) == nil {
                unused.append(Latin1.string(semantic))
            }
        }
        return unused
    }

    enum FixtureError: Error {
        case noDefineBlock(Int)
        case noOutput(Int)
        case unknownTarget(String)
    }
}

/// Stage files resolve to their capture paths; `shaders/<x>` includes search the roots in order.
private struct FixtureSources: WPEShaderSourceProviding {
    let stageFiles: [String: URL]
    let roots: [URL]

    func shaderSource(named name: String) -> [UInt8]? {
        if let url = stageFiles[name] {
            return try? Array(Data(contentsOf: url))
        }
        guard name.hasPrefix("shaders/") else { return nil }
        let relative = String(name.dropFirst("shaders/".count))
        for root in roots {
            var isDirectory: ObjCBool = false
            let url = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return try? Array(Data(contentsOf: url))
            }
        }
        return nil
    }
}
