#if !LITE_BUILD
import CryptoKit
import Foundation
import LiveWallpaperProWPE
import Metal

/// One compile job. The `processed*Source` strings are already through
/// `WPEShaderPreprocessor` (combos baked in, includes resolved, WPE macros
/// rewritten). The compiler only needs to translate canonical GLSL to MSL.
struct WPEShaderCompileRequest: Sendable, Hashable {
    let shaderName: String
    let processedVertexSource: String
    let processedFragmentSource: String
    /// Stable hash of the (raw vertex source, raw fragment source, combo
    /// values) tuple. Combined with PMA flags (`translationCacheKey`) and
    /// `WPEShaderTranslationCache.schemaVersion` as the disk-cache key.
    let sourceHash: String
    /// Raw `// [COMBO]` declarations the preprocessor saw, after combo
    /// values were merged in. Surfaced to the executor so reflection lookups
    /// know which `#define`s shipped to the GPU.
    let comboValues: [String: Int]
    /// Texture binding declarations from `// [BIND]` lines plus material
    /// `textures` array. Index → logical name. The executor maps these to
    /// MTL texture slots.
    let textureBindings: [Int: String]
    /// Texture slots whose bound source is a WPE render target (`previous` or
    /// an FBO/layer composite). Those textures already store premultiplied
    /// RGB, so the transpiler un-premultiplies them before running the
    /// shader's straight-alpha math.
    let premultipliedInputSlots: Set<Int>
    /// Whether the translated fragment should premultiply its straight-alpha
    /// final color before returning, to match a premultiplied render-target
    /// pipeline.
    let premultipliedOutput: Bool

    init(
        shaderName: String,
        processedVertexSource: String,
        processedFragmentSource: String,
        sourceHash: String,
        comboValues: [String: Int],
        textureBindings: [Int: String],
        premultipliedInputSlots: Set<Int> = [],
        premultipliedOutput: Bool = false
    ) {
        self.shaderName = shaderName
        self.processedVertexSource = processedVertexSource
        self.processedFragmentSource = processedFragmentSource
        self.sourceHash = sourceHash
        self.comboValues = comboValues
        self.textureBindings = textureBindings
        self.premultipliedInputSlots = premultipliedInputSlots
        self.premultipliedOutput = premultipliedOutput
    }

    /// Cache key that distinguishes premultiplied-alpha translation variants of
    /// an otherwise identical shader source (same `sourceHash`).
    var translationCacheKey: String {
        var key = sourceHash
        if premultipliedOutput {
            key += "|pma-output"
        }
        if !premultipliedInputSlots.isEmpty {
            key += "|pma-inputs:"
                + premultipliedInputSlots.sorted().map(String.init).joined(separator: ",")
        }
        return key
    }

    func replacingPremultipliedAlphaSettings(
        inputSlots: Set<Int>,
        output: Bool
    ) -> WPEShaderCompileRequest {
        WPEShaderCompileRequest(
            shaderName: shaderName,
            processedVertexSource: processedVertexSource,
            processedFragmentSource: processedFragmentSource,
            sourceHash: sourceHash,
            comboValues: comboValues,
            textureBindings: textureBindings,
            premultipliedInputSlots: inputSlots,
            premultipliedOutput: output
        )
    }
}

struct WPEShaderCompileResult: @unchecked Sendable {
    let library: MTLLibrary
    let vertexFunctionName: String
    let fragmentFunctionName: String
    /// Generated MSL source, kept for disk caching and snapshot tests.
    let mslSource: String
    /// Per-uniform float4 slot assignment matching the layout the transpiler
    /// emitted. The dispatcher walks this to pack the runtime uniform buffer.
    let uniformLayout: [WPEUniformSlot]
    /// Names of the texture samplers the shader expects, ordered by slot.
    let samplerNames: [String]
}

enum WPEShaderCompilerError: Error, Sendable, Equatable {
    case glslPreprocessFailed(String)
    case translationFailed(String)
    case mslLibraryFailed(String)
}

/// Process-wide MSL+reflection cache. Payload is text, never `MTLLibrary`.
/// Memory hits serve a second display / new executor; disk hits serve cold start.
/// All mutable state sits behind `lock`.
final class WPEShaderTranslationCache: @unchecked Sendable {
    static let schemaVersion = 1
    static let shared = WPEShaderTranslationCache()

    struct Payload: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var vertexFunctionName: String
        var fragmentFunctionName: String
        var mslSource: String
        var uniformLayout: [Slot]
        var samplerNames: [String]

        struct Slot: Codable, Equatable, Sendable {
            var name: String
            var glslType: String
            var slot: Int
            var slotCount: Int
            var arrayLength: Int?
            var materialName: String?
            var defaultValue: Constant?

            enum Constant: Codable, Equatable, Sendable {
                case bool(Bool)
                case number(Double)
                case string(String)
                case vector([Double])
            }
        }

        func uniformSlots() -> [WPEUniformSlot] {
            uniformLayout.map { slot in
                WPEUniformSlot(
                    name: slot.name,
                    glslType: slot.glslType,
                    slot: slot.slot,
                    slotCount: slot.slotCount,
                    arrayLength: slot.arrayLength,
                    materialName: slot.materialName,
                    defaultValue: slot.defaultValue.map(\.domainValue)
                )
            }
        }

