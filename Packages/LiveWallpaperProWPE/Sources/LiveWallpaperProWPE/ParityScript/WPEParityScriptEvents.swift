/// SceneScript events by WPE's event id (R25 §4); a script receives an event only when it exports the function.
public enum WPEParityScriptEvent: Int, Sendable, CaseIterable {
    case initialize = 0
    case update
    case resizeScreen
    case destroy
    case applyUserProperties
    case applyGeneralSettings
    case animationEvent
    /// Exported bit 0x80; the exe never dispatches it.
    case unused
    case cursorEnter
    case cursorLeave
    case cursorMove
    case cursorClick
    case cursorDown
    case cursorUp
    case mediaStatusChanged
    case mediaPlaybackChanged
    case mediaPropertiesChanged
    case mediaThumbnailChanged
    case mediaTimelineChanged

    /// The exported function's name; nil for the id the exe never sends.
    public var functionName: String? {
        switch self {
        case .initialize: "init"
        case .update: "update"
        case .resizeScreen: "resizeScreen"
        case .destroy: "destroy"
        case .applyUserProperties: "applyUserProperties"
        case .applyGeneralSettings: "applyGeneralSettings"
        case .animationEvent: "animationEvent"
        case .unused: nil
        case .cursorEnter: "cursorEnter"
        case .cursorLeave: "cursorLeave"
        case .cursorMove: "cursorMove"
        case .cursorClick: "cursorClick"
        case .cursorDown: "cursorDown"
        case .cursorUp: "cursorUp"
        case .mediaStatusChanged: "mediaStatusChanged"
        case .mediaPlaybackChanged: "mediaPlaybackChanged"
        case .mediaPropertiesChanged: "mediaPropertiesChanged"
        case .mediaThumbnailChanged: "mediaThumbnailChanged"
        case .mediaTimelineChanged: "mediaTimelineChanged"
        }
    }

    public var exportBit: Int {
        1 << rawValue
    }

    /// Any of these exported turns cursor handling on (140175880.c:377-379).
    public static let cursorBits = 0x3F80
    /// Any of these exported subscribes the engine to media callbacks (140175880.c:373-375).
    public static let mediaBits = 0x7C000
}

/// One object the cursor pass tests, topmost first; `quad` holds its corners in the cursor's space.
public struct WPEParityCursorTarget: Sendable {
    public var id: String
    public var quad: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
    /// +0x120 bit13: only solid objects are tested.
    public var solid: Bool
    /// The object and every ancestor visible.
    public var visible: Bool
    /// +0x120 bit14: a hit stops the objects below from being tested.
    public var disablePropagation: Bool

    public init(id: String, quad: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>), solid: Bool = true,
                visible: Bool = true, disablePropagation: Bool = false) {
        self.id = id
        self.quad = quad
        self.solid = solid
        self.visible = visible
        self.disablePropagation = disablePropagation
    }

    /// Inside the convex quad, edges included.
    public func contains(_ point: SIMD2<Float>) -> Bool {
        var sign: Float = 0
        for (a, b) in [(quad.0, quad.1), (quad.1, quad.2), (quad.2, quad.3), (quad.3, quad.0)] {
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if cross != 0 {
                if sign != 0, (cross > 0) != (sign > 0) {
                    return false
                }
                sign = cross
            }
        }
        return true
    }
}

/// WPE's per-frame cursor pass (140189e10.c:85-484): which objects get enter, leave, move, down, up and click.
public struct WPEParityCursorTracker: Sendable {
    public struct Dispatch: Equatable, Sendable {
        public var event: WPEParityScriptEvent
        public var id: String
    }

    public private(set) var hovered: Set<String> = []
    public private(set) var pressed: Set<String> = []
    private var wasDown = false

    public init() {}

    /// Events of one frame in dispatch order. `moved`: the cursor position changed since the last frame.
    public mutating func update(targets: [WPEParityCursorTarget], cursor: SIMD2<Float>, leftDown: Bool,
                                moved: Bool) -> [Dispatch] {
        var events: [Dispatch] = []
        let edge = leftDown != wasDown
        let dragging = !pressed.isEmpty && leftDown
        for target in targets where target.solid {
            if dragging {
                if moved, pressed.contains(target.id) {
                    events.append(Dispatch(event: .cursorMove, id: target.id))
                }
                continue
            }
            if target.contains(cursor) {
                if hovered.insert(target.id).inserted {
                    events.append(Dispatch(event: .cursorEnter, id: target.id))
                }
                if moved {
                    events.append(Dispatch(event: .cursorMove, id: target.id))
                }
                if edge {
                    events.append(Dispatch(event: leftDown ? .cursorDown : .cursorUp, id: target.id))
                    if !leftDown, pressed.contains(target.id) {
                        events.append(Dispatch(event: .cursorClick, id: target.id))
                    } else if leftDown {
                        pressed.insert(target.id)
                    }
                }
                if target.disablePropagation, target.visible {
                    break
                }
            } else {
                if edge, !leftDown, pressed.contains(target.id) {
                    events.append(Dispatch(event: .cursorUp, id: target.id))
                }
                if hovered.remove(target.id) != nil {
                    events.append(Dispatch(event: .cursorLeave, id: target.id))
                }
            }
        }
        if edge, !leftDown {
            pressed.removeAll(keepingCapacity: true)
        }
        wasDown = leftDown
        return events
    }
}
