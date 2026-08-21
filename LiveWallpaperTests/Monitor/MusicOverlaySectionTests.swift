import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

final class MusicOverlaySectionTests: XCTestCase {
    private typealias Editor = MusicOverlayBoardEditor

    // MARK: Adding

    func testAddingNowPlayingAppendsMediumWithoutOverlap() throws {
        let base = MonitorBoardConfiguration()   // default cpu/memory/gpu row
        let next = Editor.addingNowPlaying(to: base)

        XCTAssertEqual(next.widgets.count, base.widgets.count + 1)
        let added = try XCTUnwrap(Editor.nowPlayingPlacement(in: next))
        XCTAssertEqual(added.kind, .nowPlaying)
        XCTAssertEqual(added.size, .medium)

        let addedRect = Editor.normalizedRect(of: added).insetBy(dx: 1e-6, dy: 1e-6)
        for other in base.widgets {
            XCTAssertFalse(
                Editor.normalizedRect(of: other).intersects(addedRect),
                "New Now Playing placement overlaps existing \(other.kind)"
            )
        }
    }

    func testAddingNowPlayingAvoidsAnOccupiedTopLeft() throws {
        let blocker = MonitorWidgetPlacement(kind: .cpu, size: .medium, x: 0, y: 0)
        let base = MonitorBoardConfiguration(widgets: [blocker])
        let next = Editor.addingNowPlaying(to: base)

        let added = try XCTUnwrap(Editor.nowPlayingPlacement(in: next))
        let addedRect = Editor.normalizedRect(of: added).insetBy(dx: 1e-6, dy: 1e-6)
        XCTAssertFalse(Editor.normalizedRect(of: blocker).intersects(addedRect))
    }

    func testAddingNowPlayingToEmptyBoardLandsAtOrigin() throws {
        let base = MonitorBoardConfiguration(widgets: [])
        let next = Editor.addingNowPlaying(to: base)

        let added = try XCTUnwrap(Editor.nowPlayingPlacement(in: next))
        XCTAssertEqual(added.x, 0)
        XCTAssertEqual(added.y, 0)
        XCTAssertEqual(next.widgets.count, 1)
    }

    func testAddingNowPlayingIsIdempotent() {
        let once = Editor.addingNowPlaying(to: MonitorBoardConfiguration())
        let twice = Editor.addingNowPlaying(to: once)
        XCTAssertEqual(twice, once)
        XCTAssertEqual(twice.widgets.filter { $0.kind == .nowPlaying }.count, 1)
    }

    func testAddingPreservesBoardLevelSettings() {
        var base = MonitorBoardConfiguration()
        base.mouseInteractionEnabled = true
        base.refreshHz = 0.5
        base.reduceMotionOverride = true

        let next = Editor.addingNowPlaying(to: base)
        XCTAssertTrue(next.mouseInteractionEnabled)
        XCTAssertEqual(next.refreshHz, 0.5)
        XCTAssertEqual(next.reduceMotionOverride, true)
    }

    // MARK: Anchors

    func testEveryAnchorRoundTrips() throws {
        for size in MonitorWidgetKind.nowPlaying.allowedSizes {
            var board = Editor.addingNowPlaying(to: MonitorBoardConfiguration(), size: size)
            for anchor in Editor.Anchor.allCases {
                board = Editor.settingAnchor(anchor, on: board)
                let placement = try XCTUnwrap(Editor.nowPlayingPlacement(in: board))
                XCTAssertEqual(
                    Editor.anchor(of: placement), anchor,
                    "\(anchor) at \(size) did not read back as itself"
                )
            }
        }
    }

