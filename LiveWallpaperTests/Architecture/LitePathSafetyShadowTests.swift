import Foundation
import Testing

/// `AmbientWallpaperSessionBuilder` carries a `#if LITE_BUILD` copy of
/// `WPEPathSafety` because the Lite SKU does not link `LiveWallpaperProWPE`.
/// The two copies are byte-identical today, but nothing enforced that — and the
/// app test target always compiles with `LITE_BUILD` *undefined*, so the shadow
/// is never type-checked, let alone exercised, by any other test in this suite.
/// A path-containment primitive that silently drifts in the SKU nobody tests is
/// the failure this guards against.
///
/// If Lite ever needs one of the functions this shadow omits — notably the
/// `isStrictSafeRelativePath` / `strictResourceURL` pair — copy it verbatim
/// rather than writing a second version.
@Suite("Lite WPEPathSafety shadow")
struct LitePathSafetyShadowTests {

    private static let sharedFunctions = [
        "isSafeRelativePath",
        "isSafeCacheRelativePath",
        "contains",
        "resourceURL",
        "containedResourceURL",
        "normalizedPath",
    ]

    /// Extracts one `func <name>` declaration and its body by brace balance.
    private func body(of function: String, in source: String) throws -> String {
        let signature = try #require(
            source.range(of: "func \(function)("),
            "\(function) is missing"
        )
        let open = try #require(
            source.range(of: "{", range: signature.upperBound ..< source.endIndex)
        )
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[open.upperBound ..< index])
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                }
            }
            index = source.index(after: index)
        }
        Issue.record("Unbalanced braces reading \(function)")
        return ""
    }

    @Test("Every shared function in the Lite shadow matches the ProWPE original")
    func shadowMatchesOriginal() throws {
        let shadow = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Session/AmbientWallpaperSessionBuilder.swift"
        )
        let original = try RepositoryRoot.source(
            "Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/PathSafety/WPEPathSafety.swift"
        )
        // Only the shadow's own declaration block, so a same-named helper
        // elsewhere in the builder cannot satisfy the comparison by accident.
        let start = try #require(shadow.range(of: "private enum WPEPathSafety {"))
        let end = try #require(
            shadow.range(of: "\n#endif", range: start.upperBound ..< shadow.endIndex)
        )
        let shadowBlock = String(shadow[start.lowerBound ..< end.lowerBound])

        for function in Self.sharedFunctions {
            #expect(
                try body(of: function, in: shadowBlock)
                    == body(of: function, in: original),
                "Lite's \(function) has drifted from the ProWPE original"
            )
        }
    }

    @Test("The shadow declares nothing the original does not")
    func shadowAddsNoNewFunction() throws {
        let shadow = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Session/AmbientWallpaperSessionBuilder.swift"
        )
        let start = try #require(shadow.range(of: "private enum WPEPathSafety {"))
        let end = try #require(
            shadow.range(of: "\n#endif", range: start.upperBound ..< shadow.endIndex)
        )
        let declared = String(shadow[start.lowerBound ..< end.lowerBound])
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: "func ") else { return nil }
                return String(line[range.upperBound...].prefix { $0 != "(" })
                    .trimmingCharacters(in: .whitespaces)
            }
        #expect(Set(declared) == Set(Self.sharedFunctions))
    }
}
