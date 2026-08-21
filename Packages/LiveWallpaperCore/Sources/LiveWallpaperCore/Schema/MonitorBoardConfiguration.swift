import Foundation

// MARK: - Monitor widget board configuration

public enum MonitorWidgetKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case cpu
    case memory
    case gpu
    case network
    case disk
    case power
    case processes
    case fleet
    case aiEngine

    public var id: String { rawValue }

    /// Grid cells matching Apple widget frames (S 1×1 / M 2×1 / L 2×2).
    public func cellSize(for size: MonitorWidgetSize) -> (columns: Int, rows: Int) {
        switch size {
        case .small: return (1, 1)
        case .medium: return (2, 1)
        case .large: return (2, 2)
        }
    }

    public var allowedSizes: [MonitorWidgetSize] {
        switch self {
        case .processes, .fleet: return [.medium, .large]
        case .power: return [.small, .medium]
        default: return [.small, .medium, .large]
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

    /// Renderer-facing clamp for the data-push cadence (0.2…2 Hz), independent
    /// of what is persisted.
    public static func clampedRefreshHz(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0.2), 2.0)
    }

    /// Selectable refresh intervals in seconds. Deliberately non-uniform: 0.1 s
    /// resolution is only useful in the sub-2 s range people actually tune, so
    /// past 2 s the grid coarsens to whole seconds instead of adding 30 stops
    /// nobody drags to. The bounds mirror `clampedRefreshHz` exactly
    /// (0.5 s == 2 Hz, 5 s == 0.2 Hz); 0.5 s is also `DataHub`'s publish
    /// throttle, so sampling faster than that would be discarded work.
    public static let refreshIntervalSteps: [Double] =
        (5...19).map { Double($0) / 10.0 } + [2, 3, 4, 5]

    /// Nearest selectable interval. Built by comparison rather than arithmetic
    /// so the non-uniform grid stays the single source of truth.
    public static func snappedRefreshInterval(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 1.0 }
        return refreshIntervalSteps.min { abs($0 - seconds) < abs($1 - seconds) } ?? 1.0
    }

    /// Seconds-per-sample view over the persisted `refreshHz`. The UI and the
    /// sampler both speak seconds; Hz stays the stored form so existing boards
    /// decode unchanged (no schema bump).
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

    /// Always consumes exactly one unkeyed element so a failed placement decode
    /// (e.g. unknown kind from a newer build) skips that element instead of
    /// corrupting the rest of the array.
    private struct LossyPlacement: Decodable {
        let value: MonitorWidgetPlacement?
        init(from decoder: Decoder) {
            value = try? MonitorWidgetPlacement(from: decoder)
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

        // v4 only ever normalized `gridColumns`, which is gone — the board has
        // laid out free-form against `MonitorBoardGeometry` (board size ÷ Apple
        // cell pitch) for a while now. The bump is kept so a re-encoded board
        // still records the newest schema it has been through.
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
    /// Absent or corrupt key → nil (do not invent a default over real layout).
    public static func decodeIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> MonitorBoardConfiguration? {
        guard container.contains(key) else { return nil }
        return try? container.decode(MonitorBoardConfiguration.self, forKey: key)
    }

    static let defaultSystemKinds: [(MonitorWidgetKind, MonitorWidgetSize)] = [
        (.cpu, .medium), (.memory, .medium), (.gpu, .medium),
    ]

    public static func defaultSystemPlacements() -> [MonitorWidgetPlacement] {
        packedPlacements(for: defaultSystemKinds)
    }

    /// Apple-frame cell pitch (schema packs without importing the renderer).
    static let referenceCellPitch = (width: 194.0, height: 206.0)
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