    func testAnchorOriginsStayOnTheBoardAtEverySize() {
        for size in MonitorWidgetKind.nowPlaying.allowedSizes {
            let footprint = Editor.normalizedFootprint(for: .nowPlaying, size: size)
            for anchor in Editor.Anchor.allCases {
                let origin = Editor.anchorOrigin(anchor, size: size)
                XCTAssertGreaterThanOrEqual(origin.x, 0, "\(anchor) at \(size)")
                XCTAssertGreaterThanOrEqual(origin.y, 0, "\(anchor) at \(size)")
                XCTAssertLessThanOrEqual(origin.x + footprint.width, 1 + 1e-9, "\(anchor) at \(size)")
                XCTAssertLessThanOrEqual(origin.y + footprint.height, 1 + 1e-9, "\(anchor) at \(size)")
            }
        }
    }

    /// Large is the widest layer, so its three columns sit closest together —
    /// if the tolerance ever swallows a neighbour it happens here first.
    func testLargeAnchorsAreDistinctAndInBounds() {
        let footprint = Editor.normalizedFootprint(for: .nowPlaying, size: .large)
        let leading = Editor.anchorOrigin(.leading, size: .large)
        let center = Editor.anchorOrigin(.center, size: .large)
        let trailing = Editor.anchorOrigin(.trailing, size: .large)

        XCTAssertEqual(leading.x, 0)
        XCTAssertEqual(trailing.x, 1 - footprint.width, accuracy: 1e-9)
        XCTAssertEqual(center.x, (1 - footprint.width) / 2, accuracy: 1e-9)
        XCTAssertGreaterThan(center.x - leading.x, 2 * Editor.anchorTolerance)
        XCTAssertGreaterThan(trailing.x - center.x, 2 * Editor.anchorTolerance)
    }

    func testAnchorMatchesWithinToleranceAndNotOutside() throws {
        let board = Editor.settingAnchor(
            .center, on: Editor.addingNowPlaying(to: MonitorBoardConfiguration())
        )
        var placement = try XCTUnwrap(Editor.nowPlayingPlacement(in: board))

        let exact = Editor.anchorOrigin(.center, size: placement.size)
        placement.x = exact.x + Editor.anchorTolerance * 0.9
        XCTAssertEqual(Editor.anchor(of: placement), .center)

        placement.x = exact.x + Editor.anchorTolerance * 1.1
        XCTAssertNil(Editor.anchor(of: placement), "a dragged position must claim no anchor")
    }

    func testSettingAnchorLeavesOtherWidgetsAndSizeUntouched() throws {
        let base = Editor.addingNowPlaying(to: MonitorBoardConfiguration())
        let next = Editor.settingAnchor(.bottomTrailing, on: base)

        XCTAssertEqual(
            next.widgets.filter { $0.kind != .nowPlaying },
            base.widgets.filter { $0.kind != .nowPlaying }
        )
        let placement = try XCTUnwrap(Editor.nowPlayingPlacement(in: next))
        XCTAssertEqual(placement.size, try XCTUnwrap(Editor.nowPlayingPlacement(in: base)).size)
    }

    func testSettingAnchorWithoutNowPlayingIsANoOp() {
        let base = MonitorBoardConfiguration(widgets: [])
        XCTAssertEqual(Editor.settingAnchor(.center, on: base), base)
    }

    func testSettingOriginMovesOnlyTheLayer() throws {
        let base = Editor.addingNowPlaying(to: MonitorBoardConfiguration())
        let next = Editor.settingOrigin(x: 0.31, y: 0.42, on: base)

        let placement = try XCTUnwrap(Editor.nowPlayingPlacement(in: next))
        XCTAssertEqual(placement.x, 0.31)
        XCTAssertEqual(placement.y, 0.42)
        XCTAssertEqual(
            next.widgets.filter { $0.kind != .nowPlaying },
            base.widgets.filter { $0.kind != .nowPlaying }
        )
    }

    // MARK: Style

