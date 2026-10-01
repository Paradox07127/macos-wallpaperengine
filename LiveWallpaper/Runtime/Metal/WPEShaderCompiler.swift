#if !LITE_BUILD
import CryptoKit
import Darwin
import Foundation
import LiveWallpaperProWPE
import Metal

enum WPEVertexExecution: String, Codable, Hashable, Sendable {
    case synthesized, authoredFullscreen, authoredObjectQuad
}

struct WPEShaderCompiledVertex: @unchecked Sendable {
    let library: MTLLibrary
    let execution: WPEVertexExecution
    let mslSource: String
    let uniformLayout: [WPEUniformSlot]
    let samplerNames: [String]
    let textureSlotCount: Int
    /// Resolutions and TEXS metadata need resolved inputs even when no sampler is declared.
    let requiredTextureSlotCount: Int

    init(library: MTLLibrary, mslSource: String, uniformLayout: [WPEUniformSlot], samplerNames: [String], textureSlotCount: Int, execution: WPEVertexExecution = .authoredFullscreen) {
        self.execution = execution
        self.library = library; self.mslSource = mslSource; self.uniformLayout = uniformLayout
        self.samplerNames = samplerNames; self.textureSlotCount = textureSlotCount
        requiredTextureSlotCount = max(textureSlotCount, uniformLayout.compactMap {
            WPEMetalRenderExecutor.textureResolutionSlotIndex(for: $0.name)
                ?? WPEMetalRenderExecutor.textureRotationSlotIndex(for: $0.name)
                ?? WPEMetalRenderExecutor.textureTranslationSlotIndex(for: $0.name)
        }.filter { (0 ..< WPEShaderTranspiler.customTextureSlotLimit).contains($0) }.max().map { $0 + 1 } ?? 0)
    }
}

struct WPEShaderCompileRequest: Sendable, Hashable {
    let shaderName: String
    let processedVertexSource: String
    let processedFragmentSource: String
    /// Hash of (raw vertex source, raw fragment source, combo values).
    let sourceHash: String
    /// `[COMBO]` names → values after merge.
    let comboValues: [String: Int]
    /// Texture slot index → logical name.
    let textureBindings: [Int: String]
    /// Slots bound to PMA render targets; the transpiler un-premultiplies before straight-alpha math.
    let premultipliedInputSlots: Set<Int>
    /// Premultiply straight-alpha final color for a PMA render-target pipeline.
    let premultipliedOutput: Bool
    let vertexExecution: WPEVertexExecution

    init(
        shaderName: String,
        processedVertexSource: String,
        processedFragmentSource: String,
        sourceHash: String,
        comboValues: [String: Int],
        textureBindings: [Int: String],
        premultipliedInputSlots: Set<Int> = [],
        premultipliedOutput: Bool = false,
        vertexExecution: WPEVertexExecution = .synthesized
    ) {
        self.shaderName = shaderName
        self.processedVertexSource = processedVertexSource
        self.processedFragmentSource = processedFragmentSource
        self.sourceHash = sourceHash
        self.comboValues = comboValues
        self.textureBindings = textureBindings
        self.premultipliedInputSlots = premultipliedInputSlots
        self.premultipliedOutput = premultipliedOutput
        self.vertexExecution = vertexExecution
    }

    var translationCacheKey: String {
        var key = sourceHash
        if vertexExecution != .synthesized {
            key += "|vertex-execution:" + vertexExecution.rawValue
        }
        if !WPEShaderTranspiler.waterOptimizationsEnabled {
            key += "|water-reference"
        }
        if premultipliedOutput {
            key += "|pma-output"
        }
        if !premultipliedInputSlots.isEmpty {
            key += "|pma-inputs:"
                + premultipliedInputSlots.sorted().map(String.init).joined(separator: ",")
        }
        return key
    }

    func replacingVertexExecution(_ execution: WPEVertexExecution) -> Self {
        Self(shaderName: shaderName, processedVertexSource: processedVertexSource,
             processedFragmentSource: processedFragmentSource, sourceHash: sourceHash,
             comboValues: comboValues, textureBindings: textureBindings,
             premultipliedInputSlots: premultipliedInputSlots, premultipliedOutput: premultipliedOutput,
             vertexExecution: execution)
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
            premultipliedOutput: output, vertexExecution: vertexExecution
        )
    }
}

