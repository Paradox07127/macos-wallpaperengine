import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("MonitorBoardConfiguration")
struct MonitorBoardConfigurationTests {

    // MARK: - Defaults

    @Test("Default configuration matches the frozen v4 contract")
    func defaultsMatchContract() {
        let config = MonitorBoardConfiguration.default

        #expect(config.schemaVersion == 4)
        #expect(config.refreshHz == 1.0)
        #expect(config.mouseInteractionEnabled == false)
        #expect(config.reduceMotionOverride == nil)
        #expect(config.widgets.map(\.kind) == [.cpu, .memory, .gpu])
    }

    // MARK: - Refresh interval grid

    @Test("Refresh interval grid is non-uniform and spans exactly the Hz clamp")
    func refreshIntervalGridShape() {
        let steps = MonitorBoardConfiguration.refreshIntervalSteps

        #expect(steps.first == 0.5)
        #expect(steps.last == 5)
        #expect(steps.count == 19)
        #expect(steps == steps.sorted())
        // 0.1 s resolution below 2 s, whole seconds above.
        #expect(steps.filter { $0 < 2 }.count == 15)
        #expect(steps.filter { $0 >= 2 } == [2, 3, 4, 5])
        // The grid bounds must not exceed what the persisted Hz field can hold.
        for step in steps {
            #expect(MonitorBoardConfiguration.clampedRefreshHz(1.0 / step) == 1.0 / step)
        }
    }

    @Test("Every grid step survives the seconds↔Hz round-trip")
    func refreshIntervalRoundTrip() {
        var config = MonitorBoardConfiguration()
        for step in MonitorBoardConfiguration.refreshIntervalSteps {
            config.refreshIntervalSeconds = step
            #expect(config.refreshIntervalSeconds == step, "step \(step) did not round-trip")
        }
    }

    @Test("Out-of-range and non-finite intervals snap into the grid")
    func refreshIntervalSnapping() {
        #expect(MonitorBoardConfiguration.snappedRefreshInterval(0.01) == 0.5)
        #expect(MonitorBoardConfiguration.snappedRefreshInterval(99) == 5)
        #expect(MonitorBoardConfiguration.snappedRefreshInterval(1.23) == 1.2)
        #expect(MonitorBoardConfiguration.snappedRefreshInterval(2.6) == 3)
        #expect(MonitorBoardConfiguration.snappedRefreshInterval(.nan) == 1.0)
    }

    @Test("The default board reads as a 1 s interval")
    func defaultRefreshInterval() {
        #expect(MonitorBoardConfiguration.default.refreshIntervalSeconds == 1.0)
    }

    @Test("Default system placements match the documented kind/size order")
    func defaultSystemPlacementsOrder() {
        let placements = MonitorBoardConfiguration.defaultSystemPlacements()
        #expect(placements.map(\.kind) == [.cpu, .memory, .gpu])
        #expect(placements.map(\.size) == [.medium, .medium, .medium])
    }

    // MARK: - Encode/decode round-trip

    @Test("Round-trip preserves all fields including every option value case")
    func roundTripAllOptionCases() throws {
        var config = MonitorBoardConfiguration()
        config.schemaVersion = MonitorBoardConfiguration.currentSchemaVersion // avoid the v2→v3 migration path
        config.refreshHz = 0.75
        config.mouseInteractionEnabled = true
        config.reduceMotionOverride = true
        config.widgets = [
            MonitorWidgetPlacement(
                kind: .cpu,
                size: .small,
                x: 0.25,
                y: 0.5,
                options: [
                    "showGraph": .bool(true),
                    "smoothing": .number(0.42),
                    "label": .string("CPU"),
                    "cores": .stringList(["0", "1", "2", "3"]),
                ]
            ),
            MonitorWidgetPlacement(kind: .fleet, size: .medium, x: 0.1, y: 0.2),
        ]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: data)

