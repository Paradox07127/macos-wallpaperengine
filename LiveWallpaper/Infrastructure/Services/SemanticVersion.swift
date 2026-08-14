import Foundation

/// Semantic version used for Loomscreen release tags, with SemVer 2.0.0 pre-release precedence
/// so a `0.6.0-beta.1` build still sees the final `0.6.0` as an update.
struct SemanticVersion: Comparable, Equatable, Hashable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-separated pre-release identifiers; empty for a final release.
    let prerelease: [String]

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    init?(parsing raw: String) {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["loomscreen-v", "v"] where input.hasPrefix(prefix) {
            input = String(input.dropFirst(prefix.count))
            break
        }

        if let build = input.firstIndex(of: "+") {
            input = String(input[..<build])
        }

        var prerelease: [String] = []
        if let separator = input.firstIndex(of: "-") {
            let identifiers = input[input.index(after: separator)...]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
            prerelease = identifiers
            input = String(input[..<separator])
        }

        let parts = input.split(separator: ".", maxSplits: 2)
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1])
        else { return nil }

        let patch: Int
        if parts.count == 3 {
            guard let value = Int(parts[2]) else { return nil }
            patch = value
        } else {
            patch = 0
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return prereleasePrecedes(lhs.prerelease, rhs.prerelease)
    }

    /// SemVer 2.0.0 §11: a final release outranks any pre-release, numeric identifiers rank below
    /// alphanumeric ones, and a shorter identifier list outranks a longer one that shares its prefix.
    private static func prereleasePrecedes(_ lhs: [String], _ rhs: [String]) -> Bool {
        if lhs.isEmpty || rhs.isEmpty { return !lhs.isEmpty && rhs.isEmpty }
        for (left, right) in zip(lhs, rhs) where left != right {
            switch (Int(left), Int(right)) {
            case let (leftValue?, rightValue?): return leftValue < rightValue
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.count < rhs.count
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : "\(core)-\(prerelease.joined(separator: "."))"
    }
}
