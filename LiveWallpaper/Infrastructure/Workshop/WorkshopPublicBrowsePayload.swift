#if !LITE_BUILD
import Foundation

/// The browse page's own result set. Valve's SSR page embeds
/// `window.SSR.renderContext=JSON.parse("…")`: a JS string literal holding the
/// render-context JSON, whose `queryData` is itself a JSON string (the
/// react-query dehydrated state). Its `workshop_browse` query is what the page
/// renders — `state.data.results[]`, `total_count`, `total_pages`, and
/// `creator_player_link_details[]` for author names (verified 2026-09-07, 30/30
/// ids identical to the keyed API).
/// Results carry `consumer_appid` but neither `banned` nor `visibility` today;
/// both are honoured when present and read as not-banned / public when absent,
/// since the page lists public items only.
enum WorkshopPublicBrowsePayload {
    enum ParseFailure: Error, Equatable {
        case markerNotFound
        case malformedLiteral
        case malformedJSON
        case browseQueryNotFound
        /// The embedded query answers different parameters than the request
        /// (a cached or redirected page); adopting it would show another
        /// page's items under this page's number.
        case identityMismatch
        case resultNotOK(Int)
    }

    struct Page: Equatable {
        let items: [WorkshopQueryItem]
        /// `results.count` before the drop rules ran.
        let sourceItemCount: Int
        let totalCount: Int
        let totalPages: Int
    }

    private static let marker = "window.SSR.renderContext=JSON.parse(\""

    static func page(fromHTML html: String, matching request: WorkshopQueryRequest, appID: Int) throws -> Page {
        let literal = try renderContextLiteral(in: html)
        let renderContextJSON = try decodeStringLiteral(literal)
        let queryData: QueryData
        do {
            let context = try JSONDecoder().decode(RenderContext.self, from: Data(renderContextJSON.utf8))
            queryData = try JSONDecoder().decode(QueryData.self, from: Data(context.queryData.utf8))
        } catch {
            throw ParseFailure.malformedJSON
        }

        let browseQueries = queryData.queries.filter { $0.browseKey != nil }
        guard !browseQueries.isEmpty else { throw ParseFailure.browseQueryNotFound }
        guard let query = browseQueries.first(where: { matches($0.browseKey!, request, appID: appID) }) else {
            throw ParseFailure.identityMismatch
        }
        guard let data = query.data else { throw ParseFailure.malformedJSON }
        if let result = data.eresult, result != 1 {
            throw ParseFailure.resultNotOK(result)
        }
        if let currentPage = data.current_page, currentPage != request.page {
            throw ParseFailure.identityMismatch
        }
        guard let totalCount = data.total_count, let totalPages = data.total_pages else {
            throw ParseFailure.malformedJSON
        }
        // A missing `results` is an empty page only with the totals' evidence
        // for it; with items to show it is a broken payload.
        guard let results = data.results ?? (totalCount == 0 || request.page > totalPages ? [] : nil) else {
            throw ParseFailure.malformedJSON
        }
        let personaNames = Dictionary(
            (data.creator_player_link_details ?? []).compactMap { details -> (String, String)? in
                guard let steamID = details.public_data?.steamid,
                      let name = details.public_data?.persona_name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty
                else { return nil }
                return (steamID, WorkshopDiagnosticRedactor.redact(name))
            },
            uniquingKeysWith: { first, _ in first }
        )
        return Page(
            items: results.compactMap { item(from: $0, personaNames: personaNames, appID: appID) },
            sourceItemCount: results.count,
            totalCount: totalCount,
            totalPages: totalPages
        )
    }

    // MARK: - Identity