struct WPEShaderCompileResult: @unchecked Sendable {
    let library: MTLLibrary
    let vertexFunctionName: String
    let fragmentFunctionName: String
    let mslSource: String
    /// Per-uniform float4 slot assignment matching the transpiler layout.
    let uniformLayout: [WPEUniformSlot]
    let samplerNames: [String]
    /// Fragment texture/sampler arity; cached because a hit restores MSL without re-running the transpiler.
    let textureSlotCount: Int
    /// Rebuilt from the request on cold and warm compilation; never inferred from generated MSL.
    var shaderInterface: WPEShaderInterface?
    /// Restored from the request, including warm cache hits.
    var alphaContract: WPEShaderAlphaContract?
    var vertexStage: WPEShaderCompiledVertex?
    /// Recomputed from active GLSL on warm and cold assembly. Native fullscreen
    /// clip geometry preserves XY only; non-position MVP use needs a WPE producer.
    var fullscreenMVPPositionOnly: Bool = false
}

enum WPEShaderCompilerError: Error, Sendable, Equatable {
    case glslPreprocessFailed(String)
    case translationFailed(String)
    case mslLibraryFailed(String)
}

/// Process-wide MSL+reflection cache; the payload is text, never `MTLLibrary`.
/// All mutable state sits behind `lock`.
final class WPEShaderTranslationCache: @unchecked Sendable {
    static let schemaVersion = 34

    static let shared = WPEShaderTranslationCache()

    struct Payload: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var vertexFunctionName: String
        var fragmentFunctionName: String
        var mslSource: String
        var uniformLayout: [Slot]
        var samplerNames: [String]
        var textureSlotCount: Int
        var vertexMSLSource: String?
        var vertexUniformLayout: [Slot]?
        var vertexSamplerNames: [String]?
        var vertexTextureSlotCount: Int?

        struct Slot: Codable, Equatable, Sendable {
            var name: String
            var glslType: String
            var slot: Int
            var slotCount: Int
            var arrayLength: Int?
            var materialName: String?
            var defaultValue: Constant?
            /// Optional so a payload without it decodes as empty (unconditional).
            var requiredCombos: [String: Int]?

            enum Constant: Codable, Equatable, Sendable {
                case bool(Bool)
                case number(Double)
                case string(String)
                case vector([Double])
            }
        }

        func vertexTranslation() -> WPEShaderTranslationResult? {
            guard let vertexMSLSource, let vertexUniformLayout, let vertexSamplerNames,
                  let vertexTextureSlotCount else { return nil }
            let slots = Self.uniformSlots(vertexUniformLayout)
            return WPEShaderTranslationResult(mslSource: vertexMSLSource, samplers: vertexSamplerNames,
                                              uniformLayout: slots, totalSlots: slots.map { $0.slot + $0.slotCount }.max() ?? 0,
                                              textureSlotCount: vertexTextureSlotCount)
        }

        func uniformSlots() -> [WPEUniformSlot] {
            Self.uniformSlots(uniformLayout)
        }

        private static func uniformSlots(_ layout: [Slot]) -> [WPEUniformSlot] {
            layout.map { slot in
                WPEUniformSlot(
                    name: slot.name,
                    glslType: slot.glslType,
                    slot: slot.slot,
                    slotCount: slot.slotCount,
                    arrayLength: slot.arrayLength,
                    materialName: slot.materialName,
                    defaultValue: slot.defaultValue.map(\.domainValue),
                    requiredCombos: slot.requiredCombos ?? [:]
                )
            }
        }

        /// `nil` when an animated uniform default cannot round-trip; caching would silently drop it.
        private static func encodedSlots(_ layout: [WPEUniformSlot]) -> [Slot]? {
            var slots: [Slot] = []
            for slot in layout {
                if case .animated = slot.defaultValue {
                    return nil
                }
                slots.append(Slot(name: slot.name, glslType: slot.glslType, slot: slot.slot,
                                  slotCount: slot.slotCount, arrayLength: slot.arrayLength,
                                  materialName: slot.materialName, defaultValue: Slot.Constant(slot.defaultValue),
                                  requiredCombos: slot.requiredCombos))
            }
            return slots
        }

