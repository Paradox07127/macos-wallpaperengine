import Foundation
import os
import Testing
@testable import LiveWallpaper

// MARK: - Injected plumbing (transport counter, gate, clock, recording sink)

private final class RequestCounter: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String: Int]())
    func bump(_ key: String) { lock.withLock { $0[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { $0[key] ?? 0 } }
}

/// Holds gated transport responses until opened, to pin down overlap ordering.
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

private final class NowPlayingStateBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [MonitorNowPlayingState]())
    func append(_ state: MonitorNowPlayingState?) {
        guard let state else { return }
        lock.withLock { $0.append(state) }
    }

    var states: [MonitorNowPlayingState] { lock.withLock { $0 } }
    var count: Int { lock.withLock { $0.count } }
}

private actor RecordingNowPlayingSink: MonitorSnapshotSink {
    let box = NowPlayingStateBox()
    func updateSystem(_ snapshot: MonitorSystemSnapshot) async {}
    func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async {}
    func updateHealth(_ health: MonitorSourceHealth) async {}
    func updateNowPlaying(_ state: MonitorNowPlayingState?) async { box.append(state) }
}

/// Real endpoints answer with a content type, and the fetcher now requires one:
/// a 200 carrying HTML is not an oEmbed document and not a cover.
private func ok(
    _ request: URLRequest, _ data: Data, contentType: String = "application/json"
) -> (Data, URLResponse) {
    (data, HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": contentType]
    )!)
}

private func okImage(_ request: URLRequest, _ data: Data) -> (Data, URLResponse) {
    ok(request, data, contentType: "image/jpeg")
}

private func status(_ request: URLRequest, _ code: Int) -> (Data, URLResponse) {
    (Data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
}

/// Thread-safe recorder for the URLs a transport was actually asked for.
final class NowPlayingURLBox: @unchecked Sendable {
    // Every access goes through this lock; nothing else touches `storage`.
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func oembedJSON(thumbnail: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["thumbnail_url": thumbnail, "title": "x"])
}

private func itunesJSON(_ rows: [[String: String]]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["resultCount": rows.count, "results": rows])
}

private func spotifyState(
    trackID: String = "spotify:track:22ALg0cH8ADNGb9eK3RFCo",
    title: String = "CC···12yl"
) -> MonitorNowPlayingState {
    var state = MonitorNowPlayingState(phase: .playing, title: title)
    state.artist = "Sawano Hiroyuki"
    state.trackID = trackID
    state.playerBundleID = "com.spotify.client"
    return state
}

