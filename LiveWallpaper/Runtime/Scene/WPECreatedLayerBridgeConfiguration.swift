#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Immutable load-time admission, copied into the sole layer-script owner.
/// Sorting is admitted only for independent flat image passes. This is not a
/// promise to rebuild arbitrary render dependencies from a SceneScript callback.
struct WPECreatedLayerBridgeConfiguration: Sendable {
    let imagePaths: Set<String>
    let orderedLayerNames: [String]
    let allowsSorting: Bool

    func resolvedImagePath(_ path: String, workshopID: String?) -> String? {
        let matches = Set(Self.assetCandidates(path, workshopID: workshopID)).intersection(imagePaths)
        // Namespace/raw ambiguity requires an oracle decision, not a guessed asset.
        return matches.count == 1 ? matches.first : nil
    }

    static func assetCandidates(_ path: String, workshopID: String?) -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.contains("\\"), !path.contains("\0") else { return [] }
        var result = [path]
        if let workshopID, !workshopID.isEmpty,
           workshopID.allSatisfy({ $0.isASCII && $0.isNumber }),
           parts[1] != "workshop" {
            result.append("\(parts[0])/workshop/\(workshopID)/\(parts.dropFirst().joined(separator: "/"))")
        }
        return result
    }

    init(imagePaths: Set<String>, orderedLayerNames: [String], allowsSorting: Bool) {
        self.imagePaths = imagePaths
        self.orderedLayerNames = orderedLayerNames
        self.allowsSorting = allowsSorting && Set(orderedLayerNames).count == orderedLayerNames.count
            && !orderedLayerNames.contains(where: { $0.isEmpty || $0.hasPrefix("__created_") })
    }

    /// Discovery only: retain authored candidates before scripts run. Runtime
    /// selection uses the evaluated __workshopId, never source-text metadata.
    static func unqualifiedAssetPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count >= 4, parts[1] == "workshop",
              parts[2].allSatisfy({ $0.isASCII && $0.isNumber }) else { return path }
        return "\(parts[0])/\(parts.dropFirst(3).joined(separator: "/"))"
    }
}

struct WPELayerScriptPresentationMutation: Sendable, Equatable {
    var alignment: String?
    var parallaxDepth: SIMD2<Double>?
    var sortIndex: Int?
    var perspective: Bool?

    mutating func merge(_ newer: Self) {
        if let alignment = newer.alignment {
            self.alignment = alignment
        }
        if let parallaxDepth = newer.parallaxDepth {
            self.parallaxDepth = parallaxDepth
        }
        if let sortIndex = newer.sortIndex {
            self.sortIndex = sortIndex
        }
        if let perspective = newer.perspective {
            self.perspective = perspective
        }
    }
}
#endif