    func testStyleRoundtrip() throws {
        let base = Editor.addingNowPlaying(to: MonitorBoardConfiguration())

        let vinyl = Editor.settingStyle(.vinyl, on: base)
        let vinylPlacement = try XCTUnwrap(Editor.nowPlayingPlacement(in: vinyl))
        XCTAssertEqual(NowPlayingWidgetView.style(vinylPlacement.options), .vinyl)

        // Poster is the default, so setting it back drops the option key.
        let poster = Editor.settingStyle(.poster, on: vinyl)
        let posterPlacement = try XCTUnwrap(Editor.nowPlayingPlacement(in: poster))
        XCTAssertEqual(NowPlayingWidgetView.style(posterPlacement.options), .poster)
        XCTAssertNil(posterPlacement.options[NowPlayingOptions.Key.style])
    }

    // MARK: DIY options

    func testSettingOptionsWritesOnlyTheNowPlayingLayer() throws {
        let base = Editor.addingNowPlaying(to: MonitorBoardConfiguration())
        let original = try XCTUnwrap(Editor.nowPlayingPlacement(in: base))

        let next = Editor.settingOptions(on: base) {
            $0.opacity = 0.5
            $0.marquee = true
            $0.showAlbum = false
        }

        XCTAssertEqual(
            next.widgets.filter { $0.kind != .nowPlaying },
            base.widgets.filter { $0.kind != .nowPlaying },
            "a Music option edit touched another widget"
        )
        let placement = try XCTUnwrap(Editor.nowPlayingPlacement(in: next))
        XCTAssertEqual(placement.id, original.id)
        XCTAssertEqual(placement.size, original.size)
        XCTAssertEqual(placement.x, original.x)
        XCTAssertEqual(placement.y, original.y)

        let options = NowPlayingOptions(placement.options)
        XCTAssertEqual(options.opacity, 0.5)
        XCTAssertTrue(options.marquee)
        XCTAssertFalse(options.showAlbum)
    }

    /// Options carried by other widget kinds share the same dictionary shape;
    /// a Music edit must not reach into them.
    func testSettingOptionsLeavesOtherWidgetOptionsIntact() throws {
        let neighbour = MonitorWidgetPlacement(
            kind: .processes, size: .medium, x: 0, y: 0, options: ["rows": .number(7)]
        )
        let base = Editor.addingNowPlaying(to: MonitorBoardConfiguration(widgets: [neighbour]))
        let next = Editor.settingOptions(on: base) { $0.titleScale = 1.2 }

        let after = try XCTUnwrap(next.widgets.first { $0.kind == .processes })
        XCTAssertEqual(after.options["rows"]?.numberValue, 7)
    }

    /// Unrelated keys already on the Music placement (a later option, a hand
    /// edit) survive a DIY change.
    func testSettingOptionsKeepsUnknownKeysOnTheLayer() throws {
        var board = Editor.addingNowPlaying(to: MonitorBoardConfiguration())
        let index = try XCTUnwrap(board.widgets.firstIndex { $0.kind == .nowPlaying })
        board.widgets[index].options["lyricsMode"] = .string("karaoke")

        let next = Editor.settingOptions(on: board) { $0.artworkShape = .circle }
        let placement = try XCTUnwrap(Editor.nowPlayingPlacement(in: next))
        XCTAssertEqual(placement.options["lyricsMode"]?.stringValue, "karaoke")
        XCTAssertEqual(placement.options[NowPlayingOptions.Key.artworkShape]?.stringValue, "circle")
    }

    func testSettingOptionsWithoutNowPlayingIsANoOp() {
        let base = MonitorBoardConfiguration(widgets: [])
        XCTAssertEqual(Editor.settingOptions(on: base) { $0.opacity = 0.3 }, base)
    }

    /// Switching style must not pin the previous style's implicit alignment —
    /// aurora is centered, and it stays centered after a poster → aurora hop.
    func testStyleChangeDoesNotPinTheOldStylesAlignment() throws {
        let base = Editor.addingNowPlaying(to: MonitorBoardConfiguration())
        let aurora = Editor.settingStyle(.aurora, on: base)
        let placement = try XCTUnwrap(Editor.nowPlayingPlacement(in: aurora))

        XCTAssertNil(placement.options[NowPlayingOptions.Key.alignment])
        XCTAssertNil(placement.options[NowPlayingOptions.Key.titleFont])
        XCTAssertEqual(NowPlayingOptions(placement.options).resolvedAlignment, .center)
        XCTAssertEqual(NowPlayingOptions(placement.options).resolvedTitleFont, .rounded)
    }

