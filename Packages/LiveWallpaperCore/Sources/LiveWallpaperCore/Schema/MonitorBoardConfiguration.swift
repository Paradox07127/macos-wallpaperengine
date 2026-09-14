import Foundation

// MARK: - Monitor widget board configuration

/// A small tile is Apple's 170×170 and every neighbour sits exactly one `gutter` away on BOTH
/// axes, so a large tile is 2×2 cells minus the gutter it crosses and comes out square.
public enum MonitorBoardMetrics {
    public static let tileSide: Double = 170
    /// Gap between neighbouring tiles; each tile is inset by half of it.
    public static let gutter: Double = 16
    /// Cell pitch — one tile plus one gutter, so `tile == pitch - gutter`.
    public static let cellPitch: Double = tileSide + gutter
}

public enum MonitorWidgetKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case systemOverview
    /// Decode-only compatibility for the pre-Clock-section demo; the overlay migrates it out.
    case nixieClock
    case cpu
    case memory
    case gpu
    case network
    case disk
    case power
    case processes
    case fleet
    case aiEngine
    case weather

    public var id: String { rawValue }

    public static let allCases: [Self] = [
        .systemOverview, .cpu, .memory, .gpu, .network, .disk,
        .power, .processes, .fleet, .aiEngine, .weather,
    ]

    /// Matches Apple widget frames.
    public func cellSize(for size: MonitorWidgetSize) -> (columns: Int, rows: Int) {
        switch size {
        case .small: return (1, 1)
        case .medium: return (2, 1)
        case .large: return (2, 2)
        }
    }

    public var allowedSizes: [MonitorWidgetSize] {
        switch self {
        case .systemOverview, .nixieClock, .processes, .fleet: [.medium, .large]
        case .power: [.small, .medium]
        default: [.small, .medium, .large]
        }
    }
}

public enum MonitorWidgetSize: String, Codable, Sendable, CaseIterable {
    case small = "s"
    case medium = "m"
    case large = "l"
}

public enum MonitorWidgetOptionValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case stringList([String])

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Clamp in Double space before `Int` — `Int(_:)` traps past range; `isFinite` alone is insufficient.
    public func intValue(clampedTo range: ClosedRange<Int>) -> Int? {
        guard case .number(let value) = self, !value.isNaN else { return nil }
        // Double(Int.max) rounds *above* Int.max — compare before convert.
        if value <= Double(range.lowerBound) { return range.lowerBound }
        if value >= Double(range.upperBound) { return range.upperBound }
        return Int(value.rounded())
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([String].self) {
            self = .stringList(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported monitor widget option value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .stringList(let value): try c.encode(value)
        }
    }
}

/// Widget placement: normalized top-left (0…1); size → cells at render; OOB clamped.
public struct MonitorWidgetPlacement: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: MonitorWidgetKind
    public var size: MonitorWidgetSize
    public var x: Double
    public var y: Double
    public var options: [String: MonitorWidgetOptionValue]

    public init(
        id: UUID = UUID(),
        kind: MonitorWidgetKind,
        size: MonitorWidgetSize = .medium,
        x: Double = 0,
        y: Double = 0,
        options: [String: MonitorWidgetOptionValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.size = size
        self.x = x.isFinite ? min(max(x, 0), 1) : 0
        self.y = y.isFinite ? min(max(y, 0), 1) : 0
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, size, x, y, options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let kind = try c.decode(MonitorWidgetKind.self, forKey: .kind)
        let size = try c.decodeIfPresent(MonitorWidgetSize.self, forKey: .size) ?? .medium
        let x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        let y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        let options = try c.decodeIfPresent([String: MonitorWidgetOptionValue].self, forKey: .options) ?? [:]
        self.init(id: id, kind: kind, size: size, x: x, y: y, options: options)
    }
}

