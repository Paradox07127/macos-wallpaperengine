import Foundation
import os

/// Classifies WPE scene-capture utility models shared by graph construction and render execution.
/// Solid-layer utility materials are classified separately by the graph builder.
public enum WPEUtilityModelKind: String, CaseIterable, Equatable, Sendable {
    case composeLayer = "composelayer"
    case projectLayer = "projectlayer"
    case fullScreenLayer = "fullscreenlayer"

    /// WPE authors these paths with a leading `../<dependencyID>/` resolver
    /// prefix, `\`-separated Windows paths, and inconsistent case. Tolerates
    /// all three; matches on the trailing `models/util/<name>.json`.
    public static func classify(_ path: String) -> WPEUtilityModelKind? {
        // Ordinary `.png`/`.tex` layers must not pay the memo lock.
        guard hasUtilityModelSuffix(path) else { return nil }
        return cache.withLock { cache in
            if let cached = cache[path] { return cached }
            let result = kindByStrippedPath[computeStrippedPath(path)]
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[path] = result
            return result
        }
    }

    public static func isUtilityModelPath(_ path: String) -> Bool {
        classify(path) != nil
    }

    // MARK: - Classification memo (paths are load-time invariant)

    private static let kindByStrippedPath: [String: WPEUtilityModelKind] = Dictionary(
        uniqueKeysWithValues: allCases.map { ("models/util/\($0.rawValue).json", $0) }
    )

    private static let cache = OSAllocatedUnfairLock(initialState: [String: WPEUtilityModelKind?]())
    private static let cacheLimit = 512

    /// ASCII-case-insensitive `hasSuffix("layer.json")` over the raw UTF-8.
    /// `\` never appears inside the suffix, so no separator normalization is
    /// needed before the compare.
    private static let utilityModelSuffix = Array("layer.json".utf8)

    private static func hasUtilityModelSuffix(_ path: String) -> Bool {
        var utf8 = path.utf8[...]
        guard utf8.count >= utilityModelSuffix.count else { return false }
        utf8 = utf8.dropFirst(utf8.count - utilityModelSuffix.count)
        for (byte, expected) in zip(utf8, utilityModelSuffix) where (byte | 0x20) != expected {
            return false
        }
        return true
    }

    private static func computeStrippedPath(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        guard normalized.hasPrefix("../") else { return normalized }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 3 ? parts.dropFirst(2).joined(separator: "/") : normalized
    }
}