    func testSettingStyleWithoutNowPlayingIsANoOp() {
        let base = MonitorBoardConfiguration(widgets: [])
        XCTAssertEqual(Editor.settingStyle(.aurora, on: base), base)
    }

    // MARK: Size

    func testSizeRoundtripKeepsIdentityAndPosition() throws {
        let base = Editor.addingNowPlaying(to: MonitorBoardConfiguration())
        let original = try XCTUnwrap(Editor.nowPlayingPlacement(in: base))

        let large = Editor.settingSize(.large, on: base)
        let largePlacement = try XCTUnwrap(Editor.nowPlayingPlacement(in: large))
        XCTAssertEqual(largePlacement.size, .large)
        XCTAssertEqual(largePlacement.id, original.id)
        XCTAssertEqual(largePlacement.x, original.x)
        XCTAssertEqual(largePlacement.y, original.y)

        let backToMedium = Editor.settingSize(.medium, on: large)
        XCTAssertEqual(try XCTUnwrap(Editor.nowPlayingPlacement(in: backToMedium)).size, .medium)
    }

    func testGrowingNearTheRightEdgeStaysOnTheBoard() throws {
        // Park the layer where a Large footprint would hang off the right edge.
        var board = Editor.addingNowPlaying(to: MonitorBoardConfiguration())
        let index = try XCTUnwrap(board.widgets.firstIndex { $0.kind == .nowPlaying })
        board.widgets[index].x = 0.8
        board.widgets[index].y = 0.9

        let grown = try XCTUnwrap(Editor.nowPlayingPlacement(in: Editor.settingSize(.large, on: board)))
        let footprint = Editor.normalizedFootprint(for: .nowPlaying, size: .large)
        XCTAssertLessThanOrEqual(grown.x + footprint.width, 1 + 1e-9)
        XCTAssertLessThanOrEqual(grown.y + footprint.height, 1 + 1e-9)
    }

    func testGrowingOntoANeighbourRelocatesInsteadOfOverlapping() throws {
        // A CPU tile sits directly right of the layer, in the Large footprint.
        let neighbour = MonitorWidgetPlacement(
            kind: .cpu, size: .large,
            x: Editor.normalizedFootprint(for: .nowPlaying, size: .medium).width, y: 0
        )
        let board = Editor.addingNowPlaying(to: MonitorBoardConfiguration(widgets: [neighbour]))
        let grown = try XCTUnwrap(Editor.nowPlayingPlacement(in: Editor.settingSize(.large, on: board)))

        let grownRect = Editor.normalizedRect(of: grown).insetBy(dx: 1e-6, dy: 1e-6)
        XCTAssertFalse(Editor.normalizedRect(of: neighbour).intersects(grownRect))
    }

    func testAddingCanCarryARememberedSizeAndStyle() throws {
        let options: [String: MonitorWidgetOptionValue] = ["style": .string("vinyl")]
        let board = Editor.addingNowPlaying(
            to: MonitorBoardConfiguration(), size: .large, options: options
        )
        let placement = try XCTUnwrap(Editor.nowPlayingPlacement(in: board))
        XCTAssertEqual(placement.size, .large)
        XCTAssertEqual(placement.options["style"]?.stringValue, "vinyl")
    }

    func testSettingSizeWithoutNowPlayingIsANoOp() {
        let base = MonitorBoardConfiguration(widgets: [])
        XCTAssertEqual(Editor.settingSize(.large, on: base), base)
    }

