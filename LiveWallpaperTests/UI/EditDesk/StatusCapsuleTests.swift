import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("StatusCapsule — pure health/thermal mapping")
struct StatusCapsuleTests {
    @Test("Below both thresholds and thermal nominal reads as normal")
    func normalBand() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.1, thermal: .nominal)
        #expect(health == .normal)
    }

    @Test("CPU at the elevated threshold reads as elevated load")
    func elevatedByCPU() {
        let health = StatusCapsuleModel.health(cpuPercent: 60, memoryFraction: 0.1, thermal: .nominal)
        #expect(health == .elevatedLoad)
    }

    @Test("Memory at the elevated threshold reads as elevated load")
    func elevatedByMemory() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.60, thermal: .nominal)
        #expect(health == .elevatedLoad)
    }

    @Test("A fair thermal state reads as thermal fair even with idle CPU/memory")
    func elevatedByThermalFair() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.1, thermal: .fair)
        #expect(health == .thermalFair)
    }

    @Test("CPU at the hot threshold reads as high load")
    func hotByCPU() {
        let health = StatusCapsuleModel.health(cpuPercent: 85, memoryFraction: 0.1, thermal: .nominal)
        #expect(health == .highLoad)
    }

    @Test("A serious thermal state reads as thermal serious even with idle CPU/memory")
    func hotByThermalSerious() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.1, thermal: .serious)
        #expect(health == .thermalSerious)
    }

    @Test("A critical thermal state reads as thermal critical")
    func hotByThermalCritical() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.1, thermal: .critical)
        #expect(health == .thermalCritical)
    }

    @Test("Memory past the hot threshold with a nominal thermal state reads as high load, not overheating")
    func highMemoryIsLoadNotHeat() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.9, thermal: .nominal)
        #expect(StatusCapsuleModel.headlineKey(for: health) == "High Load")
    }

    @Test("Nothing counts as rendering while wallpapers are off")
    func nothingRendersWhileWallpapersAreOff() {
        #expect(StatusCapsuleModel.renderingCount(configured: 2, wallpapersEnabled: false) == 0)
        #expect(StatusCapsuleModel.renderingCount(configured: 2, wallpapersEnabled: true) == 2)
    }

    @Test("Headline keys map one-to-one to health bands")
    func headlineKeys() {
        #expect(StatusCapsuleModel.headlineKey(for: .normal) == "System Normal")
        #expect(StatusCapsuleModel.headlineKey(for: .elevatedLoad) == "Elevated Load")
        #expect(StatusCapsuleModel.headlineKey(for: .highLoad) == "High Load")
        #expect(StatusCapsuleModel.headlineKey(for: .thermalFair) == "Running Warm")
        #expect(StatusCapsuleModel.headlineKey(for: .thermalSerious) == "Running Hot")
        #expect(StatusCapsuleModel.headlineKey(for: .thermalCritical) == "Critical Heat")
    }

    @Test("Dot color follows success/warning/danger by band")
    func dotColors() {
        #expect(StatusCapsuleModel.dotColor(for: .normal) == DesignTokens.EditDesk.Colors.success)
        #expect(StatusCapsuleModel.dotColor(for: .elevatedLoad) == DesignTokens.EditDesk.Colors.warning)
        #expect(StatusCapsuleModel.dotColor(for: .thermalFair) == DesignTokens.EditDesk.Colors.warning)
        #expect(StatusCapsuleModel.dotColor(for: .highLoad) == DesignTokens.EditDesk.Colors.danger)
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

    private static func note(cpu: Double, memory: Double, thermal: ProcessInfo.ThermalState = .nominal) -> StatusCapsuleNote {
        StatusCapsuleModel.note(
            cpuPercent: cpu, memoryFraction: memory, thermal: thermal, appCPUPercent: 3, appMemoryBytes: appFootprint
        )
    }

    @Test("The reviewed panel (CPU 9%, memory 62%) names the whole system's memory and says nothing needs doing")
    func elevatedMemoryIsNamedAsTheSystems() {
        #expect(Self.note(cpu: 9, memory: 0.62) == .systemMemory(fraction: 0.62, appBytes: Self.appFootprint, suggestsAction: false))
    }

    @Test("CPU past the elevated line is named as the whole system's CPU, with this app's share beside it")
    func elevatedCPUIsNamedAsTheSystems() {
        #expect(Self.note(cpu: 72, memory: 0.3) == .systemCPU(percent: 72, appPercent: 3, suggestsAction: false))
    }

    @Test("High load suggests acting, and names whichever reading is higher")
    func highLoadSuggestsActingOnTheHigherReading() {
        #expect(Self.note(cpu: 10, memory: 0.9) == .systemMemory(fraction: 0.9, appBytes: Self.appFootprint, suggestsAction: true))
        #expect(Self.note(cpu: 95, memory: 0.9) == .systemCPU(percent: 95, appPercent: 3, suggestsAction: true))
    }

    @Test("Heat notes follow the thermal state the headline names")
    func heatNotesFollowTheThermalState() {
        for state in [ProcessInfo.ThermalState.fair, .serious, .critical] {
            #expect(Self.note(cpu: 10, memory: 0.1, thermal: state) == .heat(state))
        }
    }

    @Test("Before the first reading neither the headline nor the note claims the system is normal")
    func noReadingsIsNotCalledNormal() {
        let health = StatusCapsuleModel.health(cpuPercent: 0, memoryFraction: 0, thermal: .nominal)
        #expect(StatusCapsuleModel.headlineKey(for: health) != "System Normal")
        #expect(Self.note(cpu: 0, memory: 0) == .waitingForReadings)
        #expect(Self.note(cpu: 10, memory: 0.1) == .normal, "control: real low readings are normal")
    }

    @Test("Across the whole range the note tells the same story as the headline")
    func noteAgreesWithTheHeadline() {
        var disagreements: [String] = []
        for cpu in stride(from: 0.0, through: 100, by: 5) {
            for memory in stride(from: 0.0, through: 1, by: 0.05) {
                for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
                    let health = StatusCapsuleModel.health(cpuPercent: cpu, memoryFraction: memory, thermal: thermal)
                    let note = Self.note(cpu: cpu, memory: memory, thermal: thermal)
                    let agrees = switch (health, note) {
                    case (.noReadings, .waitingForReadings), (.normal, .normal),
                         (.thermalFair, .heat(.fair)), (.thermalSerious, .heat(.serious)), (.thermalCritical, .heat(.critical)):
                        true
                    case let (.elevatedLoad, .systemMemory(_, _, act)), let (.elevatedLoad, .systemCPU(_, _, act)):
                        !act
                    case let (.highLoad, .systemMemory(_, _, act)), let (.highLoad, .systemCPU(_, _, act)):
                        act
                    default:
                        false
                    }
                    if !agrees {
                        disagreements.append("cpu \(cpu) memory \(memory) \(thermal.rawValue): \(health) vs \(note)")
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
