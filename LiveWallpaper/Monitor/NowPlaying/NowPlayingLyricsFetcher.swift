import Foundation

// MARK: - Parsed shapes

/// One timed word inside a line (Enhanced LRC `<mm:ss.xx>`).
struct LyricWord: Equatable, Sendable {
    var time: Double
    var text: String
}

/// One timed line. `words` is nil unless the source carried word-level tags.
struct LyricLine: Equatable, Sendable {
    var time: Double
    var text: String
    var words: [LyricWord]?
}

// MARK: - Parsing and lookup (pure)

enum NowPlayingLyrics {
    /// LRC → timed lines. Never throws or traps: anything unparseable is skipped, so a malformed entry
    /// yields fewer lines, not a crash. Handles what real catalogue rows contain: BOM, CRLF,
    /// `[mm:ss.xx]`/`[mm:ss.xxx]`, multiple time tags per line (expanded to one line each), `[ar:]`-style
    /// metadata, applied `[offset:]`, blank lines, `<mm:ss.xx>` word tags, and out-of-order timestamps.
    nonisolated static func parseLRC(_ text: String) -> [LyricLine] {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let rows = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        /// Milliseconds. A whole-file value, so it is collected across the pass
        /// and applied afterwards rather than only to the rows below the tag.
        var offsetMilliseconds = 0.0
        var parsed: [LyricLine] = []

        for row in rows {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            var times: [Double] = []
            var cursor = trimmed.startIndex
            scan: while cursor < trimmed.endIndex, trimmed[cursor] == "[" {
                guard let close = trimmed[cursor...].firstIndex(of: "]") else { break }
                let inner = String(trimmed[trimmed.index(after: cursor)..<close])
                if let seconds = timestamp(inner) {
                    times.append(seconds)
                } else if let value = offsetValue(inner) {
                    offsetMilliseconds = value
                } else if !isMetadata(inner) {
                    // `[chorus]` and friends are lyric text, not a tag.
                    break scan
                }
                cursor = trimmed.index(after: close)
            }
            guard !times.isEmpty else { continue }

            let (plain, words) = splitWords(String(trimmed[cursor...]))
            guard !plain.isEmpty else { continue }

            // A repeated line re-plays its words at the same relative offsets.
            let base = times[0]
            for time in times {
                let shift = time - base
                parsed.append(LyricLine(
                    time: time,
                    text: plain,
                    words: words.map { list in list.map { LyricWord(time: $0.time + shift, text: $0.text) } }
                ))
            }
        }

        // Wikipedia's LRC reference: the value is in milliseconds and `+` makes
        // the lyrics appear sooner, so it is subtracted rather than added.
        let offset = offsetMilliseconds / 1000
        for index in parsed.indices {
            parsed[index].time -= offset
            if let words = parsed[index].words {
                parsed[index].words = words.map { LyricWord(time: $0.time - offset, text: $0.text) }
            }
        }

        // `sort` is not stable, so the original order breaks ties explicitly.
        return parsed.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }

