public struct WPEStageBindingPlan: Sendable {
    private struct Binding: Hashable, Sendable {
        let kind: WPEStageReflection.ArgumentEntry.Kind
        let register: Int
        let space: Int
    }

    public let stage: WPEStageReflection.Stage
    public let entries: [WPEStageReflection.ArgumentEntry]
    public let totalSize: Int
    private let offsets: [Binding: Int]
    private let textureOffsets: [String: [Int?]]
    private let samplerOffsets: [String: [Int?]]

    public init(_ reflection: WPEStageReflection) throws {
        guard reflection.schema == 1 else {
            throw WPEParityBindingError.invalidBinding("reflection schema")
        }
        var offsets: [Binding: Int] = [:]
        var ranges: [Range<Int>] = []
        var totalSize = 0
        for entry in reflection.topLevelArgumentBuffer {
            guard entry.register >= 0, entry.space >= 0, entry.offset >= 0,
                  entry.offset % 8 == 0, entry.size > 0, entry.size % 24 == 0,
                  entry.offset <= Int.max - entry.size,
                  entry.register <= Int.max - (entry.size / 24 - 1) else {
                throw WPEParityBindingError.invalidBinding("argument entry")
            }
            let range = entry.offset ..< (entry.offset + entry.size)
            guard !ranges.contains(where: { $0.overlaps(range) }) else {
                throw WPEParityBindingError.invalidBinding("overlapping argument entries")
            }
            for index in 0 ..< (entry.size / 24) {
                let binding = Binding(kind: entry.kind, register: entry.register + index, space: entry.space)
                guard offsets[binding] == nil else {
                    throw WPEParityBindingError.invalidBinding("duplicate register")
                }
                offsets[binding] = entry.offset + index * 24
            }
            ranges.append(range)
            totalSize = max(totalSize, range.upperBound)
        }
        var textureOffsets: [String: [Int?]] = [:]
        var samplerOffsets: [String: [Int?]] = [:]
        for resource in reflection.resources {
            guard resource.register >= 0, resource.space >= 0, resource.count > 0,
                  resource.register <= Int.max - (resource.count - 1) else {
                throw WPEParityBindingError.invalidBinding(resource.name)
            }
            let kind: WPEStageReflection.ArgumentEntry.Kind = resource.kind == .texture ? .srv : .sampler
            let locations = (0 ..< resource.count).map {
                offsets[Binding(kind: kind, register: resource.register + $0, space: resource.space)]
            }
            if resource.kind == .texture {
                guard textureOffsets[resource.name] == nil else {
                    throw WPEParityBindingError.invalidBinding(resource.name)
                }
                textureOffsets[resource.name] = locations
            } else {
                guard samplerOffsets[resource.name] == nil else {
                    throw WPEParityBindingError.invalidBinding(resource.name)
                }
                samplerOffsets[resource.name] = locations
            }
        }
        stage = reflection.stage
        entries = reflection.topLevelArgumentBuffer
        self.totalSize = totalSize
        self.offsets = offsets
        self.textureOffsets = textureOffsets
        self.samplerOffsets = samplerOffsets
    }

    public func offset(kind: WPEStageReflection.ArgumentEntry.Kind, register: Int, space: Int = 0) -> Int? {
        offsets[Binding(kind: kind, register: register, space: space)]
    }

    public func cbufferOffset(register: Int, space: Int = 0) -> Int? {
        offset(kind: .cbv, register: register, space: space)
    }

    public func textureOffset(named name: String, element: Int = 0) -> Int? {
        guard let locations = textureOffsets[name], locations.indices.contains(element) else { return nil }
        return locations[element]
    }

    public func samplerOffset(named name: String, element: Int = 0) -> Int? {
        guard let locations = samplerOffsets[name], locations.indices.contains(element) else { return nil }
        return locations[element]
    }

    /// Fields match IRDescriptorTableEntry; metadata is already encoded by the caller.
    public func writeEntry(at offset: Int, gpuAddress: UInt64, resourceID: UInt64,
                           metadata: UInt64, into bytes: inout [UInt8]) throws {
        guard offsets.values.contains(offset) else {
            throw WPEParityBindingError.invalidBinding("unknown entry offset")
        }
        guard bytes.count >= totalSize else {
            throw WPEParityBindingError.bufferTooSmall(required: totalSize, actual: bytes.count)
        }
        for (field, value) in [gpuAddress, resourceID, metadata].enumerated() {
            for byte in 0 ..< 8 {
                bytes[offset + field * 8 + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8))
            }
        }
    }
}
