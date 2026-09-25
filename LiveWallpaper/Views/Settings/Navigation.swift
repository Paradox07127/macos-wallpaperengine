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
    case systemWallpaperPlayback
    case systemWallpaperStatus
    case systemWallpaperMaintenance
    case systemWallpaperLibrary
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

        let wholeQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.compactMap { item in
            let targets = item.searchTargets(capabilities: capabilities)
            // Exact name first: "Global Shortcuts" also sits inside the earlier "Enable Global Shortcuts" section.
            if let target = targets.first(where: { $0.hasName(equalTo: wholeQuery) })
                ?? targets.first(where: { $0.matches(terms: terms) }) {
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
            keywords: ["import", "export", "configuration", "display defaults", "bookmarks"],
            rows: ["Export Configuration", "Import Configuration"]
        ),
        SettingsNavigationItem(
            destination: .advanced,
            group: .support,
            title: "Advanced",
            systemImage: "slider.horizontal.3",
            keywords: ["logs", "diagnostics"],
            rows: [
                "Copy Diagnostic Summary", "Export Diagnostics", "Report a Bug", "Log Files",
                "Reset All Settings",
            ]
        ),
        SettingsNavigationItem(
            destination: .about,
            group: .support,
            title: "About",
            systemImage: "info.circle",
            keywords: ["version", "github", "report bug", "welcome tour"],
            rows: ["View on GitHub", "Discussions", "Report a Bug", "Welcome Tour"]
        ),
    ]
}

struct SettingsNavigationItem: Identifiable, Equatable {
    let destination: SettingsNavigation
    let group: SettingsNavigationGroup
    let title: String
    let systemImage: String
    let keywords: [String]
    /// Catalog keys of the rows on a page that has no section targets.
    var rows: [String] = []

    var id: SettingsNavigation { destination }

    func searchableText() -> String {
        Self.searchIndexes[destination] ?? buildSearchableText()
    }

    private func buildSearchableText() -> String {
        (title.localizedInEveryLanguage + keywords + rows.flatMap(\.localizedInEveryLanguage)).joined(separator: " ")
    }

    /// Built once: `allItems` is a `static let`, and the index no longer depends on the
    /// current language, so it can never go stale.
    private static let searchIndexes: [SettingsNavigation: String] = Dictionary(
        uniqueKeysWithValues: SettingsNavigation.allItems.map { ($0.destination, $0.buildSearchableText()) }
    )

