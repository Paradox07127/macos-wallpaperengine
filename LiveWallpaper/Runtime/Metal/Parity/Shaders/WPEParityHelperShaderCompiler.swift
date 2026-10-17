#if !LITE_BUILD
import CryptoKit
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import os

/// Compiles each stage by running the `wpe-shaderc` helper, which loads DXC and Metal Shader Converter itself.
struct WPEParityHelperShaderCompiler: WPEParityShaderCompiling {
    enum Failure: Error, CustomStringConvertible {
        case helperFailed(stage: WPEParityShaderKey.Stage, status: Int32, stderr: String)

        var description: String {
            switch self {
            case let .helperFailed(stage, status, stderr):
                "wpe-shaderc \(stage.rawValue) stage exited with \(status): \(stderr)"
            }
        }
    }

    /// SHA-256 of the helper and both libraries, so cached shaders follow the binaries rather than their paths;
    /// each file is rehashed only when its path, size, mtime or inode changes.
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
        compilerIdentity = try "wpe-shaderc " + [helper, dxcompiler, metalIRConverter].map(Self.fileDigest)
            .joined(separator: " ")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    private struct FileStamp: Hashable {
        let path: String
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let inode: ino_t
    }

    private static let fileDigests = OSAllocatedUnfairLock<[FileStamp: String]>(initialState: [:])

    private static func fileDigest(_ url: URL) throws -> String {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let stamp = FileStamp(path: url.path, size: info.st_size, modifiedSeconds: info.st_mtimespec.tv_sec,
                              modifiedNanoseconds: info.st_mtimespec.tv_nsec, inode: info.st_ino)
        if let digest = fileDigests.withLock({ $0[stamp] }) {
            return digest
        }
        #if DEBUG
        fileHashCounts.withLock { $0[url.path, default: 0] += 1 }
        #endif
        let digest = try digest(Data(contentsOf: url, options: .alwaysMapped))
        fileDigests.withLock { $0[stamp] = digest }
        return digest
    }

    #if DEBUG
    private static let fileHashCounts = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    /// How many times this process has read and hashed the file at `path` for an identity.
    static func fileHashCount(path: String) -> Int {
        fileHashCounts.withLock { $0[path, default: 0] }
    }
    #endif

    func compile(_ request: WPEParityShaderCompileRequest) async throws -> WPEParityCompiledStages {
        let sources: [(WPEParityShaderKey.Stage, [UInt8]?)] = [
            (.vertex, request.program.vertex), (.fragment, request.program.fragment),
            (.geometry, request.program.geometry),
        ]
        let emulatesGeometry = request.program.geometry != nil
        return try await withThrowingTaskGroup(
            of: (WPEParityShaderKey.Stage, WPEParityCompiledStages.Stage).self
        ) { group in
            for case let (stage, hlsl?) in sources {
                group.addTask {
                    try await (stage, compile(stage, hlsl: hlsl, options: request.options,
                                              stageIn: emulatesGeometry && stage == .vertex))
                }
            }
            var stages: [WPEParityShaderKey.Stage: WPEParityCompiledStages.Stage] = [:]
            for try await (stage, compiled) in group {
                stages[stage] = compiled
            }
            return WPEParityCompiledStages(stages: stages)
        }
    }

    /// `stageIn` compiles a vertex stage for MSC geometry emulation, which also yields a stage-in metallib.
    private func compile(_ stage: WPEParityShaderKey.Stage, hlsl: [UInt8], options: WPEParityShaderCompileOptions,
                         stageIn: Bool) async throws -> WPEParityCompiledStages.Stage {
        let base = workDirectory.appending(path: UUID().uuidString)
        let input = base.appendingPathExtension("hlsl")
        let metallib = base.appendingPathExtension("metallib")
        let reflection = base.appendingPathExtension("json")
        let stageInMetallib = base.appendingPathExtension("stagein.metallib")
        let log = base.appendingPathExtension("stderr")
        defer {
            for url in [input, metallib, reflection, stageInMetallib, log] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let source = Data(hlsl)
        try source.write(to: input)
        var arguments = [
            "--stage", stage.rawValue, "--entry", "main", "--input", input.path,
            "--output-metallib", metallib.path, "--output-reflection", reflection.path,
            "--dxcompiler", dxcompiler.path, "--metalirconverter", metalIRConverter.path,
            "--min-macos", options.minimumMacOS,
        ]
        if options.boundsCheck {
            arguments.append("--bounds-check")
        }
        if stageIn {
            arguments += ["--output-stage-in", stageInMetallib.path]
        }
        let result = try await run(arguments, stage: stage, stderr: log)
        guard result.status == 0 else {
            let stderr = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.helperFailed(stage: stage, status: result.status, stderr: stderr)
        }
        do {
            let output = try WPEParityCompiledStages.Stage(
                metallib: Data(contentsOf: metallib), reflectionJSON: Data(contentsOf: reflection),
                stageIn: stageIn ? Data(contentsOf: stageInMetallib) : nil
            )
            Logger.notice("WPE parity shader output appPID=\(ProcessInfo.processInfo.processIdentifier) "
                + "childPID=\(result.pid) stage=\(stage.rawValue) minMacOS=\(options.minimumMacOS) "
                + "boundsCheck=\(options.boundsCheck) inputSHA256=\(Self.digest(source)) "
                + "metallibBytes=\(output.metallib.count) metallibSHA256=\(Self.digest(output.metallib)) "
                + "reflectionBytes=\(output.reflectionJSON.count) reflectionSHA256=\(Self.digest(output.reflectionJSON)) "
                + "stageInBytes=\(output.stageIn?.count ?? 0) stageInSHA256=\(output.stageIn.map(Self.digest) ?? "none")",
                category: .wpeRender)
            return output
        } catch {
            Logger.warning("WPE parity shader output unavailable appPID=\(ProcessInfo.processInfo.processIdentifier) "
                + "childPID=\(result.pid) stage=\(stage.rawValue): \(error)", category: .wpeRender)
            throw error
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// stderr goes to a file: a pipe nobody drains while waiting would stall the helper once it fills.
    private func run(_ arguments: [String], stage: WPEParityShaderKey.Stage,
                     stderr: URL) async throws -> (pid: Int32, status: Int32) {
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
        let appPID = ProcessInfo.processInfo.processIdentifier
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { child in
                Logger.notice("WPE parity shader helper appPID=\(appPID) childPID=\(child.processIdentifier) "
                    + "stage=\(stage.rawValue) exit=\(child.terminationStatus) reason=\(child.terminationReason.rawValue)",
                    category: .wpeRender)
                continuation.resume(returning: (child.processIdentifier, child.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                Logger.warning("WPE parity shader helper appPID=\(appPID) childPID=none "
                    + "stage=\(stage.rawValue) spawn-failed: \(error)", category: .wpeRender)
                continuation.resume(throwing: error)
            }
        }
    }
}
#endif
