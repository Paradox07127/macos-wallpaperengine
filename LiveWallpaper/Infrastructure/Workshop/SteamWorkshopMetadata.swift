#if !LITE_BUILD
import Foundation

struct SteamWorkshopMetadata: Equatable, Sendable {
    let publishedFileID: UInt64
    let title: String
    let shortDescription: String
    /// Creator's SteamID64 (`creator` on the payload).
    let creatorID: String?
    /// Optional — paste flow has no API key, so the supplemental
    /// `ISteamUser/GetPlayerSummaries/v2` lookup can't run.
    let creatorPersonaName: String?
    let previewImageURL: URL?
    let fileSizeBytes: UInt64?
    let timeUpdated: Date?
    let timeCreated: Date?
    let visibility: Visibility
    let isBanned: Bool
    let appID: UInt32
    let steamCommunityURL: URL
    let tags: [String]
    let subscriptionCount: Int?
    let viewCount: Int?
    let favoriteCount: Int?

    /// Steam's documented visibility enum on `GetPublishedFileDetails`:
    /// `0` public, `1` friends-only, `2` private; anything else → `.unknown`.
    enum Visibility: String, Equatable, Sendable {
        case `public`
        case friendsOnly
        case `private`
        case unknown

        init(rawCode: Int?) {
            switch rawCode {
            case 0: self = .public
            case 1: self = .friendsOnly
            case 2: self = .private
            default: self = .unknown
            }
        }
    }
}

enum SteamWorkshopMetadataError: Error, Equatable, Sendable {
    case invalidInput(WorkshopURLParser.InvalidReason)
    case networkUnreachable
    case timeout
    case unauthorized
    case http(status: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case responseParseFailure
    case schemaMismatch
    case itemPrivate
    case itemBanned
    case itemNotFound
    case cancelled
    case unknown(String)
}

@MainActor
final class SteamWorkshopMetadataService {

    private let session: URLSession
    private let now: @Sendable () -> Date

    static let endpoint = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!
        /// Payloads are a few KB per item and callers batch ≤50 ids. Bounds a
        /// hostile response without risking a false reject on a legitimate one.
        static let maxResponseBytes = 8 * 1024 * 1024

    init(session: URLSession = SteamWorkshopMetadataService.defaultSession(),
         now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    func fetch(publishedFileID id: UInt64) async -> Result<SteamWorkshopMetadata, SteamWorkshopMetadataError> {
        let results = await fetch(publishedFileIDs: [id])
        return results[id] ?? .failure(.responseParseFailure)
    }

    func fetch(publishedFileIDs ids: [UInt64]) async -> [UInt64: Result<SteamWorkshopMetadata, SteamWorkshopMetadataError>] {
        guard !ids.isEmpty else { return [:] }
        do {
            return try await Self.results(from: post(publishedFileIDs: ids), requestedIDs: ids)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                return Self.uniformFailure(.timeout, ids: ids)
            case .cancelled:
                return Self.uniformFailure(.cancelled, ids: ids)
            case .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed:
                return Self.uniformFailure(.networkUnreachable, ids: ids)
            default:
                return Self.uniformFailure(.unknown(urlError.localizedDescription), ids: ids)
            }
        } catch let error as SteamWorkshopMetadataError {
            return Self.uniformFailure(error, ids: ids)
        } catch {
            return Self.uniformFailure(.unknown(error.localizedDescription), ids: ids)
        }
    }

    /// Replaying this POST is safe — GetPublishedFileDetails is a read-only lookup that Valve exposes as POST.
    func post(publishedFileIDs ids: [UInt64]) async throws -> WorkshopRetryPolicy.Response {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        request.httpBody = Self.formBody(publishedFileIDs: ids).data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedNetworkFetch.fetch(request, session: session, byteCap: Self.maxResponseBytes)
        } catch is BoundedNetworkFetch.ResponseTooLarge {
            throw SteamWorkshopMetadataError.responseParseFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw SteamWorkshopMetadataError.responseParseFailure
        }
        return (data, http)
    }

