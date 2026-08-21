import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

final class NowPlayingWidgetLayoutTests: XCTestCase {
    private typealias Layout = NowPlayingWidgetLayout
    private typealias Component = NowPlayingWidgetLayout.Component
    private typealias Style = NowPlayingWidgetView.Style

    // MARK: Fixtures (the three acceptance shapes from the plan)

    /// Spotify while playing: every field present.
    private func fullState() -> MonitorNowPlayingState {
        var state = MonitorNowPlayingState(phase: .playing, title: "ENDROLL")
        state.artist = "Yoohei Kawakami"
        state.album = "Q&A"
        state.duration = 245
        state.position = 61.5
        state.positionSampledAt = 1_700_000_000
        state.trackID = "player:track:abc123"
        state.artwork = Data([0xFF, 0xD8, 0xFF])
        return state
    }

    /// Apple Music shape: duration but no position, no track ID, no artwork.
    private func durationOnlyState() -> MonitorNowPlayingState {
        var state = MonitorNowPlayingState(phase: .playing, title: "ENDROLL")
        state.artist = "Yoohei Kawakami"
        state.album = "Q&A"
        state.duration = 245
        return state
    }

    private func titleOnlyState() -> MonitorNowPlayingState {
        MonitorNowPlayingState(phase: .playing, title: "Untitled Stream")
    }

    /// Options default to "user wants everything", so every expectation below
    /// still reads as a statement about the fields the player sent.
    private func resolve(
        _ state: MonitorNowPlayingState?,
        _ size: MonitorWidgetSize,
        _ style: Style,
        isEditing: Bool = false,
        reduceMotion: Bool = false,
        options: NowPlayingOptions = NowPlayingOptions(),
        canControl: Bool = false,
        hovering: Bool = false,
        hasLyrics: Bool = false
    ) -> Layout {
        var options = options
        options.style = style
        return Layout.resolve(
            state: state, size: size, options: options, isEditing: isEditing,
            reduceMotion: reduceMotion, canControl: canControl, hovering: hovering,
            hasLyrics: hasLyrics
        )
    }

    // MARK: Lyrics

    /// Same AND rule as every other component, plus a size floor: the small
    /// tile has no room for a line of text under the title.
    func testLyricsNeedBothTheDataAndTheSwitch() {
        var wanted = NowPlayingOptions()
        wanted.showLyrics = true
        let off = NowPlayingOptions()

        for style in Style.allCases {
            XCTAssertFalse(
                resolve(fullState(), .large, style, options: off, hasLyrics: true)
                    .visible.contains(.lyrics),
                "\(style): the switch is off"
            )
            XCTAssertFalse(
                resolve(fullState(), .large, style, options: wanted, hasLyrics: false)
                    .visible.contains(.lyrics),
                "\(style): the track has no lyrics"
            )
            XCTAssertFalse(
                resolve(fullState(), .small, style, options: wanted, hasLyrics: true)
                    .visible.contains(.lyrics),
                "\(style): small tiles never carry lyrics"
            )
            for size in [MonitorWidgetSize.medium, .large] {
                XCTAssertTrue(
                    resolve(fullState(), size, style, options: wanted, hasLyrics: true)
                        .visible.contains(.lyrics),
                    "\(style) \(size)"
                )
            }
        }

        // A paused track still shows its words; only the tile dims.
        var paused = fullState()
        paused.phase = .paused
        XCTAssertTrue(
            resolve(paused, .large, .poster, options: wanted, hasLyrics: true).visible.contains(.lyrics)
        )
    }

    func testLyricsRowCountFollowsTheTileSize() {
        var options = NowPlayingOptions()
        options.showLyrics = true
        XCTAssertEqual(Layout.lyricsLineCount(for: .large, options: options), 3)
        XCTAssertEqual(Layout.lyricsLineCount(for: .medium, options: options), 1)
        XCTAssertEqual(Layout.lyricsLineCount(for: .small, options: options), 0)

        // The row-count option only reaches the large tile.
        options.lyricsLines = 1
        XCTAssertEqual(Layout.lyricsLineCount(for: .large, options: options), 1)
        XCTAssertEqual(Layout.lyricsLineCount(for: .medium, options: options), 1)
    }

    // MARK: Full matrix — visible components per state × style × size

