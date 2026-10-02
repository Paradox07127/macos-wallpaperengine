import AppKit

/// The "Wallpaper transition" setting.
enum WallpaperTransitionChoice: String, CaseIterable, Identifiable {
    case none
    case crossfade
    case meteor
    case ink
    case leak
    case aurora
    case weave
    case random

    static let defaultsKey = "loomscreen.wallpapers.transition.v1"
    static let defaultChoice: WallpaperTransitionChoice = .crossfade

    var id: String {
        rawValue
    }

    static func stored(in defaults: UserDefaults = .appScoped()) -> WallpaperTransitionChoice {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? defaultChoice
    }
}

/// A transition that cuts the outgoing wallpaper away with a mask, uncovering the ready new one beneath it.
enum WallpaperRevealEffect: String, CaseIterable {
    case meteor
    case ink
    case leak
    case aurora
    case weave

    var duration: TimeInterval {
        switch self {
        case .meteor: 1.5
        case .ink: 1.6
        case .leak: 1.5
        case .aurora: 1.7
        case .weave: 1.4
        }
    }

    var maskFunctionName: String {
        "wallpaperTransition\(shaderStem)Mask"
    }

    /// nil when the effect draws no overlay.
    var lightFunctionName: String? {
        self == .ink ? nil : "wallpaperTransition\(shaderStem)Light"
    }

    private var shaderStem: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

/// The "Opening animation" setting.
enum WallpaperOpeningChoice: String, CaseIterable, Identifiable {
    case off
    case loom
    case frame
    case dawn
    case random

    static let defaultsKey = "loomscreen.wallpapers.opening.v1"
    static let defaultChoice: WallpaperOpeningChoice = .loom

    var id: String {
        rawValue
    }

    static func stored(in defaults: UserDefaults = .appScoped()) -> WallpaperOpeningChoice {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? defaultChoice
    }
}

/// Played once per display when the first wallpaper after launch appears.
enum WallpaperOpeningEffect: String, CaseIterable {
    case loom
    case frame
    case dawn

    var duration: TimeInterval {
        switch self {
        case .loom: 2.6
        case .frame: 2.4
        case .dawn: 2.8
        }
    }

    var maskFunctionName: String {
        "wallpaperOpening\(shaderStem)Mask"
    }

    var lightFunctionName: String {
        "wallpaperOpening\(shaderStem)Light"
    }

    /// True when the new wallpaper stays on its first frame until the opening finishes.
    var holdsNewWallpaper: Bool {
        self == .loom
    }

    private var shaderStem: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// nil for `.off`.
    static func resolve(_ choice: WallpaperOpeningChoice, using generator: inout some RandomNumberGenerator) -> WallpaperOpeningEffect? {
        switch choice {
        case .off: nil
        case .loom: .loom
        case .frame: .frame
        case .dawn: .dawn
        case .random: allCases.randomElement(using: &generator)
        }
    }
}

enum WallpaperTransitionPace {
    case manual
    case automatic

    var durationScale: Double {
        switch self {
        case .manual: 1
        case .automatic: 1.5
        }
    }
}

/// One user action or automation tick; every display it switches shares one plan and pace.
@MainActor
final class WallpaperSwitchGroup {
    /// Set around automation handlers; tasks they create inherit it up to the commit.
    @TaskLocal static var current: WallpaperSwitchGroup?

    let pace: WallpaperTransitionPace
    private var resolvedPlan: WallpaperTransitionPlan?

    init(pace: WallpaperTransitionPace) {
        self.pace = pace
    }

    /// The first retiring display resolves; later members reuse that result.
    func plan(_ resolve: () -> WallpaperTransitionPlan) -> WallpaperTransitionPlan {
        if let resolvedPlan {
            return resolvedPlan
        }
        let plan = resolve()
        resolvedPlan = plan
        return plan
    }
}

enum WallpaperTransitionPlan: Equatable {
    case none
    case crossfade
    case reveal(WallpaperRevealEffect)

    static let randomPool: [WallpaperTransitionPlan] = [.crossfade] + WallpaperRevealEffect.allCases.map { .reveal($0) }

    /// Reduce Motion and Low Power Mode turn every animated choice into the crossfade, which `Screen` then runs at its short duration.
    /// `previous` is the last random pick; random avoids repeating it.
    static func resolve(
        _ choice: WallpaperTransitionChoice,
        reduceMotion: Bool,
        lowPower: Bool,
        avoiding previous: WallpaperTransitionPlan?,
        using generator: inout some RandomNumberGenerator
    ) -> WallpaperTransitionPlan {
        if choice == .none {
            return .none
        }
        if reduceMotion || lowPower {
            return .crossfade
        }
        switch choice {
        case .none: return .none
        case .crossfade: return .crossfade
        case .meteor: return .reveal(.meteor)
        case .ink: return .reveal(.ink)
        case .leak: return .reveal(.leak)
        case .aurora: return .reveal(.aurora)
        case .weave: return .reveal(.weave)
        case .random:
            let fresh = randomPool.filter { $0 != previous }
            return (fresh.isEmpty ? randomPool : fresh).randomElement(using: &generator) ?? .crossfade
        }
    }

    @MainActor private static var lastRandomPick: WallpaperTransitionPlan?

    @MainActor
    static func current(reduceMotion: Bool, lowPower: Bool) -> WallpaperTransitionPlan {
        var generator = SystemRandomNumberGenerator()
        let choice = WallpaperTransitionChoice.stored()
        let plan = resolve(choice, reduceMotion: reduceMotion, lowPower: lowPower, avoiding: lastRandomPick, using: &generator)
        if choice == .random, !reduceMotion, !lowPower {
            lastRandomPick = plan
        }
        return plan
    }
}
