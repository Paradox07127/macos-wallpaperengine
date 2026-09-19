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

    @Test("CPU at the elevated threshold reads as elevated")
    func elevatedByCPU() {
        let health = StatusCapsuleModel.health(cpuPercent: 60, memoryFraction: 0.1, thermal: .nominal)
        #expect(health == .elevated)
    }

    @Test("Memory at the elevated threshold reads as elevated")
    func elevatedByMemory() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.60, thermal: .nominal)
        #expect(health == .elevated)
    }

    @Test("A fair thermal state reads as elevated even with idle CPU/memory")
    func elevatedByThermalFair() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.1, thermal: .fair)
        #expect(health == .elevated)
    }

    @Test("CPU at the hot threshold reads as hot")
    func hotByCPU() {
        let health = StatusCapsuleModel.health(cpuPercent: 85, memoryFraction: 0.1, thermal: .nominal)
        #expect(health == .hot)
    }

    @Test("A serious thermal state reads as hot even with idle CPU/memory")
    func hotByThermalSerious() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.1, thermal: .serious)
        #expect(health == .hot)
    }

    @Test("A critical thermal state reads as hot")
    func hotByThermalCritical() {
        let health = StatusCapsuleModel.health(cpuPercent: 10, memoryFraction: 0.1, thermal: .critical)
        #expect(health == .hot)
    }

    @Test("Headline keys map one-to-one to health bands")
    func headlineKeys() {
        #expect(StatusCapsuleModel.headlineKey(for: .normal) == "System Normal")
        #expect(StatusCapsuleModel.headlineKey(for: .elevated) == "System Elevated")
        #expect(StatusCapsuleModel.headlineKey(for: .hot) == "System Overheating")
    }

    @Test("Dot color follows success/warning/danger by band")
    func dotColors() {
        #expect(StatusCapsuleModel.dotColor(for: .normal) == DesignTokens.EditDesk.Colors.success)
        #expect(StatusCapsuleModel.dotColor(for: .elevated) == DesignTokens.EditDesk.Colors.warning)
        #expect(StatusCapsuleModel.dotColor(for: .hot) == DesignTokens.EditDesk.Colors.danger)
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
}