    func testFullFieldsMatrix() {
        let state = fullState()
        let expected: [Style: [MonitorWidgetSize: Set<Component>]] = [
            .poster: [
                .small: [.title, .artistLine, .progress, .timeText],
                .medium: [.title, .artistLine, .albumLine, .artworkThumb, .progress, .timeText],
                .large: [.title, .artistLine, .albumLine, .artworkThumb, .progress, .timeText],
            ],
            .vinyl: [
                .small: [.title, .disc, .discArtwork, .progress],
                .medium: [.title, .disc, .discArtwork, .artistLine, .albumLine, .timeText, .progress],
                .large: [.title, .disc, .discArtwork, .artistLine, .albumLine, .timeText, .progress],
            ],
            .aurora: [
                .small: [.title, .glow, .progress],
                .medium: [.title, .glow, .artistLine, .progress],
                .large: [.title, .glow, .artistLine, .progress],
            ],
        ]
        for (style, bySize) in expected {
            for (size, visible) in bySize {
                let layout = resolve(state, size, style)
                XCTAssertTrue(layout.renders, "\(style) \(size)")
                XCTAssertEqual(layout.visible, visible, "\(style) \(size)")
                XCTAssertTrue(layout.motion, "\(style) \(size)")
                XCTAssertFalse(layout.dimmed, "\(style) \(size)")
            }
        }
    }

    /// No position → no progress anywhere; total length only where the style keeps it.
    func testDurationWithoutPositionMatrix() {
        let state = durationOnlyState()
        let expected: [Style: [MonitorWidgetSize: Set<Component>]] = [
            .poster: [
                .small: [.title, .artistLine],
                .medium: [.title, .artistLine, .albumLine],
                .large: [.title, .artistLine, .albumLine],
            ],
            .vinyl: [
                .small: [.title, .disc],
                .medium: [.title, .disc, .artistLine, .albumLine, .timeText],
                .large: [.title, .disc, .artistLine, .albumLine, .timeText],
            ],
            .aurora: [
                .small: [.title, .glow],
                .medium: [.title, .glow, .artistLine],
                .large: [.title, .glow, .artistLine],
            ],
        ]
        for (style, bySize) in expected {
            for (size, visible) in bySize {
                let layout = resolve(state, size, style)
                XCTAssertEqual(layout.visible, visible, "\(style) \(size)")
                XCTAssertFalse(layout.visible.contains(.progress), "\(style) \(size)")
            }
        }
    }

    /// Title-only extreme: nothing optional leaks into any style at any size.
    func testTitleOnlyMatrix() {
        let state = titleOnlyState()
        let expected: [Style: Set<Component>] = [
            .poster: [.title],
            .vinyl: [.title, .disc],
            .aurora: [.title, .glow],
        ]
        for (style, visible) in expected {
            for size in MonitorWidgetSize.allCases {
                let layout = resolve(state, size, style)
                XCTAssertEqual(layout.visible, visible, "\(style) \(size)")
            }
        }
    }

    // MARK: Missing == absent, not placeholder (empty strings count as missing)

    func testEmptyOptionalFieldsAreNotVisible() {
        var state = titleOnlyState()
        state.artist = ""
        state.album = ""
        state.artwork = Data()
        for style in Style.allCases {
            let layout = resolve(state, .large, style)
            XCTAssertFalse(layout.visible.contains(.artistLine), "\(style)")
            XCTAssertFalse(layout.visible.contains(.albumLine), "\(style)")
            XCTAssertFalse(layout.visible.contains(.artworkThumb), "\(style)")
            XCTAssertFalse(layout.visible.contains(.discArtwork), "\(style)")
        }
    }

    // MARK: No-track phases — invisible off duty, placeholder while editing

    func testNoTrackPhasesDoNotRenderOutsideEditMode() {
        let states: [MonitorNowPlayingState?] = [
            nil,
            MonitorNowPlayingState(phase: .awaitingFirstEvent, title: ""),
            MonitorNowPlayingState(phase: .noPlayer, title: ""),
        ]
        for state in states {
            for style in Style.allCases {
                let layout = resolve(state, .medium, style, isEditing: false)
                XCTAssertFalse(layout.renders, "\(style) \(String(describing: state?.phase))")
                XCTAssertTrue(layout.visible.isEmpty, "\(style)")
            }
        }
    }

    func testNoTrackPhasesRenderPlaceholderWhileEditing() {
        let states: [MonitorNowPlayingState?] = [
            nil,
            MonitorNowPlayingState(phase: .awaitingFirstEvent, title: ""),
            MonitorNowPlayingState(phase: .noPlayer, title: ""),
        ]
        for state in states {
            for style in Style.allCases {
                let layout = resolve(state, .medium, style, isEditing: true)
                XCTAssertTrue(layout.renders, "\(style)")
                XCTAssertEqual(layout.visible, [.placeholder], "\(style)")
                XCTAssertFalse(layout.motion, "\(style)")
            }
        }
    }

