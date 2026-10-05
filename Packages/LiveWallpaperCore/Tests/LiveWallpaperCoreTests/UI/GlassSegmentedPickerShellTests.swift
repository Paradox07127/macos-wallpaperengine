import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

/// The glass backing must not add layout footprint to the navigation control.
@Suite("GlassSegmentedPicker shells")
struct GlassSegmentedPickerShellTests {

    @MainActor
    @Test("The glass backing costs the pill no width or height")
    func glassBackingAddsNoFootprint() {
        let picker = Self.probePicker().fixedSize()
        // SCREENS S1's geometry, rebuilt by hand: item height 26 with 14pt each side,
        // 2pt between items, 3pt around the row.
        let reference = HStack(spacing: 2) {
            ForEach(Self.probeTitles, id: \.self) { title in
                Text(verbatim: title).frame(height: 26).padding(.horizontal, 14)
            }
        }
        .padding(3)
        .fixedSize()

        let measured = NSHostingView(rootView: picker).fittingSize
        let expected = NSHostingView(rootView: reference).fittingSize
        #expect(measured.width > 0)
        #expect(
            abs(measured.width - expected.width) < 0.5 && abs(measured.height - expected.height) < 0.5,
            Comment(rawValue: "pill measures \(measured), the unbacked row measures \(expected)")
        )
    }

    // MARK: Probe

    private static let probeTitles = ["AAAA", "BBBB"]

    @MainActor
    private static func probePicker() -> some View {
        GlassSegmentedPicker(
            selection: .constant(probeTitles[0]),
            values: probeTitles,
            shell: .editDesk
        ) { title, _ in
            Text(verbatim: title)
        }
    }
}
