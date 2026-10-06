import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("StatusCapsule — pure health/thermal mapping")
struct StatusCapsuleTests {
    @MainActor
    private final class Footprint {
        var frames: [PageGuideTarget: CGRect] = [:]
    }

    private struct CapsuleInToolbar: View {
        let content: StatusCapsuleContent
        let windowWidth: CGFloat
        let footprint: Footprint

        var body: some View {
            TopBar(
                page: .constant(.home), workshopAvailable: true,
                windowWidth: windowWidth,
                status: StatusCapsule(
                    content: content,
                    footerLabels: [.displaysConfigured(1), .pausesOnBattery],
                    memoryPressure: { .normal }
                )
            ) { EmptyView() }
            .overlayPreferenceValue(PageGuideAnchorKey.self) { anchors in
                GeometryReader { _ in
                    Color.clear
                        .onGeometryChange(for: [PageGuideTarget: CGRect].self, of: { proxy in
                            anchors.mapValues { proxy[$0] }
                        }, action: { footprint.frames = $0 })
                }
            }
            .frame(width: windowWidth, height: DesignTokens.EditDesk.Spacing.topBar)
        }
    }

    @MainActor
    @Test("Switching to wallpapers-only clears navigation at narrow and wide toolbar sizes", arguments: ["en", "zh-Hans", "zh-Hant", "ja", "es"])
    func wallpapersOnlyDoesNotFillTheToolbar(language: String) throws {
        let footprint = Footprint()
        func root(_ content: StatusCapsuleContent, _ width: CGFloat) -> some View {
            CapsuleInToolbar(content: content, windowWidth: width, footprint: footprint)
                .environment(\.locale, Locale(identifier: language))
        }
        let host = NSHostingView(rootView: root(.systemHealth, 1040))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func layout(_ content: StatusCapsuleContent, _ width: CGFloat) -> CGFloat {
            host.rootView = root(content, width)
            window.setContentSize(NSSize(width: width, height: 100))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let status = footprint.frames[.status] ?? .zero
            let navigation = footprint.frames[.navigation] ?? .zero
            #expect(navigation.width > 0)
            #expect(abs(navigation.midX - width / 2) < 1, "navigation must remain centered")
            if content != .hidden {
                #expect(status.width > 0)
                #expect(status.minX >= navigation.maxX + DesignTokens.iconButtonDiameter(.large) + 2 * DesignTokens.EditDesk.Spacing.s12 - 1,
                        "page guide must leave 12pt beside navigation, plus its 12pt gap to status: \(navigation) / \(status)")
                #expect(status.maxX <= width - DesignTokens.Spacing.lg + 1)
            }
            return status.width
        }
        let collapsed = layout(.systemHealth, 1040)
        let narrow = layout(.wallpapersOnly, 1040)
        let wide = layout(.wallpapersOnly, 1600)
        #expect(collapsed > 0 && collapsed < 200)
        #expect(wide < 300, "the footer must not absorb extra toolbar width: \(wide)")
        #expect(wide >= narrow - 1, "the narrow toolbar may compress the panel")
        _ = layout(.hidden, 1040)
        #expect(abs(layout(.wallpapersOnly, 1040) - narrow) < 1, "hiding and restoring must not change the footprint")
    }

    @Test("Below both thresholds and thermal nominal reads as normal")
    func normalBand() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.1, memoryPressure: .normal, thermal: .nominal)
        #expect(health == .normal)
    }

    @Test("CPU at the elevated threshold reads as elevated load")
    func elevatedByCPU() {
        let health = StatusCapsuleModel.health(cpuPercent: 60, memoryFraction: 0.1, memoryPressure: .normal, thermal: .nominal)
        #expect(health == .elevatedLoad)
    }

    @Test("Memory occupancy alone never warns while the kernel reports normal pressure")
    func occupancyAloneIsNormal() {
        for memory in [0.60, 0.90] {
            let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: memory, memoryPressure: .normal, thermal: .nominal)
            #expect(health == .normal, Comment(rawValue: "memory \(memory)"))
        }
    }

    @Test("Warning and critical memory pressure raise their own bands even at low occupancy")
    func memoryPressureBands() {
        let warning = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.4, memoryPressure: .warning, thermal: .nominal)
        #expect(warning == .memoryWarning)
        let critical = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.4, memoryPressure: .critical, thermal: .nominal)
        #expect(critical == .memoryCritical)
    }

    @Test("Memory pressure outranks CPU load and a fair thermal state")
    func memoryPressureOutranksCPUAndFairHeat() {
        #expect(StatusCapsuleModel.health(cpuPercent: 95, memoryFraction: 0.4, memoryPressure: .warning, thermal: .nominal) == .memoryWarning)
        #expect(StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.4, memoryPressure: .warning, thermal: .fair) == .memoryWarning)
    }

    @Test("Serious and critical heat still win over memory pressure")
    func heatWinsOverMemoryPressure() {
        #expect(StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.4, memoryPressure: .critical, thermal: .serious) == .thermalSerious)
        #expect(StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.4, memoryPressure: .critical, thermal: .critical) == .thermalCritical)
    }

    @Test("A fair thermal state reads as thermal fair even with idle CPU/memory")
    func elevatedByThermalFair() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.1, memoryPressure: .normal, thermal: .fair)
        #expect(health == .thermalFair)
    }

    @Test("CPU at the hot threshold reads as high load")
    func hotByCPU() {
        let health = StatusCapsuleModel.health(cpuPercent: 85, memoryFraction: 0.1, memoryPressure: .normal, thermal: .nominal)
        #expect(health == .highLoad)
    }

    @Test("A serious thermal state reads as thermal serious even with idle CPU/memory")
    func hotByThermalSerious() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.1, memoryPressure: .normal, thermal: .serious)
        #expect(health == .thermalSerious)
    }

    @Test("A critical thermal state reads as thermal critical")
    func hotByThermalCritical() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.1, memoryPressure: .normal, thermal: .critical)
        #expect(health == .thermalCritical)
    }

    @Test("Critical memory pressure with a nominal thermal state reads as memory, not overheating")
    func memoryPressureIsMemoryNotHeat() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.9, memoryPressure: .critical, thermal: .nominal)
        #expect(StatusCapsuleModel.headlineKey(for: health) == "Critical Memory")
    }

    @Test("The footer counts configured displays, says when wallpapers are off, and names only an enabled battery pause")
    func footerLabels() {
        #expect(StatusCapsuleModel.footerLabels(configured: 2, wallpapersEnabled: true, pausesOnBattery: false) == [.displaysConfigured(2)])
        #expect(
            StatusCapsuleModel.footerLabels(configured: 2, wallpapersEnabled: true, pausesOnBattery: true)
                == [.displaysConfigured(2), .pausesOnBattery]
        )
        #expect(StatusCapsuleModel.footerLabels(configured: 2, wallpapersEnabled: false, pausesOnBattery: false) == [.wallpapersOff])
        #expect(
            StatusCapsuleModel.footerLabels(configured: 0, wallpapersEnabled: false, pausesOnBattery: true)
                == [.wallpapersOff, .pausesOnBattery]
        )
    }

    @Test("The footer's display count picks one screen up to one display and two screens from two on")
    func displaysSymbolFollowsTheCount() {
        #expect(StatusCapsuleModel.displaysSymbol(count: 0) == "display")
        #expect(StatusCapsuleModel.displaysSymbol(count: 1) == "display")
        #expect(StatusCapsuleModel.displaysSymbol(count: 2) == "display.2")
        #expect(StatusCapsuleModel.displaysSymbol(count: 3) == "display.2")
        for count in [1, 2] {
            let name = StatusCapsuleModel.displaysSymbol(count: count)
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, Comment(rawValue: name))
        }
    }

    @Test("Headline keys map one-to-one to health bands")
    func headlineKeys() {
        #expect(StatusCapsuleModel.headlineKey(for: .normal) == "System Normal")
        #expect(StatusCapsuleModel.headlineKey(for: .elevatedLoad) == "Elevated Load")
        #expect(StatusCapsuleModel.headlineKey(for: .highLoad) == "High Load")
        #expect(StatusCapsuleModel.headlineKey(for: .memoryWarning) == "Low Memory")
        #expect(StatusCapsuleModel.headlineKey(for: .memoryCritical) == "Critical Memory")
        #expect(StatusCapsuleModel.headlineKey(for: .thermalFair) == "Running Warm")
        #expect(StatusCapsuleModel.headlineKey(for: .thermalSerious) == "Running Hot")
        #expect(StatusCapsuleModel.headlineKey(for: .thermalCritical) == "Critical Heat")
    }

    @Test("Dot color follows success/warning/danger by band")
    func dotColors() {
        #expect(StatusCapsuleModel.dotColor(for: .normal) == DesignTokens.EditDesk.Colors.success)
        #expect(StatusCapsuleModel.dotColor(for: .elevatedLoad) == DesignTokens.EditDesk.Colors.warning)
        #expect(StatusCapsuleModel.dotColor(for: .thermalFair) == DesignTokens.EditDesk.Colors.warning)
        #expect(StatusCapsuleModel.dotColor(for: .memoryWarning) == DesignTokens.EditDesk.Colors.warning)
        #expect(StatusCapsuleModel.dotColor(for: .highLoad) == DesignTokens.EditDesk.Colors.danger)
        #expect(StatusCapsuleModel.dotColor(for: .memoryCritical) == DesignTokens.EditDesk.Colors.danger)
        #expect(StatusCapsuleModel.dotColor(for: .thermalSerious) == DesignTokens.EditDesk.Colors.danger)
        #expect(StatusCapsuleModel.dotColor(for: .thermalCritical) == DesignTokens.EditDesk.Colors.danger)
    }

    @Test("Thermal labels cover all four ProcessInfo states")
    func thermalLabels() {
        #expect(StatusCapsuleModel.thermalLabelKey(.nominal) == "Thermal Nominal")
        #expect(StatusCapsuleModel.thermalLabelKey(.fair) == "Thermal Fair")
        #expect(StatusCapsuleModel.thermalLabelKey(.serious) == "Thermal Serious")
        #expect(StatusCapsuleModel.thermalLabelKey(.critical) == "Thermal Critical")
    }

    @Test("Thermal bar fraction steps 0.25/0.5/0.75/1")
    func thermalBarFractions() {
        #expect(StatusCapsuleModel.thermalBarFraction(.nominal) == 0.25)
        #expect(StatusCapsuleModel.thermalBarFraction(.fair) == 0.5)
        #expect(StatusCapsuleModel.thermalBarFraction(.serious) == 0.75)
        #expect(StatusCapsuleModel.thermalBarFraction(.critical) == 1)
    }

    // MARK: The sentence beside the headline

    private static let appFootprint: UInt64 = 1_288_490_189

    private static func note(
        cpu: Double, memory: Double, pressure: SystemMemoryPressureLevel = .normal, thermal: ProcessInfo.ThermalState = .nominal
    ) -> StatusCapsuleNote {
        StatusCapsuleModel.note(
            cpuPercent: cpu, memoryFraction: memory, memoryPressure: pressure, thermal: thermal,
            appCPUPercent: 3, appMemoryBytes: appFootprint
        )
    }

    @Test("The reviewed panel (CPU 9%, memory 62%) under normal pressure is normal, not a memory warning")
    func occupancyAloneHasTheNormalNote() {
        #expect(Self.note(cpu: 9, memory: 0.62) == .normal)
        #expect(Self.note(cpu: 10, memory: 0.9) == .normal)
    }

    @Test("Memory pressure names the whole system's memory and suggests acting, even at low occupancy")
    func memoryPressureSuggestsActing() {
        for pressure in [SystemMemoryPressureLevel.warning, .critical] {
            #expect(
                Self.note(cpu: 10, memory: 0.4, pressure: pressure)
                    == .lowMemory(appBytes: Self.appFootprint)
            )
        }
    }

    @Test("CPU past the elevated line is named as the whole system's CPU, with this app's share beside it")
    func elevatedCPUIsNamedAsTheSystems() {
        #expect(Self.note(cpu: 72, memory: 0.3) == .systemCPU(percent: 72, appPercent: 3, suggestsAction: false))
    }

    @Test("High CPU load suggests acting and names the CPU, however full memory is")
    func highLoadSuggestsActingOnTheCPU() {
        #expect(Self.note(cpu: 95, memory: 0.9) == .systemCPU(percent: 95, appPercent: 3, suggestsAction: true))
        #expect(Self.note(cpu: 95, memory: 0.1) == .systemCPU(percent: 95, appPercent: 3, suggestsAction: true))
    }

    @Test("Heat notes follow the thermal state the headline names")
    func heatNotesFollowTheThermalState() {
        for state in [ProcessInfo.ThermalState.fair, .serious, .critical] {
            #expect(Self.note(cpu: 10, memory: 0.1, thermal: state) == .heat(state))
        }
    }

    @Test("Before the first reading neither the headline nor the note claims the system is normal")
    func noReadingsIsNotCalledNormal() {
        let health = StatusCapsuleModel.health(cpuPercent: 0, memoryFraction: 0, memoryPressure: .normal, thermal: .nominal)
        #expect(StatusCapsuleModel.headlineKey(for: health) != "System Normal")
        #expect(Self.note(cpu: 0, memory: 0) == .waitingForReadings)
        #expect(Self.note(cpu: 0, memory: 0, pressure: .critical) == .waitingForReadings)
        #expect(Self.note(cpu: 10, memory: 0.1) == .normal, "control: real low readings are normal")
    }

    @Test("Across the whole range the note tells the same story as the headline")
    func noteAgreesWithTheHeadline() {
        var disagreements: [String] = []
        for cpu in stride(from: 0.0, through: 100, by: 5) {
            for memory in stride(from: 0.0, through: 1, by: 0.05) {
                for pressure in SystemMemoryPressureLevel.allCases {
                    for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
                        let health = StatusCapsuleModel.health(
                            cpuPercent: cpu, memoryFraction: memory, memoryPressure: pressure, thermal: thermal
                        )
                        let note = Self.note(cpu: cpu, memory: memory, pressure: pressure, thermal: thermal)
                        let agrees = switch (health, note) {
                        case (.noReadings, .waitingForReadings), (.normal, .normal),
                             (.thermalFair, .heat(.fair)), (.thermalSerious, .heat(.serious)), (.thermalCritical, .heat(.critical)):
                            true
                        case (.memoryWarning, .lowMemory), (.memoryCritical, .lowMemory):
                            true
                        case let (.elevatedLoad, .systemCPU(_, _, act)):
                            !act
                        case let (.highLoad, .systemCPU(_, _, act)):
                            act
                        default:
                            false
                        }
                        if !agrees {
                            disagreements.append("cpu \(cpu) memory \(memory) \(pressure) \(thermal.rawValue): \(health) vs \(note)")
                        }
                    }
                }
            }
        }
        #expect(disagreements.isEmpty, Comment(rawValue: "\(disagreements.count) disagree, e.g. \(disagreements.prefix(3))"))
    }

    // MARK: Memory and battery

    private static let gib: UInt64 = 1 << 30

    @Test("The memory row and dial read this app in the App scope and the whole system otherwise")
    func memoryReadoutFollowsTheScope() {
        let app = StatusCapsuleModel.memoryReadout(scope: "app", systemFraction: 0.5, appBytes: Self.gib, totalBytes: 16 * Self.gib)
        #expect(app.fraction == 1.0 / 16)
        #expect(app.text.hasPrefix(FormatUtils.formatBytes(Self.gib)), Comment(rawValue: app.text))
        let system = StatusCapsuleModel.memoryReadout(scope: "system", systemFraction: 0.5, appBytes: Self.gib, totalBytes: 16 * Self.gib)
        #expect(system.fraction == 0.5)
        #expect(system.text == "\(FormatUtils.formatBytes(8 * Self.gib)) / \(FormatUtils.formatBytes(16 * Self.gib))")
    }

    @Test("The collapsed capsule names the scope its readings follow")
    func scopeLabelKeys() {
        #expect(StatusCapsuleModel.scopeLabelKey(for: "system") == "System")
        #expect(StatusCapsuleModel.scopeLabelKey(for: "app") == "App")
    }

    @Test("The CPU dial reads this app in the App scope and the whole system otherwise")
    func cpuReadoutFollowsTheScope() {
        #expect(StatusCapsuleModel.cpuReadout(scope: "app", systemPercent: 72, appPercent: 3) == 3)
        #expect(StatusCapsuleModel.cpuReadout(scope: "system", systemPercent: 72, appPercent: 3) == 72)
    }

    @Test("The open status panel is stacked above the nav pill")
    func statusPanelSitsAboveTheNavPill() throws {
        let bar = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/TopBar.swift")
        let pill = try #require(bar.range(of: "NavPill(selection:"))
        let cluster = try #require(bar.range(of: "trailingContent"))
        #expect(pill.upperBound <= cluster.lowerBound, "declared after the cluster, the pill covers the status panel")
        #expect(!bar.contains(".overlay(alignment: .center)"), "an overlay draws the pill over the status panel")
    }

    @Test("On battery the footer carries the charge and its icon; on external power it says nothing")
    func batteryReadoutOnlyOnBattery() {
        let battery = StatusCapsuleModel.batteryReadout(.battery(level: 0.72))
        #expect(battery?.text == FormatUtils.formatFractionAsPercent(0.72))
        #expect(battery?.symbol == "battery.75")
        #expect(StatusCapsuleModel.batteryReadout(.external) == nil)
    }

    // MARK: Dismissal hit testing

    /// WP 7B: the click arrives from AppKit in window coordinates (y up from the content view's
    /// bottom edge) while the panel is measured from SwiftUI's top, so every case is stated in both.
    private static let windowHeight: CGFloat = 800
    /// Top-right, in SwiftUI's y-down space: the panel covers y 60...160, the capsule y 14...42.
    private static let panel = CGRect(x: 600, y: 60, width: 200, height: 100)
    private static let trigger = CGRect(x: 682, y: 14, width: 118, height: 28)

    private static func dismisses(_ click: CGPoint) -> Bool {
        StatusCapsuleDismissal.shouldDismiss(
            clickInWindow: click,
            panelFrameFromTop: panel,
            capsuleFrameFromTop: trigger,
            windowHeight: windowHeight
        )
    }

    @Test("A click inside the panel leaves it open")
    func clickInsideThePanelKeepsItOpen() {
        // SwiftUI y 60...160 is AppKit y 640...740.
        #expect(Self.dismisses(CGPoint(x: 700, y: 690)) == false)
    }

    @Test("A click on the trigger capsule is left to the button's own toggle")
    func clickOnTheTriggerIsNotADismissal() {
        // SwiftUI y 14...42 is AppKit y 758...786. Dismissing here would close the panel a
        // moment before the button reopens it.
        #expect(Self.dismisses(CGPoint(x: 740, y: 772)) == false)
    }

    @Test("A click anywhere else dismisses")
    func clickElsewhereDismisses() {
        #expect(Self.dismisses(CGPoint(x: 200, y: 400)))
        #expect(Self.dismisses(CGPoint(x: 700, y: 500)), "below the panel")
        #expect(Self.dismisses(CGPoint(x: 700, y: 790)), "above the panel, beside the trigger")
    }

    @Test("The y flip runs the right way round")
    func theFlipIsNotAnIdentity() {
        // Read without the flip the panel would sit at AppKit y 60...160 and the trigger at
        // 14...42; clicks there have to read as outside, or the conversion is a no-op.
        #expect(Self.dismisses(CGPoint(x: 700, y: 110)))
        #expect(Self.dismisses(CGPoint(x: 740, y: 28)))
    }
}