    // MARK: Presence choreography — paused dims and freezes, reduceMotion freezes

    func testPausedDimsAndFreezesMotion() {
        var state = fullState()
        state.phase = .paused
        for style in Style.allCases {
            let layout = resolve(state, .medium, style)
            XCTAssertTrue(layout.renders, "\(style)")
            XCTAssertTrue(layout.dimmed, "\(style)")
            XCTAssertFalse(layout.motion, "\(style)")
        }
    }

    func testPausedAuroraLosesTheGlow() {
        var state = fullState()
        state.phase = .paused
        let layout = resolve(state, .medium, .aurora)
        XCTAssertFalse(layout.visible.contains(.glow))
        XCTAssertTrue(layout.visible.contains(.title))
    }

    func testReduceMotionFreezesMotionWhilePlaying() {
        let layout = resolve(fullState(), .medium, .vinyl, reduceMotion: true)
        XCTAssertTrue(layout.renders)
        XCTAssertFalse(layout.motion)
        XCTAssertFalse(layout.dimmed)
    }

    // MARK: Visibility is data AND user intent

    /// All four quadrants of the AND rule, for every optional component that
    /// has a switch. Neither half alone puts anything on screen.
    func testVisibilityIsDataAndUserIntent() {
        let cases: [(Component, Style, WritableKeyPath<NowPlayingOptions, Bool>)] = [
            (.artworkThumb, .poster, \.showArtwork),
            (.artistLine, .poster, \.showArtist),
            (.albumLine, .poster, \.showAlbum),
            (.progress, .poster, \.showProgress),
            (.discArtwork, .vinyl, \.showArtwork),
            (.artistLine, .vinyl, \.showArtist),
            (.albumLine, .vinyl, \.showAlbum),
            (.progress, .aurora, \.showProgress),
        ]
        for (component, style, switchPath) in cases {
            let on = NowPlayingOptions()
            var off = NowPlayingOptions()
            off[keyPath: switchPath] = false

            // data ✓ switch ✓
            XCTAssertTrue(
                resolve(fullState(), .large, style, options: on).visible.contains(component),
                "\(component) in \(style) with the field present and the switch on"
            )
            // data ✓ switch ✗
            XCTAssertFalse(
                resolve(fullState(), .large, style, options: off).visible.contains(component),
                "\(component) in \(style) survived its switch being off"
            )
            // data ✗ switch ✓ — and ✗/✗
            let bare = titleOnlyState()
            XCTAssertFalse(
                resolve(bare, .large, style, options: on).visible.contains(component),
                "\(component) in \(style) appeared without the player sending the field"
            )
            XCTAssertFalse(
                resolve(bare, .large, style, options: off).visible.contains(component),
                "\(component) in \(style) appeared with neither half"
            )
        }
    }

    /// Poster's readout is elapsed/total, so it goes with the progress switch;
    /// vinyl's is the total length alone and stays.
    func testProgressSwitchTakesPosterTimeTextButNotVinylDuration() {
        var off = NowPlayingOptions()
        off.showProgress = false

        let poster = resolve(fullState(), .large, .poster, options: off)
        XCTAssertFalse(poster.visible.contains(.timeText))
        XCTAssertFalse(poster.visible.contains(.progress))

        let vinyl = resolve(fullState(), .large, .vinyl, options: off)
        XCTAssertTrue(vinyl.visible.contains(.timeText))
        XCTAssertFalse(vinyl.visible.contains(.progress))
    }

    /// The platter is the vinyl style itself, not the cover: hiding artwork
    /// leaves the record spinning with a plain label.
    func testHidingArtworkKeepsTheVinylPlatter() {
        var off = NowPlayingOptions()
        off.showArtwork = false
        let layout = resolve(fullState(), .large, .vinyl, options: off)
        XCTAssertTrue(layout.visible.contains(.disc))
        XCTAssertFalse(layout.visible.contains(.discArtwork))
    }

    // MARK: Marquee

