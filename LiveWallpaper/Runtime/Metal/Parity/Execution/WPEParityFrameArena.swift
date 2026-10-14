#if !LITE_BUILD
import Metal
import os

/// Per-frame bump allocator for cbuffers and MSC top-level argument buffers.
final class WPEParityFrameArena {
    struct Allocation {
        let buffer: MTLBuffer
        let offset: Int

        var contents: UnsafeMutableRawPointer {
            buffer.contents() + offset
        }

        var gpuAddress: UInt64 {
            buffer.gpuAddress + UInt64(offset)
        }
    }

    /// The encoder alone mutates a frame before commit. Its completion callback only releases the sampler
    /// references after the GPU reader has finished; it never touches the cursor or encodes more work.
    final class Frame: @unchecked Sendable {
        let buffer: MTLBuffer
        private var cursor = 0
        private var samplers: [ObjectIdentifier: any MTLSamplerState] = [:]

        fileprivate init(buffer: MTLBuffer) {
            self.buffer = buffer
        }

        /// Reserve eligibility for a whole draw before packing any of its stages. Encoding owns this slot
        /// serially, so a draw that does not fit can be dropped without consuming part of the next draw's space.
        func canAllocate(length: Int) -> Bool {
            length >= 0 && WPEParityFrameArena.aligned(cursor) <= buffer.length - length
        }

        /// `nil` when the slot is full; it never grows mid-frame.
        func allocate(length: Int) -> Allocation? {
            let offset = WPEParityFrameArena.aligned(cursor)
            guard canAllocate(length: length) else { return nil }
            cursor = offset + length
            return Allocation(buffer: buffer, offset: offset)
        }

        /// MSC argument tables contain a raw sampler GPU ID, which does not retain its Metal object.
        func retainSampler(_ sampler: any MTLSamplerState) {
            samplers[ObjectIdentifier(sampler)] = sampler
        }

        fileprivate func complete() {
            samplers.removeAll()
        }
    }

    static let slotCount = 3
    static let alignment = 256

    static func aligned(_ length: Int) -> Int {
        (length + alignment - 1) / alignment * alignment
    }

    private let device: MTLDevice
    private var buffers: [MTLBuffer]
    private let busy = OSAllocatedUnfairLock(initialState: [Bool](repeating: false, count: slotCount))
    /// Bytes per slot. A slot takes a larger capacity when it next begins a frame, so a buffer in flight is never
    /// replaced; the replaced buffer is released then, its last frame having completed.
    var capacity: Int

    init?(device: MTLDevice, capacity: Int) {
        var buffers: [MTLBuffer] = []
        for _ in 0 ..< Self.slotCount {
            guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) else { return nil }
            buffers.append(buffer)
        }
        self.device = device
        self.buffers = buffers
        self.capacity = capacity
    }

    /// `nil` while every slot is in flight; the caller skips the frame. The slot frees when
    /// `commandBuffer` completes, so a command buffer that is never committed keeps it forever.
    func beginFrame(for commandBuffer: MTLCommandBuffer) -> Frame? {
        let slot = busy.withLock { state -> Int? in
            guard let free = state.firstIndex(of: false) else { return nil }
            state[free] = true
            return free
        }
        guard let slot else { return nil }
        // A failed allocation keeps the smaller buffer; draws that then do not fit are dropped or fail as before.
        if buffers[slot].length < capacity,
           let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) {
            buffers[slot] = buffer
        }
        let frame = Frame(buffer: buffers[slot])
        commandBuffer.addCompletedHandler { [busy, frame] _ in
            frame.complete()
            busy.withLock { $0[slot] = false }
        }
        return frame
    }
}
#endif
