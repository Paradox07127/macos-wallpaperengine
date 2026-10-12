#if !LITE_BUILD
import CryptoKit
import Foundation
import LiveWallpaperProWPE

/// Compiles each stage by running the `wpe-shaderc` helper, which loads DXC and Metal Shader Converter itself.
struct WPEParityHelperShaderCompiler: WPEParityShaderCompiling {
    enum Failure: Error, CustomStringConvertible {
        case helperFailed(stage: WPEParityShaderKey.Stage, status: Int32, stderr: String)
        /// The helper keeps DXC's reflection but cannot convert a geometry stage into a metallib.
        case geometryUnsupported(stderr: String)

        var description: String {
            switch self {
            case let .helperFailed(stage, status, stderr):
                "wpe-shaderc \(stage.rawValue) stage exited with \(status): \(stderr)"
            case let .geometryUnsupported(stderr):
                "wpe-shaderc produced no metallib for the geometry stage (geometry unsupported): \(stderr)"
            }
        }
    }

    /// SHA-256 of the helper and both libraries, so cached shaders follow the binaries rather than their paths.
    let compilerIdentity: String
    private let helper: URL
    private let dxcompiler: URL
    private let metalIRConverter: URL
    private let workDirectory: URL

    init(helper: URL, dxcompiler: URL, metalIRConverter: URL, workDirectory: URL) throws {
        self.helper = helper
        self.dxcompiler = dxcompiler
        self.metalIRConverter = metalIRConverter
        self.workDirectory = workDirectory
        compilerIdentity = try "wpe-shaderc " + [helper, dxcompiler, metalIRConverter].map { url in
            try SHA256.hash(data: Data(contentsOf: url, options: .alwaysMapped))
                .map { String(format: "%02x", $0) }.joined()
        }.joined(separator: " ")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    func compile(_ request: WPEParityShaderCompileRequest) async throws -> WPEParityCompiledStages {
        let sources: [(WPEParityShaderKey.Stage, [UInt8]?)] = [
            (.vertex, request.program.vertex), (.fragment, request.program.fragment),
            (.geometry, request.program.geometry),
        ]
        return try await withThrowingTaskGroup(
            of: (WPEParityShaderKey.Stage, WPEParityCompiledStages.Stage).self
        ) { group in
            for case let (stage, hlsl?) in sources {
                group.addTask { try await (stage, compile(stage, hlsl: hlsl, options: request.options)) }
            }
            var stages: [WPEParityShaderKey.Stage: WPEParityCompiledStages.Stage] = [:]
            for try await (stage, compiled) in group {
                stages[stage] = compiled
            }
            return WPEParityCompiledStages(stages: stages)
        }
    }

    private func compile(_ stage: WPEParityShaderKey.Stage, hlsl: [UInt8],
                         options: WPEParityShaderCompileOptions) async throws -> WPEParityCompiledStages.Stage {
        let base = workDirectory.appending(path: UUID().uuidString)
        let input = base.appendingPathExtension("hlsl")
        let metallib = base.appendingPathExtension("metallib")
        let reflection = base.appendingPathExtension("json")
        let log = base.appendingPathExtension("stderr")
        defer {
            for url in [input, metallib, reflection, log] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try Data(hlsl).write(to: input)
        var arguments = [
            "--stage", stage.rawValue, "--entry", "main", "--input", input.path,
            "--output-metallib", metallib.path, "--output-reflection", reflection.path,
            "--dxcompiler", dxcompiler.path, "--metalirconverter", metalIRConverter.path,
            "--min-macos", options.minimumMacOS,
        ]
        if options.boundsCheck {
            arguments.append("--bounds-check")
        }
        let status = try await run(arguments, stderr: log)
        let stderr = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else { throw Failure.helperFailed(stage: stage, status: status, stderr: stderr) }
        guard FileManager.default.fileExists(atPath: metallib.path) else {
            throw Failure.geometryUnsupported(stderr: stderr)
        }
        return try .init(metallib: Data(contentsOf: metallib), reflectionJSON: Data(contentsOf: reflection))
    }

    /// stderr goes to a file: a pipe nobody drains while waiting would stall the helper once it fills.
    private func run(_ arguments: [String], stderr: URL) async throws -> Int32 {
        guard FileManager.default.createFile(atPath: stderr.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: stderr.path])
        }
        let log = try FileHandle(forWritingTo: stderr)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = log
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
#endif
