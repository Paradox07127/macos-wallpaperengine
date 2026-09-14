import Foundation
import Testing

/// Derived from `browse_trend7_p1.html` (provenance in `Fixtures/workshop/README.md`).
/// Its SSR payload is three escape layers deep, so a JSON quote appears as `\\\"`.
enum WorkshopBrowseFixture {
    struct ReplacementMiss: Error, CustomStringConvertible {
        let target: String
        let hits: Int

        var description: String {
            "Expected exactly one occurrence of \(target) in the browse fixture, found \(hits)"
        }
    }

    static func base() throws -> String {
        try RepositoryRoot.source("LiveWallpaperTests/Fixtures/workshop/browse_trend7_p1.html")
    }

    static func keyPage2() throws -> String {
        try replacing(
            #"\\\"eresult\\\":1,\\\"current_page\\\":1,"#,
            with: #"\\\"eresult\\\":1,\\\"current_page\\\":2,"#,
            in: replacing(
                #"\\\"num_per_page\\\":30,\\\"page\\\":1,"#,
                with: #"\\\"num_per_page\\\":30,\\\"page\\\":2,"#,
                in: base()
            )
        )
    }

    static func keyRequiresApproved() throws -> String {
        try replacing(
            #"\\\"num_per_page\\\":30,\\\"page\\\":1,"#,
            with: #"\\\"num_per_page\\\":30,\\\"page\\\":1,\\\"required_tags\\\":[\\\"Approved\\\"],"#,
            in: base()
        )
    }

    static func keySearchTargetTitleOnly() throws -> String {
        try replacing(
            #"\\\"search_text_target\\\":0,\\\"section\\\":\\\"readytouseitems\\\""#,
            with: #"\\\"search_text_target\\\":1,\\\"section\\\":\\\"readytouseitems\\\""#,
            in: base()
        )
    }

    static func keySectionCollections() throws -> String {
        try replacing(
            #"\\\"section\\\":\\\"readytouseitems\\\",\\\"trend_days\\\":7}"#,
            with: #"\\\"section\\\":\\\"collections\\\",\\\"trend_days\\\":7}"#,
            in: base()
        )
    }

    static func keyChild42() throws -> String {
        try replacing(
            #"\\\"childpublishedfileid\\\":\\\"\\\",\\\"excluded_tags\\\""#,
            with: #"\\\"childpublishedfileid\\\":\\\"42\\\",\\\"excluded_tags\\\""#,
            in: base()
        )
    }

    /// SSR `state.data.current_page` 1 → 2 while the key still says page 1.
    static func dataCurrentPage2() throws -> String {
        try replacing(
            #"\\\"eresult\\\":1,\\\"current_page\\\":1,"#,
            with: #"\\\"eresult\\\":1,\\\"current_page\\\":2,"#,
            in: base()
        )
    }

    /// The captured page's query key excludes three tags; a browse built from today's
    /// Everyone-only default excludes five. Composable, so a variant can carry both changes.
    static func excludingMaturity(in page: String) throws -> String {
        try replacing(
            #"\\\"excluded_tags\\\":[\\\"Application\\\",\\\"Asset\\\",\\\"Preset\\\"]"#,
            with: #"\\\"excluded_tags\\\":[\\\"Application\\\",\\\"Asset\\\",\\\"Mature\\\",\\\"Preset\\\",\\\"Questionable\\\"]"#,
            in: page
        )
    }

    static func pages3() throws -> String {
        try replacing(#"\\\"total_pages\\\":1000,"#, with: #"\\\"total_pages\\\":3,"#, in: base())
    }

    /// Result 1's preview is off the CDN allow-list, result 2 banned, result 3 non-public.
    /// The live payload carries neither `banned` nor `visibility`; both are synthetic here.
    static func tainted() throws -> String {
        var page = try replacing(
            #"\\\"preview_url\\\":\\\"https://images.steamusercontent.com/ugc/12506494599842728983/02B16F0FC38B65438430F8CEAE44F9B38479522A/\\\""#,
            with: #"\\\"preview_url\\\":\\\"https://evil.example/ugc/1/preview.jpg\\\""#,
            in: base()
        )
        page = try replacing(
            #"{\\\"publishedfileid\\\":\\\"3795510669\\\","#,
            with: #"{\\\"publishedfileid\\\":\\\"3795510669\\\",\\\"banned\\\":true,"#,
            in: page
        )
        return try replacing(
            #"{\\\"publishedfileid\\\":\\\"3794850351\\\","#,
            with: #"{\\\"publishedfileid\\\":\\\"3794850351\\\",\\\"visibility\\\":2,"#,
            in: page
        )
    }

    static func withoutSSRScript() throws -> String {
        let page = try base()
        guard let start = page.range(of: "<script"), let end = page.range(of: "</script>") else {
            throw ReplacementMiss(target: "<script>…</script>", hits: 0)
        }
        return page.replacingCharacters(in: start.lowerBound ..< end.upperBound, with: "")
    }

    static func replacing(_ target: String, with replacement: String, in page: String) throws -> String {
        let hits = page.components(separatedBy: target).count - 1
        guard hits == 1 else { throw ReplacementMiss(target: target, hits: hits) }
        return page.replacingOccurrences(of: target, with: replacement)
    }
}

@Suite("Workshop browse fixture derivation")
struct WorkshopBrowseFixtureTests {
    @Test("A replacement must hit exactly once")
    func replacementHitsExactlyOnce() throws {
        let page = try WorkshopBrowseFixture.base()
        #expect(throws: WorkshopBrowseFixture.ReplacementMiss.self) {
            try WorkshopBrowseFixture.replacing("no such fragment in the page", with: "x", in: page)
        }
        #expect(throws: WorkshopBrowseFixture.ReplacementMiss.self) {
            try WorkshopBrowseFixture.replacing("filedetails/?id=", with: "x", in: page)
        }
        let derived = try WorkshopBrowseFixture.replacing(#"\\\"total_pages\\\":1000,"#, with: #"\\\"total_pages\\\":3,"#, in: page)
        #expect(derived.components(separatedBy: #"\\\"total_pages\\\":3,"#).count == 2)
        #expect(!derived.contains(#"\\\"total_pages\\\":1000,"#))
    }

    @Test("The no-SSR page drops the whole script and keeps the grid")
    func noSSRPageDropsScript() throws {
        let page = try WorkshopBrowseFixture.withoutSSRScript()
        #expect(!page.contains("window.SSR"))
        #expect(!page.contains("<script"))
        #expect(page.components(separatedBy: "filedetails/?id=").count - 1 == 60)
    }
}
