import Foundation

/// Zero-copy view into a (typically memory-mapped) `Data` owner. Deliberately
/// not a `Data.SubSequence`: bridging slices back to `Data`/`NSData` can copy,
/// and a slice hides which allocation keeps the mapping alive. The span retains
/// `owner` explicitly, so `.tex` payload views stay valid for as long as any
/// mip span exists, and mapped clean pages remain reclaimable by the kernel.
///
/// `range` is buffer-relative (0-based into the owner's logical bytes),
/// matching `Data.withUnsafeBytes` coordinates rather than `Data` indices.
public struct WPEMappedByteSpan: Sendable {
    public let owner: Data
    public let range: Range<Int>

    public init(owner: Data, range: Range<Int>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= owner.count,
                     "span range \(range) exceeds owner count \(owner.count)")
        self.owner = owner
        self.range = range
    }

    public init(data: Data) {
        self.owner = data
        self.range = 0..<data.count
    }

    public var count: Int { range.count }
    public var isEmpty: Bool { range.isEmpty }

    public func withUnsafeBytes<R>(
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) rethrows -> R {
        try owner.withUnsafeBytes { buffer in
            try body(UnsafeRawBufferPointer(rebasing: buffer[range]))
        }
    }

    public func prefix(_ maxLength: Int) -> WPEMappedByteSpan {
        let clamped = Swift.min(Swift.max(maxLength, 0), count)
        return WPEMappedByteSpan(owner: owner, range: range.lowerBound..<(range.lowerBound + clamped))
    }

    public func byte(at offset: Int) -> UInt8 {
        precondition(offset >= 0 && offset < count)
        return owner.withUnsafeBytes { $0[range.lowerBound + offset] }
    }

    /// Explicit heap copy — the only way bytes leave the mapping. Callers that
    /// need a standalone `Data` (ImageIO, disk cache) pay the copy visibly.
    public func materializedData() -> Data {
        guard !isEmpty else { return Data() }
        return withUnsafeBytes { Data($0) }
    }
}

extension WPEMappedByteSpan: Equatable {
    /// Content equality (matches the former `Data` payload semantics).
    public static func == (lhs: WPEMappedByteSpan, rhs: WPEMappedByteSpan) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.isEmpty { return true }
        return lhs.withUnsafeBytes { lhsBuffer in
            rhs.withUnsafeBytes { rhsBuffer in
                memcmp(lhsBuffer.baseAddress!, rhsBuffer.baseAddress!, lhs.count) == 0
            }
        }
    }
}
