import AppKit
import LiveWallpaperCore

/// Where the Now Playing layer sits and how large it draws. The three sizes are expressed in the
/// Monitor grid's cell pitch as a unit of measure only — the layer keeps the exact footprint it had
/// while it was a widget, without belonging to a board.
enum MusicOverlayLayout {
    static let referenceBoardSize = CGSize(width: 1512, height: 982)

    /// A borderless art layer, not a panel: S 2×1 / M 3×1 / L 4×2.
    static func cells(for size: MusicOverlaySize) -> (columns: Int, rows: Int) {
        switch size {
        case .small: return (2, 1)
        case .medium: return (3, 1)
        case .large: return (4, 2)
        }
    }

    static func normalizedFootprint(for size: MusicOverlaySize, boardSize: CGSize = referenceBoardSize) -> CGSize {
        let cells = cells(for: size)
        return CGSize(
            width: Double(cells.columns) * MonitorBoardGeometry.appleCellPitch.width / max(1, boardSize.width),
            height: Double(cells.rows) * MonitorBoardGeometry.appleCellPitch.height / max(1, boardSize.height)
        )
    }

    /// The layer's rect in board coordinates (y-down from the top edge), gutters
    /// applied exactly as a tile's are. Nil when the board has no usable area.
    static func renderRect(
        configuration: MusicOverlayConfiguration,
        boardSize: CGSize,
        safeArea: MonitorSafeAreaInsets
    ) -> CGRect? {
        let geometry = MonitorBoardGeometry(
            boardSize: boardSize,
            safeArea: safeArea
        )
        guard !geometry.isDegenerate else { return nil }
        let cells = cells(for: configuration.size)
        let footprint = geometry.pixelSize(columns: cells.columns, rows: cells.rows)
        let origin = geometry.clampOrigin(
            LayoutEngine.pixelOrigin(
                normalized: CGPoint(x: configuration.x, y: configuration.y),
                boardSize: geometry.boardSize
            ),
            footprint: footprint
        )
        return geometry.renderRect(forRawRect: CGRect(origin: origin, size: footprint))
    }

    /// The nine positions the Position control offers. Anything else is a spot
    /// the user dragged to, which no button claims.
    // MARK: - Edits

    /// Drag landing spot from the inspector preview.
    static func setting(x: Double, y: Double, on configuration: MusicOverlayConfiguration) -> MusicOverlayConfiguration {
        var next = configuration
        next.x = min(max(x, 0), 1)
        next.y = min(max(y, 0), 1)
        return next
    }

    /// Growing the layer can push it off the board, so the origin is re-clamped
    /// to the new footprint. Nothing else shares its space any more, so there is
    /// no collision to resolve.
    static func setting(size: MusicOverlaySize, on configuration: MusicOverlayConfiguration, boardSize: CGSize = referenceBoardSize) -> MusicOverlayConfiguration {
        var next = configuration
        next.size = size
        let footprint = normalizedFootprint(for: size, boardSize: boardSize)
        next.x = min(max(next.x, 0), max(0, 1 - footprint.width))
        next.y = min(max(next.y, 0), max(0, 1 - footprint.height))
        return next
    }

    static func settingOptions(
        on configuration: MusicOverlayConfiguration,
        _ transform: (inout NowPlayingOptions) -> Void
    ) -> MusicOverlayConfiguration {
        var options = NowPlayingOptions(configuration.options)
        transform(&options)
        var next = configuration
        next.options = options.applied(to: configuration.options)
        return next
    }
}
