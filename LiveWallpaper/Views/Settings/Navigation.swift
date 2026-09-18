import Foundation
import LiveWallpaperCore
import SwiftUI

enum SettingsSearchAnchor: String, Hashable, Identifiable, Sendable {
    case generalAppearance
    case generalStartup
    case generalWallpaper
    case displayDefaultsArrangement
    case displayDefaultsVideo
    case displayDefaultsWeb
    case displayDefaultsScene
    case integrationsAudio
    case integrationsWeather
    case overlaysAppearance
    case overlaysUnits
    case performancePause
    case performanceRendering
    case performanceMemory
    case shortcutsMaster
    case shortcutsGlobal
    case storageDashboard
    case storageCaches
    case workshopSetup
    case workshopConnection
    case workshopAssets
    case workshopContent
    case workshopDiagnostics
    case workshopLegal
    case workshopBadges

    var id: String { rawValue }
}

struct SettingsNavigationSearchResult: Identifiable, Equatable {
    let item: SettingsNavigationItem
    let anchor: SettingsSearchAnchor?
    let matchHint: String?

    var id: String {
        "\(item.destination.rawValue):\(anchor?.rawValue ?? "category")"
    }

    var destination: SettingsNavigation { item.destination }
    var title: String { item.title }
    var systemImage: String { item.systemImage }
}

/// Sidebar grouping. Names avoid every page title so the sidebar never reads
/// "General > General".
enum SettingsNavigationGroup: String, CaseIterable, Hashable, Identifiable {
    case setup
    case playback
    case content
    case data
    case support

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .setup: "Setup"
        case .playback: "Playback"
        case .content: "Content"
        case .data: "Data"
        case .support: "Support"
        }
    }
}

enum SettingsNavigation: String, CaseIterable, Hashable, Identifiable {
    case general
    case displayDefaults
    case systemWallpaper
    case performancePower
    case integrations
    case overlays
    case shortcuts
    case storage
    case backupRestore
    case workshopSetup
    case advanced
    case about

    var id: String { rawValue }

