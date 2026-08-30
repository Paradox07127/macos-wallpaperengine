import AppKit
import LiveWallpaperCore

/// Where the Now Playing layer sits and how large it draws. The three sizes are expressed in the
/// Monitor grid's cell pitch as a unit of measure only — the layer keeps the exact footprint it had
/// while it was a widget, without belonging to a board.
enum MusicOverlayLayout {
    /// Reference-board fractions of one cell, from the same 1512×982 board the
    /// nine-up anchors are computed against.
    private static let normalizedCell = CGSize(
        width: MonitorBoardGeometry.appleCellPitch.width / 1512.0,
        height: MonitorBoardGeometry.appleCellPitch.height / 982.0
    )

    /// A borderless art layer, not a panel: S 2×1 / M 3×1 / L 4×2.
    static func cells(for size: MusicOverlaySize) -> (columns: Int, rows: Int) {
        switch size {
        case .small: return (2, 1)
        case .medium: return (3, 1)
        case .large: return (4, 2)
        }
    }

    static func normalizedFootprint(for size: MusicOverlaySize) -> CGSize {
        let cells = cells(for: size)
        return CGSize(
            width: Double(cells.columns) * normalizedCell.width,
            height: Double(cells.rows) * normalizedCell.height
        )
    }

    static func normalizedRect(_ configuration: MusicOverlayConfiguration) -> CGRect {
        let footprint = normalizedFootprint(for: configuration.size)
        return CGRect(
            x: configuration.x, y: configuration.y,
            width: footprint.width, height: footprint.height
        )
    }

    /// The layer's rect in board coordinates (y-down from the top edge), gutters
    /// applied exactly as a tile's are. Nil when the board has no usable area.
    static func renderRect(
        configuration: MusicOverlayConfiguration,
        boardSize: CGSize,
        topInsetFraction: CGFloat
    ) -> CGRect? {
        let geometry = MonitorBoardGeometry(
            boardSize: boardSize,
            topInsetFraction: topInsetFraction
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

    // MARK: - Nine-up anchors

    /// The nine positions the Position control offers. Anything else is a spot
    /// the user dragged to, which no button claims.
    enum Anchor: String, CaseIterable, Hashable {
        case topLeading, top, topTrailing
        case leading, center, trailing
        case bottomLeading, bottom, bottomTrailing
    }

    /// Wide enough to survive the rounding a drag leaves behind, far narrower
    /// than the gap between two neighbouring anchors at any allowed size.
    static let anchorTolerance = 0.02

    /// A layer wider than the board would otherwise produce a negative origin.
    static func anchorOrigin(_ anchor: Anchor, size: MusicOverlaySize) -> CGPoint {
        let footprint = normalizedFootprint(for: size)
        let freeX = max(0, 1 - footprint.width)
        let freeY = max(0, 1 - footprint.height)
        let x: Double = switch anchor {
        case .topLeading, .leading, .bottomLeading: 0
        case .top, .center, .bottom: freeX / 2
        case .topTrailing, .trailing, .bottomTrailing: freeX
        }
        let y: Double = switch anchor {
        case .topLeading, .top, .topTrailing: 0
        case .leading, .center, .trailing: freeY / 2
        case .bottomLeading, .bottom, .bottomTrailing: freeY
        }
        return CGPoint(x: x, y: y)
    }

    /// Which anchor this layer sits on, or nil for a dragged position.
    static func anchor(of configuration: MusicOverlayConfiguration) -> Anchor? {
        Anchor.allCases.first { candidate in
            let origin = anchorOrigin(candidate, size: configuration.size)
            return abs(origin.x - configuration.x) <= anchorTolerance
                && abs(origin.y - configuration.y) <= anchorTolerance
        }
    }

    // MARK: - Edits

    static func setting(anchor: Anchor, on configuration: MusicOverlayConfiguration) -> MusicOverlayConfiguration {
        var next = configuration
        let origin = anchorOrigin(anchor, size: configuration.size)
        next.x = origin.x
        next.y = origin.y
        return next
    }

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
    static func setting(size: MusicOverlaySize, on configuration: MusicOverlayConfiguration) -> MusicOverlayConfiguration {
        var next = configuration
        next.size = size
        let footprint = normalizedFootprint(for: size)
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
