import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Dynamic color registration")
struct DynamicColorConcurrencyTests {
    @Test("Concurrent token initialization keeps AppKit's named-color registry coherent")
    func initializesConcurrently() async {
        let colors = await withTaskGroup(of: Color.self, returning: [Color].self) { group in
            for index in 0 ..< 256 {
                group.addTask {
                    DesignTokens.EditDesk.Colors.adaptive("concurrency-\(index)", light: .white, dark: .black)
                }
            }
            var colors: [Color] = []
            for await color in group {
                colors.append(color)
            }
            return colors
        }
        #expect(colors.count == 256)
        // Retain every color until registration has finished; their lifetime matches static tokens.
        #expect(colors.allSatisfy { NSColor($0).type == .catalog || NSColor($0).type == .componentBased })
    }
}
