import Darwin
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Process memory accounting")
struct ProcessResourceTests {
    @Test("Footprint takes precedence including zero; only missing usage falls back to RSS")
    func memoryAccounting() throws {
        #expect(ProcessResourceUsage.memory(resident: 300, footprint: 120).bytes == 120)
        #expect(ProcessResourceUsage.memory(resident: 300, footprint: 0).bytes == 0)
        #expect(ProcessResourceUsage.memory(resident: 300, footprint: nil).metric == "resident")
        #expect(ProcessResourceUsage.memory(resident: 300, footprint: nil).bytes == 300)
        let usage = try #require(ProcessResourceUsage.read(pid: getpid()))
        #expect(usage.ri_phys_footprint > 0)
    }
}