    func testMarqueeNeedsBothTheSwitchAndMotion() {
        var on = NowPlayingOptions()
        on.marquee = true

        XCTAssertTrue(resolve(fullState(), .medium, .poster, options: on).marquee)
        XCTAssertFalse(
            resolve(fullState(), .medium, .poster, options: NowPlayingOptions()).marquee,
            "marquee ran without the user asking for it"
        )
        XCTAssertFalse(
            resolve(fullState(), .medium, .poster, reduceMotion: true, options: on).marquee,
            "marquee kept moving under reduce motion"
        )

        var paused = fullState()
        paused.phase = .paused
        XCTAssertFalse(resolve(paused, .medium, .poster, options: on).marquee)
        XCTAssertFalse(resolve(nil, .medium, .poster, isEditing: true, options: on).marquee)
    }

    // MARK: Transport controls — data AND user intent AND the pointer

    /// Three terms, and every one of them can veto on its own.
    func testControlsNeedTheTableTheSwitchAndThePointer() {
        var off = NowPlayingOptions()
        off.showControls = false

        for style in Style.allCases {
            XCTAssertTrue(
                resolve(fullState(), .large, style, canControl: true, hovering: true)
                    .visible.contains(.controls),
                "\(style) hid the controls with all three terms satisfied"
            )
            XCTAssertFalse(
                resolve(fullState(), .large, style, canControl: false, hovering: true)
                    .visible.contains(.controls),
                "\(style) offered controls for a player it cannot drive"
            )
            XCTAssertFalse(
                resolve(fullState(), .large, style, options: off, canControl: true, hovering: true)
                    .visible.contains(.controls),
                "\(style) kept controls after the user switched them off"
            )
            XCTAssertFalse(
                resolve(fullState(), .large, style, canControl: true, hovering: false)
                    .visible.contains(.controls),
                "\(style) showed controls with the pointer away"
            )
        }
    }

    /// Paused is exactly when the play button matters most.
    /// The transport row must occupy the same space whether or not the pointer
    /// is over the tile. Gating its *layout* on hover made arriving with the
    /// pointer reflow the stack, which slid the button out from under the
    /// click that was aiming at it.
    func testControlsReserveTheirSpaceRegardlessOfHover() {
        for style in Style.allCases {
            let hovered = resolve(fullState(), .large, style, canControl: true, hovering: true)
            let idle = resolve(fullState(), .large, style, canControl: true, hovering: false)
            XCTAssertTrue(hovered.controlsAllowed, "\(style) hovered")
            XCTAssertTrue(
                idle.controlsAllowed,
                "\(style): the row must stay laid out so hover only fades it"
            )
            XCTAssertTrue(hovered.visible.contains(.controls))
            XCTAssertFalse(idle.visible.contains(.controls), "\(style): idle must not paint them")
        }
    }

    /// The three cases that genuinely have no row: no permission, switch off,
    /// edit mode. Those may collapse it — nothing can be clicked there anyway.
    func testControlsClaimNoSpaceWhenTheyCanNeverAppear() {
        var off = NowPlayingOptions()
        off.showControls = false
        XCTAssertFalse(resolve(fullState(), .large, .poster, canControl: false).controlsAllowed)
        XCTAssertFalse(
            resolve(fullState(), .large, .poster, options: off, canControl: true).controlsAllowed
        )
        XCTAssertFalse(
            resolve(fullState(), .large, .poster, isEditing: true, canControl: true).controlsAllowed
        )
    }

    func testControlsSurviveThePausedDim() {
        var state = fullState()
        state.phase = .paused
        let layout = resolve(state, .large, .poster, canControl: true, hovering: true)
        XCTAssertTrue(layout.visible.contains(.controls))
        XCTAssertTrue(layout.dimmed)
    }

    func testNoTrackNeverShowsControls() {
        let states: [MonitorNowPlayingState?] = [nil, MonitorNowPlayingState(phase: .noPlayer, title: "")]
        for state in states {
            for editing in [true, false] {
                let layout = resolve(
                    state, .medium, .poster, isEditing: editing, canControl: true, hovering: true
                )
                XCTAssertFalse(layout.visible.contains(.controls))
            }
        }
    }

    /// The board-level gate that lets any of this reach the tile outside edit
    /// mode. Every other widget must stay click-through.
    func testOnlyTheNowPlayingLayerAsksForThePointer() {
        var options = NowPlayingOptions()
        options.showControls = false
        options.seekOnProgressDrag = false

        XCTAssertTrue(WidgetFactory.wantsPointerInteraction(
            MonitorWidgetPlacement(kind: .nowPlaying)
        ))
        XCTAssertFalse(WidgetFactory.wantsPointerInteraction(
            MonitorWidgetPlacement(kind: .nowPlaying, options: options.applied(to: [:]))
        ))
        for kind in MonitorWidgetKind.allCases where kind != .nowPlaying {
            XCTAssertFalse(
                WidgetFactory.wantsPointerInteraction(MonitorWidgetPlacement(kind: kind)),
                "\(kind) started taking clicks off the desktop"
            )
        }
    }

