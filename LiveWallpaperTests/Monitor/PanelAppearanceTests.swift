@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Monitor widget card appearance")
struct PanelAppearanceTests {
    @MainActor @Test("Every supported tile renders at its actual footprint")
    func renderAllTileFootprints() throws {
        let now = Date()
        var system = MonitorSystemSnapshot(cpuTotal: 0.42, cpuUser: 0.3, cpuSystem: 0.12,
                                           perCore: [0.2, 0.3, 0.4, 0.5, 0.7, 0.2, 0.8, 0.4],
                                           memUsedBytes: 21_000_000_000, memTotalBytes: 32_000_000_000,
                                           gpuUsage: 0.54, netRxBytesPerSec: 8_400_000, netTxBytesPerSec: 1_200_000,
                                           diskReadBytesPerSec: 12_000_000, diskWriteBytesPerSec: 3_000_000,
                                           batteryLevel: 0.72, batteryCharging: false)
        var processes: [MonitorProcessSample] = []
        for index in 0 ..< 20 {
            let name = index == 0 ? "Very long application name" : "Application \(index)"
            let cpu = index == 0 ? 327.0 : Double(40 - index)
            processes.append(MonitorProcessSample(name: name, cpuPercent: cpu, memBytes: 1_400_000_000))
        }
        system.topProcesses = processes
        system.memBreakdown = MonitorMemoryBreakdown(appBytes: 14_000_000_000, wiredBytes: 4_000_000_000,
                                                     compressedBytes: 3_000_000_000, cachedFilesBytes: 2_000_000_000)
        system.cpuInfo = MonitorCPUInfo(deviceName: "Apple M4 Pro", coreCount: 8,
                                        coreGroups: [MonitorCPUCoreGroup(name: "Performance", physicalCount: 4),
                                                     MonitorCPUCoreGroup(name: "Efficiency", physicalCount: 4)])
        system.gpuDeviceName = "Apple M4 Pro"
        system.gpuRendererUtil = 0.37
        system.gpuTilerUtil = 0.18
        system.gpuSampledAt = now.timeIntervalSince1970
        system.netInterfaces = [MonitorNetworkInterface(name: "en0", addresses: ["192.168.1.101"], isActive: true)]
        system.netPath = MonitorNetworkPath(status: "satisfied", interfaceType: "wifi")
        system.powerSource = "battery"
        system.aneFootprintPresent = true
        system.aneFootprintBytes = 240_000_000
        system.aneProcesses = [MonitorANEProcess(name: "Long application name", footprintBytes: 240_000_000)]
        system.sensors = MonitorSensorReadings(cpuTempC: 53, gpuTempC: 49, fanRPM: [1200])
        system.sampledAt = now.timeIntervalSince1970
        system.metricSamples = Dictionary(uniqueKeysWithValues: MonitorWidgetKind.allCases.map {
            ($0.rawValue, MonitorMetricSample(available: true, sampledAt: now.timeIntervalSince1970, interval: 1))
        })
        let snapshot = MonitorSnapshot(timestamp: now.timeIntervalSince1970, system: system, agents: [])
        let store = MonitorHistoryStore()
        for index in 0 ..< 60 {
            var frame = snapshot
            frame.system?.sampledAt = now.timeIntervalSince1970 - Double(59 - index)
            frame.system?.gpuSampledAt = now.timeIntervalSince1970 - Double(59 - index)
            frame.system?.cpuTotal = 0.2 + Double(index % 10) * 0.05
            store.ingest(frame)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LoomscreenWidgetVisualReview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for kind in MonitorWidgetKind.allCases {
            let row = HStack(alignment: .top, spacing: 20) {
                ForEach(kind.allowedSizes, id: \.self) { size in
                    let cells = kind.cellSize(for: size)
                    WidgetFactory.tile(context: MonitorWidgetContext(snapshot: snapshot, history: store.current,
                                                                     placement: MonitorWidgetPlacement(kind: kind, size: size), isEditing: false, reduceMotion: true, now: now))
                        .frame(width: CGFloat(cells.columns) * 186 - 16, height: CGFloat(cells.rows) * 186 - 16)
                }
            }
            .padding(20)
            .background(Color.white)
            .environment(\.locale, AppLanguagePreference.current.locale)
            let renderer = ImageRenderer(content: row)
            renderer.scale = 1
            let rendered = try #require(renderer.cgImage)
            #expect(rendered.width > 350)
            let bitmap = NSBitmapImageRep(cgImage: rendered)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(kind.rawValue).png"))
            if kind == .disk {
                let bounds = NSRect(x: 0, y: 0, width: rendered.width, height: rendered.height)
                let host = NSHostingView(rootView: row)
                let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                host.frame = bounds
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let native = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
                host.cacheDisplay(in: bounds, to: native)
                let nativePNG = try #require(native.representation(using: .png, properties: [:]))
                try nativePNG.write(to: directory.appendingPathComponent("disk-native.png"))
            }
        }
        print("Widget visual review: \(directory.path)")
    }

    @Test("Reduced transparency is opaque and faint labels stay readable over white")
    func contrastSurvivesBrightBackgrounds() throws {
        func rgb(_ color: Color) throws -> NSColor {
            try #require(NSColor(color).usingColorSpace(.sRGB))
        }
        func luminance(_ components: [Double]) -> Double {
            let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let ink = try rgb(Design.inkFaint)
        let foreground = luminance([ink.redComponent, ink.greenComponent, ink.blueComponent])
        for hex in ["", "#FFFFFF", "#FFFF00", "#00FFFF", "#FF00FF"] {
            let opaque = MonitorPanelAppearance.fill(tintHex: hex, opacity: 0.25, reduceTransparency: true)
            #expect(try rgb(opaque.top).alphaComponent == 1)
            #expect(try rgb(opaque.bottom).alphaComponent == 1)
            let fill = try rgb(MonitorPanelAppearance.fill(tintHex: hex, opacity: 0.25).top)
            let background = luminance([fill.redComponent, fill.greenComponent, fill.blueComponent].map {
                $0 * fill.alphaComponent + 1 - fill.alphaComponent
            })
            #expect((foreground + 0.05) / (background + 0.05) >= 4.5)
        }
    }

    /// Liquid Glass is the one card style that can be vetoed by something other
    /// than the user: Reduce Transparency turns off the transparency the whole
    /// material is made of, and below macOS 26 there is no Liquid Glass to draw.
    @Test("Reduce Transparency overrides the switch")
    func reduceTransparencyWins() {
        #expect(!MonitorPanelAppearance.usesGlass(true, reduceTransparency: true))
        #expect(!MonitorPanelAppearance.usesGlass(false, reduceTransparency: true))
        #expect(!MonitorPanelAppearance.usesGlass(false, reduceTransparency: false))
    }

    @Test("the switch decides on an OS that has the material")
    func switchDecidesWhenAvailable() {
        let expected: Bool
        if #available(macOS 26.0, *) { expected = true } else { expected = false }
        #expect(MonitorPanelAppearance.usesGlass(true, reduceTransparency: false) == expected)
    }

    /// Opt-in, and not only because of the OS floor: glass re-samples what is
    /// behind it every frame, and behind these cards is a wallpaper that may be
    /// a live scene.
    @Test("glass is off until asked for")
    func glassIsOptIn() {
        #expect(MonitorPanelAppearance.defaultGlass == false)
    }

    /// The scrim has to stay lighter than the painted card's own fill — the
    /// point is that the wallpaper still shows through the body — while the
    /// opacity dial keeps meaning the same thing in both styles.
    @Test("the glass scrim is lighter than the painted fill but tracks opacity")
    func glassScrimIsLighterAndTracksOpacity() {
        func alpha(_ color: Color) -> Double {
            Double(NSColor(color).usingColorSpace(.sRGB)?.alphaComponent ?? 1)
        }
        let hex = "#3366FF"
        let scrimFull = alpha(MonitorPanelAppearance.glassScrim(tintHex: hex, opacity: 1))
        let paintedFull = alpha(MonitorPanelAppearance.fill(tintHex: hex, opacity: 1).top)
        #expect(scrimFull < paintedFull)
        #expect(scrimFull > 0)

        let scrimHalf = alpha(MonitorPanelAppearance.glassScrim(tintHex: hex, opacity: 0.5))
        #expect(scrimHalf < scrimFull)
    }

    /// A malformed stored hex must not paint the card black — same rule the
    /// painted fill already follows.
    @Test("a malformed tint falls back instead of painting black")
    func malformedTintFallsBack() {
        let bad = MonitorPanelAppearance.glassScrim(tintHex: "not-a-colour", opacity: 1)
        let designed = MonitorPanelAppearance.glassScrim(tintHex: "", opacity: 1)
        #expect(NSColor(bad).usingColorSpace(.sRGB) == NSColor(designed).usingColorSpace(.sRGB))
    }
}
