#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE

/// Serves the HLSL capture's precompiled stages: a request's program is matched to captures through the WPE `.dxs`
/// cache key its `WPEParityProgram` produces, as listed in `dxs-pairs.json`.
struct WPEParityFixtureShaderCompiler: WPEParityShaderCompiling {
    enum Failure: Error {
        case unknownProgram
        case noCapture(dxs: String, target: String)
    }

    private struct Pair: Decodable {
        let n: Int
        let target: String
        let hlsl: String
        let dxs: String
    }

    private let directory: URL
    private let dxsKeys: [WPEHLSLProgram: String]
    /// `.dxs` stem → shader target ("vs_5_0", "ps_5_0", "gs_5_0") → captures in manifest order.
    private let captures: [String: [String: [Pair]]]

    init(directory: URL, programs: some Sequence<WPEParityProgram>) throws {
        self.directory = directory
        dxsKeys = Dictionary(programs.map { ($0.hlsl, $0.dxsKey()) }) { first, _ in first }
        let pairs = try JSONDecoder().decode([Pair].self,
                                             from: Data(contentsOf: directory.appending(path: "dxs-pairs.json")))
        var captures: [String: [String: [Pair]]] = [:]
        for pair in pairs {
            let stem = URL(fileURLWithPath: pair.dxs).deletingPathExtension().lastPathComponent
            captures[stem, default: [:]][pair.target, default: []].append(pair)
        }
        self.captures = captures
    }

    func compile(_ request: WPEParityShaderCompileRequest) async throws -> WPEParityCompiledStages {
        guard let dxs = dxsKeys[request.program] else { throw Failure.unknownProgram }
        var stages: [WPEParityShaderKey.Stage: WPEParityCompiledStages.Stage] = [:]
        let compiled = directory.appending(path: "compiled")
        for stage in request.stages {
            let (target, hlsl) = switch stage {
            case .vertex: ("vs_5_0", request.program.vertex)
            case .fragment: ("ps_5_0", request.program.fragment)
            case .geometry: ("gs_5_0", request.program.geometry)
            }
            // One `.dxs` key can name more than one capture of a stage; the HLSL bytes pick the one compiled here.
            let candidates = captures[dxs]?[target] ?? []
            guard let number = try candidates.first(where: {
                try Array(Data(contentsOf: directory.appending(path: $0.hlsl))) == hlsl
            })?.n else { throw Failure.noCapture(dxs: dxs, target: target) }
            stages[stage] = try .init(
                metallib: Data(contentsOf: compiled.appending(path: "\(number).metallib")),
                reflectionJSON: Self.fillingVertexInputs(Data(contentsOf: compiled.appending(path: "\(number).json")))
            )
        }
        return WPEParityCompiledStages(stages: stages)
    }

    /// The capture leaves `vertexInputs` empty while MSC's raw reflection lists them under `state.vertex_inputs`.
    private static func fillingVertexInputs(_ json: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              (object["vertexInputs"] as? [Any])?.isEmpty == true,
              let msc = object["mscReflection"] as? [String: Any],
              let state = msc["state"] as? [String: Any],
              let inputs = state["vertex_inputs"] as? [[String: Any]] else { return json }
        object["vertexInputs"] = inputs.map { input -> [String: Any] in
            ["name": input["name"] ?? "", "index": input["index"] ?? 0,
             "elementType": input["elementType"] ?? "", "columns": input["columnCount"] ?? 0]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
#endif
