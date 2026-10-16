import Foundation
@testable import LiveWallpaperProWPE

/// The three capture scenes run through document → frame → programs, matched stage by stage against the captures.
struct ParityProgramCaptureFixture {
    struct Capture: Decodable {
        let n: Int
        let name: String
        let target: String
        let hlsl: String
        let dxs: String
    }

    struct DrawResult {
        let pass: WPEPassIdentity
        let shader: String
        let program: WPEParityProgram?
        /// Capture number per stage the program reproduces byte for byte.
        let matches: [WPEHLSLStage: Int]
        /// Empty when every stage matched.
        let problems: [String]
        /// Fragment capture whose `.dxs` key equals the program's when the bytes differ: WPE compiles a key once and
        /// reuses that program, so the capture holds the text of whichever draw compiled it first.
        let keyMatch: Int?

        var matched: Bool {
            program != nil && problems.isEmpty
        }
    }

    /// Manifest order is load order: 3815666789 compiled 1–14, 3509243656 (the only HDR and BACKBUFFER_MS scene)
    /// 15–82, 3660962877 83–145.
    static let scenes: [(id: String, captures: ClosedRange<Int>)] = [
        ("3815666789", 1 ... 14), ("3509243656", 15 ... 82), ("3660962877", 83 ... 145),
    ]

    /// The capture machine ran postprocessing ultra with MSAA on (the report infers it from HDR and BACKBUFFER_MS).
    static let captureSettings = WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaa: true)

    let root: URL
    let assetRoots: [URL]
    let captures: [Int: Capture]
    private let bytes: [Int: [UInt8]]

    init(root: URL, wpeAssets: URL) throws {
        self.root = root
        // The capture's wpeassets/ holds only shaders; util materials and models come from a WPE install.
        assetRoots = [root.appendingPathComponent("wpeassets"), wpeAssets]
        let list = try JSONDecoder().decode([Capture].self,
                                            from: Data(contentsOf: root.appendingPathComponent("dxs-pairs.json")))
        captures = Dictionary(uniqueKeysWithValues: list.map { ($0.n, $0) })
        bytes = try Dictionary(uniqueKeysWithValues: list.map {
            try ($0.n, Array(Data(contentsOf: root.appendingPathComponent($0.hlsl))))
        })
    }

    func document(_ sceneID: String) throws -> WPESceneDocument {
        let data = try Data(contentsOf: root.appendingPathComponent("scene-sources/\(sceneID)/scene.json"))
        return try WPESceneDocumentParser.parse(data: data, userValues: [:],
                                                makeTransformScriptResolver: { _, _ in NoScriptResolver() })
    }

    func run(_ sceneID: String, captureRange: ClosedRange<Int>,
             adjust: (inout WPEParityProgramDescription, WPEParityProgramAssets) -> Void = { _, _ in }) throws
        -> [DrawResult] {
        let assets = WPEParityProgramAssets(
            sceneDirectory: root.appendingPathComponent("scene-sources/\(sceneID)"), assetRoots: assetRoots
        )
        let scene = try WPEParityProgramScene(document: document(sceneID), assets: assets,
                                              settings: Self.captureSettings)
        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess, frameIndex: 0)
        return frame.draws.keys.sorted().map { index in
            let pass = frame.operations[index].pass
            guard var description = frame.draws[index].flatMap({ WPEParityProgramBuilder.description(of: $0, scene: scene) })
            else {
                return DrawResult(pass: pass, shader: "?", program: nil, matches: [:],
                                  problems: ["no material file"], keyMatch: nil)
            }
            adjust(&description, assets)
            let shader = description.material.shader
            do {
                let program = try WPEParityProgramResolver.resolve(description, sources: assets)
                let (matches, problems) = match(program, in: captureRange)
                let key = program.dxsKey()
                let keyMatch = problems.isEmpty ? nil : captureRange.first { n in
                    captures[n]?.target == "ps_5_0" && dxsKey(n) == key
                }
                return DrawResult(pass: pass, shader: shader, program: program, matches: matches,
                                  problems: problems, keyMatch: keyMatch)
            } catch {
                return DrawResult(pass: pass, shader: shader, program: nil, matches: [:],
                                  problems: ["\(error)"], keyMatch: nil)
            }
        }
    }

    func dxsKey(_ capture: Int) -> String? {
        captures[capture].map { URL(fileURLWithPath: $0.dxs).deletingPathExtension().lastPathComponent }
    }

    private func match(_ program: WPEParityProgram,
                       in range: ClosedRange<Int>) -> ([WPEHLSLStage: Int], [String]) {
        let stages: [(WPEHLSLStage, [UInt8]?, String, String)] = [
            (.vertex, program.hlsl.vertex, "vs_5_0", "vert"),
            (.geometry, program.hlsl.geometry, "gs_5_0", "geom"),
            (.fragment, program.hlsl.fragment, "ps_5_0", "frag"),
        ]
        var matches: [WPEHLSLStage: Int] = [:]
        var problems: [String] = []
        for (stage, output, target, ext) in stages {
            guard let output else { continue }
            let candidates = range.compactMap { captures[$0] }.filter { $0.target == target }
            if let hit = candidates.first(where: { bytes[$0.n] == output }) {
                matches[stage] = hit.n
                continue
            }
            let name = "shaders/\(program.shader).\(ext)"
            let named = candidates.filter { $0.name == name }
            guard !named.isEmpty else {
                problems.append("\(ext): no capture of \(name)")
                continue
            }
            let scored = named.map { ($0.n, Self.firstDifference(bytes[$0.n] ?? [], output)) }
            let best = scored.max { $0.1.line < $1.1.line }!
            problems.append("\(ext): closest n=\(best.0) \(best.1.text)")
        }
        return (matches, problems)
    }

    static func firstDifference(_ expected: [UInt8], _ actual: [UInt8]) -> (line: Int, text: String) {
        let want = expected.split(separator: Latin1.lf, omittingEmptySubsequences: false)
        let got = actual.split(separator: Latin1.lf, omittingEmptySubsequences: false)
        for index in 0 ..< max(want.count, got.count) {
            let a = index < want.count ? Latin1.string(want[index]) : "<EOF>"
            let b = index < got.count ? Latin1.string(got[index]) : "<EOF>"
            if a != b {
                return (index, "L\(index + 1) want \(a.debugDescription) got \(b.debugDescription)")
            }
        }
        return (Int.max, "same lines, bytes differ")
    }
}

private struct NoScriptResolver: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