    /// While arranging the board a click means "grab this layer"; the board's
    /// drag gesture runs alongside subview gestures, so a live button under the
    /// pointer would fire mid-drag.
    func testEditModeHasNoControlsAndNoScrub() {
        let layout = resolve(
            fullState(), .large, .poster, isEditing: true, canControl: true, hovering: true
        )
        XCTAssertFalse(layout.visible.contains(.controls))
        XCTAssertFalse(layout.seekable)
    }

    func testSmallTilesKeepOnlyPlayPause() {
        XCTAssertEqual(Layout.controlButtons(for: .small), [.playPause])
        XCTAssertEqual(Layout.controlButtons(for: .medium), [.previous, .playPause, .next])
        XCTAssertEqual(Layout.controlButtons(for: .large), [.previous, .playPause, .next])
    }

    // MARK: Scrub

    /// Every term of the seek rule, one veto at a time.
    func testSeekableNeedsProgressIntentControlAndDuration() {
        XCTAssertTrue(resolve(fullState(), .large, .poster, canControl: true).seekable)

        var noSeek = NowPlayingOptions()
        noSeek.seekOnProgressDrag = false
        XCTAssertFalse(resolve(fullState(), .large, .poster, options: noSeek, canControl: true).seekable)

        var noProgress = NowPlayingOptions()
        noProgress.showProgress = false
        XCTAssertFalse(
            resolve(fullState(), .large, .poster, options: noProgress, canControl: true).seekable
        )

        XCTAssertFalse(
            resolve(fullState(), .large, .poster, canControl: false).seekable,
            "a player we cannot drive offered a scrub"
        )

        // Apple Music's shape: a duration but no position, so no progress line
        // and nothing to scrub — and the player-agnostic reason is the field.
        XCTAssertFalse(resolve(durationOnlyState(), .large, .poster, canControl: true).seekable)

        var noDuration = fullState()
        noDuration.duration = nil
        XCTAssertFalse(
            resolve(noDuration, .large, .poster, canControl: true).seekable,
            "a scrub without a duration has no scale"
        )
    }

    /// Vinyl draws progress as a ring around a spinning platter, which is a
    /// readout rather than a scrub target.
    func testOnlyTheLinearStylesAreSeekable() {
        XCTAssertTrue(resolve(fullState(), .large, .poster, canControl: true).seekable)
        XCTAssertTrue(resolve(fullState(), .large, .aurora, canControl: true).seekable)
        XCTAssertFalse(resolve(fullState(), .large, .vinyl, canControl: true).seekable)
    }

    // MARK: Optimistic seek position

    func testSeekDraftWinsUntilThePlayerReportsAFresherPosition() {
        var state = fullState()
        state.position = 60
        state.positionSampledAt = 1_700_000_000
        let landedAt = Date(timeIntervalSince1970: 1_700_000_005)
        let draft = Layout.SeekDraft(seconds: 200, landedAt: landedAt)

        // Draft advances on the same wall clock as a real position.
        XCTAssertEqual(
            Layout.displayPosition(
                state: state, draft: draft, now: Date(timeIntervalSince1970: 1_700_000_015)
            ),
            210
        )

        // A report sampled after the drag lands supersedes it.
        state.positionSampledAt = 1_700_000_006
        state.position = 12
        XCTAssertEqual(
            Layout.displayPosition(
                state: state, draft: draft, now: Date(timeIntervalSince1970: 1_700_000_016)
            ),
            22
        )
    }

