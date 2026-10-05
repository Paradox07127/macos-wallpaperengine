#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct StorageInfoButton<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(Text("Details"))
        .accessibilityLabel(Text("Details"))
        .appLanguagePopover(isPresented: $isPresented, arrowEdge: .bottom) {
            content().padding(DesignTokens.Spacing.cardInset)
        }
    }
}

#endif
