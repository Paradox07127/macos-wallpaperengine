/// Immutable function metadata from one effect resource. Native 1401ee3a0 uses the number of matched names,
/// then clears that many entries from the compact, condition-accepted FBO declaration list.
public struct WPEParityMaterialFunctions: Sendable {
    public struct Function: Sendable {
        public let name: String
        public let clearCount: Int
    }

    public struct Target: Sendable {
        public let name: String
        /// Stored producer channels, independent of the initial-clear enable bit.
        public let clearColor: WPEClearColor
    }

    public let functions: [Function]
    public let targets: [Target]

    /// Match the original length + memcmp contract, rather than Swift's Unicode canonical equivalence.
    public func clearTargets(named name: String) throws -> ArraySlice<Target> {
        guard let function = functions.first(where: { $0.name.utf8.elementsEqual(name.utf8) }) else { return [] }
        guard function.clearCount <= targets.count else {
            throw WPEParityMaterialFunctionError.unsafeClearCount(function: name, count: function.clearCount,
                                                                  available: targets.count)
        }
        return targets.prefix(function.clearCount)
    }

    /// Only safe functions contribute storage readiness. Unsafe calls are rejected before any prefix executes.
    var preparedTargetNames: [String] {
        let count = functions.filter { $0.clearCount <= targets.count }.map(\.clearCount).max() ?? 0
        return targets.prefix(count).map(\.name)
    }
}

public enum WPEParityMaterialFunctionError: Error, Sendable {
    case unsafeClearCount(function: String, count: Int, available: Int)
}