    func testSettingSizeLeavesOtherWidgetsUntouched() {
        let base = Editor.addingNowPlaying(to: MonitorBoardConfiguration())
        let next = Editor.settingSize(.small, on: base)
        XCTAssertEqual(
            next.widgets.filter { $0.kind != .nowPlaying },
            base.widgets.filter { $0.kind != .nowPlaying }
        )
    }

    // MARK: Footprint

    func testNormalizedFootprintTracksCellSize() {
        let small = Editor.normalizedFootprint(for: .nowPlaying, size: .small)
        let medium = Editor.normalizedFootprint(for: .nowPlaying, size: .medium)
        let large = Editor.normalizedFootprint(for: .nowPlaying, size: .large)

        // S 2×1 / M 3×1 / L 4×2 cells: widths scale 2:3:4, large is double height.
        XCTAssertEqual(medium.width / small.width, 1.5, accuracy: 1e-9)
        XCTAssertEqual(large.width / small.width, 2.0, accuracy: 1e-9)
        XCTAssertEqual(small.height, medium.height, accuracy: 1e-9)
        XCTAssertEqual(large.height, small.height * 2, accuracy: 1e-9)
    }
    // MARK: Preview wiring (source contracts)

    /// The layer drag is attached to the very view `.position` moves. Reading
    /// the translation in that view's own space re-bases it every frame, which
    /// made the layer strobe under the cursor; it must use the named canvas.
    func testPreviewDragUsesAStableCoordinateSpace() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Views/ScreenDetail/OverlayPreviewArea.swift"
        )
        XCTAssertTrue(source.contains("coordinateSpace: .named(Self.canvasSpace)"))
        XCTAssertTrue(source.contains(".coordinateSpace(name: Self.canvasSpace)"))
        XCTAssertFalse(
            source.contains("DragGesture(minimumDistance: 2)\n"),
            "a bare DragGesture defaults to .local - that is the jitter"
        )
    }

    /// The live readout moved onto the preview; leaving a copy in the option
    /// list would show the same thing twice.
    func testStatusReadoutLivesOnThePreviewOnly() throws {
        let preview = try RepositoryRoot.source(
            "LiveWallpaper/Views/ScreenDetail/OverlayPreviewArea.swift"
        )
        let section = try RepositoryRoot.source(
            "LiveWallpaper/Views/Monitor/MusicOverlaySection.swift"
        )
        XCTAssertTrue(preview.contains("MusicStatusBadge(state:"))
        XCTAssertFalse(section.contains("statusCard"), "the inspector copy must be gone")
    }

    /// Poster draws the cover as a photo while vinyl draws its platter from
    /// scratch - a stand-in without artwork therefore looked like poster had
    /// lost its cover. The preview's sample must carry one.
    func testPreviewSampleTrackCarriesArtwork() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Views/ScreenDetail/OverlayPreviewArea.swift"
        )
        XCTAssertTrue(source.contains("state.artwork = sampleArtwork"))
    }
    /// The transport row must stay an overlay. In a style's stack it was the
    /// last child of a bottom-aligned VStack, so a one-cell-tall tile pushed it
    /// past the widget rect — the exact region the overlay window hit-tests.
    /// The buttons then sat outside their own hover area: walking towards them
    /// left the tile and folded them away before they could be clicked.
    func testTransportControlsStayOutOfTheLayoutFlow() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Monitor/Widgets/NowPlayingWidgetView.swift"
        )
        XCTAssertTrue(
            source.contains(".overlay { transportOverlay(state: state, in: geo.size) }"),
            "controls must be mounted as an overlay on the tile"
        )
        for stackCall in ["controlsRow(state: state, side:"] {
            XCTAssertFalse(
                source.contains(stackCall),
                "a stack-mounted control row re-introduces the overflow bug"
            )
        }
        // Centred, per the same fix: an edge-anchored row is the thing that
        // can leave the tile when the content grows.
        XCTAssertTrue(source.contains("maxHeight: .infinity, alignment: .center)"))
    }
}
