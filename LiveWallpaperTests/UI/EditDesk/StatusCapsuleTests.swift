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
