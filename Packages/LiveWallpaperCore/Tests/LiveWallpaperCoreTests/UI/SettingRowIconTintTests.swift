import LiveWallpaperCore
import SwiftUI
import Testing

struct SettingRowIconTintTests {
    @Test func offRowIsGrey() {
        #expect(SettingRowIconTint.resolve(isOn: false, status: .secondary, brand: .pink) == .secondary)
    }

    @Test func onRowWithNeutralStatusKeepsBrandColor() {
        #expect(SettingRowIconTint.resolve(isOn: true, status: .secondary, brand: .pink) == .pink)
    }

    @Test func onRowShowsMeaningfulStatus() {
        #expect(SettingRowIconTint.resolve(isOn: true, status: .red, brand: .pink) == .red)
    }
}
