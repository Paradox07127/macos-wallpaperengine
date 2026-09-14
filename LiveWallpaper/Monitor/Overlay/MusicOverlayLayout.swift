import AppKit
import LiveWallpaperCore

enum MusicOverlayLayout {
    static let referenceBoardSize = CGSize(width: 1512, height: 982)

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

    /// Layer rect in board coordinates (y-down from the top edge). Nil when the board has no usable area.
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

    // MARK: - Edits

    static func setting(x: Double, y: Double, on configuration: MusicOverlayConfiguration) -> MusicOverlayConfiguration {
        var next = configuration
        next.x = min(max(x, 0), 1)
        next.y = min(max(y, 0), 1)
        return next
    }

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