private func musicState() -> MonitorNowPlayingState {
    var state = MonitorNowPlayingState(phase: .playing, title: "ENDROLL")
    state.artist = "Yoohei Kawakami"
    state.album = "ENDROLL"
    state.playerBundleID = "com.apple.Music"
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

@Suite("Now Playing artwork fetcher")
struct NowPlayingArtworkFetcherTests {
    // MARK: URL construction and scoring (pure)

    /// Spotify's own dictionary carries the cover URL, so the oEmbed lookup is
    /// a round trip spent re-deriving what the player already knows. It only
    /// knows it once Automation consent exists, so oEmbed has to stay for
    /// everyone who has not granted it.
    @Test("a player-supplied cover URL is used instead of the oEmbed lookup")
    func playerURLBeatsOEmbed() async {
        let art = Data([0x89, 0x50, 0x4E, 0x47, 0x11])
        let seen = NowPlayingURLBox()
        let fetcher = NowPlayingArtworkFetcher(
            transport: { request in
                seen.append(request.url!.absoluteString)
                return okImage(request, art)
            },
            artworkURLProvider: { _ in URL(string: "https://i.scdn.co/image/direct") }
        )
        let data = await fetcher.artwork(for: spotifyState())
        #expect(data == art)
        #expect(seen.values == ["https://i.scdn.co/image/direct"])   // no oEmbed hop
    }

    @Test("without consent the oEmbed route still resolves the cover")
    func fallsBackToOEmbedWithoutConsent() async {
        let art = Data([0x89, 0x50, 0x4E, 0x47, 0x22])
        let seen = NowPlayingURLBox()
        let fetcher = NowPlayingArtworkFetcher(
            transport: { request in
                seen.append(request.url!.absoluteString)
                if request.url!.absoluteString.contains("oembed") {
                    return ok(request, oembedJSON(thumbnail: "https://i.scdn.co/image/fallback"))
                }
                return okImage(request, art)
            },
            artworkURLProvider: { _ in nil }
        )
        let data = await fetcher.artwork(for: spotifyState())
        #expect(data == art)
        #expect(seen.values.contains { $0.contains("oembed") })
    }

    /// "Spotify said so" is not a reason to fetch from an arbitrary host: the
    /// URL crosses a process boundary like any other input.
    @Test("a player-supplied URL off the allow-list is refused, not followed")
    func playerURLIsStillAllowListed() async {
        let seen = NowPlayingURLBox()
        let fetcher = NowPlayingArtworkFetcher(
            transport: { request in
                seen.append(request.url!.absoluteString)
                if request.url!.absoluteString.contains("oembed") {
                    return ok(request, oembedJSON(thumbnail: "https://i.scdn.co/image/fallback"))
                }
                return okImage(request, Data([0x89, 0x50, 0x4E, 0x47]))
            },
            artworkURLProvider: { _ in URL(string: "https://attacker.example/image") }
        )
        _ = await fetcher.artwork(for: spotifyState())
        #expect(!seen.values.contains { $0.contains("attacker.example") })
        #expect(seen.values.contains { $0.contains("oembed") })
    }

    @Test("oEmbed request URL matches the documented form character for character")
    func oembedDocumentForm() {
        let url = NowPlayingArtworkFetcher.spotifyOEmbedURL(trackID: "spotify:track:22ALg0cH8ADNGb9eK3RFCo")
        #expect(
            url?.absoluteString ==
                "https://open.spotify.com/oembed?url=https%3A%2F%2Fopen.spotify.com%2Ftrack%2F22ALg0cH8ADNGb9eK3RFCo"
        )
        #expect(NowPlayingArtworkFetcher.spotifyOEmbedURL(trackID: "spotify:album:22ALg0cH8ADNGb9eK3RFCo") == nil)
        #expect(NowPlayingArtworkFetcher.spotifyOEmbedURL(trackID: "spotify:track:") == nil)
        #expect(NowPlayingArtworkFetcher.spotifyOEmbedURL(trackID: "spotify:track:abc/../etc") == nil)
        #expect(NowPlayingArtworkFetcher.spotifyOEmbedURL(trackID: "garbage") == nil)
    }

    @Test("iTunes scoring picks the right album among same-name tracks")
    func itunesScoringPicksAlbum() {
        typealias Candidate = NowPlayingArtworkFetcher.ITunesCandidate
        // Shapes from the 2026-08-20 live probe: the right row lists every
        // collaborator in artistName; a same-name track sits on another album.
        let single = Candidate(
            artistName: "Yoohei Kawakami, SennaRin & Hiroyuki Sawano",
            trackName: "ENDROLL", collectionName: "ENDROLL", artworkUrl100: "single-100"
        )
        let compilation = Candidate(
            artistName: "Yoohei Kawakami, SennaRin & Hiroyuki Sawano",
            trackName: "ENDROLL", collectionName: "LOSTandFOUND", artworkUrl100: "comp-100"
        )
        let unrelated = Candidate(
            artistName: "Someone Else", trackName: "Other Song",
            collectionName: "Other", artworkUrl100: "other-100"
        )
        let best = NowPlayingArtworkFetcher.bestMatch(
            in: [unrelated, compilation, single],
            artist: "Yoohei Kawakami", title: "ENDROLL", album: "ENDROLL"
        )
        // single: artist containment 1 + title 2 + album 2 = 5; compilation = 3.
        #expect(best?.artworkUrl100 == "single-100")
        #expect(
            NowPlayingArtworkFetcher.matchScore(
                candidate: single, artist: "Yoohei Kawakami", title: "ENDROLL", album: "ENDROLL"
            ) == 5
        )
        #expect(
            NowPlayingArtworkFetcher.bestMatch(
                in: [unrelated], artist: "Yoohei Kawakami", title: "ENDROLL", album: "ENDROLL"
            ) == nil
        )
    }

    @Test("a title-only hit by another artist is rejected, not shown wrong")
    func itunesScoringRequiresArtistAgreement() {
        typealias Candidate = NowPlayingArtworkFetcher.ITunesCandidate
        // Common title, wrong artist: title equality alone scores > 0, but
        // when the notification names an artist that artist must also match.
        let wrongArtist = Candidate(
            artistName: "Someone Else", trackName: "Intro",
            collectionName: "Their Album", artworkUrl100: "wrong-100"
        )
        #expect(
            NowPlayingArtworkFetcher.bestMatch(
                in: [wrongArtist], artist: "Yoohei Kawakami", title: "Intro", album: nil
            ) == nil
        )
        // Without an artist in the notification the title match may stand.
        #expect(
            NowPlayingArtworkFetcher.bestMatch(
                in: [wrongArtist], artist: nil, title: "Intro", album: nil
            )?.artworkUrl100 == "wrong-100"
        )
    }

    // MARK: Network discipline

    @Test("concurrent requests for one track key merge into one transport hit")
    func concurrentSameKeyMerges() async {
        let counter = RequestCounter()
        let gate = Gate()
        let image = Data(repeating: 7, count: 64)
        let fetcher = NowPlayingArtworkFetcher(transport: { request in
            let url = request.url!.absoluteString
            if url.contains("oembed") {
                counter.bump("oembed")
                await gate.wait()
                return ok(request, oembedJSON(thumbnail: "https://i.scdn.co/image/thumb"))
            }
            counter.bump("image")
            return okImage(request, image)
        })

        async let first = fetcher.artwork(for: spotifyState())
        async let second = fetcher.artwork(for: spotifyState())
        #expect(await waitUntil { counter.count("oembed") >= 1 })
        await gate.open()
        let results = await (first, second)
        #expect(results.0 == image)
        #expect(results.1 == image)
        #expect(counter.count("oembed") == 1)
        #expect(counter.count("image") == 1)
    }

    @Test("failure enters the negative cache; TTL blocks retries until it expires")
    func negativeCacheTTL() async {
        let counter = RequestCounter()
        let clock = ClockBox()
        let fetcher = NowPlayingArtworkFetcher(
            transport: { _ in
                counter.bump("any")
                throw URLError(.notConnectedToInternet)
            },
            now: { clock.now }
        )

        #expect(await fetcher.artwork(for: spotifyState()) == nil)
        // One transient failure earns exactly one retry.
        #expect(counter.count("any") == 2)

        #expect(await fetcher.artwork(for: spotifyState()) == nil)
        #expect(counter.count("any") == 2)

        clock.advance(NowPlayingArtworkFetcher.negativeTTL + 1)
        #expect(await fetcher.artwork(for: spotifyState()) == nil)
        #expect(counter.count("any") == 4)
    }

    @Test("images over 2MB are abandoned without retry and negative-cached")
    func oversizeImageAbandoned() async {
        let counter = RequestCounter()
        let oversize = Data(count: NowPlayingArtworkFetcher.maxImageBytes + 1)
        let fetcher = NowPlayingArtworkFetcher(transport: { request in
            let url = request.url!.absoluteString
            if url.contains("oembed") {
                counter.bump("oembed")
                return ok(request, oembedJSON(thumbnail: "https://i.scdn.co/image/big"))
            }
            counter.bump("image")
            return okImage(request, oversize)
        })

        #expect(await fetcher.artwork(for: spotifyState()) == nil)
        #expect(counter.count("image") == 1)
        #expect(await fetcher.artwork(for: spotifyState()) == nil)
        #expect(counter.count("image") == 1)
    }

    @Test("iTunes path upgrades to 600x600bb and falls back to the 100 URL")
    func itunesUpgradeAndFallback() async {
        let counter = RequestCounter()
        let art600 = Data(repeating: 6, count: 32)
        let art100 = Data(repeating: 1, count: 16)
        let row = [
            "artistName": "Yoohei Kawakami", "trackName": "ENDROLL",
            "collectionName": "ENDROLL", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/a/100x100bb.jpg",
        ]
        let upgrading = NowPlayingArtworkFetcher(transport: { request in
            let url = request.url!.absoluteString
            if url.contains("itunes.apple.com") { return ok(request, itunesJSON([row])) }
            if url.contains("600x600bb") {
                counter.bump("600")
                return okImage(request, art600)
            }
            counter.bump("100")
            return okImage(request, art100)
        })
        #expect(await upgrading.artwork(for: musicState()) == art600)
        #expect(counter.count("100") == 0)

        let fallingBack = NowPlayingArtworkFetcher(transport: { request in
            let url = request.url!.absoluteString
            if url.contains("itunes.apple.com") { return ok(request, itunesJSON([row])) }
            if url.contains("600x600bb") { return status(request, 404) }
            return okImage(request, art100)
        })
        #expect(await fallingBack.artwork(for: musicState()) == art100)
    }

    // MARK: Source integration (generation token, stop)

    @MainActor
    @Test("a slow response for the previous track is discarded on track change")
    func slowPreviousTrackResponseDiscarded() async {
        let gate = Gate()
        let artA = Data(repeating: 0xA, count: 8)
        let artB = Data(repeating: 0xB, count: 8)
        let idA = "spotify:track:AAAAAAAAAAAAAAAAAAAAAA"
        let idB = "spotify:track:BBBBBBBBBBBBBBBBBBBBBB"
        let fetcher = NowPlayingArtworkFetcher(transport: { request in
            let url = request.url!.absoluteString
            if url.contains("oembed") {
                if url.contains("AAAAAAAAAAAAAAAAAAAAAA") {
                    await gate.wait()
                    return ok(request, oembedJSON(thumbnail: "https://i.scdn.co/image/A"))
                }
                return ok(request, oembedJSON(thumbnail: "https://i.scdn.co/image/B"))
            }
            return okImage(request, url.hasSuffix("/A") ? artA : artB)
        })

        let monitor = NowPlayingMonitor(registersObservers: false, runningBundleIDs: { [] })
        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(monitor: monitor, artworkFetcher: fetcher)
        await source.start(sink: sink)

        monitor.ingest(
            name: "com.spotify.client.PlaybackStateChanged",
            userInfo: ["Name": "Track A", "Player State": "Playing", "Track ID": idA]
        )
        #expect(await waitUntil { sink.box.states.contains { $0.title == "Track A" } })

        monitor.ingest(
            name: "com.spotify.client.PlaybackStateChanged",
            userInfo: ["Name": "Track B", "Player State": "Playing", "Track ID": idB]
        )
        #expect(await waitUntil { sink.box.states.contains { $0.artwork == artB } })

        await gate.open()
        _ = await waitUntil(timeout: 0.3) { false } // settle
        #expect(!sink.box.states.contains { $0.artwork == artA })
        #expect(sink.box.states.last?.title == "Track B")
        await source.stop()
    }

    @MainActor
    @Test("a fetch completing after stop publishes nothing")
    func fetchAfterStopPublishesNothing() async {
        let gate = Gate()
        let fetcher = NowPlayingArtworkFetcher(transport: { request in
            let url = request.url!.absoluteString
            if url.contains("oembed") {
                await gate.wait()
                return ok(request, oembedJSON(thumbnail: "https://i.scdn.co/image/thumb"))
            }
            return okImage(request, Data(repeating: 9, count: 8))
        })

        let monitor = NowPlayingMonitor(registersObservers: false, runningBundleIDs: { [] })
        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(monitor: monitor, artworkFetcher: fetcher)
        await source.start(sink: sink)
        monitor.ingest(
            name: "com.spotify.client.PlaybackStateChanged",
            userInfo: [
                "Name": "Stopped Track", "Player State": "Playing",
                "Track ID": "spotify:track:CCCCCCCCCCCCCCCCCCCCCC",
            ]
        )
        #expect(await waitUntil { sink.box.states.contains { $0.title == "Stopped Track" } })

        await source.stop()
        let countAtStop = sink.box.count
        await gate.open()
        _ = await waitUntil(timeout: 0.3) { false } // settle
        #expect(sink.box.count == countAtStop)
        #expect(!sink.box.states.contains { $0.artwork != nil })
    }

    // MARK: - Origin policy

    @Test("Only the named endpoints and their cover CDNs are reachable")
    func originAllowList() {
        func url(_ string: String) -> URL? { URL(string: string) }
        #expect(NowPlayingNetwork.isAllowed(url("https://open.spotify.com/oembed?url=x"), for: .api))
        #expect(NowPlayingNetwork.isAllowed(url("https://itunes.apple.com/search?term=x"), for: .api))
        #expect(NowPlayingNetwork.isAllowed(url("https://lrclib.net/api/get"), for: .api))
        #expect(!NowPlayingNetwork.isAllowed(url("https://open.spotify.com/oembed"), for: .artwork))
        #expect(NowPlayingNetwork.isAllowed(url("https://i.scdn.co/image/a"), for: .artwork))
        #expect(NowPlayingNetwork.isAllowed(url("https://is1-ssl.mzstatic.com/image/a"), for: .artwork))

        // A suffix match, not a substring one.
        #expect(!NowPlayingNetwork.isAllowed(url("https://evil-scdn.co/image/a"), for: .artwork))
        #expect(!NowPlayingNetwork.isAllowed(url("https://scdn.co.evil.example/a"), for: .artwork))
        #expect(!NowPlayingNetwork.isAllowed(url("https://attacker.example/a"), for: .artwork))

        // Shapes that make a "trusted host" string lie.
        #expect(!NowPlayingNetwork.isAllowed(url("http://i.scdn.co/image/a"), for: .artwork))
        #expect(!NowPlayingNetwork.isAllowed(url("file:///etc/passwd"), for: .artwork))
        #expect(!NowPlayingNetwork.isAllowed(url("https://127.0.0.1/a"), for: .artwork))
        #expect(!NowPlayingNetwork.isAllowed(url("https://i.scdn.co:8080/a"), for: .artwork))
        #expect(!NowPlayingNetwork.isAllowed(url("https://i.scdn.co@attacker.example/a"), for: .artwork))
        #expect(!NowPlayingNetwork.isAllowed(nil, for: .api))
    }

    @Test("A thumbnail URL pointing off the CDN list is never requested")
    func offListThumbnailIsNotDownloaded() async {
        let counter = RequestCounter()
        let fetcher = NowPlayingArtworkFetcher(transport: { request in
            let url = request.url!.absoluteString
            if url.contains("oembed") {
                counter.bump("oembed")
                return ok(request, oembedJSON(thumbnail: "https://attacker.example/cover.jpg"))
            }
            counter.bump("image")
            return okImage(request, Data([1, 2, 3]))
        })

        #expect(await fetcher.artwork(for: spotifyState()) == nil)
        #expect(counter.count("oembed") == 1)
        #expect(counter.count("image") == 0, "the fetcher must not follow an arbitrary URL from the API")
    }

    @Test("A 200 that is not an image is not cached as a cover")
    func nonImageContentTypeIsRejected() async {
        let fetcher = NowPlayingArtworkFetcher(transport: { request in
            let url = request.url!.absoluteString
            if url.contains("oembed") {
                return ok(request, oembedJSON(thumbnail: "https://i.scdn.co/image/thumb"))
            }
            return ok(request, Data("<html>login</html>".utf8), contentType: "text/html")
        })
        #expect(await fetcher.artwork(for: spotifyState()) == nil)
    }

    @Test("A response that ended up off the allow-list is not read as the endpoint's answer")
    func redirectedResponseIsRejected() async {
        let fetcher = NowPlayingArtworkFetcher(transport: { request in
            // What a followed redirect looks like: the body arrives, but the
            // URL the response reports is somewhere else entirely.
            let response = HTTPURLResponse(
                url: URL(string: "https://attacker.example/oembed")!,
                statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (oembedJSON(thumbnail: "https://i.scdn.co/image/thumb"), response)
        })
        #expect(await fetcher.artwork(for: spotifyState()) == nil)
    }

    @Test("Metadata bodies are bounded too, not just images")
    func oversizeMetadataIsRefused() async {
        let bloated = Data(repeating: 0x20, count: NowPlayingArtworkFetcher.maxMetadataBytes + 1)
        let fetcher = NowPlayingArtworkFetcher(transport: { request in ok(request, bloated) })
        #expect(await fetcher.artwork(for: spotifyState()) == nil)
    }
}