    func testSeekDraftIsFrozenWhilePausedAndClampedToDuration() {
        var state = fullState()
        state.phase = .paused
        state.duration = 245
        state.positionSampledAt = 1_700_000_000
        let draft = Layout.SeekDraft(seconds: 200, landedAt: Date(timeIntervalSince1970: 1_700_000_005))
        XCTAssertEqual(
            Layout.displayPosition(
                state: state, draft: draft, now: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            200
        )

        var playing = state
        playing.phase = .playing
        XCTAssertEqual(
            Layout.displayPosition(
                state: playing, draft: draft, now: Date(timeIntervalSince1970: 1_700_000_500)
            ),
            245
        )
    }

    func testWithoutADraftTheRealPositionIsUsed() {
        var state = fullState()
        state.position = 60
        state.positionSampledAt = 1_700_000_000
        let now = Date(timeIntervalSince1970: 1_700_000_010)
        XCTAssertEqual(Layout.displayPosition(state: state, draft: nil, now: now), 70)
    }

    // MARK: Style option parsing

    func testStyleParsingDefaultsToPoster() {
        XCTAssertEqual(NowPlayingWidgetView.style([:]), .poster)
        XCTAssertEqual(NowPlayingWidgetView.style(["style": .string("garbage")]), .poster)
        XCTAssertEqual(NowPlayingWidgetView.style(["style": .string("vinyl")]), .vinyl)
        XCTAssertEqual(NowPlayingWidgetView.style(["style": .string("aurora")]), .aurora)
    }

    func testStyleDraftDropsKeyOnDefault() {
        let placement = MonitorWidgetPlacement(kind: .nowPlaying)
        let vinyl = MonitorWidgetDraft.settingNowPlayingStyle(.vinyl, on: placement)
        XCTAssertEqual(vinyl.options["style"]?.stringValue, "vinyl")
        let back = MonitorWidgetDraft.settingNowPlayingStyle(.poster, on: vinyl)
        XCTAssertNil(back.options["style"])
    }

    // MARK: Wall-clock interpolation (invariant 5)

    func testInterpolationAdvancesWhilePlaying() {
        var state = fullState()
        state.position = 60
        state.positionSampledAt = 1_700_000_000
        let now = Date(timeIntervalSince1970: 1_700_000_010)
        XCTAssertEqual(NowPlayingWidgetLayout.interpolatedPosition(state: state, now: now), 70)
    }

    func testInterpolationFrozenWhilePaused() {
        var state = fullState()
        state.phase = .paused
        state.position = 60
        state.positionSampledAt = 1_700_000_000
        let now = Date(timeIntervalSince1970: 1_700_000_099)
        XCTAssertEqual(NowPlayingWidgetLayout.interpolatedPosition(state: state, now: now), 60)
    }

    func testInterpolationClampsToDuration() {
        var state = fullState()
        state.position = 240
        state.duration = 245
        state.positionSampledAt = 1_700_000_000
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        XCTAssertEqual(NowPlayingWidgetLayout.interpolatedPosition(state: state, now: now), 245)
    }

    func testInterpolationNilWithoutPosition() {
        let state = durationOnlyState()
        XCTAssertNil(NowPlayingWidgetLayout.interpolatedPosition(state: state, now: Date()))
    }

    // MARK: Seek outcome

    private static let landedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func outcome(
        _ failure: NowPlayingControlFailure?,
        committed: String = "track-a",
        current: String = "track-a"
    ) -> NowPlayingWidgetLayout.SeekOutcome {
        NowPlayingWidgetLayout.seekOutcome(
            failure: failure, committedKey: committed, currentKey: current,
            seconds: 42, landedAt: Self.landedAt
        )
    }

    func testSuccessfulSeekCommitsTheDraft() {
        XCTAssertEqual(
            outcome(nil),
            .commit(NowPlayingWidgetLayout.SeekDraft(seconds: 42, landedAt: Self.landedAt))
        )
    }

    /// Throttled means the identical seek is already on its way, so the position
    /// the user asked for is the truth — clearing the draft snapped the playhead
    /// back to where it was before the drag.
    func testThrottledSeekKeepsTheDraft() {
        XCTAssertEqual(
            outcome(.throttled),
            .commit(NowPlayingWidgetLayout.SeekDraft(seconds: 42, landedAt: Self.landedAt))
        )
    }

    func testRefusedSeekDropsTheDraft() {
        XCTAssertEqual(outcome(.notAuthorized), .discard)
        XCTAssertEqual(outcome(.scriptFailed(-1728)), .discard)
        XCTAssertEqual(outcome(.noPlayer), .discard)
        XCTAssertEqual(outcome(.unsupportedPlayer), .discard)
    }

    /// A seek that lands after the track changed must never write track A's
    /// optimistic position onto track B — in either direction.
    func testSeekLandingOnAnotherTrackIsIgnored() {
        XCTAssertEqual(outcome(nil, current: "track-b"), .ignore)
        XCTAssertEqual(outcome(.throttled, current: "track-b"), .ignore)
        XCTAssertEqual(outcome(.notAuthorized, current: "track-b"), .ignore)
    }
}