    static func availableItems(
        capabilities: ProductCapabilities,
        includeWorkshopOnline: Bool = false
    ) -> [SettingsNavigationItem] {
        allItems.filter { item in
            switch item.destination {
            case .systemWallpaper:
                if #available(macOS 26.0, *) {
                    true
                } else {
                    false
                }
            case .integrations, .overlays:
                // Weather and overlay widgets ship on every SKU; only the audio row
                // inside Integrations compiles out of Lite.
                true
            case .storage:
                capabilities.enabledFeatures.contains(.wpeImport)
            case .workshopSetup:
                capabilities.sku == .pro
                    && (includeWorkshopOnline || capabilities.enabledFeatures.contains(.workshopOnline))
            default:
                true
            }
        }
    }

    static func filteredResults(
        matching query: String,
        capabilities: ProductCapabilities,
        includeWorkshopOnline: Bool = false
    ) -> [SettingsNavigationSearchResult] {
        let items = availableItems(
            capabilities: capabilities,
            includeWorkshopOnline: includeWorkshopOnline
        )
        let terms = query
            .localizedStandardTokens
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else {
            return items.map {
                SettingsNavigationSearchResult(item: $0, anchor: nil, matchHint: nil)
            }
        }

        return items.compactMap { item in
            if let target = item.searchTargets(capabilities: capabilities).first(where: { $0.matches(terms: terms) }) {
                return SettingsNavigationSearchResult(
                    item: item,
                    anchor: target.anchor,
                    matchHint: target.matchHint(matching: terms)
                )
            }

            let searchableText = item.searchableText()
            guard terms.allSatisfy({ searchableText.localizedCaseInsensitiveContains($0) }) else {
                return nil
            }
            return SettingsNavigationSearchResult(
                item: item,
                anchor: nil,
                matchHint: item.searchMatchHint(matching: query)
            )
        }
    }

    static let allItems: [SettingsNavigationItem] = [
        SettingsNavigationItem(
            destination: .general,
            group: .setup,
            title: "General",
            systemImage: "gearshape",
            keywords: [
                "language", "login", "dock", "lock screen", "behavior",
                "Show wallpaper in screen captures", "screenshots", "recording", "screen sharing",
                "在截屏与共享中显示壁纸", "在截圖與共享中顯示桌布",
                "画面キャプチャに壁紙を表示", "Mostrar el fondo en capturas de pantalla",
            ]
        ),
        SettingsNavigationItem(
            destination: .displayDefaults,
            group: .setup,
            title: "Display Defaults",
            systemImage: "rectangle.3.group",
            keywords: [
                "screen defaults", "screen default",
                "playback defaults", "reset display", "new display", "baseline",
                "frame rate", "fps", "volume", "mute", "scaling", "color space", "interaction",
                "帧率", "屏幕默认", "显示默认", "影格率", "フレームレート",
                "fotogramas",
            ]
        ),
        SettingsNavigationItem(
            destination: .shortcuts,
            group: .setup,
            title: "Shortcuts",
            systemImage: "command",
            keywords: ["global shortcuts", "hotkeys", "keyboard"]
        ),
        SettingsNavigationItem(
            destination: .performancePower,
            group: .playback,
            title: "Performance",
            systemImage: "bolt.circle",
            keywords: [
                "power", "battery", "fullscreen", "game", "covered", "frame rate", "fps",
                "帧率", "fotogramas", "memory", "video preload", "Adaptive frame rate",
                "自适应帧率", "自適應影格率", "適応フレームレート", "Frecuencia de fotogramas adaptativa",
            ]
        ),
        SettingsNavigationItem(
            destination: .integrations,
            group: .playback,
            title: "Integrations",
            systemImage: "app.connected.to.app.below.fill",
            // Audio terms stay out: they belong to a Pro-only section, and the
            // capability-gated search target below is what must decide their visibility.
            keywords: [
                "weather", "location", "rain", "snow", "fog", "conditions",
                "天气", "位置", "天氣", "天気", "clima",
            ]
        ),
        SettingsNavigationItem(
            destination: .overlays,
            group: .playback,
            title: "Overlays",
            systemImage: "square.on.square.badge.person.crop",
            keywords: [
                "monitor", "widget", "tint", "opacity", "liquid glass",
                "temperature", "celsius", "fahrenheit",
                "组件", "浮层", "温度", "浮層", "溫度", "ウィジェット", "温度", "widget",
            ]
        ),
        SettingsNavigationItem(
            destination: .systemWallpaper,
            group: .content,
            title: "System Wallpaper",
            systemImage: "macwindow.on.rectangle",
            keywords: [
                "Video playback", "Lock screen only", "extension", "Spaces", "Maintenance",
                "Inspect Registrations", "Restart Wallpaper Service", "Automatically recover stalled connections",
                "解锁", "锁屏", "播放", "维护", "修复", "重启", "扩展", "維護", "修復", "延伸功能",
                "保守", "修復", "再起動", "mantenimiento", "reparar", "reiniciar",
            ]
        ),
        SettingsNavigationItem(
            destination: .workshopSetup,
            group: .content,
            title: "Workshop",
            systemImage: "cube.transparent",
            keywords: ["steam", "api key", "steamcmd", "doctor", "online browse"]
        ),
        SettingsNavigationItem(
            destination: .storage,
            group: .data,
            title: "Storage",
            systemImage: "internaldrive",
            keywords: ["cache", "disk", "wallpaper engine", "downloaded projects", "clear"]
        ),
        SettingsNavigationItem(
            destination: .backupRestore,
            group: .data,
            title: "Backup & Restore",
            systemImage: "arrow.triangle.2.circlepath",
            keywords: ["import", "export", "configuration", "display defaults", "bookmarks"]
        ),
        SettingsNavigationItem(
            destination: .advanced,
            group: .support,
            title: "Advanced",
            systemImage: "slider.horizontal.3",
            keywords: ["logs", "diagnostics"]
        ),
        SettingsNavigationItem(
            destination: .about,
            group: .support,
            title: "About",
            systemImage: "info.circle",
            keywords: ["version", "github", "report bug", "welcome tour"]
        ),
    ]
}

struct SettingsNavigationItem: Identifiable, Equatable {
    let destination: SettingsNavigation
    let group: SettingsNavigationGroup
    let title: String
    let systemImage: String
    let keywords: [String]

    var id: SettingsNavigation { destination }

    func searchableText() -> String {
        Self.searchIndexes[destination] ?? buildSearchableText()
    }

    private func buildSearchableText() -> String {
        (title.localizedInEveryLanguage + keywords).joined(separator: " ")
    }

