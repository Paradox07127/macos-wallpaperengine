import Foundation

/// Which artwork lookup a player's states go through — a data row keyed by
/// bundle ID, mirroring `NowPlayingPlayerMapping`: a new player is a new row,
/// not a new branch in the fetch path.
struct NowPlayingArtworkRoute: Sendable {
    enum Strategy: Sendable {
        /// Ask Spotify for the cover URL, falling back to oEmbed via track ID — a round trip re-deriving
        /// what the player's own dictionary already has, because that only exists once Automation consent
        /// is granted, and a wallpaper layer can't demand consent, so oEmbed stays the path until it is.
        case spotifyOEmbed
        /// iTunes Search scored against artist/title/album (no track ID exists).
        case itunesSearch
    }

    let bundleID: String
    let strategy: Strategy

    static let all: [NowPlayingArtworkRoute] = [
        NowPlayingArtworkRoute(bundleID: "com.spotify.client", strategy: .spotifyOEmbed),
        NowPlayingArtworkRoute(bundleID: "com.apple.Music", strategy: .itunesSearch),
    ]
}

/// Resolves cover art for a now-playing state over the network, under the
/// plan's network discipline (invariant 7): positive LRU cache, in-flight
/// merging per track key, one retry, and a TTL'd negative cache so an offline
/// failure is not permanent for the process lifetime.
actor NowPlayingArtworkFetcher {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// One process-wide instance so the caches survive pipeline rebuilds.
    static let shared = NowPlayingArtworkFetcher()

    static let maxImageBytes = 2 * 1024 * 1024
    /// oEmbed and an iTunes page of 10 rows are a few KB; anything near this is junk.
    static let maxMetadataBytes = 256 * 1024
    static let negativeTTL: TimeInterval = 600
    static let positiveCacheLimit = 32

    /// A player-supplied cover URL, or nil when the player has no vocabulary
    /// for it or has not been granted Automation consent.
    typealias ArtworkURLProvider = @Sendable (MonitorNowPlayingState) async -> URL?

    private let transport: Transport
    private let artworkURLProvider: ArtworkURLProvider
    private let now: @Sendable () -> Date

    private var cache: [String: Data] = [:]
    /// Least-recently-used first.
    private var cacheOrder: [String] = []
    /// Track key → expiry instant.
    private var negativeCache: [String: Date] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init(
        transport: @escaping Transport = NowPlayingNetwork.boundedTransport(byteCap: maxImageBytes),
        artworkURLProvider: @escaping ArtworkURLProvider = NowPlayingArtworkFetcher.playerArtworkURL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.artworkURLProvider = artworkURLProvider
        self.now = now
    }

    /// Never prompts: `value(for:from:)` answers nil until consent exists.
    static let playerArtworkURL: ArtworkURLProvider = { state in
        guard let text = await NowPlayingController.shared
            .value(for: .artworkURL, from: state.playerBundleID)?.stringValue
        else { return nil }
        return URL(string: text)
    }

    // MARK: - Keys and URLs (pure, test-visible)

    /// Spotify states carry a stable track ID; Apple Music has none, so its
    /// key is the metadata triple — prefixed by the player so one player's
    /// negative-cache entry can't block another player's valid lookup for the
    /// same song.
    static func trackKey(for state: MonitorNowPlayingState) -> String? {
        guard !state.title.isEmpty else { return nil }
        if let trackID = state.trackID { return trackID }
        return [state.playerBundleID ?? "", state.title, state.artist ?? "", state.album ?? ""]
            .joined(separator: "|")
    }

    /// Document form: `https://open.spotify.com/oembed?url=` + the URL-encoded
    /// canonical track URL. Returns nil for anything that is not a well-formed
    /// `spotify:track:<id>` URI.
    static func spotifyOEmbedURL(trackID: String) -> URL? {
        let parts = trackID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" else { return nil }
        let id = parts[2]
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        // RFC 3986 unreserved characters: keeps the dots readable while `:`
        // and `/` become %3A / %2F, matching the documented example.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = "https://open.spotify.com/track/\(id)"
            .addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "https://open.spotify.com/oembed?url=\(encoded)")
    }

    static func itunesSearchURL(artist: String?, title: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        let term = [artist, title].compactMap { $0 }.joined(separator: " ")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        return components?.url
    }

    struct ITunesCandidate: Decodable, Sendable {
        var artistName: String?
        var trackName: String?
        var collectionName: String?
        var artworkUrl100: String?
    }

    /// Per field: case-insensitive equality 2, containment either way 1
    /// (real iTunes rows list every collaborator in `artistName`, so the
    /// notification's single artist matches by containment).
    static func matchScore(candidate: ITunesCandidate, artist: String?, title: String, album: String?) -> Int {
        fieldScore(candidate.artistName, artist)
            + fieldScore(candidate.trackName, title)
            + fieldScore(candidate.collectionName, album)
    }

    private static func fieldScore(_ candidate: String?, _ target: String?) -> Int {
        guard let candidate, let target, !candidate.isEmpty, !target.isEmpty else { return 0 }
        let c = candidate.lowercased()
        let t = target.lowercased()
        if c == t { return 2 }
        if c.contains(t) || t.contains(c) { return 1 }
        return 0
    }

    /// Highest-scoring candidate with score > 0, or nil (→ negative cache).
    /// When the notification names an artist, a candidate that matches only
    /// on title is rejected — a common title ("Intro") by someone else must
    /// yield no cover, not the wrong one.
    static func bestMatch(
        in candidates: [ITunesCandidate], artist: String?, title: String, album: String?
    ) -> ITunesCandidate? {
        let scored = candidates
            .map { ($0, matchScore(candidate: $0, artist: artist, title: title, album: album)) }
            .filter { $0.1 > 0 }
            .filter { artist == nil || fieldScore($0.0.artistName, artist) > 0 }
        return scored.max { $0.1 < $1.1 }?.0
    }

    // MARK: - Cache and fetch

    /// Positive-cache-only lookup; never touches the network.
    func cachedArtwork(forKey key: String) -> Data? {
        guard let data = cache[key] else { return nil }
        touch(key)
        return data
    }

    /// Resolves artwork for the state, merging concurrent calls per track key.
    /// Returns nil when the state has no route or the lookup failed (in which
    /// case the key sits in the negative cache until its TTL expires).
    func artwork(for state: MonitorNowPlayingState) async -> Data? {
        guard let key = Self.trackKey(for: state),
              let route = NowPlayingArtworkRoute.all.first(where: { $0.bundleID == state.playerBundleID })
        else { return nil }
        if let data = cachedArtwork(forKey: key) { return data }
        if let expiry = negativeCache[key] {
            if now() < expiry { return nil }
            negativeCache.removeValue(forKey: key)
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task<Data?, Never> {
            let result = await self.runFetch(strategy: route.strategy, state: state)
            await self.finish(key: key, result: result)
            return result
        }
        inFlight[key] = task
        return await task.value
    }

    /// Drops every merged fetch except the one the caller still wants. Without
    /// this, skipping through a playlist leaves one live download per skipped
    /// track: the callers go away, but the merged task they shared does not.
    func cancelInFlight(except key: String?) {
        for (running, task) in inFlight where running != key {
            task.cancel()
            inFlight.removeValue(forKey: running)
        }
    }

    private func finish(key: String, result: Data?) {
        inFlight.removeValue(forKey: key)
        if let result {
            store(key: key, data: result)
        } else {
            negativeCache[key] = now().addingTimeInterval(Self.negativeTTL)
        }
    }

    private func store(key: String, data: Data) {
        cache[key] = data
        touch(key)
        while cacheOrder.count > Self.positiveCacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private func touch(_ key: String) {
        if let index = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: index) }
        cacheOrder.append(key)
    }

    // MARK: - Network

    /// Thrown errors are transient (transport/HTTP) and get one retry; a nil
    /// return is semantic (malformed ID, no match, oversize) and is final.
    private func runFetch(strategy: NowPlayingArtworkRoute.Strategy, state: MonitorNowPlayingState) async -> Data? {
        do {
            return try await attempt(strategy: strategy, state: state)
        } catch {
            guard !Task.isCancelled else { return nil }
            return try? await attempt(strategy: strategy, state: state)
        }
    }

    private func attempt(strategy: NowPlayingArtworkRoute.Strategy, state: MonitorNowPlayingState) async throws -> Data? {
        switch strategy {
        case .spotifyOEmbed:
            // The allow-list still applies: this URL comes from another
            // process, and "Spotify said so" is not a reason to fetch from an
            // arbitrary host.
            if let direct = await artworkURLProvider(state),
               NowPlayingNetwork.isAllowed(direct, for: .artwork),
               let data = try? await downloadImage(direct) {
                return data
            }
            guard let trackID = state.trackID, let url = Self.spotifyOEmbedURL(trackID: trackID) else { return nil }
            guard let body = try await fetch(url) else { return nil }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let thumbnail = object["thumbnail_url"] as? String,
                  let thumbnailURL = URL(string: thumbnail)
            else { return nil }
            return try await downloadImage(thumbnailURL)

        case .itunesSearch:
            guard let url = Self.itunesSearchURL(artist: state.artist, title: state.title) else { return nil }
            guard let body = try await fetch(url) else { return nil }
            struct SearchResponse: Decodable { var results: [ITunesCandidate] }
            guard let response = try? JSONDecoder().decode(SearchResponse.self, from: body),
                  let best = Self.bestMatch(
                      in: response.results, artist: state.artist, title: state.title, album: state.album
                  ),
                  let art100 = best.artworkUrl100
            else { return nil }
            // 600x600bb is widely used but undocumented — fall back to the
            // documented 100x100 URL rather than hard-depending on it.
            if art100.contains("100x100bb"),
               let url600 = URL(string: art100.replacingOccurrences(of: "100x100bb", with: "600x600bb")),
               let data = try? await downloadImage(url600) {
                return data
            }
            guard let url100 = URL(string: art100) else { return nil }
            return try await downloadImage(url100)
        }
    }

    /// nil = refused (off-list origin, wrong content type, oversize); those are
    /// final, while a thrown transport/HTTP error is transient and gets a retry.
    private func fetch(_ url: URL) async throws -> Data? {
        guard NowPlayingNetwork.isAllowed(url, for: .api) else { return nil }
        let (data, response) = try await transport(URLRequest(url: url))
        if let http = response as? HTTPURLResponse {
            if http.statusCode != 200 { throw URLError(.badServerResponse) }
            // Re-check the URL we actually ended on: a redirect off the list
            // must not be read as if the named endpoint had answered.
            guard NowPlayingNetwork.isAllowed(http.url, for: .api),
                  (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("json")
            else { return nil }
        }
        return data.count > Self.maxMetadataBytes ? nil : data
    }

    /// nil = deliberately abandoned (off-list CDN, not an image, or over the
    /// size cap for a wallpaper snapshot).
    private func downloadImage(_ url: URL) async throws -> Data? {
        guard NowPlayingNetwork.isAllowed(url, for: .artwork) else { return nil }
        let (data, response) = try await transport(URLRequest(url: url))
        if let http = response as? HTTPURLResponse {
            if http.statusCode != 200 { throw URLError(.badServerResponse) }
            guard NowPlayingNetwork.isAllowed(http.url, for: .artwork),
                  (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("image/")
            else { return nil }
            if http.expectedContentLength > Int64(Self.maxImageBytes) { return nil }
        }
        if data.count > Self.maxImageBytes { return nil }
        return data
    }
}
