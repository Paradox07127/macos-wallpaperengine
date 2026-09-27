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

enum WallpaperTransitionPlan: Equatable {
    case none
    case crossfade
    case reveal(WallpaperRevealEffect)

    static let randomPool: [WallpaperTransitionPlan] = [.crossfade] + WallpaperRevealEffect.allCases.map { .reveal($0) }

    /// Reduce Motion turns every animated choice into the crossfade, which itself skips the fade under Reduce Motion.
    static func resolve(
        _ choice: WallpaperTransitionChoice,
        reduceMotion: Bool,
        using generator: inout some RandomNumberGenerator
    ) -> WallpaperTransitionPlan {
        if choice == .none {
            return .none
        }
        if reduceMotion {
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
        case .random: return randomPool.randomElement(using: &generator) ?? .crossfade
        }
    }

    static func current() -> WallpaperTransitionPlan {
        var generator = SystemRandomNumberGenerator()
        return resolve(
            WallpaperTransitionChoice.stored(),
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            using: &generator
        )
    }
}
