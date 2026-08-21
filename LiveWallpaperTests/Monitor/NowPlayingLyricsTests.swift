import Foundation
import os
import Testing
@testable import LiveWallpaper

// MARK: - Injected plumbing

private final class RequestLog: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [URLRequest]())
    func record(_ request: URLRequest) { lock.withLock { $0.append(request) } }
    var requests: [URLRequest] { lock.withLock { $0 } }
    var count: Int { lock.withLock { $0.count } }
    func count(matching needle: String) -> Int {
        lock.withLock { $0.filter { $0.url?.absoluteString.contains(needle) == true }.count }
    }
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class ClockBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
    var now: Date { lock.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { lock.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

private func ok(_ request: URLRequest, _ data: Data) -> (Data, URLResponse) {
    (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

private func status(_ request: URLRequest, _ code: Int) -> (Data, URLResponse) {
    (Data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
}

private let syncedFixture = "[00:10.00] first line\n[00:20.50] second line"

private func recordJSON(
    synced: String? = syncedFixture,
    instrumental: Bool = false,
    trackName: String = "Creep",
    artistName: String = "Radiohead",
    albumName: String = "Pablo Honey"
) -> Data {
    var object: [String: Any] = [
        "trackName": trackName,
        "artistName": artistName,
        "albumName": albumName,
        "instrumental": instrumental,
    ]
    if let synced { object["syncedLyrics"] = synced }
    return try! JSONSerialization.data(withJSONObject: object)
}

private func searchJSON(_ rows: [Data]) -> Data {
    let objects = rows.map { try! JSONSerialization.jsonObject(with: $0) }
    return try! JSONSerialization.data(withJSONObject: objects)
}

private func trackState(
    title: String = "Creep",
    artist: String? = "Radiohead",
    album: String? = "Pablo Honey",
    duration: Double? = 239
) -> MonitorNowPlayingState {
    var state = MonitorNowPlayingState(phase: .playing, title: title)
    state.artist = artist
    state.album = album
    state.duration = duration
    state.playerBundleID = "com.spotify.client"
    state.trackID = "spotify:track:\(title)"
    return state
}

@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

// MARK: - Tests

@Suite("Now Playing lyrics")
struct NowPlayingLyricsTests {
    // MARK: Parsing

    @Test("Both timestamp precisions parse to the same seconds")
    func bothPrecisionsParse() {
        let lines = NowPlayingLyrics.parseLRC("[00:12.34] two digits\n[01:02.500] three digits")
        #expect(lines.count == 2)
        #expect(abs(lines[0].time - 12.34) < 0.0001)
        #expect(lines[0].text == "two digits")
        #expect(abs(lines[1].time - 62.5) < 0.0001)
        #expect(lines[1].text == "three digits")
    }

    @Test("One row with several time tags expands into one line per tag")
    func multipleTagsExpand() {
        let lines = NowPlayingLyrics.parseLRC("[00:12.00][01:30.00][00:45.00]chorus\n[02:00.00]outro")
        #expect(lines.map(\.text) == ["chorus", "chorus", "chorus", "outro"])
        #expect(lines.map(\.time) == [12, 45, 90, 120])
    }

    @Test("A positive offset pulls lines earlier and a negative one pushes them later")
    func offsetAppliesWithBothSigns() {
        let earlier = NowPlayingLyrics.parseLRC("[offset:+500]\n[00:10.00]a\n[00:20.00]b")
        #expect(earlier.map(\.time) == [9.5, 19.5])

        let later = NowPlayingLyrics.parseLRC("[offset:-500]\n[00:10.00]a\n[00:20.00]b")
        #expect(later.map(\.time) == [10.5, 20.5])

        // The tag is file-wide even when it is written below the first row.
        let trailing = NowPlayingLyrics.parseLRC("[00:10.00]a\n[offset:+1000]\n[00:20.00]b")
        #expect(trailing.map(\.time) == [9, 19])
    }

    @Test("Word tags become words; the line keeps its full text")
    func wordTagsParse() {
        let lines = NowPlayingLyrics.parseLRC("[00:10.00]<00:10.00>Hello <00:10.80>world")
        #expect(lines.count == 1)
        #expect(lines[0].text == "Hello world")
        #expect(lines[0].words?.map(\.text) == ["Hello ", "world"])
        #expect(lines[0].words?.map(\.time) == [10, 10.8])

        // A repeated row replays its words at the same relative offsets.
        let repeated = NowPlayingLyrics.parseLRC("[00:10.00][00:30.00]<00:10.00>a <00:11.00>b")
        #expect(repeated.count == 2)
        #expect(repeated[0].words?.map(\.time) == [10, 11])
        #expect(repeated[1].words?.map(\.time) == [30, 31])

        // No tags at all leaves `words` nil rather than an empty list.
        #expect(NowPlayingLyrics.parseLRC("[00:10.00]plain")[0].words == nil)
    }

    @Test("Out-of-order timestamps come back sorted, ties in source order")
    func outOfOrderIsSorted() {
        let lines = NowPlayingLyrics.parseLRC("[00:30.00]c\n[00:10.00]a\n[00:20.00]b\n[00:10.00]a2")
        #expect(lines.map(\.text) == ["a", "a2", "b", "c"])
        #expect(lines.map(\.time) == [10, 10, 20, 30])
    }

    @Test("A BOM, CRLF endings and blank rows survive intact")
    func bomAndCRLFAreTolerated() {
        let text = "\u{FEFF}[ti:Creep]\r\n[00:10.00]first\r\n\r\n[00:20.00]second\r\n"
        let lines = NowPlayingLyrics.parseLRC(text)
        #expect(lines.map(\.text) == ["first", "second"])
        #expect(lines.map(\.time) == [10, 20])
    }

    @Test("Metadata-only and empty documents parse to nothing without trapping")
    func metadataOnlyYieldsNoLines() {
        #expect(NowPlayingLyrics.parseLRC("").isEmpty)
        #expect(NowPlayingLyrics.parseLRC("\n\n   \n").isEmpty)
        #expect(NowPlayingLyrics.parseLRC("[ar:Radiohead]\n[ti:Creep]\n[al:Pablo Honey]\n[by:someone]").isEmpty)
        // A timed row with no words is not a row worth drawing.
        #expect(NowPlayingLyrics.parseLRC("[00:10.00]").isEmpty)
        // A bracketed word that is not a tag stays lyric text.
        #expect(NowPlayingLyrics.parseLRC("[00:10.00][chorus] sing")[0].text == "[chorus] sing")
    }

    // MARK: Lookup

    @Test("activeIndex returns the last line at or before the instant")
    func activeIndexBoundaries() {
        let lines = NowPlayingLyrics.parseLRC("[00:10.00]a\n[00:20.00]b\n[00:30.00]c")
        #expect(NowPlayingLyrics.activeIndex(lines: [], at: 5) == nil)
        #expect(NowPlayingLyrics.activeIndex(lines: lines, at: 0) == nil)
        #expect(NowPlayingLyrics.activeIndex(lines: lines, at: 9.999) == nil)
        #expect(NowPlayingLyrics.activeIndex(lines: lines, at: 10) == 0)      // exact boundary
        #expect(NowPlayingLyrics.activeIndex(lines: lines, at: 19.9) == 0)
        #expect(NowPlayingLyrics.activeIndex(lines: lines, at: 20) == 1)
        #expect(NowPlayingLyrics.activeIndex(lines: lines, at: 30) == 2)
        #expect(NowPlayingLyrics.activeIndex(lines: lines, at: 9_999) == 2)   // past the last line
    }

    @Test("activeWordIndex follows the same rule inside one line")
    func activeWordIndexBoundaries() {
        let line = NowPlayingLyrics.parseLRC("[00:10.00]<00:10.00>a <00:11.00>b <00:12.00>c")[0]
        #expect(NowPlayingLyrics.activeWordIndex(line: line, at: 9.9) == nil)
        #expect(NowPlayingLyrics.activeWordIndex(line: line, at: 10) == 0)
        #expect(NowPlayingLyrics.activeWordIndex(line: line, at: 10.99) == 0)
        #expect(NowPlayingLyrics.activeWordIndex(line: line, at: 11) == 1)
        #expect(NowPlayingLyrics.activeWordIndex(line: line, at: 500) == 2)

        let untimed = LyricLine(time: 0, text: "plain", words: nil)
        #expect(NowPlayingLyrics.activeWordIndex(line: untimed, at: 5) == nil)
        #expect(NowPlayingLyrics.activeWordIndex(line: LyricLine(time: 0, text: "x", words: []), at: 5) == nil)
    }

    // MARK: URLs

    @Test("The exact endpoint drops parameters the player never reported")
    func exactURLShape() {
        #expect(
            NowPlayingLyricsFetcher.getURL(
                artist: "Radiohead", title: "Creep", album: "Pablo Honey", duration: 239
            )?.absoluteString ==
                "https://lrclib.net/api/get?artist_name=Radiohead&track_name=Creep&album_name=Pablo%20Honey&duration=239"
        )
        // A duration LRCLIB disagrees with 404s the endpoint, so an absent one
        // is omitted rather than guessed.
        #expect(
            NowPlayingLyricsFetcher.getURL(artist: nil, title: "Creep", album: nil, duration: nil)?
                .absoluteString == "https://lrclib.net/api/get?track_name=Creep"
        )
        #expect(NowPlayingLyricsFetcher.getURL(artist: "x", title: "", album: nil, duration: nil) == nil)
        #expect(
            NowPlayingLyricsFetcher.searchURL(artist: "Radiohead", title: "Creep")?.absoluteString ==
                "https://lrclib.net/api/search?track_name=Creep&artist_name=Radiohead"
        )
    }

    @Test("Scoring prefers a timed row and refuses a title-only hit by another artist")
    func scoringPrefersSyncedAndAgreeingArtist() {
        typealias Candidate = NowPlayingLyricsFetcher.Candidate
        let plain = Candidate(
            trackName: "Creep", artistName: "Radiohead", albumName: "Pablo Honey",
            instrumental: false, syncedLyrics: nil
        )
        let synced = Candidate(
            trackName: "Creep", artistName: "Radiohead", albumName: "Pablo Honey",
            instrumental: false, syncedLyrics: syncedFixture
        )
        #expect(
            NowPlayingLyricsFetcher.bestMatch(
                in: [plain, synced], artist: "Radiohead", title: "Creep", album: "Pablo Honey"
            )?.syncedLyrics == syncedFixture
        )
        let wrongArtist = Candidate(
            trackName: "Creep", artistName: "Someone Else", albumName: "Other",
            instrumental: false, syncedLyrics: syncedFixture
        )
        #expect(
            NowPlayingLyricsFetcher.bestMatch(
                in: [wrongArtist], artist: "Radiohead", title: "Creep", album: nil
            ) == nil
        )
        #expect(
            NowPlayingLyricsFetcher.matchScore(
                candidate: synced, artist: "Radiohead", title: "Creep", album: "Pablo Honey"
            ) == 6
        )
    }

    // MARK: Network discipline

    @Test("Every request identifies the app in User-Agent")
    func requestsCarryTheUserAgent() async {
        let log = RequestLog()
        let fetcher = NowPlayingLyricsFetcher(transport: { request in
            log.record(request)
            return ok(request, recordJSON())
        })
        _ = await fetcher.lyrics(for: trackState())

        #expect(log.count == 1)
        let header = log.requests.first?.value(forHTTPHeaderField: "User-Agent")
        #expect(header == NowPlayingLyricsFetcher.userAgent)
        #expect(header?.hasPrefix("Loomscreen/") == true)
        #expect(header?.hasSuffix(" (https://github.com/Paradox07127/macos-wallpaperengine)") == true)
    }

    @Test("An exact-endpoint hit is parsed and never falls through to search")
    func exactHitIsUsed() async {
        let log = RequestLog()
        let fetcher = NowPlayingLyricsFetcher(transport: { request in
            log.record(request)
            return ok(request, recordJSON())
        })
        let lines = await fetcher.lyrics(for: trackState())
        #expect(lines?.map(\.text) == ["first line", "second line"])
        #expect(log.count(matching: "/api/search") == 0)
    }

    @Test("A 404 from the exact endpoint falls back to search")
    func notFoundFallsBackToSearch() async {
        let log = RequestLog()
        let fetcher = NowPlayingLyricsFetcher(transport: { request in
            log.record(request)
            let url = request.url!.absoluteString
            if url.contains("/api/get") { return status(request, 404) }
            return ok(request, searchJSON([recordJSON()]))
        })
        let lines = await fetcher.lyrics(for: trackState())
        #expect(lines?.count == 2)
        #expect(log.count(matching: "/api/get") == 1)
        #expect(log.count(matching: "/api/search") == 1)
    }

    @Test("No usable match is negative-cached until the TTL expires")
    func noMatchIsNegativeCached() async {
        let log = RequestLog()
        let clock = ClockBox()
        let fetcher = NowPlayingLyricsFetcher(
            transport: { request in
                log.record(request)
                let url = request.url!.absoluteString
                if url.contains("/api/get") { return status(request, 404) }
                return ok(request, searchJSON([]))
            },
            now: { clock.now }
        )

        #expect(await fetcher.lyrics(for: trackState()) == nil)
        #expect(log.count == 2)

        #expect(await fetcher.lyrics(for: trackState()) == nil)
        #expect(log.count == 2)

        clock.advance(NowPlayingLyricsFetcher.negativeTTL + 1)
        #expect(await fetcher.lyrics(for: trackState()) == nil)
        #expect(log.count == 4)
    }

    @Test("An instrumental track is a definitive no — no search, no repeat request")
    func instrumentalStopsTheLookup() async {
        let log = RequestLog()
        let fetcher = NowPlayingLyricsFetcher(transport: { request in
            log.record(request)
            return ok(request, recordJSON(synced: nil, instrumental: true))
        })

        #expect(await fetcher.lyrics(for: trackState()) == nil)
        #expect(log.count(matching: "/api/get") == 1)
        #expect(log.count(matching: "/api/search") == 0)

        #expect(await fetcher.lyrics(for: trackState()) == nil)
        #expect(log.count == 1)
    }

    @Test("Concurrent requests for one track key merge into one transport hit")
    func concurrentSameKeyMerges() async {
        let log = RequestLog()
        let gate = Gate()
        let fetcher = NowPlayingLyricsFetcher(transport: { request in
            log.record(request)
            await gate.wait()
            return ok(request, recordJSON())
        })

        async let first = fetcher.lyrics(for: trackState())
        async let second = fetcher.lyrics(for: trackState())
        #expect(await waitUntil { log.count >= 1 })
        await gate.open()
        let results = await (first, second)
        #expect(results.0?.count == 2)
        #expect(results.1?.count == 2)
        #expect(log.count == 1)
    }

    @Test("A body past the 512KB cap is abandoned without a retry")
    func oversizeBodyIsAbandoned() async {
        let log = RequestLog()
        let oversize = Data(count: NowPlayingLyricsFetcher.maxBodyBytes + 1)
        let fetcher = NowPlayingLyricsFetcher(transport: { request in
            log.record(request)
            return ok(request, oversize)
        })

        #expect(await fetcher.lyrics(for: trackState()) == nil)
        // One exact call plus one search call — and no retry, because an
        // oversize body is a decision, not a transport failure.
        #expect(log.count == 2)
        #expect(await fetcher.lyrics(for: trackState()) == nil)
        #expect(log.count == 2)
    }

    @Test("A transient failure earns exactly one retry")
    func transientFailureRetriesOnce() async {
        let log = RequestLog()
        let fetcher = NowPlayingLyricsFetcher(transport: { request in
            log.record(request)
            throw URLError(.notConnectedToInternet)
        })
        #expect(await fetcher.lyrics(for: trackState()) == nil)
        #expect(log.count == 2)
    }

    // MARK: Store

    @MainActor
    @Test("The store caches per track key and merges concurrent asks")
    func storeCachesAndMerges() async {
        let gate = Gate()
        let store = NowPlayingLyricsStore(load: { _ in
            await gate.wait()
            return NowPlayingLyrics.parseLRC(syncedFixture)
        })

        async let first = store.lyrics(for: trackState())
        async let second = store.lyrics(for: trackState())
        await gate.open()
        let results = await (first, second)
        #expect(results.0.count == 2)
        #expect(results.1.count == 2)
        #expect(store.loadCount == 1)

        _ = await store.lyrics(for: trackState())
        #expect(store.loadCount == 1)

        // A miss is cached too, so an absent lyric is not re-fetched per tick.
        let empty = NowPlayingLyricsStore(load: { _ in nil })
        #expect(await empty.lyrics(for: trackState(title: "Other")).isEmpty)
        #expect(await empty.lyrics(for: trackState(title: "Other")).isEmpty)
        #expect(empty.loadCount == 1)
    }

    /// A miss used to be stored as a permanent empty array, which outlived and
    /// masked the fetcher's own 10-minute negative cache: one offline moment
    /// meant that track could never show lyrics again this session.
    @MainActor
    @Test("A cached miss expires on the same TTL as the fetcher's negative cache")
    func storeMissesExpire() async {
        let clock = ClockBox()
        let store = NowPlayingLyricsStore(load: { _ in nil }, now: { clock.now })

        #expect(await store.lyrics(for: trackState()).isEmpty)
        #expect(store.loadCount == 1)

        clock.advance(NowPlayingLyricsFetcher.negativeTTL - 1)
        #expect(await store.lyrics(for: trackState()).isEmpty)
        #expect(store.loadCount == 1, "a miss inside the TTL must not re-ask")

        clock.advance(2)
        #expect(await store.lyrics(for: trackState()).isEmpty)
        #expect(store.loadCount == 2, "a miss past the TTL must be retried")
    }

    /// The counterpart: a hit is kept for good, not re-fetched once the TTL that
    /// only governs misses rolls past.
    @MainActor
    @Test("A cached hit is never re-fetched")
    func storeHitsAreKept() async {
        let clock = ClockBox()
        let store = NowPlayingLyricsStore(
            load: { _ in NowPlayingLyrics.parseLRC(syncedFixture) },
            now: { clock.now }
        )

        #expect(await store.lyrics(for: trackState()).count == 2)
        clock.advance(NowPlayingLyricsFetcher.negativeTTL * 10)
        #expect(await store.lyrics(for: trackState()).count == 2)
        #expect(store.loadCount == 1)
    }
}