    func searchTargets(capabilities: ProductCapabilities) -> [SettingsNavigationSearchTarget] {
        switch destination {
        case .displayDefaults:
            var targets: [SettingsNavigationSearchTarget] = [
                SettingsNavigationSearchTarget(
                    label: "Displays",
                    anchor: .displayDefaultsArrangement,
                    rows: [],
                    keywords: []
                ),
            ]
            if capabilities.canRender(.video) {
                targets.append(
                    SettingsNavigationSearchTarget(
                        label: "Video",
                        anchor: .displayDefaultsVideo,
                        rows: ["Mute", "Volume", "Frame Rate", "Scaling", "Color Space"],
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
                        rows: ["Mute audio", "Volume", "Frame Rate", "Interaction"],
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
                        rows: ["Mute", "Volume", "Frame Rate", "Scaling", "Follow Cursor", "Interaction"],
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
                        label: "Audio",
                        anchor: .integrationsAudio,
                        rows: ["Audio Response"],
                        keywords: ["audio", "music", "sound", "reactive", "frequency spectrum"]
                    )
                )
            }
            targets.append(
                SettingsNavigationSearchTarget(
                    label: "Weather",
                    anchor: .integrationsWeather,
                    rows: ["Weather Location"],
                    keywords: ["weather", "location", "rain", "snow", "fog", "conditions"]
                )
            )
            return targets
        case .general:
            return [
                SettingsNavigationSearchTarget(
                    label: "General",
                    anchor: .generalAppearance,
                    rows: [
                        "Language", "Appearance", "Light", "Dark", "Library tile size", "Shelf style",
                        "Main window background", "Cards rendered at once", "Autoplay preview on hover",
                        "Status capsule shows", "Home opens as",
                    ],
                    keywords: [
                        "language", "appearance", "theme", "dark", "light", "tile size", "library",
                        "shelf style", "facing in", "crate", "folders", "fan", "focus row", "cards rendered",
                        "shelf capacity", "autoplay preview", "hover", "status capsule", "system health", "home default",
                        "架子样式", "两侧朝中", "木箱", "文件夹", "扇形", "焦点横排", "状态胶囊", "主界面默认态",
                        "兩側朝中", "資料夾", "焦點橫排", "内向き", "クレート", "フォルダ", "フォーカス",
                        "hacia dentro", "cajón", "carpetas", "abanico", "fila con foco",
                    ]
                ),
                SettingsNavigationSearchTarget(
                    label: "Startup",
                    anchor: .generalStartup,
                    rows: ["Start at login", "Check for updates automatically", "Show in Dock"],
                    keywords: ["login", "start", "launch", "update", "dock", "menu bar"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Wallpaper",
                    anchor: .generalWallpaper,
                    rows: ["Capture video frame when locking", "Show wallpaper in screen captures"],
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
                    rows: [
                        "Pause on full-screen apps", "Pause in Low Power Mode",
                        "Pause when windows cover the desktop", "Pause on battery", "Application Pause Rules",
                    ],
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
                        rows: ["Adaptive frame rate", "MetalFX upscaling", "HDR output", "Multithreaded rendering"],
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
                    rows: ["Video preload (RAM)"],
                    keywords: ["memory", "ram", "video preload", "preload", "cache"]
                )
            )
            return targets
        case .overlays:
            return [
                SettingsNavigationSearchTarget(
                    label: "Widgets",
                    anchor: .overlaysAppearance,
                    rows: ["Widget tint", "Widget opacity", "Liquid Glass"],
                    keywords: ["widget", "tint", "opacity", "liquid glass", "panel", "appearance"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Units",
                    anchor: .overlaysUnits,
                    rows: ["Temperature"],
                    keywords: ["temperature", "celsius", "fahrenheit", "unit"]
                ),
            ]
        case .shortcuts:
            return [
                SettingsNavigationSearchTarget(
                    label: "Shortcuts",
                    anchor: .shortcutsMaster,
                    rows: ["Enable Global Shortcuts"],
                    keywords: ["enable global shortcuts", "master switch", "shortcuts"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Global Shortcuts",
                    anchor: .shortcutsGlobal,
                    rows: [
                        "Play / Pause All Wallpapers", "Next Wallpaper (Active Display)",
                        "Previous Wallpaper (Active Display)", "Toggle Mute", "Toggle Interaction",
                        "Show / Hide All Wallpapers", "Reload All Wallpapers", "Open Settings Window",
                    ],
                    keywords: ["global shortcuts", "hotkeys", "keyboard", "bindings"]
                )
            ]
        case .storage:
            return [
                SettingsNavigationSearchTarget(
                    label: "Storage",
                    anchor: .storageDashboard,
                    rows: ["Wallpapers", "Engine Assets", "System Wallpaper"],
                    keywords: [
                        "storage", "downloaded projects", "engine assets", "projects",
                        "archives", "download archives", "reclaim",
                    ]
                ),
                SettingsNavigationSearchTarget(
                    label: "Caches",
                    anchor: .storageCaches,
                    rows: ["Scene Video Texture Cache"],
                    keywords: [
                        "cache", "caches", "video cache", "scene video texture cache",
                        "clear all caches", "wallpaper engine cache"
                    ]
                )
            ]
        case .workshopSetup:
            return [
                SettingsNavigationSearchTarget(
                    label: "Steam connection",
                    anchor: .workshopConnection,
                    rows: ["Steam library", "SteamCMD", "Steam account", "Subscribed wallpapers"],
                    keywords: [
                        "steam", "steamcmd", "doctor", "diagnostics",
                        "steam library", "steam account", "sign in",
                    ]
                ),
                SettingsNavigationSearchTarget(
                    label: "Scene resources",
                    anchor: .workshopAssets,
                    rows: ["Wallpaper Engine assets", "Check for asset updates at launch"],
                    keywords: [
                        "wallpaper engine assets", "engine assets",
                        "download from steam", "link folder",
                    ]
                ),
                SettingsNavigationSearchTarget(
                    label: "Steam Web API key (optional)",
                    anchor: .workshopSetup,
                    rows: ["Steam Web API key"],
                    keywords: ["api key", "steam web api key", "web api", "key"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Content",
                    anchor: .workshopContent,
                    rows: [
                        "Blur mature thumbnails", "Hide items already in my library", "Show presets as wallpapers",
                        "Default sort", "Default time frame",
                    ],
                    keywords: ["mature", "blur mature thumbnails", "hide downloaded", "library"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Thumbnail badges",
                    anchor: .workshopBadges,
                    rows: [
                        "Wallpaper type", "Type badge style", "Rating", "Resolution", "Already installed",
                        "Update available", "Currently in use",
                    ],
                    keywords: [
                        "badge", "thumbnail badges", "rating", "resolution",
                        "wallpaper type", "in use", "update available",
                    ]
                ),
                SettingsNavigationSearchTarget(
                    label: "Diagnostics",
                    anchor: .workshopDiagnostics,
                    rows: [
                        "SteamCMD binary identity", "Code signature", "Gatekeeper / quarantine",
                        "Steam Library access", "Steam sign-in", "Workshop content folder", "Scene resources",
                        "Background Steam connector",
                    ],
                    keywords: []
                ),
                SettingsNavigationSearchTarget(
                    label: "Privacy & terms",
                    anchor: .workshopLegal,
                    rows: ["File access", "Steam sign-in", "Web API key", "Where requests go", "Wallpaper Engine assets"],
                    keywords: []
                ),
            ]
        case .systemWallpaper:
            return [
                SettingsNavigationSearchTarget(
                    label: "Playback",
                    anchor: .systemWallpaperPlayback,
                    rows: ["Video playback"],
                    keywords: []
                ),
                SettingsNavigationSearchTarget(
                    label: "Extension status",
                    anchor: .systemWallpaperStatus,
                    rows: ["Another app copy provides the system wallpaper"],
                    keywords: []
                ),
                SettingsNavigationSearchTarget(
                    label: "Maintenance",
                    anchor: .systemWallpaperMaintenance,
                    rows: [
                        "Inspect Registrations", "Restart Wallpaper Service",
                        "Automatically recover stalled connections",
                    ],
                    keywords: []
                ),
                SettingsNavigationSearchTarget(
                    label: "System Wallpaper Library",
                    anchor: .systemWallpaperLibrary,
                    rows: ["Remove All from System Wallpaper"],
                    keywords: []
                ),
            ]
        default:
            return []
        }
    }

    func searchMatchHint(matching query: String) -> String? {
        let terms = query.localizedStandardTokens.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }

        if let row = rows.first(where: { row in
            row.localizedInEveryLanguage.contains { text in terms.allSatisfy { text.localizedCaseInsensitiveContains($0) } }
        }) {
            return row.localized(in: .appLanguage)
        }

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

struct SettingsNavigationSearchTarget: Equatable {
    let label: String
    let anchor: SettingsSearchAnchor
    /// Catalog keys of the section's rows, searched in every shipped language like `label`.
    let rows: [String]
    let keywords: [String]

    /// Built once over the Pro superset; valid because capabilities decide only which
    /// sections are offered, never what a section's names are.
    private static let indexes: [SettingsSearchAnchor: SearchIndex] = Dictionary(
        uniqueKeysWithValues: SettingsNavigation.allItems
            .flatMap { $0.searchTargets(capabilities: ProductCapabilities.pro.withWorkshopOnline()) }
            .map { ($0.anchor, SearchIndex($0)) }
    )

    private var index: SearchIndex {
        Self.indexes[anchor] ?? SearchIndex(self)
    }

    func matches(terms: [String]) -> Bool {
        let text = index.text
        return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }

    func hasName(equalTo query: String) -> Bool {
        index.names.contains { name in
            name.texts.contains { $0.localizedCaseInsensitiveCompare(query) == .orderedSame }
        }
    }

    func matchHint(matching terms: [String]) -> String {
        let name = index.names.first { name in
            name.texts.contains { text in terms.allSatisfy { text.localizedCaseInsensitiveContains($0) } }
        }
        if let name {
            return name.key.localized(in: .appLanguage)
        }

        guard let keyword = keywords.first(where: { keyword in
            terms.allSatisfy { keyword.localizedCaseInsensitiveContains($0) }
        }) else {
            return label.localized(in: .appLanguage)
        }

        return String(localized: "\(label.localized(in: .appLanguage)): \(keyword.formattedSearchHint)", bundle: .appLanguage)
    }

    private struct SearchIndex {
        /// `label`, then `rows`; `texts` is the key plus every shipped translation of it.
        let names: [(key: String, texts: [String])]
        let text: String

        init(_ target: SettingsNavigationSearchTarget) {
            names = ([target.label] + target.rows).map { ($0, $0.localizedInEveryLanguage) }
            text = (names.flatMap(\.texts) + target.keywords).joined(separator: " ")
        }
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