public struct MonitorBoardConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var widgets: [MonitorWidgetPlacement]
    /// Data-push cadence; renderer clamps to 0.2…2 Hz regardless of persistence.
    public var refreshHz: Double
    /// When true the wallpaper stops being click-through so the board can receive
    /// clicks (widget editing / dragging) instead of passing them to the desktop.
    public var mouseInteractionEnabled: Bool
    public var reduceMotionOverride: Bool?

    public static let currentSchemaVersion = 4
    public static let `default` = MonitorBoardConfiguration()

    /// Renderer-facing clamp (0.2…2 Hz), independent of what is persisted.
    public static func clampedRefreshHz(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0.2), 2.0)
    }

    /// Selectable refresh intervals in seconds, deliberately non-uniform: 0.1 s steps below 2 s,
    /// whole seconds above. The bounds mirror `clampedRefreshHz` (0.5 s == 2 Hz, 5 s == 0.2 Hz),
    /// and 0.5 s is also `DataHub`'s publish throttle, so sampling faster would be discarded work.
    public static let refreshIntervalSteps: [Double] =
        (5...19).map { Double($0) / 10.0 } + [2, 3, 4, 5]

    /// Nearest selectable interval. Built by comparison rather than arithmetic
    /// so the non-uniform grid stays the single source of truth.
    public static func snappedRefreshInterval(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 1.0 }
        return refreshIntervalSteps.min { abs($0 - seconds) < abs($1 - seconds) } ?? 1.0
    }

    /// Seconds-per-sample view over the persisted `refreshHz`; Hz stays the stored form so
    /// existing boards decode unchanged.
    public var refreshIntervalSeconds: Double {
        get { Self.snappedRefreshInterval(1.0 / refreshHz) }
        set { refreshHz = Self.clampedRefreshHz(1.0 / Self.snappedRefreshInterval(newValue)) }
    }

    public init(
        schemaVersion: Int = MonitorBoardConfiguration.currentSchemaVersion,
        widgets: [MonitorWidgetPlacement]? = nil,
        refreshHz: Double = 1.0,
        mouseInteractionEnabled: Bool = false,
        reduceMotionOverride: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.widgets = widgets ?? Self.defaultSystemPlacements()
        self.refreshHz = Self.clampedRefreshHz(refreshHz)
        self.mouseInteractionEnabled = mouseInteractionEnabled
        self.reduceMotionOverride = reduceMotionOverride
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, widgets, refreshHz, mouseInteractionEnabled, reduceMotionOverride
    }

    /// Always consumes exactly one unkeyed element so a failed placement decode (e.g. an unknown
    /// kind from a newer build) skips that element instead of corrupting the rest of the array.
    /// Silent to the format but not to the log — the widget really is gone from the board.
    private struct LossyPlacement: Decodable {
        let value: MonitorWidgetPlacement?
        init(from decoder: Decoder) {
            do {
                value = try MonitorWidgetPlacement(from: decoder)
            } catch {
                Logger.warning(
                    "MonitorBoardConfiguration: dropped an undecodable widget placement "
                        + "(likely a kind added by a newer build): \(error)",
                    category: .settings
                )
                value = nil
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        let lossy = try c.decodeIfPresent([LossyPlacement].self, forKey: .widgets)
        widgets = lossy.map { $0.compactMap(\.value) } ?? Self.defaultSystemPlacements()
        refreshHz = Self.clampedRefreshHz(
            try c.decodeIfPresent(Double.self, forKey: .refreshHz) ?? 1.0
        )
        mouseInteractionEnabled = try c.decodeIfPresent(Bool.self, forKey: .mouseInteractionEnabled) ?? false
        reduceMotionOverride = try c.decodeIfPresent(Bool.self, forKey: .reduceMotionOverride)

        // The bump only records the newest schema a re-encoded board has been through:
        // v4's `gridColumns` normalization is gone.
        if schemaVersion < 4 {
            schemaVersion = 4
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(widgets, forKey: .widgets)
        try c.encode(refreshHz, forKey: .refreshHz)
        try c.encode(mouseInteractionEnabled, forKey: .mouseInteractionEnabled)
        try c.encodeIfPresent(reduceMotionOverride, forKey: .reduceMotionOverride)
    }
}

// MARK: Board decode + default layout

extension MonitorBoardConfiguration {
    static let defaultSystemKinds: [(MonitorWidgetKind, MonitorWidgetSize)] = [
        (.cpu, .medium), (.memory, .medium), (.gpu, .medium),
    ]

    public static func defaultSystemPlacements() -> [MonitorWidgetPlacement] {
        packedPlacements(for: defaultSystemKinds)
    }

    /// Square on purpose (see `MonitorBoardMetrics`); a test pins it against the renderer's
    /// `MonitorBoardGeometry.appleCellPitch`.
    static let referenceCellPitch = (
        width: MonitorBoardMetrics.cellPitch, height: MonitorBoardMetrics.cellPitch
    )
    /// Reference board for default placement normalization.
    static let referenceBoard = (width: 1512.0, height: 982.0)

    /// Bottom-anchored rows on the reference board; other sizes clamp at render.
    public static func packedPlacements(
        for kinds: [(MonitorWidgetKind, MonitorWidgetSize)]
    ) -> [MonitorWidgetPlacement] {
        let columns = max(Int(referenceBoard.width / referenceCellPitch.width), 1)
        let cellW = referenceCellPitch.width / referenceBoard.width
        let cellH = referenceCellPitch.height / referenceBoard.height
        let bottomMargin = 0.02

        var placements: [MonitorWidgetPlacement] = []
        var row: [(MonitorWidgetKind, MonitorWidgetSize)] = []
        var rowCells = 0
        var bottomY = 1.0 - bottomMargin

        func flushRow() {
            guard !row.isEmpty else { return }
            let rowRows = row.map { $0.0.cellSize(for: $0.1).rows }.max() ?? 1
            let height = Double(rowRows) * cellH
            var cellX = 0
            for (kind, size) in row {
                let cells = kind.cellSize(for: size)
                placements.append(MonitorWidgetPlacement(
                    kind: kind, size: size,
                    x: Double(cellX) * cellW, y: bottomY - height
                ))
                cellX += cells.columns
            }
            bottomY -= height
            row = []
            rowCells = 0
        }

        for (kind, size) in kinds {
            let cells = kind.cellSize(for: size)
            if rowCells + cells.columns > columns { flushRow() }
            row.append((kind, size))
            rowCells += cells.columns
        }
        flushRow()
        return placements
    }
}
