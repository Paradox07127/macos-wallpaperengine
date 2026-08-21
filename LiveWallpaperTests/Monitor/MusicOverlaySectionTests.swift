import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

/// The Now Playing layer's own placement math. Everything here used to be board
/// surgery — first-fit around Monitor tiles, "leaves other widgets untouched",
/// no-ops when the board carried no layer. The layer has its own configuration
/// now, so those cases stopped existing rather than being deleted.
final class MusicOverlaySectionTests: XCTestCase {
    private typealias Layout = MusicOverlayLayout

    private func layer(
        size: MusicOverlaySize = .medium,
        x: Double = 0,
        y: Double = 0,
        options: [String: MonitorWidgetOptionValue] = [:]
    ) -> MusicOverlayConfiguration {
        MusicOverlayConfiguration(enabled: true, size: size, x: x, y: y, options: options)
    }

    // MARK: Independence from the Monitor board

    /// The split's whole point: a Music edit and a board edit cannot reach each
    /// other, because they no longer share a container.
    func testMusicAndBoardAreSeparatelyStored() {
        var overlay = MonitorOverlayConfiguration()
        let board = overlay.board
        overlay.music = Layout.setting(anchor: .bottomTrailing, on: layer())
        XCTAssertEqual(overlay.board, board, "a Music edit must not be able to touch the board")

        var withWidgets = overlay
        withWidgets.board.widgets = [MonitorWidgetPlacement(kind: .cpu, size: .small)]
        XCTAssertEqual(withWidgets.music, overlay.music, "a board edit must not be able to touch Music")
    }

    /// A config written while the layer was a widget still decodes; the stray
    /// placement is dropped with every other unknown kind, and Music comes back
    /// on its own defaults rather than inheriting a board position.
    func testLegacyBoardWidgetDoesNotDecodeIntoTheBoard() throws {
        let json = """
        {"enabled":true,"level":"desktop","board":{"schemaVersion":4,"widgets":[
        {"kind":"cpu","size":"s","x":0,"y":0},
        {"kind":"nowPlaying","size":"m","x":0.5,"y":0.5}
        ],"refreshHz":1,"mouseInteractionEnabled":false}}
        """
        let overlay = try JSONDecoder().decode(
            MonitorOverlayConfiguration.self, from: Data(json.utf8)
        )
        XCTAssertEqual(overlay.board.widgets.map(\.kind), [.cpu])
        XCTAssertEqual(overlay.music, .default)
    }

    // MARK: Anchors

    func testEveryAnchorRoundTrips() {
        for size in MusicOverlaySize.allCases {
            var configuration = layer(size: size)
            for anchor in Layout.Anchor.allCases {
                configuration = Layout.setting(anchor: anchor, on: configuration)
                XCTAssertEqual(
                    Layout.anchor(of: configuration), anchor,
                    "\(anchor) at \(size) did not read back as itself"
                )
            }
        }
    }