    /// Index of the line being sung at `time`, or nil before the first line.
    /// Binary search: the view asks on every tick, and a long lyric is ~100 rows.
    nonisolated static func activeIndex(lines: [LyricLine], at time: Double) -> Int? {
        guard let first = lines.first, time >= first.time else { return nil }
        var low = 0
        var high = lines.count - 1
        var found = 0
        while low <= high {
            let mid = low + (high - low) / 2
            if lines[mid].time <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// Same search over one line's word tags; nil when the line has none or the
    /// first word has not started.
    nonisolated static func activeWordIndex(line: LyricLine, at time: Double) -> Int? {
        guard let words = line.words, let first = words.first, time >= first.time else { return nil }
        var low = 0
        var high = words.count - 1
        var found = 0
        while low <= high {
            let mid = low + (high - low) / 2
            if words[mid].time <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    // MARK: Tag helpers

    /// `mm:ss`, `mm:ss.xx` or `mm:ss.xxx` → seconds. Rejects `ar:Radiohead`
    /// because neither half parses as a number.
    private nonisolated static func timestamp(_ inner: String) -> Double? {
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int(parts[0]), minutes >= 0,
              !parts[1].isEmpty,
              parts[1].allSatisfy({ $0.isNumber || $0 == "." }),
              let seconds = Double(parts[1])
        else { return nil }
        return Double(minutes) * 60 + seconds
    }

    private nonisolated static func offsetValue(_ inner: String) -> Double? {
        let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "offset" else { return nil }
        var value = parts[1].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("+") { value.removeFirst() }
        return Double(value)
    }

    private nonisolated static func isMetadata(_ inner: String) -> Bool {
        let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return parts[0].allSatisfy { $0.isLetter }
    }

    /// Splits `<mm:ss.xx>` word tags out of a line body. The plain text keeps
    /// every segment (including any untimed lead-in) so a partially tagged line
    /// still reads correctly; `words` is nil when the line carries no tags.
    private nonisolated static func splitWords(_ body: String) -> (String, [LyricWord]?) {
        guard body.contains("<") else {
            return (body.trimmingCharacters(in: .whitespaces), nil)
        }
        var plain = ""
        var words: [LyricWord] = []
        var cursor = body.startIndex
        while cursor < body.endIndex {
            guard body[cursor] == "<",
                  let close = body[cursor...].firstIndex(of: ">"),
                  let seconds = timestamp(String(body[body.index(after: cursor)..<close]))
            else {
                plain.append(body[cursor])
                // Text before the first tag belongs to the line but to no word.
                if !words.isEmpty { words[words.count - 1].text.append(body[cursor]) }
                cursor = body.index(after: cursor)
                continue
            }
            words.append(LyricWord(time: seconds, text: ""))
            cursor = body.index(after: close)
        }
        let trimmedWords = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        return (
            plain.trimmingCharacters(in: .whitespaces),
            trimmedWords.isEmpty ? nil : trimmedWords
        )
    }
}

// MARK: - Fetcher

/// Resolves synced lyrics from LRCLIB, under the same network discipline as `NowPlayingArtworkFetcher`:
/// positive LRU cache, in-flight merging per track key, one retry, and a TTL'd negative cache. LRCLIB
/// is keyless and needs no OAuth; it asks callers to identify themselves in `User-Agent`, which every
/// request here carries.
actor NowPlayingLyricsFetcher {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// One process-wide instance so the caches survive pipeline rebuilds.
    static let shared = NowPlayingLyricsFetcher()

    /// Text, not images: a long LRC is a few KB, so anything near this is junk.
    static let maxBodyBytes = 512 * 1024
    static let negativeTTL: TimeInterval = 600
    static let positiveCacheLimit = 32

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Loomscreen/\(version) (https://github.com/Paradox07127/macos-wallpaperengine)"
    }()

    private let transport: Transport
    private let now: @Sendable () -> Date

    private var cache: [String: [LyricLine]] = [:]
    /// Least-recently-used first.
    private var cacheOrder: [String] = []
    private var negativeCache: [String: Date] = [:]
    private var inFlight: [String: Task<[LyricLine]?, Never>] = [:]

    init(
        transport: @escaping Transport = NowPlayingNetwork.boundedTransport(byteCap: maxBodyBytes),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.now = now
    }

    // MARK: URLs and scoring (pure, test-visible)

    /// Exact-match endpoint. A duration that disagrees with LRCLIB's record
    /// 404s it, so the parameter is only sent when the player reported one;
    /// album is likewise optional (both were probed live on 2026-08-20).
    static func getURL(artist: String?, title: String, album: String?, duration: Double?) -> URL? {
        guard !title.isEmpty else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items: [URLQueryItem] = []
        if let artist, !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        items.append(URLQueryItem(name: "track_name", value: title))
        if let album, !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        // The value arrives as an unvalidated NSNumber from a distributed
        // notification, so the upper bound is what keeps `Int(_:)` from
        // trapping on something like 1e300 — 24 h is already absurd for a track.
        if let duration, duration.isFinite, duration > 0, duration <= 86_400 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components?.queryItems = items
        return components?.url
    }

    static func searchURL(artist: String?, title: String) -> URL? {
        guard !title.isEmpty else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/search")
        var items = [URLQueryItem(name: "track_name", value: title)]
        if let artist, !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        components?.queryItems = items
        return components?.url
    }

    struct Candidate: Decodable, Sendable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var instrumental: Bool?
        var syncedLyrics: String?
    }

    /// Per field: case-insensitive equality 2, containment either way 1.
    static func matchScore(candidate: Candidate, artist: String?, title: String, album: String?) -> Int {
        fieldScore(candidate.artistName, artist)
            + fieldScore(candidate.trackName, title)
            + fieldScore(candidate.albumName, album)
    }

    private static func fieldScore(_ candidate: String?, _ target: String?) -> Int {
        guard let candidate, let target, !candidate.isEmpty, !target.isEmpty else { return 0 }
        let c = candidate.lowercased()
        let t = target.lowercased()
        if c == t { return 2 }
        if c.contains(t) || t.contains(c) { return 1 }
        return 0
    }

    /// Highest-scoring row with score > 0. Rows without synced lyrics lose every
    /// tie: plain text carries no timing, which is the whole point here. When
    /// the player names an artist, a row that matches only on title is rejected
    /// — showing another band's words is worse than showing none.
    static func bestMatch(
        in candidates: [Candidate], artist: String?, title: String, album: String?
    ) -> Candidate? {
        candidates
            .map { ($0, matchScore(candidate: $0, artist: artist, title: title, album: album)) }
            .filter { $0.1 > 0 }
            .filter { artist == nil || fieldScore($0.0.artistName, artist) > 0 }
            .max { lhs, rhs in
                let lhsSynced = lhs.0.syncedLyrics?.isEmpty == false
                let rhsSynced = rhs.0.syncedLyrics?.isEmpty == false
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return !lhsSynced && rhsSynced
            }?.0
    }

    // MARK: Cache and fetch

    /// Resolves lyrics for the state, merging concurrent calls per track key.
    /// nil means "no lyrics for this track", cached either way.
    func lyrics(for state: MonitorNowPlayingState) async -> [LyricLine]? {
        guard let key = NowPlayingArtworkFetcher.trackKey(for: state) else { return nil }
        if let hit = cache[key] {
            touch(key)
            return hit
        }
        if let expiry = negativeCache[key] {
            if now() < expiry { return nil }
            negativeCache.removeValue(forKey: key)
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task<[LyricLine]?, Never> {
            let result = await self.runFetch(state: state)
            self.finish(key: key, result: result)
            return result
        }
        inFlight[key] = task
        return await task.value
    }

    /// Drops every merged fetch except the one the caller still wants — see
    /// `NowPlayingArtworkFetcher.cancelInFlight(except:)` for why.
    func cancelInFlight(except key: String?) {
        for (running, task) in inFlight where running != key {
            task.cancel()
            inFlight.removeValue(forKey: running)
        }
    }

    private func finish(key: String, result: [LyricLine]?) {
        inFlight.removeValue(forKey: key)
        if let result, !result.isEmpty {
            cache[key] = result
            touch(key)
            while cacheOrder.count > Self.positiveCacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        } else {
            negativeCache[key] = now().addingTimeInterval(Self.negativeTTL)
        }
    }

    private func touch(_ key: String) {
        if let index = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: index) }
        cacheOrder.append(key)
    }

    // MARK: Network

    /// Thrown errors are transient (transport/HTTP) and get one retry; a nil
    /// return is semantic (no match, instrumental, oversize) and is final.
    private func runFetch(state: MonitorNowPlayingState) async -> [LyricLine]? {
        do {
            return try await attempt(state: state)
        } catch {
            guard !Task.isCancelled else { return nil }
            return try? await attempt(state: state)
        }
    }

    private func attempt(state: MonitorNowPlayingState) async throws -> [LyricLine]? {
        let exactURL = Self.getURL(
            artist: state.artist, title: state.title, album: state.album, duration: state.duration
        )
        if let exactURL,
           let data = try await load(exactURL),
           let record = try? JSONDecoder().decode(Candidate.self, from: data) {
            // LRCLIB flags instrumental tracks instead of shipping empty
            // lyrics: a definitive "none", not a reason to keep searching.
            if record.instrumental == true { return nil }
            if let lines = Self.lines(from: record) { return lines }
        }

        guard let url = Self.searchURL(artist: state.artist, title: state.title),
              let data = try await load(url),
              let rows = try? JSONDecoder().decode([Candidate].self, from: data),
              let best = Self.bestMatch(
                  in: rows, artist: state.artist, title: state.title, album: state.album
              ),
              best.instrumental != true
        else { return nil }
        return Self.lines(from: best)
    }

    /// Only timed lyrics are usable — `plainLyrics` carries no timeline, and the
    /// product ladder is word → line → nothing.
    private static func lines(from candidate: Candidate) -> [LyricLine]? {
        guard let synced = candidate.syncedLyrics, !synced.isEmpty else { return nil }
        let lines = NowPlayingLyrics.parseLRC(synced)
        return lines.isEmpty ? nil : lines
    }

    /// nil = no usable body (404, or past the size cap); throws = transient.
    private func load(_ url: URL) async throws -> Data? {
        guard NowPlayingNetwork.isAllowed(url, for: .api) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            if http.statusCode != 200 { throw URLError(.badServerResponse) }
            // A redirect off the allow-list must not be read as LRCLIB's answer.
            guard NowPlayingNetwork.isAllowed(http.url, for: .api),
                  (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("json")
            else { return nil }
            if http.expectedContentLength > Int64(Self.maxBodyBytes) { return nil }
        }
        if data.count > Self.maxBodyBytes { return nil }
        return data
    }
}

// MARK: - Store (main-actor cache the view can ask on every track change)

/// Lyrics stay out of `MonitorSnapshot` — the snapshot is a wire type shared by
/// every widget, and only this layer wants a whole song's text. The view asks
/// here with `.task(id: trackKey)` instead.
@MainActor
final class NowPlayingLyricsStore {
    static let shared = NowPlayingLyricsStore()

    private let load: @Sendable (MonitorNowPlayingState) async -> [LyricLine]?
    /// Retires the fetcher's merged work for every other track before starting
    /// a new one, so skipping through a playlist does not leave one live
    /// request per skipped track.
    private let cancelOthers: @Sendable (String?) async -> Void
    private let now: @Sendable () -> Date
    /// Positive results only — a permanent empty entry here would outlive and
    /// mask the fetcher's own TTL'd negative cache, so a track that failed once
    /// (offline, LRCLIB down) could never get lyrics again for the process's life.
    private var cache: [String: [LyricLine]] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<[LyricLine], Never>] = [:]
    /// Misses expire on the same clock as the fetcher's negative cache, so the
    /// two layers agree on when a retry is due.
    private var missExpiry: [String: Date] = [:]
    private let capacity = 8
    /// Test seam: how many times the loader actually ran.
    private(set) var loadCount = 0

    init(
        load: @escaping @Sendable (MonitorNowPlayingState) async -> [LyricLine]? = {
            await NowPlayingLyricsFetcher.shared.lyrics(for: $0)
        },
        cancelOthers: @escaping @Sendable (String?) async -> Void = {
            NowPlayingLyricsFetcher.shared.cancelInFlight(except: $0)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.load = load
        self.cancelOthers = cancelOthers
        self.now = now
    }

    func lyrics(for state: MonitorNowPlayingState) async -> [LyricLine] {
        guard let key = NowPlayingArtworkFetcher.trackKey(for: state) else { return [] }
        if let hit = cache[key] { return hit }
        if let expiry = missExpiry[key] {
            if now() < expiry { return [] }
            missExpiry.removeValue(forKey: key)
        }
        if let pending = inFlight[key] { return await pending.value }
        loadCount += 1
        let load = self.load
        let task = Task<[LyricLine], Never> { await load(state) ?? [] }
        // Registered before the first suspension, or two concurrent asks for
        // one track both miss `inFlight` and start their own load.
        inFlight[key] = task
        await cancelOthers(key)
        let value = await task.value
        inFlight[key] = nil
        if value.isEmpty {
            missExpiry[key] = now().addingTimeInterval(NowPlayingLyricsFetcher.negativeTTL)
        } else {
            store(value, for: key)
        }
        return value
    }

    private func store(_ value: [LyricLine], for key: String) {
        if cache[key] == nil { order.append(key) }
        cache[key] = value
        while order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
    }
}