        /// `nil` when the result cannot round-trip: `Slot.Constant` has no
        /// `.animated` case, so an animated uniform default would come back as
        /// no default at all and the fallback in `resolvedUniformValue` would
        /// silently change between the compile that produced it and every later
        /// hit — including the second display in the same process. Refusing to
        /// cache keeps the fresh translation authoritative.
        static func from(_ result: WPEShaderCompileResult) -> Payload? {
            var slots: [Slot] = []
            slots.reserveCapacity(result.uniformLayout.count)
            for slot in result.uniformLayout {
                if case .animated = slot.defaultValue { return nil }
                slots.append(Slot(
                    name: slot.name,
                    glslType: slot.glslType,
                    slot: slot.slot,
                    slotCount: slot.slotCount,
                    arrayLength: slot.arrayLength,
                    materialName: slot.materialName,
                    defaultValue: Slot.Constant(slot.defaultValue)
                ))
            }
            return Payload(
                schemaVersion: WPEShaderTranslationCache.schemaVersion,
                vertexFunctionName: result.vertexFunctionName,
                fragmentFunctionName: result.fragmentFunctionName,
                mslSource: result.mslSource,
                uniformLayout: slots,
                samplerNames: result.samplerNames
            )
        }
    }

    /// Disk budget. An MSL payload is a few KB to a few tens of KB, so this
    /// holds several scenes' worth while bounding a user who browses a lot of
    /// Workshop content. Caches/ is purgeable, but that is the OS's backstop,
    /// not a reason to grow without limit.
    static let maximumDiskBytes = 64 * 1024 * 1024
    /// Stores between sweeps. The sweep enumerates the directory, so it must not
    /// run on every store during a scene load's compile burst.
    private static let pruneInterval = 64

    private let lock = NSLock()
    private var memory: [String: Payload] = [:]
    private var storesSincePrune = 0
    private let rootURL: URL
    private let fileManager: FileManager

    #if DEBUG
    private(set) var memoryHitCountForTesting = 0
    private(set) var diskHitCountForTesting = 0
    private(set) var storeCountForTesting = 0
    #endif

    init(rootURL: URL? = nil) {
        self.fileManager = .default
        self.rootURL = (rootURL ?? Self.defaultRootURL)
            .appendingPathComponent("v\(Self.schemaVersion)", isDirectory: true)
    }

    nonisolated static var defaultRootURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wpe-msl", isDirectory: true)
    }

    func lookup(_ translationCacheKey: String) -> Payload? {
        lock.lock()
        if let payload = memory[translationCacheKey] {
            #if DEBUG
            memoryHitCountForTesting += 1
            #endif
            lock.unlock()
            return payload
        }
        lock.unlock()
        guard let payload = readDisk(translationCacheKey),
              payload.schemaVersion == Self.schemaVersion else {
            return nil
        }
        lock.lock()
        memory[translationCacheKey] = payload
        #if DEBUG
        diskHitCountForTesting += 1
        #endif
        lock.unlock()
        return payload
    }

    func store(_ payload: Payload, for translationCacheKey: String) {
        lock.lock()
        memory[translationCacheKey] = payload
        storesSincePrune += 1
        let shouldPrune = storesSincePrune >= Self.pruneInterval
        if shouldPrune { storesSincePrune = 0 }
        #if DEBUG
        storeCountForTesting += 1
        #endif
        lock.unlock()
        writeDisk(payload, for: translationCacheKey)
        if shouldPrune { pruneDisk() }
    }

    func remove(_ translationCacheKey: String) {
        lock.lock()
        memory.removeValue(forKey: translationCacheKey)
        lock.unlock()
        let url = fileURL(for: translationCacheKey)
        try? fileManager.removeItem(at: url)
    }

    #if DEBUG
    func dropMemoryForTesting() {
        lock.lock()
        memory.removeAll(keepingCapacity: false)
        lock.unlock()
    }
    #endif

    private func fileURL(for translationCacheKey: String) -> URL {
        let digest = SHA256.hash(data: Data(translationCacheKey.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return rootURL.appendingPathComponent("\(hex).json", isDirectory: false)
    }

    private func readDisk(_ translationCacheKey: String) -> Payload? {
        let url = fileURL(for: translationCacheKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return payload
    }

    /// Drops oldest-written entries until the directory fits the budget. By
    /// write time, not access time: a hit only reads, so this is insertion order
    /// rather than true LRU — enough to bound the directory, and a dropped entry
    /// costs one re-translation.
    private func pruneDisk() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let items = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        for url in items {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize else { continue }
            entries.append((url, values.contentModificationDate ?? .distantPast, size))
            total += size
        }
        guard total > Self.maximumDiskBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
            if total <= Self.maximumDiskBytes { break }
        }
    }

    private func writeDisk(_ payload: Payload, for translationCacheKey: String) {
        let url = fileURL(for: translationCacheKey)
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache is a speedup; a failed write must not fail the compile.
        }
    }
}

private extension WPEShaderTranslationCache.Payload.Slot.Constant {
    init?(_ value: WPESceneShaderConstantValue?) {
        switch value {
        case .bool(let flag): self = .bool(flag)
        case .number(let number): self = .number(number)
        case .string(let string): self = .string(string)
        case .vector(let vector): self = .vector(vector)
        case .animated, .none: return nil
        }
    }

    var domainValue: WPESceneShaderConstantValue {
        switch self {
        case .bool(let flag): return .bool(flag)
        case .number(let number): return .number(number)
        case .string(let string): return .string(string)
        case .vector(let vector): return .vector(vector)
        }
    }
}
#endif