    /// Every parameter the browse URL states must be echoed by the query key;
    /// tags compare as sets because the key's order is Valve's, not ours.
    private static func matches(_ key: BrowseKey, _ request: WorkshopQueryRequest, appID: Int) -> Bool {
        key.appid == appID
            && key.browse_sort == WorkshopPublicBrowseURL.browseSort(for: request.sort)
            && key.page == request.page
            && (key.search_text ?? "") == request.searchText
            && (key.search_text_target ?? 0) == request.searchTextTarget.rawValue
            && (key.childpublishedfileid ?? "") == (request.childPublishedFileID.map { String($0) } ?? "")
            // The browse URL never states a section, so only the default one
            // (not `collections`) answers it.
            && (key.section ?? "readytouseitems") == "readytouseitems"
            && (request.days == nil || key.trend_days == request.days)
            && Set(key.required_tags ?? []) == Set(request.requiredTagsIncludingMiscellaneous)
            && Set(key.excluded_tags ?? []) == Set(request.excludedTags)
    }

    // MARK: - Item mapping (same drop rules as the keyed path and `SteamWorkshopMetadata`)

    private static func item(from result: BrowseResult, personaNames: [String: String], appID: Int) -> WorkshopQueryItem? {
        guard let id = UInt64(result.publishedfileid), result.consumer_appid == appID else { return nil }
        if result.banned?.value == true {
            return nil
        }
        let visibility = SteamWorkshopMetadata.Visibility(rawCode: result.visibility ?? 0)
        guard visibility == .public else { return nil }

        var previewURL: URL?
        if let candidate = result.preview_url?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty,
           case let .allowed(url) = WorkshopCDNHostAllowList.evaluate(candidate) {
            previewURL = url
        }
        let creatorID = result.creator?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkshopQueryItem(
            id: id,
            rawTitle: title.flatMap { $0.isEmpty ? nil : WorkshopDiagnosticRedactor.redact($0) },
            shortDescription: WorkshopDiagnosticRedactor.redact(
                result.short_description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ),
            creatorID: creatorID.flatMap { $0.isEmpty ? nil : $0 },
            creatorPersonaName: creatorID.flatMap { personaNames[$0] },
            previewImageURL: previewURL,
            fileSizeBytes: result.file_size?.value,
            timeUpdated: result.time_updated.map { Date(timeIntervalSince1970: $0) },
            subscriptionCount: result.lifetime_subscriptions ?? result.subscriptions,
            viewCount: result.views,
            favoriteCount: result.lifetime_favorited ?? result.favorited,
            rating: rating(stars: result.star_rating, totalVotes: result.total_votes),
            timeCreated: result.time_created.map { Date(timeIntervalSince1970: $0) },
            commentCount: result.num_comments_public,
            requiredItemIDs: (result.children ?? [])
                .sorted { ($0.sortorder ?? 0) < ($1.sortorder ?? 0) }
                .compactMap { $0.publishedfileid.flatMap { UInt64($0) } },
            tags: (result.tags ?? [])
                .compactMap { ($0.display_name ?? $0.tag)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .map(WorkshopDiagnosticRedactor.redact)
                .filter { !$0.isEmpty },
            visibility: visibility,
            isBanned: false,
            steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
        )
    }

    /// Valve sends -1 for "not rated yet": zero stars with the vote count, so
    /// it reads as "no ratings" rather than "unavailable". Anything outside
    /// -1 and 1…5 is not a rating.
    private static func rating(stars: Int?, totalVotes: Int?) -> WorkshopRating? {
        guard let stars else { return nil }
        let votes = max(totalVotes ?? 0, 0)
        switch stars {
        case -1: return .stars(0, totalVotes: votes)
        case 1 ... 5: return .stars(stars, totalVotes: votes)
        default: return nil
        }
    }

    // MARK: - Literal extraction

    /// Walks the JS string literal after the marker to its closing quote,
    /// skipping escaped pairs — descriptions legitimately contain `\")`.
    private static func renderContextLiteral(in html: String) throws -> Substring {
        guard let start = html.range(of: marker)?.upperBound else { throw ParseFailure.markerNotFound }
        let bytes = html.utf8
        var index = start
        while index < bytes.endIndex {
            switch bytes[index] {
            case UInt8(ascii: "\\"):
                index = bytes.index(index, offsetBy: 2, limitedBy: bytes.endIndex) ?? bytes.endIndex
            case UInt8(ascii: "\""):
                return html[start ..< index]
            default:
                index = bytes.index(after: index)
            }
        }
        throw ParseFailure.malformedLiteral
    }

    /// Valve emits the literal with JSON's string grammar, so JSON decodes it
    /// (`\"`, `\\`, `\uXXXX` and surrogate pairs included).
    private static func decodeStringLiteral(_ literal: Substring) throws -> String {
        let quoted = Data(("\"" + literal + "\"").utf8)
        guard let string = try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed) as? String else {
            throw ParseFailure.malformedLiteral
        }
        return string
    }