        #expect(decoded == config)
    }

    @Test("Bool option value survives round-trip as bool, not number")
    func boolOptionSurvivesAsBool() throws {
        // Any kind works — this exercises bool-option round-tripping, not the kind.
        let placement = MonitorWidgetPlacement(kind: .cpu, options: ["showTrend": .bool(true)])
        var config = MonitorBoardConfiguration()
        config.widgets = [placement]

        let data = try JSONEncoder().encode(config)

        // The JSON itself must contain a literal `true`, not `1`, so a
        // non-Swift reader (or a stricter decoder) also sees a boolean.
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let widgets = try #require(object["widgets"] as? [[String: Any]])
        let options = try #require(widgets.first?["options"] as? [String: Any])
        let rawValue = try #require(options["showTrend"])
        #expect(rawValue as? Bool == true)

        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: data)
        #expect(decoded.widgets.first?.options["showTrend"] == .bool(true))
        #expect(decoded.widgets.first?.options["showTrend"]?.boolValue == true)
        #expect(decoded.widgets.first?.options["showTrend"]?.numberValue == nil)
    }

    // MARK: - Lossy placement decode

    @Test("Lossy decode keeps valid placements in order and drops bad ones")
    func lossyDecodeDropsInvalidPlacements() throws {
        let json = """
        {
          "schemaVersion": 2,
          "widgets": [
            { "id": "00000000-0000-0000-0000-000000000001", "kind": "cpu", "size": "m", "x": 0.1, "y": 0.1, "options": {} },
            { "id": "00000000-0000-0000-0000-000000000002", "kind": "notAKind", "size": "m", "x": 0.2, "y": 0.2, "options": {} },
            "this is not an object at all",
            { "id": "00000000-0000-0000-0000-000000000003", "kind": "memory", "size": "s", "x": 0.3, "y": 0.3, "options": {} }
          ],
          "refreshHz": 1.0,
          "mouseInteractionEnabled": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: json)

        #expect(decoded.widgets.map(\.kind) == [.cpu, .memory])
        #expect(decoded.widgets.map { $0.id.uuidString } == [
            "00000000-0000-0000-0000-000000000001".uppercased(),
            "00000000-0000-0000-0000-000000000003".uppercased(),
        ])
    }

    @Test("Lossy decode drops a structurally invalid element missing the required kind field")
    func lossyDecodeDropsMissingKind() throws {
        let json = """
        {
          "widgets": [
            { "kind": "power", "size": "s", "x": 0.0, "y": 0.0 },
            { "size": "m", "x": 0.5, "y": 0.5 }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: json)

        #expect(decoded.widgets.map(\.kind) == [.power])
    }

    // MARK: - .large size

    @Test("MonitorWidgetSize.large round-trips through its \"l\" raw value")
    func largeSizeRawValueRoundTrips() throws {
        let data = try JSONEncoder().encode(MonitorWidgetSize.large)
        #expect(String(data: data, encoding: .utf8) == "\"l\"")
        let decoded = try JSONDecoder().decode(MonitorWidgetSize.self, from: data)
        #expect(decoded == .large)
    }

    @Test("cellSize(for: .large) is 2x2 for every kind except the Now Playing canvas")
    func largeCellSizeIsTwoByTwo() {
        for kind in MonitorWidgetKind.allCases {
            let cells = kind.cellSize(for: .large)
            #expect(cells.columns == 2 && cells.rows == 2, "\(kind)")
        }
    }

    @Test("allowedSizes matrix matches the design mock's per-kind META, minus xl")
    func allowedSizesMatrix() {
        let mediumLarge: Set<MonitorWidgetKind> = [.processes, .fleet]
        let smallMedium: Set<MonitorWidgetKind> = [.power]
        for kind in MonitorWidgetKind.allCases {
            if mediumLarge.contains(kind) {
                #expect(kind.allowedSizes == [.medium, .large], "\(kind)")
            } else if smallMedium.contains(kind) {
                #expect(kind.allowedSizes == [.small, .medium], "\(kind)")
            } else {
                #expect(kind.allowedSizes == [.small, .medium, .large], "\(kind)")
            }
        }
    }

    @Test("A placement missing the size key defaults to .medium")
    func missingSizeKeyDefaultsToMedium() throws {
        let json = """
        { "widgets": [{ "kind": "cpu", "x": 0.0, "y": 0.0 }] }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: json)
        #expect(decoded.widgets.map(\.size) == [.medium])
    }

    @Test("A placement with an unrecognized size string is dropped, like an unrecognized kind")
    func unknownSizeStringDropsThePlacement() throws {
        let json = """
        {
          "widgets": [
            { "kind": "cpu", "size": "m", "x": 0.1, "y": 0.1 },
            { "kind": "memory", "size": "xl", "x": 0.2, "y": 0.2 },
            { "kind": "gpu", "size": "l", "x": 0.3, "y": 0.3 }
          ]
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: json)
        #expect(decoded.widgets.map(\.kind) == [.cpu, .gpu])
    }

    // MARK: - Missing-key resilience

    @Test("Empty JSON object decodes to full defaults including default placements")
    func emptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: Data("{}".utf8))

        // Compare field-by-field rather than via `==`: `MonitorWidgetPlacement.id`
        // is a fresh random UUID per construction, so two independently built
        // default boards are never Equatable-equal even though every other
        // field matches.
        #expect(decoded.schemaVersion == MonitorBoardConfiguration.default.schemaVersion)
        #expect(decoded.refreshHz == MonitorBoardConfiguration.default.refreshHz)
        #expect(decoded.mouseInteractionEnabled == MonitorBoardConfiguration.default.mouseInteractionEnabled)
        #expect(decoded.reduceMotionOverride == MonitorBoardConfiguration.default.reduceMotionOverride)
        #expect(decoded.widgets.map(\.kind) == MonitorBoardConfiguration.default.widgets.map(\.kind))
        #expect(decoded.widgets.map(\.size) == MonitorBoardConfiguration.default.widgets.map(\.size))
        #expect(decoded.widgets.map(\.x) == MonitorBoardConfiguration.default.widgets.map(\.x))
        #expect(decoded.widgets.map(\.y) == MonitorBoardConfiguration.default.widgets.map(\.y))
        #expect(decoded.widgets.map(\.kind) == [.cpu, .memory, .gpu])
    }

    @Test("An explicit empty widgets array stays empty and is not re-populated with defaults")
    func explicitEmptyWidgetsStaysEmpty() throws {
        let json = """
        { "widgets": [] }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: json)

        #expect(decoded.widgets.isEmpty)
    }

    // MARK: - Clamping

    @Test("refreshHz clamps to the 0.2...2 window")
    func refreshHzClamps() {
        #expect(MonitorBoardConfiguration(refreshHz: 0.0).refreshHz == 0.2)
        #expect(MonitorBoardConfiguration(refreshHz: 0.1).refreshHz == 0.2)
        #expect(MonitorBoardConfiguration(refreshHz: 5.0).refreshHz == 2.0)
        #expect(MonitorBoardConfiguration(refreshHz: 1.5).refreshHz == 1.5)
    }

    @Test("refreshHz decoded from JSON also clamps")
    func refreshHzClampsOnDecode() throws {
        let json = """
        { "refreshHz": 99.0 }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: json)
        #expect(decoded.refreshHz == 2.0)
    }

    @Test("Placement x/y clamp to 0...1")
    func placementXYClamp() {
        let placement = MonitorWidgetPlacement(kind: .cpu, x: -0.5, y: 1.5)
        #expect(placement.x == 0)
        #expect(placement.y == 1)
    }

    @Test("Non-finite placement x/y clamp to 0")
    func placementNonFiniteClampsToZero() {
        let nanPlacement = MonitorWidgetPlacement(kind: .cpu, x: .nan, y: .nan)
        #expect(nanPlacement.x == 0)
        #expect(nanPlacement.y == 0)

        let infPlacement = MonitorWidgetPlacement(kind: .cpu, x: .infinity, y: -.infinity)
        #expect(infPlacement.x == 0)
        #expect(infPlacement.y == 0)
    }

    // MARK: - Schema migration (→ v4)

    @Test("A v2 board advances to schema v4 on decode")
    func v2BoardMigratesToV4() throws {
        let json = """
        { "schemaVersion": 2, "gridColumns": 12 }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: json)
        #expect(decoded.schemaVersion == 4)
    }

    @Test("A v3 board advances to schema v4 on decode")
    func v3BoardMigratesToV4() throws {
        let json = """
        { "schemaVersion": 3, "gridColumns": 8 }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: json)
        #expect(decoded.schemaVersion == 4)
    }

    @Test("A board with no schemaVersion is treated as current")
    func missingSchemaVersionSkipsMigration() throws {
        let json = """
        { "refreshHz": 1.5 }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: json)
        #expect(decoded.schemaVersion == MonitorBoardConfiguration.currentSchemaVersion)
    }

    // MARK: - packedPlacements geometry invariants

    /// Mirrors `MonitorBoardConfiguration.packedPlacements`' own math so tests
    /// assert against an independently derived reference rather than
    /// hardcoded floats that would silently drift from the production
    /// formula. `columns` here is the packer's own reference-board basis.
    private struct ReferenceAABB {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var maxX: Double { x + width }
        var maxY: Double { y + height }

        func overlaps(_ other: ReferenceAABB) -> Bool {
            x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
        }
    }

    // Square cells at the 16:10 reference: cellW = 1/10 = 0.1,
    // cellH_norm = aspect/columns = 1.6/10 = 0.16 (so cellH_px == cellW_px).
    private static let referenceColumns = 10.0
    private static let referenceAspect = 16.0 / 10.0
    private static let referenceCellW = 1.0 / referenceColumns
    private static let referenceCellH = referenceAspect / referenceColumns

    private func referenceAABB(for placement: MonitorWidgetPlacement) -> ReferenceAABB {
        let cells = placement.kind.cellSize(for: placement.size)
        return ReferenceAABB(
            x: placement.x,
            y: placement.y,
            width: Double(cells.columns) * Self.referenceCellW,
            height: Double(cells.rows) * Self.referenceCellH
        )
    }

    @Test("All packed placements stay within the board on both axes")
    func packedPlacementsWithinBounds() {
        let placements = MonitorBoardConfiguration.defaultSystemPlacements()
        #expect(!placements.isEmpty)
        for placement in placements {
            let aabb = referenceAABB(for: placement)
            #expect(aabb.x >= 0)
            #expect(aabb.y >= 0)
            // Packing is cell-exact (gutters are the renderer's job), so a
            // full 10-column row ends exactly at x=1, never past it.
            #expect(aabb.maxX <= 1.0 + 1e-9)
            #expect(aabb.maxY <= 1.0 + 1e-9)
        }
    }

    @Test("No two packed placements' bounding boxes overlap")
    func packedPlacementsDoNotOverlap() {
        let placements = MonitorBoardConfiguration.defaultSystemPlacements()
        let aabbs = placements.map(referenceAABB(for:))
        for i in 0..<aabbs.count {
            for j in (i + 1)..<aabbs.count where j > i {
                #expect(!aabbs[i].overlaps(aabbs[j]), "placements \(i) and \(j) overlap")
            }
        }
    }

    @Test("A full row wraps: within a row y is shared and x runs left→right")
    func packedPlacementsWrapRows() {
        // 7 mediums (14 cols) exceed the reference board's column count on any
        // plausible pitch, so at least one wrap is guaranteed without hardcoding
        // the column count (now derived from the Apple cell pitch, not a fixed 10).
        let kinds = Array(repeating: (MonitorWidgetKind.cpu, MonitorWidgetSize.medium), count: 7)
        let placements = MonitorBoardConfiguration.packedPlacements(for: kinds)
        let distinctRows = Set(placements.map { ($0.y * 1000).rounded() })
        #expect(distinctRows.count >= 2, "expected the row to wrap")
        // Row one (widgets sharing the first placement's y) runs left→right from x=0.
        let rowOne = placements.filter { $0.y == placements[0].y }
        let xs = rowOne.map(\.x)
        #expect(xs == xs.sorted())
        #expect(xs.first == 0)
    }

    @Test("Later (wrapped) rows sit above earlier rows: smaller y")
    func packedPlacementsLaterRowsHaveSmallerY() {
        let kinds = Array(repeating: (MonitorWidgetKind.cpu, MonitorWidgetSize.medium), count: 7)
        let placements = MonitorBoardConfiguration.packedPlacements(for: kinds)
        #expect(placements.last!.y < placements.first!.y)
    }

    @Test("Widgets that fit within one row all share it")
    func packedPlacementsExactFitStaysOnOneRow() {
        // The 3-medium default (6 cols) fits within the reference board's row.
        let placements = MonitorBoardConfiguration.defaultSystemPlacements()
        #expect(Set(placements.map { ($0.y * 1000).rounded() }).count == 1)
    }

    @Test("Empty kind list packs to no placements")
    func packedPlacementsEmptyInput() {
        #expect(MonitorBoardConfiguration.packedPlacements(for: []).isEmpty)
    }

    // MARK: - decodeIfPresent: board decode boundary

    /// Drives `MonitorBoardConfiguration.decodeIfPresent` from a nested `config`
    /// object, mirroring the `WallpaperContent` / `ScreenConfiguration` call sites.
    /// `decoded` is nil exactly when the decoder returns nil.
    private struct DecodeProbe: Decodable {
        let decoded: MonitorBoardConfiguration?
        enum Key: String, CodingKey { case config }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            decoded = MonitorBoardConfiguration.decodeIfPresent(from: c, forKey: .config)
        }
    }

    private func decodeConfig(_ configJSON: String) throws -> MonitorBoardConfiguration? {
        let json = "{ \"config\": \(configJSON) }"
        return try JSONDecoder().decode(DecodeProbe.self, from: Data(json.utf8)).decoded
    }

    @Test("A corrupt board payload returns nil — never a fabricated default board")
    func corruptBoardReturnsNil() throws {
        // `widgets` is present but is a string, not an array, so the decode throws.
        // The decoder returns nil so the caller treats the slot as absent rather than
        // substituting a bogus default board for the user's real layout.
        let result = try decodeConfig(#"{ "widgets": "not-an-array", "schemaVersion": 2 }"#)
        #expect(result == nil)
    }

    @Test("A wrong-typed field makes the board decode fail closed to nil")
    func wrongTypedFieldReturnsNil() throws {
        let result = try decodeConfig(#"{ "refreshHz": [1,2,3] }"#)  // refreshHz wrong type → throws
        #expect(result == nil)
        #expect(result?.widgets.map(\.kind) != [.cpu, .memory, .gpu])
    }

    @Test("An intact board decodes straight through")
    func intactBoardPassesThrough() throws {
        let result = try decodeConfig(#"{ "schemaVersion": 2, "widgets": [{ "kind": "gpu", "size": "s", "x": 0.1, "y": 0.2 }] }"#)
        #expect(result?.widgets.map(\.kind) == [.gpu])
        #expect(result?.widgets.first?.size == .small)
    }

    @Test("An empty config object decodes to the default system board")
    func emptyObjectDecodesToDefaultBoard() throws {
        // A present-but-empty object is a valid all-default board (widgets absent →
        // default system placements), distinct from an absent slot (→ nil).
        let result = try decodeConfig("{}")
        #expect(result?.widgets.map(\.kind) == [.cpu, .memory, .gpu])
    }

    // MARK: - MonitorWidgetOptionValue decode precedence

    @Test("JSON literal true decodes as .bool, never .number(1)")
    func boolLiteralDecodesAsBoolNotNumber() throws {
        let decoded = try JSONDecoder().decode(MonitorWidgetOptionValue.self, from: Data("true".utf8))
        #expect(decoded == .bool(true))
        if case .number = decoded {
            Issue.record("true decoded as .number instead of .bool")
        }
    }

    @Test("JSON literal false decodes as .bool")
    func falseLiteralDecodesAsBool() throws {
        let decoded = try JSONDecoder().decode(MonitorWidgetOptionValue.self, from: Data("false".utf8))
        #expect(decoded == .bool(false))
    }

    @Test("A numeric literal decodes as .number")
    func numericLiteralDecodesAsNumber() throws {
        let decoded = try JSONDecoder().decode(MonitorWidgetOptionValue.self, from: Data("1".utf8))
        #expect(decoded == .number(1))
    }

    @Test("A string literal decodes as .string")
    func stringLiteralDecodesAsString() throws {
        let decoded = try JSONDecoder().decode(MonitorWidgetOptionValue.self, from: Data("\"hello\"".utf8))
        #expect(decoded == .string("hello"))
    }

    @Test("A string array literal decodes as .stringList")
    func stringArrayLiteralDecodesAsStringList() throws {
        let decoded = try JSONDecoder().decode(MonitorWidgetOptionValue.self, from: Data("[\"a\",\"b\"]".utf8))
        #expect(decoded == .stringList(["a", "b"]))
    }

    // MARK: - intValue(clampedTo:)

    /// An imported layout carries its option bag verbatim, so every widget that
    /// turns an option into an `Int` is a crash site until the value is clamped.
    /// `1e300` is the probe because it is finite: an `isFinite` guard passes it
    /// and `Int(_:)` still traps.
    @Test("An out-of-range option clamps to the bound instead of trapping")
    func outOfRangeOptionClamps() throws {
        let decoded = try JSONDecoder().decode(
            MonitorWidgetOptionValue.self,
            from: Data("1e300".utf8)
        )
        #expect(decoded.numberValue?.isFinite == true)
        #expect(decoded.intValue(clampedTo: 1 ... 50) == 50)
        #expect(
            MonitorWidgetOptionValue.number(-1e300).intValue(clampedTo: 1 ... 50) == 1
        )
        #expect(
            MonitorWidgetOptionValue.number(.infinity).intValue(clampedTo: 1 ... 50) == 50
        )
        #expect(
            MonitorWidgetOptionValue.number(.nan).intValue(clampedTo: 1 ... 50) == nil
        )
    }

    @Test("Clamping survives a bound of Int.max, where Double(Int.max) overflows")
    func clampingSurvivesIntMaxBound() {
        #expect(
            MonitorWidgetOptionValue.number(1e300)
                .intValue(clampedTo: 0 ... Int.max) == Int.max
        )
    }

    @Test("In-range options round to the nearest Int and non-numbers stay nil")
    func inRangeOptionsRound() {
        #expect(MonitorWidgetOptionValue.number(7.4).intValue(clampedTo: 1 ... 50) == 7)
        #expect(MonitorWidgetOptionValue.number(7.6).intValue(clampedTo: 1 ... 50) == 8)
        #expect(MonitorWidgetOptionValue.string("7").intValue(clampedTo: 1 ... 50) == nil)
        #expect(MonitorWidgetOptionValue.bool(true).intValue(clampedTo: 1 ... 50) == nil)
    }
}
