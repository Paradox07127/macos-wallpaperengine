public struct WPEMSVCUnorderedMap<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public private(set) var bucketCount = 8
    public private(set) var keys: [Key] = []
    private var values: [[UInt8]: Value] = [:]
    private let keyBytes: @Sendable (Key) -> [UInt8]
    private let copyReversalEnabled: Bool

    fileprivate init(keyBytes: @escaping @Sendable (Key) -> [UInt8], copyReversalEnabled: Bool) {
        self.keyBytes = keyBytes
        self.copyReversalEnabled = copyReversalEnabled
    }

    public subscript(key: Key) -> Value? {
        values[keyBytes(key)]
    }

    public var entries: [(key: Key, value: Value)] {
        keys.compactMap { key in values[keyBytes(key)].map { (key, $0) } }
    }

    public mutating func set(_ key: Key, value: Value) {
        let bytes = keyBytes(key)
        if values[bytes] == nil {
            if keys.count + 1 > bucketCount {
                rehash(Self.desiredBuckets(current: bucketCount, count: keys.count + 1))
            }
            place(key)
        }
        values[bytes] = value
    }

    public mutating func setIfMissing(_ key: Key, value: Value) {
        if values[keyBytes(key)] == nil {
            set(key, value: value)
        }
    }

    /// FUN_1401a6c60 / FUN_140164850: copy into a fresh eight-bucket map, then force rehash.
    public func copyAssigned() -> Self {
        var result = self
        if copyReversalEnabled {
            result.rehash(Self.desiredBuckets(current: 8, count: keys.count))
        }
        return result
    }

    private mutating func rehash(_ count: Int) {
        bucketCount = count
        let old = keys
        keys = []
        for key in old {
            place(key)
        }
    }

    private mutating func place(_ key: Key) {
        let bucket = Self.fnv1a(keyBytes(key)) & UInt64(bucketCount - 1)
        if let first = keys.firstIndex(where: { Self.fnv1a(keyBytes($0)) & UInt64(bucketCount - 1) == bucket }) {
            keys.insert(key, at: first)
        } else {
            keys.append(key)
        }
    }

    private static func desiredBuckets(current: Int, count: Int) -> Int {
        var required = max(8, count)
        if required <= current {
            return current
        }
        if current < 512, required <= current * 8 {
            required = current * 8
        }
        var result = 8
        while result < required {
            result *= 2
        }
        return result
    }

    fileprivate static func fnv1a(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var result: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            result = (result ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return result
    }
}

public extension WPEMSVCUnorderedMap where Key == String {
    init() {
        self.init(copyReversalEnabled: true)
    }

    internal init(copyReversalEnabled: Bool) {
        self.init(keyBytes: { Array($0.utf8) }, copyReversalEnabled: copyReversalEnabled)
    }
}

public extension WPEMSVCUnorderedMap where Key == Int32 {
    init() {
        self.init(copyReversalEnabled: true)
    }

    internal init(copyReversalEnabled: Bool) {
        self.init(keyBytes: { key in
            let bits = UInt32(bitPattern: key)
            return (0 ..< 4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        }, copyReversalEnabled: copyReversalEnabled)
    }
}
