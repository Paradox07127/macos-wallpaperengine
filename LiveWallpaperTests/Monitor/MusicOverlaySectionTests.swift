import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

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

    func testMusicAndBoardAreSeparatelyStored() {
        var overlay = MonitorOverlayConfiguration()
        let board = overlay.board
        overlay.music = Layout.setting(x: 0.7, y: 0.8, on: layer())
        XCTAssertEqual(overlay.board, board, "a Music edit must not be able to touch the board")

        var withWidgets = overlay
        withWidgets.board.widgets = [MonitorWidgetPlacement(kind: .cpu, size: .small)]
        XCTAssertEqual(withWidgets.music, overlay.music, "a board edit must not be able to touch Music")
    }

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

    func testMusicLayerStaysClearOfADockOnAnyEdge() throws {
        let board = CGSize(width: 1600, height: 1000)
        let cases: [(String, MonitorSafeAreaInsets)] = [
            ("bottom", MonitorSafeAreaInsets(top: 0.04, bottom: 0.12)),
            ("left", MonitorSafeAreaInsets(top: 0.04, leading: 0.06)),
            ("right", MonitorSafeAreaInsets(top: 0.04, trailing: 0.06)),
        ]
        for (name, insets) in cases {
            let safe = MonitorBoardGeometry(boardSize: board, safeArea: insets).safeRect
            for size in MusicOverlaySize.allCases {
                let footprint = Layout.normalizedFootprint(for: size, boardSize: board)
                // The nine extremes of the free area — every corner, every edge and the
                // middle — which is where a Dock is most likely to catch the layer.
                for fx in [0.0, 0.5, 1.0] {
                    for fy in [0.0, 0.5, 1.0] {
                        let configuration = Layout.setting(
                            x: fx * max(0, 1 - footprint.width),
                            y: fy * max(0, 1 - footprint.height),
                            on: layer(size: size)
                        )
                        let rect = try XCTUnwrap(Layout.renderRect(
                            configuration: configuration, boardSize: board, safeArea: insets
                        ))
                        XCTAssertTrue(
                            safe.insetBy(dx: -0.5, dy: -0.5).contains(rect),
                            "\(name) Dock, \(size) at (\(fx), \(fy)): \(rect) escaped \(safe)"
                        )
                    }
                }
            }
        }
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

    /// The drag is attached to the very view `.position` moves, so reading the translation
    /// in that view's own space re-bases it every frame — it must use the named canvas.
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

    /// Poster draws the cover as a photo, so a stand-in without artwork looks like poster
    /// lost its cover — the preview's sample must carry one.
    func testPreviewSampleTrackCarriesArtwork() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Views/ScreenDetail/OverlayPreviewArea.swift"
        )
        XCTAssertTrue(source.contains("state.artwork = sampleArtwork"))
    }
    /// The transport row must stay an overlay: mounted inside a style's stack it can be
    /// pushed past the widget rect, which is the exact region the overlay window hit-tests.
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
        // Top-trailing is the only corner no style draws a scrubbable line in; centred, the
        // pill covers the progress line vinyl and aurora put there.
        XCTAssertTrue(source.contains("maxHeight: .infinity, alignment: .topTrailing)"))
        // Both halves are needed: the tile rect is the frame plus this inset, and without the
        // inset the row can reach the edge the hit test stops at.
        XCTAssertTrue(source.contains("maxWidth: .infinity, maxHeight: .infinity, alignment:"))
        XCTAssertTrue(source.contains(".padding(max(6, side * 0.26))"))
    }

    /// The paused dim reaches the cover only; the opacity dial still reaches the whole
    /// layer, type included.
    func testPausedDimNoLongerMultipliesTheWholeTile() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Monitor/Widgets/NowPlayingWidgetView.swift"
        )
        XCTAssertFalse(
            source.contains(".opacity(layout.dimmed ? 0.55 : 1)"),
            "a tile-wide pause dim takes the type down with the cover"
        )
        XCTAssertTrue(
            source.contains(".opacity(visibility.art)"),
            "the pause dim must still reach the cover"
        )
        XCTAssertTrue(
            source.contains(".opacity(visibility.layer)"),
            "the opacity dial stays a whole-layer dial, type included"
        )
    }
}