        static func from(_ result: WPEShaderCompileResult) -> Payload? {
            guard let slots = encodedSlots(result.uniformLayout) else { return nil }
            let vertexSlots: [Slot]?
            if let vertex = result.vertexStage {
                guard let encoded = encodedSlots(vertex.uniformLayout) else { return nil }
                vertexSlots = encoded
            } else {
                vertexSlots = nil
            }
            return Payload(schemaVersion: WPEShaderTranslationCache.schemaVersion,
                           vertexFunctionName: result.vertexFunctionName,
                           fragmentFunctionName: result.fragmentFunctionName,
                           mslSource: result.mslSource, uniformLayout: slots,
                           samplerNames: result.samplerNames, textureSlotCount: result.textureSlotCount,
                           vertexMSLSource: result.vertexStage?.mslSource,
                           vertexUniformLayout: vertexSlots,
                           vertexSamplerNames: result.vertexStage?.samplerNames,
                           vertexTextureSlotCount: result.vertexStage?.textureSlotCount)
        }
    }

    static let maximumDiskBytes = 64 * 1024 * 1024
    /// One quarter of the disk budget in encoded payload bytes; the count cap
    /// bounds collection overhead. This is a cache policy, not an RSS limit.
    static let maximumMemoryBytes = maximumDiskBytes / 4
    static let maximumMemoryEntries = 256
    /// Stores between sweeps. The sweep enumerates the directory, so it must not
    /// run on every store during a scene load's compile burst.
    private static let pruneInterval = 64

    private let lock = NSLock()
    private struct MemoryEntry {
        let payload: Payload
        let bytes: Int
    }

    private var memory: [String: MemoryEntry] = [:]
    private var memoryLRU: [String] = []
    private var memoryBytes = 0
    private let memoryByteLimit: Int
    private let memoryEntryLimit: Int
    private let diskByteLimit: Int
    private var storesSincePrune = 0
    private let rootURL: URL
    private let fileManager: FileManager

    #if DEBUG
    private(set) var memoryHitCountForTesting = 0
    private(set) var diskHitCountForTesting = 0
    private(set) var storeCountForTesting = 0
    #endif

    init(rootURL: URL? = nil, memoryByteLimit: Int = maximumMemoryBytes,
         memoryEntryLimit: Int = maximumMemoryEntries, diskByteLimit: Int = maximumDiskBytes) {
        self.memoryByteLimit = max(0, memoryByteLimit)
        self.memoryEntryLimit = max(0, memoryEntryLimit)
        self.diskByteLimit = min(max(0, diskByteLimit), Self.maximumDiskBytes)
        self.fileManager = .default
        let base = rootURL ?? Self.defaultRootURL
        self.rootURL = base.appendingPathComponent("v\(Self.schemaVersion)", isDirectory: true)
        Self.removeStaleSchemaDirectories(in: base, fileManager: fileManager)
    }

    /// Previous `v{N}` directories would otherwise keep a full budget of unreadable payloads.
    private static func removeStaleSchemaDirectories(in base: URL, fileManager: FileManager) {
        let current = "v\(schemaVersion)"
        guard let items = try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in items {
            let name = url.lastPathComponent
            guard name != current, name.hasPrefix("v"),
                  let version = Int(name.dropFirst()), version >= 0,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    nonisolated static var defaultRootURL: URL {
        // The hosted test process must not read or prune the user's schema cache.
        if NSClassFromString("XCTestCase") != nil {
            return ConfigurationDirectory().root.appendingPathComponent("wpe-msl", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wpe-msl", isDirectory: true)
    }

    func lookup(_ translationCacheKey: String) -> Payload? {
        lock.lock()
        if let entry = memory[translationCacheKey] {
            touchMemory(translationCacheKey)
            #if DEBUG
            memoryHitCountForTesting += 1
            #endif
            lock.unlock()
            return entry.payload
        }
        lock.unlock()
        guard let disk = readDisk(translationCacheKey),
              disk.payload.schemaVersion == Self.schemaVersion else {
            return nil
        }
        lock.lock()
        insertMemory(disk.payload, bytes: disk.bytes, for: translationCacheKey)
        #if DEBUG
        diskHitCountForTesting += 1
        #endif
        lock.unlock()
        return disk.payload
    }

    func store(_ payload: Payload, for translationCacheKey: String) {
        let data = try? JSONEncoder().encode(payload)
        lock.lock()
        insertMemory(payload, bytes: data?.count ?? Int.max, for: translationCacheKey)
        storesSincePrune += 1
        let shouldPrune = storesSincePrune >= Self.pruneInterval
        if shouldPrune { storesSincePrune = 0 }
        #if DEBUG
        storeCountForTesting += 1
        #endif
        lock.unlock()
        if let data, data.count <= diskByteLimit {
            writeDisk(data, for: translationCacheKey)
        }
        if shouldPrune { pruneDisk() }
    }

    func remove(_ translationCacheKey: String) {
        lock.lock()
        removeMemory(translationCacheKey)
        lock.unlock()
        let url = fileURL(for: translationCacheKey)
        try? fileManager.removeItem(at: url)
    }

    #if DEBUG
    func dropMemoryForTesting() {
        lock.lock()
        memory.removeAll(keepingCapacity: false)
        memoryLRU.removeAll(keepingCapacity: false)
        memoryBytes = 0
        lock.unlock()
    }
    #endif

    /// Called only while holding `lock`; hits promote an entry without disk I/O.
    private func touchMemory(_ key: String) {
        if let index = memoryLRU.firstIndex(of: key) {
            memoryLRU.remove(at: index)
        }
        memoryLRU.append(key)
    }

    private func removeMemory(_ key: String) {
        if let old = memory.removeValue(forKey: key) {
            memoryBytes -= old.bytes
        }
        if let index = memoryLRU.firstIndex(of: key) {
            memoryLRU.remove(at: index)
        }
    }

    private func insertMemory(_ payload: Payload, bytes: Int, for key: String) {
        removeMemory(key)
        // Oversized entries remain on disk and must not evict useful small entries.
        guard memoryEntryLimit > 0, bytes <= memoryByteLimit else {
            return
        }
        while let oldest = memoryLRU.first,
              memory.count >= memoryEntryLimit || bytes > memoryByteLimit - memoryBytes {
            removeMemory(oldest)
        }
        memory[key] = MemoryEntry(payload: payload, bytes: bytes)
        memoryBytes += bytes
        touchMemory(key)
    }

    #if DEBUG
    func memoryUsageForTesting() -> (entries: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (memory.count, memoryBytes)
    }
    #endif

    private func fileURL(for translationCacheKey: String) -> URL {
        let digest = SHA256.hash(data: Data(translationCacheKey.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return rootURL.appendingPathComponent("\(hex).json", isDirectory: false)
    }

    private func readDisk(_ translationCacheKey: String) -> (payload: Payload, bytes: Int)? {
        let url = fileURL(for: translationCacheKey)
        guard let data = readRegularCacheData(at: url) else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              Self.validCachedLayout(payload.uniformLayout),
              payload.vertexUniformLayout.map(Self.validCachedLayout) ?? true,
              (0 ... WPEShaderTranspiler.customTextureSlotLimit).contains(payload.textureSlotCount),
              payload.vertexTextureSlotCount.map({ (0 ... WPEShaderTranspiler.customTextureSlotLimit).contains($0) }) ?? true else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return (payload, data.count)
    }

    /// The leaf must be a bounded regular file. The descriptor keeps checks and
    /// reads on the same inode; parent-directory replacement is outside this contract.
    private func readRegularCacheData(at url: URL) -> Data? {
        guard diskByteLimit > 0 else { return nil }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= Int64(diskByteLimit) else { return nil }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, diskByteLimit + 1))
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, diskByteLimit - data.count + 1))
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            if count == 0 {
                return data
            }
            // A file growing after fstat must not bypass the admission size.
            guard count <= diskByteLimit - data.count else {
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func validCachedLayout(_ slots: [Payload.Slot]) -> Bool {
        guard slots.count <= WPEShaderTranspiler.uniformSlotMaximum else { return false }
        return slots.allSatisfy { slot in
            guard let type = WPEUniformType(glslType: slot.glslType) else { return false }
            let count = slot.arrayLength ?? 1
            let maximum = WPEShaderTranspiler.uniformSlotMaximum
            guard count > 0, count <= maximum / type.elementSlotCount,
                  slot.slotCount == count * type.elementSlotCount,
                  slot.slot >= 0, slot.slotCount <= maximum,
                  slot.slot <= maximum - slot.slotCount else { return false }
            return true
        }
    }

    /// Evicts oldest-written, not LRU: a hit only reads, so this is insertion order.
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

    private func writeDisk(_ data: Data, for translationCacheKey: String) {
        let url = fileURL(for: translationCacheKey)
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
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