    nonisolated static func results(
        from response: WorkshopRetryPolicy.Response,
        requestedIDs ids: [UInt64]
    ) -> [UInt64: Result<SteamWorkshopMetadata, SteamWorkshopMetadataError>] {
        switch response.http.statusCode {
        case 200:
            return decodeBatch(data: response.data, requestedIDs: ids)
        case 429:
            let retryAfter = (response.http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return uniformFailure(.rateLimited(retryAfter: retryAfter), ids: ids)
        case 401, 403:
            return uniformFailure(.unauthorized, ids: ids)
        // A 404 from the endpoint says nothing about the items (it is the
        // endpoint that was not found), so it is an HTTP failure like any other.
        default:
            return uniformFailure(.http(status: response.http.statusCode), ids: ids)
        }
    }

    nonisolated static func formBody(publishedFileIDs ids: [UInt64]) -> String {
        var parts = ["itemcount=\(ids.count)"]
        for (index, id) in ids.enumerated() {
            parts.append("publishedfileids%5B\(index)%5D=\(id)")
        }
        return parts.joined(separator: "&")
    }

    private nonisolated static func uniformFailure(
        _ error: SteamWorkshopMetadataError,
        ids: [UInt64]
    ) -> [UInt64: Result<SteamWorkshopMetadata, SteamWorkshopMetadataError>] {
        var results: [UInt64: Result<SteamWorkshopMetadata, SteamWorkshopMetadataError>] = [:]
        for id in ids {
            results[id] = .failure(error)
        }
        return results
    }

    // MARK: - Decoding

    nonisolated static func decodeBatch(
        data: Data,
        requestedIDs: [UInt64]
    ) -> [UInt64: Result<SteamWorkshopMetadata, SteamWorkshopMetadataError>] {
        let envelope: GetPublishedFileDetailsEnvelope
        do {
            envelope = try JSONDecoder().decode(GetPublishedFileDetailsEnvelope.self, from: data)
        } catch {
            return uniformFailure(.responseParseFailure, ids: requestedIDs)
        }
        // publishedfileid is a JSON string. First payload wins on a duplicated id — a trailing failure would flip an earlier success.
        var payloadsByID: [UInt64: GetPublishedFileDetailsEnvelope.Payload] = [:]
        for payload in envelope.response.publishedfiledetails {
            guard let id = UInt64(payload.publishedfileid), payloadsByID[id] == nil else { continue }
            payloadsByID[id] = payload
        }
        var results: [UInt64: Result<SteamWorkshopMetadata, SteamWorkshopMetadataError>] = [:]
        for id in requestedIDs {
            guard let payload = payloadsByID[id] else {
                // Steam drops unknown ids from the response entirely — same
                // signal as an explicit result code 9.
                results[id] = .failure(.itemNotFound)
                continue
            }
            results[id] = decode(payload: payload, publishedFileID: id)
        }
        return results
    }

    private nonisolated static func decode(
        payload: GetPublishedFileDetailsEnvelope.Payload,
        publishedFileID id: UInt64
    ) -> Result<SteamWorkshopMetadata, SteamWorkshopMetadataError> {
        // Steam result: 1 OK, 9 not found, 15 access denied — only 9/15 are permanently invisible; other codes are transient. Check before the app-id guard: non-OK payloads omit consumer_app_id.
        switch payload.result {
        case 1:
            break
        case 9:
            return .failure(.itemNotFound)
        case 15:
            return .failure(.itemPrivate)
        default:
            return .failure(.unknown("result \(payload.result)"))
        }
        // Looked up by id alone — a different Steam app would come back. UInt32(exactly:) (not UInt32(_:)) rejects negative/overflow instead of crashing.
        guard let consumerAppID = payload.consumer_app_id,
              let appID = UInt32(exactly: consumerAppID),
              appID == UInt32(WorkshopQueryService.wallpaperEngineAppID)
        else {
            return .failure(.schemaMismatch)
        }
        if let bannedInt = payload.banned, bannedInt != 0 {
            return .failure(.itemBanned)
        }
        let visibility = SteamWorkshopMetadata.Visibility(rawCode: payload.visibility)
        // Unknown visibility fails closed because only explicitly public items are safe to display.
        if visibility != .public {
            return .failure(.itemPrivate)
        }

        var preview: URL?
        if let candidate = payload.preview_url {
            switch WorkshopCDNHostAllowList.evaluate(candidate) {
            case .allowed(let url):
                preview = url
            case .rejected:
                preview = nil
            }
        }

        let communityURL = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
        let creatorID = payload.creator?.trimmingCharacters(in: .whitespacesAndNewlines)

        return .success(SteamWorkshopMetadata(
            publishedFileID: id,
            title: payload.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            // Not `description`: that is raw BBCode.
            shortDescription: payload.short_description ?? "",
            creatorID: creatorID.flatMap { $0.isEmpty ? nil : $0 },
            creatorPersonaName: nil,
            previewImageURL: preview,
            fileSizeBytes: payload.file_size.flatMap(UInt64.init),
            timeUpdated: payload.time_updated.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            timeCreated: payload.time_created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            visibility: visibility,
            isBanned: (payload.banned ?? 0) != 0,
            appID: appID,
            steamCommunityURL: communityURL,
            tags: payload.tags?.compactMap(\.tag) ?? [],
            subscriptionCount: payload.lifetime_subscriptions ?? payload.subscriptions,
            viewCount: payload.views,
            favoriteCount: payload.lifetime_favorited ?? payload.favorited
        ))
    }

    // MARK: - URLSession factory

    private static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Loomscreen/Workshop (+https://loomscreen.app/)"
        ]
        return URLSession(configuration: config)
    }
}

// MARK: - JSON Envelope

private struct GetPublishedFileDetailsEnvelope: Decodable {
    let response: ResponseBody

    struct ResponseBody: Decodable {
        let result: Int?
        let resultcount: Int?
        let publishedfiledetails: [Payload]
    }

    // swiftlint:disable identifier_name (Valve JSON keys are snake_case).
    struct Payload: Decodable {
        let publishedfileid: String
        let result: Int
        let creator: String?
        let consumer_app_id: Int?
        let filename: String?
        let file_size: String?
        let preview_url: String?
        let url: String?
        let title: String?
        let short_description: String?
        let time_created: Int?
        let time_updated: Int?
        let visibility: Int?
        /// Steam sends 0/1 as Int (not Bool); non-zero ⇒ banned.
        let banned: Int?
        let tags: [Tag]?
        let subscriptions: Int?
        let lifetime_subscriptions: Int?
        let favorited: Int?
        let lifetime_favorited: Int?
        let views: Int?

        struct Tag: Decodable {
            let tag: String?
        }
    }
    // swiftlint:enable identifier_name
}
#endif
