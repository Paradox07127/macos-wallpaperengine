#if !LITE_BUILD
import Foundation
import Metal

struct WPEParticleRenderSlice {
    let buffer: MTLBuffer
    let offset: Int
    let length: Int
}

/// The caller holds the executor's submission lease for `frameSlot` before writing.
final class WPEParticleFrameArena {
    private let device: MTLDevice
    private var buffers: [MTLBuffer?]
    private(set) var allocationCount = 0

    init(device: MTLDevice) {
        self.device = device
        buffers = .init(repeating: nil, count: WPEMetalRenderExecutor.maxFramesInFlight)
    }

    var allocatedBytes: Int {
        buffers.reduce(0) { $0 + ($1?.length ?? 0) }
    }

    func prepare(_ systems: [WPEParticleSystem], frameSlot: Int) -> Bool {
        precondition(buffers.indices.contains(frameSlot))
        for system in systems {
            system.discardRenderData()
        }
        let required = systems.reduce(0) { $0 + Self.aligned($1.requiredRenderByteCount) }
        guard required > 0 else { return true }
        if (buffers[frameSlot]?.length ?? 0) < required {
            guard let buffer = device.makeBuffer(length: Self.aligned(required, to: 4096), options: .storageModeShared) else {
                return false
            }
            buffer.label = "WPE particle frame arena \(frameSlot)"
            buffers[frameSlot] = buffer
            allocationCount += 1
        }
        guard let buffer = buffers[frameSlot] else { return false }
        var offset = 0
        for system in systems {
            let length = system.requiredRenderByteCount
            if length > 0 {
                system.prepareRenderData(frameSlot: frameSlot, slice: .init(buffer: buffer, offset: offset, length: length))
            }
            offset += Self.aligned(length)
        }
        return true
    }

    private static func aligned(_ bytes: Int, to alignment: Int = 64) -> Int {
        (bytes + alignment - 1) & ~(alignment - 1)
    }
}

extension WPEMetalSceneRenderer {
    static let particleFrameArenaEnabled = ProcessInfo.processInfo.environment["WPE_PARTICLE_FRAME_ARENA"] != "0"

    func prepareParticleFrameOutput(frameSlot: Int) throws {
        for system in particleSystems where system.usesFrameArena {
            system.discardRenderData()
        }
        if particleFrameArena == nil {
            particleFrameArena = WPEParticleFrameArena(device: executor.textureSourceDevice)
        }
        let systems = particleSystems.enumerated()
            .filter { $0.element.definition.rendersSprite && particleSystemVisible($0.element) }
            .sorted {
                $0.element.sortIndex != $1.element.sortIndex
                    ? $0.element.sortIndex < $1.element.sortIndex : $0.offset < $1.offset
            }
            .map(\.element)
        guard particleFrameArena?.prepare(systems, frameSlot: frameSlot) == true else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
    }
}
#endif