    func testAnchorOriginsStayOnTheBoardAtEverySize() {
        for size in MusicOverlaySize.allCases {
            let footprint = Layout.normalizedFootprint(for: size)
            for anchor in Layout.Anchor.allCases {
                let origin = Layout.anchorOrigin(anchor, size: size)
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
        let footprint = Layout.normalizedFootprint(for: .large)
        let leading = Layout.anchorOrigin(.leading, size: .large)
        let center = Layout.anchorOrigin(.center, size: .large)
        let trailing = Layout.anchorOrigin(.trailing, size: .large)

        XCTAssertEqual(leading.x, 0)
        XCTAssertEqual(trailing.x, 1 - footprint.width, accuracy: 1e-9)
        XCTAssertEqual(center.x, (1 - footprint.width) / 2, accuracy: 1e-9)
        XCTAssertGreaterThan(center.x - leading.x, 2 * Layout.anchorTolerance)
        XCTAssertGreaterThan(trailing.x - center.x, 2 * Layout.anchorTolerance)
    }

    func testAnchorMatchesWithinToleranceAndNotOutside() {
        var configuration = Layout.setting(anchor: .center, on: layer())
        let exact = Layout.anchorOrigin(.center, size: configuration.size)

        configuration.x = exact.x + Layout.anchorTolerance * 0.9
        XCTAssertEqual(Layout.anchor(of: configuration), .center)

        configuration.x = exact.x + Layout.anchorTolerance * 1.1
        XCTAssertNil(Layout.anchor(of: configuration), "a dragged position must claim no anchor")
    }

    func testSettingAnchorLeavesSizeAndOptionsUntouched() {
        let base = layer(size: .large, options: ["style": .string("vinyl")])
        let next = Layout.setting(anchor: .bottomTrailing, on: base)
        XCTAssertEqual(next.size, base.size)
        XCTAssertEqual(next.options, base.options)
        XCTAssertEqual(next.enabled, base.enabled)
    }

    func testSettingOriginClampsToTheBoard() {
        let next = Layout.setting(x: 0.31, y: 0.42, on: layer())
        XCTAssertEqual(next.x, 0.31)
        XCTAssertEqual(next.y, 0.42)

        let clamped = Layout.setting(x: 2, y: -1, on: layer())
        XCTAssertEqual(clamped.x, 1)
        XCTAssertEqual(clamped.y, 0)
    }

    // MARK: Style and options

    func testStyleRoundtrip() {
        let vinyl = Layout.settingOptions(on: layer()) { $0.style = .vinyl }
        XCTAssertEqual(NowPlayingWidgetView.style(vinyl.options), .vinyl)

        // Poster is the default, so setting it back drops the option key.
        let poster = Layout.settingOptions(on: vinyl) { $0.style = .poster }
        XCTAssertEqual(NowPlayingWidgetView.style(poster.options), .poster)
        XCTAssertNil(poster.options[NowPlayingOptions.Key.style])
    }

    func testSettingOptionsKeepsPositionSizeAndUnknownKeys() {
        let base = layer(size: .large, x: 0.2, y: 0.3, options: ["lyricsMode": .string("karaoke")])
        let next = Layout.settingOptions(on: base) {
            $0.opacity = 0.5
            $0.marquee = true
            $0.showAlbum = false
            $0.artworkShape = .circle
        }

        XCTAssertEqual(next.size, base.size)
        XCTAssertEqual(next.x, base.x)
        XCTAssertEqual(next.y, base.y)
        XCTAssertEqual(next.options["lyricsMode"]?.stringValue, "karaoke")
        XCTAssertEqual(next.options[NowPlayingOptions.Key.artworkShape]?.stringValue, "circle")

        let options = NowPlayingOptions(next.options)
        XCTAssertEqual(options.opacity, 0.5)
        XCTAssertTrue(options.marquee)
        XCTAssertFalse(options.showAlbum)
    }

    /// Switching style must not pin the previous style's implicit alignment —
    /// aurora is centered, and it stays centered after a poster → aurora hop.
    func testStyleChangeDoesNotPinTheOldStylesAlignment() {
        let aurora = Layout.settingOptions(on: layer()) { $0.style = .aurora }

        XCTAssertNil(aurora.options[NowPlayingOptions.Key.alignment])
        XCTAssertNil(aurora.options[NowPlayingOptions.Key.titleFont])
        XCTAssertEqual(NowPlayingOptions(aurora.options).resolvedAlignment, .center)
        XCTAssertEqual(NowPlayingOptions(aurora.options).resolvedTitleFont, .rounded)
    }

    // MARK: Size

    func testSizeRoundtripKeepsPosition() {
        let base = layer(x: 0.1, y: 0.2)
        let large = Layout.setting(size: .large, on: base)
        XCTAssertEqual(large.size, .large)
        XCTAssertEqual(large.x, base.x)
        XCTAssertEqual(large.y, base.y)
        XCTAssertEqual(Layout.setting(size: .medium, on: large).size, .medium)
    }

    func testGrowingNearTheRightEdgeStaysOnTheBoard() {
        let grown = Layout.setting(size: .large, on: layer(x: 0.8, y: 0.9))
        let footprint = Layout.normalizedFootprint(for: .large)
        XCTAssertLessThanOrEqual(grown.x + footprint.width, 1 + 1e-9)
        XCTAssertLessThanOrEqual(grown.y + footprint.height, 1 + 1e-9)
    }

    // MARK: Footprint

    func testNormalizedFootprintTracksCellSize() {
        let small = Layout.normalizedFootprint(for: .small)
        let medium = Layout.normalizedFootprint(for: .medium)
        let large = Layout.normalizedFootprint(for: .large)

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