    /// Built once: `allItems` is a `static let`, and the index no longer depends on the
    /// current language, so it can never go stale.
    private static let searchIndexes: [SettingsNavigation: String] = Dictionary(
        uniqueKeysWithValues: SettingsNavigation.allItems.map { ($0.destination, $0.buildSearchableText()) }
    )

    fileprivate func searchTargets(capabilities: ProductCapabilities) -> [SettingsNavigationSearchTarget] {
        switch destination {
        case .displayDefaults:
            var targets: [SettingsNavigationSearchTarget] = []
            if capabilities.canRender(.video) {
                targets.append(
                    SettingsNavigationSearchTarget(
                        label: "Video",
                        anchor: .displayDefaultsVideo,
                        keywords: [
                            "video", "frame rate", "fps", "volume", "mute", "scaling",
                            "span displays", "color space", "帧率", "影格率", "フレームレート",
                        ]
                    )
                )
            }
            if capabilities.canRender(.html) {
                targets.append(
                    SettingsNavigationSearchTarget(
                        label: "Web",
                        anchor: .displayDefaultsWeb,
                        keywords: [
                            "web", "html", "interaction", "pointer", "click", "mute audio",
                            "web audio",
                        ]
                    )
                )
            }
            if capabilities.canRender(.scene) {
                targets.append(
                    SettingsNavigationSearchTarget(
                        label: "Scene",
                        anchor: .displayDefaultsScene,
                        keywords: [
                            "scene", "wallpaper engine", "frame rate", "fps", "scaling",
                            "interaction", "follow cursor",
                        ]
                    )
                )
            }
            return targets
        case .integrations:
            var targets: [SettingsNavigationSearchTarget] = []
            if capabilities.sku == .pro {
                targets.append(
                    SettingsNavigationSearchTarget(
                        label: "Audio Response",
                        anchor: .integrationsAudio,
                        keywords: ["audio", "music", "sound", "reactive", "frequency spectrum"]
                    )
                )
            }
            targets.append(
                SettingsNavigationSearchTarget(
                    label: "Weather",
                    anchor: .integrationsWeather,
                    keywords: ["weather", "location", "rain", "snow", "fog", "conditions"]
                )
            )
            return targets
        case .general:
            return [
                SettingsNavigationSearchTarget(
                    label: "General",
                    anchor: .generalAppearance,
                    keywords: ["language", "appearance", "theme", "dark", "light", "tile size", "library"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Startup",
                    anchor: .generalStartup,
                    keywords: ["login", "start", "launch", "update", "dock", "menu bar"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Wallpaper",
                    anchor: .generalWallpaper,
                    keywords: [
                        "lock", "lock screen", "capture", "screenshot", "screen capture",
                        "recording", "sharing", "desktop picture",
                    ]
                ),
            ]
        case .performancePower:
            var targets: [SettingsNavigationSearchTarget] = [
                SettingsNavigationSearchTarget(
                    label: "Performance & Battery",
                    anchor: .performancePause,
                    keywords: [
                        "pause", "full-screen", "fullscreen", "battery", "low power",
                        "cover", "occlusion", "application", "rules", "exceptions",
                    ]
                ),
            ]
            if capabilities.canRender(.scene) {
                targets.append(
                    SettingsNavigationSearchTarget(
                        label: "Rendering",
                        anchor: .performanceRendering,
                        keywords: [
                            "frame rate", "fps", "adaptive", "metalfx", "upscaling",
                            "hdr", "multithreaded", "rendering",
                        ]
                    )
                )
            }
            targets.append(
                SettingsNavigationSearchTarget(
                    label: "Memory",
                    anchor: .performanceMemory,
                    keywords: ["memory", "ram", "video preload", "preload", "cache"]
                )
            )
            return targets
        case .overlays:
            return [
                SettingsNavigationSearchTarget(
                    label: "Widgets",
                    anchor: .overlaysAppearance,
                    keywords: ["widget", "tint", "opacity", "liquid glass", "panel", "appearance"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Units",
                    anchor: .overlaysUnits,
                    keywords: ["temperature", "celsius", "fahrenheit", "unit"]
                ),
            ]
        case .shortcuts:
            return [
                SettingsNavigationSearchTarget(
                    label: "Shortcuts",
                    anchor: .shortcutsMaster,
                    keywords: ["enable global shortcuts", "master switch", "shortcuts"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Global Shortcuts",
                    anchor: .shortcutsGlobal,
                    keywords: ["global shortcuts", "hotkeys", "keyboard", "bindings"]
                )
            ]
        case .storage:
            return [
                SettingsNavigationSearchTarget(
                    label: "Storage",
                    anchor: .storageDashboard,
                    keywords: [
                        "storage", "downloaded projects", "engine assets", "projects",
                        "archives", "download archives", "reclaim",
                    ]
                ),
                SettingsNavigationSearchTarget(
                    label: "Caches",
                    anchor: .storageCaches,
                    keywords: [
                        "cache", "caches", "video cache", "scene video texture cache",
                        "clear all caches", "wallpaper engine cache"
                    ]
                )
            ]
        case .workshopSetup:
            return [
                SettingsNavigationSearchTarget(
                    label: "Steam Web API key",
                    anchor: .workshopSetup,
                    keywords: ["api key", "steam web api key", "web api", "key"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Steam connection",
                    anchor: .workshopConnection,
                    keywords: [
                        "steam", "steamcmd", "doctor", "diagnostics",
                        "steam library", "steam account", "sign in",
                    ]
                ),
                SettingsNavigationSearchTarget(
                    label: "Wallpaper Engine assets",
                    anchor: .workshopAssets,
                    keywords: [
                        "wallpaper engine assets", "engine assets",
                        "download from steam", "link folder",
                    ]
                ),
                SettingsNavigationSearchTarget(
                    label: "Content",
                    anchor: .workshopContent,
                    keywords: ["mature", "blur mature thumbnails", "hide downloaded", "library"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Thumbnail badges",
                    anchor: .workshopBadges,
                    keywords: [
                        "badge", "thumbnail badges", "rating", "resolution",
                        "wallpaper type", "in use", "update available"
                    ]
                )
            ]
        default:
            return []
        }
    }

    func searchMatchHint(matching query: String) -> String? {
        let terms = query.localizedStandardTokens.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }

        let candidates = [title, title.localized(in: .appLanguage)] + keywords
        let exactCandidate = candidates.first { candidate in
            terms.allSatisfy { candidate.localizedCaseInsensitiveContains($0) }
        }
        if let exactCandidate, exactCandidate.localizedCaseInsensitiveCompare(title) != .orderedSame {
            return exactCandidate.formattedSearchHint
        }

        let partialCandidates = candidates.filter { candidate in
            terms.contains { candidate.localizedCaseInsensitiveContains($0) }
        }
        let hints = partialCandidates
            .filter { $0.localizedCaseInsensitiveCompare(title) != .orderedSame }
            .prefix(2)
            .map(\.formattedSearchHint)

        guard !hints.isEmpty else { return nil }
        return hints.joined(separator: ", ")
    }
}

private struct SettingsNavigationSearchTarget: Equatable {
    let label: String
    let anchor: SettingsSearchAnchor
    let keywords: [String]

    private var searchableText: String {
        (label.localizedInEveryLanguage + keywords).joined(separator: " ")
    }

    func matches(terms: [String]) -> Bool {
        terms.allSatisfy { searchableText.localizedCaseInsensitiveContains($0) }
    }

    func matchHint(matching terms: [String]) -> String {
        let candidates = [label] + keywords
        guard let candidate = candidates.first(where: { candidate in
            terms.allSatisfy { candidate.localizedCaseInsensitiveContains($0) }
        }) else {
            return label
        }

        if candidate.localizedCaseInsensitiveCompare(label) == .orderedSame {
            return label
        }

        return "\(label): \(candidate.formattedSearchHint)"
    }
}

extension String {
    func localized(in bundle: Bundle) -> String {
        String(localized: String.LocalizationValue(self), bundle: bundle)
    }

    /// Every shipped translation of this key, plus the key itself.
    ///
    /// Search indexes all of them rather than only the current language: a bilingual user
    /// running the app in English still searches in their own language, and Apple's own
    /// `.searchTerms` files mix the two for the same reason.
    var localizedInEveryLanguage: [String] {
        [self] + SettingsLocalizationBundles.all.map { localized(in: $0) }
    }
}

enum SettingsLocalizationBundles {
    static let all: [Bundle] = AppLanguagePreference.allCases
        .filter { $0 != .system }
        .map { $0.localizationBundle() }
}

private extension String {
    var localizedStandardTokens: [String] {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var formattedSearchHint: String {
        split(separator: " ")
            .map { token in
                token.lowercased() == "fps" ? "FPS" : token.capitalized
            }
            .joined(separator: " ")
    }
}
