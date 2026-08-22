#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

/// Indexed fragment-texture slots for one transpiled-shader dispatch.
final class WPEMetalTextureSlotTable {
    private var textures: ContiguousArray<MTLTexture?>

    init(slotCount: Int = WPEShaderTranspiler.customTextureSlotCount) {
        textures = ContiguousArray(repeating: nil, count: max(0, slotCount))
    }

    var slotCount: Int { textures.count }

    subscript(slot: Int) -> MTLTexture? {
        get { textures.indices.contains(slot) ? textures[slot] : nil }
        set {
            guard textures.indices.contains(slot) else { return }
            textures[slot] = newValue
        }
    }

    func reset() {
        for index in textures.indices {
            textures[index] = nil
        }
    }
}

enum WPEMetalSceneCaptureUtilityModels {
    /// `fullscreenlayer.json` / `projectlayer.json` always render full-frame;
    /// a spatial `composelayer.json` may be `.subregion` (see `outputGeometry`).
    static func isSceneCaptureUtilityModelPath(_ path: String) -> Bool {
        WPEUtilityModelKind.isUtilityModelPath(path)
    }

    enum OutputGeometry { case fullscreen, subregion }

    /// Fullscreen/project always cover the frame. A composelayer stays fullscreen
    /// unless its authored footprint is a safe sub-rect: oversized coverage keeps
    /// 3479521040's 5000×2300 rotated passthrough fullscreen (98f79b5); small
    /// z-rotated compose (2986828130) stays `.subregion`.
    static func outputGeometry(
        path: String,
        geometry: WPERenderLayerGeometry,
        sceneSize: CGSize
    ) -> OutputGeometry {
        outputGeometry(
            kind: WPEUtilityModelKind.classify(path),
            geometry: geometry,
            sceneSize: sceneSize
        )
    }

    /// Same rule, using the classification already on the layer.
    static func outputGeometry(
        kind: WPEUtilityModelKind?,
        geometry: WPERenderLayerGeometry,
        sceneSize: CGSize
    ) -> OutputGeometry {
        guard kind == .composeLayer else { return .fullscreen }
        guard let size = geometry.size else { return .fullscreen }
        let sceneW = max(Float(sceneSize.width), 1)
        let sceneH = max(Float(sceneSize.height), 1)
        let width = Float(size.width) * max(abs(Float(geometry.scale.x)), 0.0001)
        let height = Float(size.height) * max(abs(Float(geometry.scale.y)), 0.0001)
        guard width.isFinite, height.isFinite, width > 1, height > 1 else { return .fullscreen }
        let rotationEpsilon: Float = 0.001
        let zAxisTurn = normalizedAbsoluteZTurn(Float(geometry.angles.z))
        let isHalfTurn = abs(zAxisTurn - .pi) <= rotationEpsilon
        if abs(Float(geometry.angles.x)) > rotationEpsilon
            || abs(Float(geometry.angles.y)) > rotationEpsilon {
            return .fullscreen
        }
        let flipsX = geometry.scale.x < 0
        let flipsY = geometry.scale.y < 0
        if flipsX != flipsY && !isHalfTurn { return .fullscreen }
        let fullCoverage: Float = 0.95
        if width >= sceneW * fullCoverage && height >= sceneH * fullCoverage { return .fullscreen }
        return .subregion
    }

    private static func normalizedAbsoluteZTurn(_ radians: Float) -> Float {
        guard radians.isFinite else { return .infinity }
        return abs(radians.remainder(dividingBy: 2 * .pi))
    }
}

/// Memo of `outputGeometry` per layer. Key omits fields the function never reads.
final class WPESceneCaptureOutputGeometryMemo {
    private struct Entry {
        let path: String
        let size: CGSize?
        let scale: SIMD3<Double>
        let angles: SIMD3<Double>
        let sceneSize: CGSize
        let result: WPEMetalSceneCaptureUtilityModels.OutputGeometry
    }

    private var entries: [String: Entry] = [:]

    func outputGeometry(
        layer: WPERenderLayer,
        geometry: WPERenderLayerGeometry,
        sceneSize: CGSize
    ) -> WPEMetalSceneCaptureUtilityModels.OutputGeometry {
        let path = layer.imagePath
        let objectID = layer.objectID
        if let entry = entries[objectID],
           entry.sceneSize == sceneSize,
           entry.size == geometry.size,
           entry.scale == geometry.scale,
           entry.angles == geometry.angles,
           entry.path == path {
            return entry.result
        }
        let result = WPEMetalSceneCaptureUtilityModels.outputGeometry(
            kind: layer.utilityModelKind,
            geometry: geometry,
            sceneSize: sceneSize
        )
        if entries.count >= 512, entries[objectID] == nil {
            entries.removeAll(keepingCapacity: true)
        }
        entries[objectID] = Entry(
            path: path,
            size: geometry.size,
            scale: geometry.scale,
            angles: geometry.angles,
            sceneSize: sceneSize,
            result: result
        )
        return result
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }
}

/// Thread-safe sink for GPU command-buffer errors. They surface in the
/// completed handler on a GPU thread *after* the frame call returned, so they
/// can't throw — recorded here and surfaced in the scene diagnostic log. Bounded
/// to count + last message so a persistently-failing GPU never grows memory.
final class WPEGPUErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var errorCount = 0
    private var lastMessage: String?

    /// First five, then every 300th — same cadence as present drawable-miss logs.
    static func shouldLogOccurrence(_ count: Int) -> Bool {
        count <= 5 || count % 300 == 0
    }

    @discardableResult
    func record(_ message: String) -> Int {
        lock.lock()
        errorCount += 1
        lastMessage = message
        let n = errorCount
        lock.unlock()
        return n
    }

    var summary: (count: Int, last: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (errorCount, lastMessage)
    }
}

/// Custom-shader compile failures, deduped by shader name, surfaced in the scene
/// diagnostic log — the `WPESceneDebugArtifacts` dump is hard-off in Release, so
/// otherwise a skipped (non-compiling) pass is invisible in a bug report.
final class WPEShaderErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: String] = [:]

    func record(shader: String, reason: String) {
        lock.lock()
        failures[shader] = reason
        lock.unlock()
    }

    var summary: (count: Int, entries: [(shader: String, reason: String)]) {
        lock.lock()
        defer { lock.unlock() }
        let entries = failures.sorted { $0.key < $1.key }.map { (shader: $0.key, reason: $0.value) }
        return (entries.count, entries)
    }
}
#endif