    // MARK: - Wire format

    private struct RenderContext: Decodable {
        let queryData: String
    }

    private struct QueryData: Decodable {
        let queries: [Query]
    }

    /// Only `workshop_browse` entries decode their `state.data`; the other
    /// queries' data has unrelated shapes (null, arrays, config objects).
    private struct Query: Decodable {
        let browseKey: BrowseKey?
        let data: BrowseData?

        private enum CodingKeys: String, CodingKey {
            case queryKey
            case state
        }

        private enum StateKeys: String, CodingKey {
            case data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var keyParts = try container.nestedUnkeyedContainer(forKey: .queryKey)
            guard let head = try? keyParts.decode(String.self), head == "workshop_browse" else {
                browseKey = nil
                data = nil
                return
            }
            browseKey = try keyParts.decode(BrowseKey.self)
            let state = try container.nestedContainer(keyedBy: StateKeys.self, forKey: .state)
            data = try state.decodeIfPresent(BrowseData.self, forKey: .data)
        }
    }

    // Valve JSON keys are snake_case.
    // swiftlint:disable identifier_name
    /// `queryKey[1]` of a `workshop_browse` query, e.g. `{"admin_view":false,
    /// "appid":431960,"browse_sort":"trend","childpublishedfileid":"",
    /// "excluded_tags":[…],"num_per_page":30,"page":1,"required_apps_preset":0,
    /// "search_text":"","search_text_target":0,"section":"readytouseitems",
    /// "trend_days":7}`.
    private struct BrowseKey: Decodable {
        let appid: Int?
        let browse_sort: String?
        let page: Int?
        let search_text: String?
        let search_text_target: Int?
        let childpublishedfileid: String?
        let section: String?
        let trend_days: Int?
        let required_tags: [String]?
        let excluded_tags: [String]?
    }

    private struct BrowseData: Decodable {
        let eresult: Int?
        let current_page: Int?
        let total_count: Int?
        let total_pages: Int?
        let results: [BrowseResult]?
        let creator_player_link_details: [LinkDetails]?
    }

    private struct BrowseResult: Decodable {
        let publishedfileid: String
        let creator: String?
        let consumer_appid: Int?
        let preview_url: String?
        let title: String?
        let short_description: String?
        let time_created: Double?
        let time_updated: Double?
        let file_size: LenientUInt64?
        let tags: [Tag]?
        let subscriptions: Int?
        let lifetime_subscriptions: Int?
        let favorited: Int?
        let lifetime_favorited: Int?
        let views: Int?
        let num_comments_public: Int?
        let star_rating: Int?
        let total_votes: Int?
        let children: [Child]?
        let banned: LenientBool?
        let visibility: Int?

        struct Tag: Decodable {
            let tag: String?
            let display_name: String?
        }

        struct Child: Decodable {
            let publishedfileid: String?
            let sortorder: Int?
        }
    }

    private struct LinkDetails: Decodable {
        let public_data: PublicData?

        struct PublicData: Decodable {
            let steamid: String?
            let persona_name: String?
        }
    }

    // swiftlint:enable identifier_name

    /// `file_size` arrives as a decimal string on this page and on QueryFiles.
    private struct LenientUInt64: Decodable {
        let value: UInt64

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(UInt64.self) {
                value = number
            } else if let string = try? container.decode(String.self), let number = UInt64(string) {
                value = number
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an unsigned integer")
            }
        }
    }

    /// Valve flips between `true` and `1` for flags across endpoints.
    private struct LenientBool: Decodable {
        let value: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                value = flag
            } else if let number = try? container.decode(Int.self) {
                value = number != 0
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a flag")
            }
        }
    }
}
#endif
