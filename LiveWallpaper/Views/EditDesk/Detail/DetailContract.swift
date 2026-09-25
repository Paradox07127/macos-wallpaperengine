import CoreGraphics
import Foundation
import LiveWallpaperCore
import SwiftUI

// Seam for M3: the half-immersive display detail. Pure geometry and value types only; the
// shell renders them, the host in `HomePage` drives the flight handshake with the stage.

/// GAP_ANALYSIS.md §8.2 layout B in window points (title bar included, like the stage's `stageSize`):
/// the preview on the left, a resident inspector column on the right.
enum DetailGeometry {
    static let topBarHeight: CGFloat = 56
    static let inspectorWidth: CGFloat = 372
    static let sideMargin: CGFloat = 24
    /// Fixed 16:9, never the display's own ratio.
    static let heroAspect: CGFloat = 16 / 9

    /// Everything left of the inspector and below the top bar.
    static func stageRect(in windowSize: CGSize, inspectorWidth: CGFloat = Self.inspectorWidth) -> CGRect {
        CGRect(
            x: 0, y: topBarHeight,
            width: windowSize.width - inspectorWidth,
            height: windowSize.height - topBarHeight
        )
    }

    static func heroFrame(in windowSize: CGSize, inspectorWidth: CGFloat = Self.inspectorWidth) -> CGRect {
        let stage = stageRect(in: windowSize, inspectorWidth: inspectorWidth)
        let verticalBudget = max(1, stage.height - 2 * sideMargin)
        let width = max(1, min(stage.width - 2 * sideMargin, verticalBudget * heroAspect))
        let height = width / heroAspect
        let blockHeight = height
        return CGRect(
            x: stage.minX + (stage.width - width) / 2,
            y: stage.minY + (stage.height - blockHeight) / 2,
            width: width, height: height
        )
    }
}

/// What the detail top bar shows for every display, current one included.
struct DetailDisplayTag: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var thumbnail: CGImage?
    var isCurrent: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.thumbnail === rhs.thumbnail && lhs.isCurrent == rhs.isCurrent
    }
}

/// What the wallpaper column shows: an inspected attempt takes the whole column, the two failure
/// notices sit above the empty setup or the hero.
enum DetailPreviewState: Equatable {
    case empty, preparing, prepareFailed, lastAttemptFailed, runtimeError, hero

    /// `attempt` is the display's load attempt whether or not it is inspected; `applying` is an apply
    /// from the Edit Desk still waiting on this display.
    static func resolve(
        hasConfiguration: Bool, attempt: WallpaperLoadAttempt?, hasRuntimeError: Bool, applying: Bool = false
    ) -> Self {
        if let attempt, attempt.isInspecting {
            return attempt.phase == .failed ? .prepareFailed : .preparing
        }
        if applying {
            return .preparing
        }
        if attempt?.phase == .failed {
            return .lastAttemptFailed
        }
        if hasRuntimeError {
            return .runtimeError
        }
        return hasConfiguration ? .hero : .empty
    }

    var showsAttempt: Bool {
        self == .preparing || self == .prepareFailed
    }

    /// Whether a runtime error, when the display has one, gets its banner. It is independent of a failed
    /// attempt, so it also stands under that notice; only an attempt's page, which fills the column, hides it.
    var showsRuntimeError: Bool {
        !showsAttempt
    }
}

/// What the still hero's chips and its HUD transport say; the desktop is the live preview, the
/// hero a frame grab, so the transport follows the desktop session, never the still.
struct DetailHeroStatus: Equatable {
    var title: String
    var kindLine: String
    /// The user's play intent, which a policy pause leaves set; nil when no player is running.
    var intendsToPlay: Bool?
    /// Why a policy holds the desktop session stopped; nil while none does.
    var pauseReason: String?
    var canNavigatePlaylist = false
    var facts: [DetailFact] = []
}

struct DetailFact: Equatable {
    let text: String
    var isWarning = false
}

/// The facts the old page's information overlays show over its preview, with their rules and order.
@MainActor
enum DetailFacts {
    /// `fileSize` in bytes; nil leaves it out.
    static func video(format: VideoFormatInfo?, fileSize: Int64?) -> [DetailFact] {
        var facts = (format?.badges ?? []).map { DetailFact(text: $0.displayLabel) }
        if let resolution = format?.resolution {
            facts.append(DetailFact(text: "\(Int(resolution.width))×\(Int(resolution.height))"))
        }
        if let frameRate = format?.frameRate {
            facts.append(DetailFact(text: "\(Int(frameRate)) FPS"))
        }
        if let fileSize {
            facts.append(DetailFact(text: WorkshopByteFormatter.kilobytesAndUp.string(fromByteCount: fileSize)))
        }
        return facts
    }

    static func web(source: HTMLSource?, config: HTMLConfig) -> [DetailFact] {
        guard let source else { return [] }
        var facts: [DetailFact] = []
        if source.isInsecureURL {
            facts.append(DetailFact(text: "HTTP", isWarning: true))
        }
        if case .url = source, config.allowJavaScript {
            facts.append(DetailFact(text: "JS"))
        } else if !config.allowJavaScript {
            facts.append(DetailFact(text: String(localized: "No JS", bundle: .appLanguage), isWarning: true))
        }
        if config.physicalPixelLayout {
            facts.append(DetailFact(text: String(localized: "Phys PX", bundle: .appLanguage)))
        }
        if config.allowMouseInteraction {
            facts.append(DetailFact(text: String(localized: "Clicks", bundle: .appLanguage)))
        }
        return facts
    }

    #if !LITE_BUILD
    static func scene(origin: WPEOrigin, descriptor: SceneDescriptor) -> [DetailFact] {
        var facts: [DetailFact] = []
        if origin.requiresWindowsPlugin || descriptor.preflightFeatureFlags.contains(.windowsPlugin) {
            facts.append(DetailFact(text: String(localized: "Win plugin", bundle: .appLanguage), isWarning: true))
        }
        if descriptor.capabilityTier == .unsupported {
            facts.append(DetailFact(text: descriptor.capabilityTier.localizedLabel, isWarning: true))
        }
        if descriptor.assetStorage == .sourceDirectory {
            facts.append(DetailFact(text: String(localized: "Folder", bundle: .appLanguage)))
        }
        if !descriptor.dependencyWorkshopIDs.isEmpty {
            let dependencies = String(localized: "Dependencies", bundle: .appLanguage)
            facts.append(DetailFact(text: "\(dependencies) \(descriptor.dependencyWorkshopIDs.count)"))
        }
        return facts
    }
    #endif
}
