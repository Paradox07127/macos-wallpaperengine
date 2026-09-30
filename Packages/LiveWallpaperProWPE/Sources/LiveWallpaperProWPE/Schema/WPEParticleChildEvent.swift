import Foundation

/// The authored event type remains on the reference. Unknown values never acquire
/// static/follow semantics from flags; flags are the legacy fallback for absence only.
public enum WPEParticleChildEventKind: Equatable, Sendable {
    case staticSystem, follow, spawn, death
    case unsupported(String)

    public init(authoredType: String?, flags: Int?) {
        guard let authoredType else {
            self = flags.map { ($0 & 2) != 0 } == true ? .follow : .staticSystem
            return
        }
        switch authoredType.lowercased() {
        case "static": self = .staticSystem
        case "eventfollow": self = .follow
        case "eventspawn": self = .spawn
        case "eventdeath": self = .death
        default: self = .unsupported(authoredType)
        }
    }

    public var isEventDriven: Bool {
        switch self {
        case .follow, .spawn, .death: true
        case .staticSystem, .unsupported: false
        }
    }
}
