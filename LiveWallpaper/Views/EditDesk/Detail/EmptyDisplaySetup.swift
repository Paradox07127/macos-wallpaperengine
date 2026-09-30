import LiveWallpaperCore
import SwiftUI

/// Setup actions for a display without a configured wallpaper.
struct EmptyDisplaySetup: View {
    let screen: Screen
    let chooseFile: () -> Void
    let applyWebSource: (HTMLSource) -> Void
    /// nil while the wallpaper library is empty.
    var chooseFromLibrary: (() -> Void)?
    @State private var showsWebSetup = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                if showsWebSetup {
                    HTMLEmptyState(screen: screen, config: .default, apply: applyWebSource)
                        .frame(width: min(540, proxy.size.width - 64), height: min(380, proxy.size.height - 100))
                        .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.sheet))
                        .overlay(alignment: .topLeading) {
                            GlassIconButton("chevron.left") { showsWebSetup = false }
                                .help(Text("Set up this display"))
                                .accessibilityLabel(Text("Set up this display"))
                                .padding(16)
                        }
                } else {
                    introduction
                }
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: showsWebSetup)
    }

    private var introduction: some View {
        VStack(spacing: 20) {
            Image(systemName: "display")
                .font(.system(size: DesignTokens.EmptyState.iconSize, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Set up this display")
                    .font(DesignTokens.Typography.pageTitle)
                Text(verbatim: screen.name)
                    .font(DesignTokens.Typography.body).foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("Make this display your own.")
                    .font(DesignTokens.Typography.body).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { setupButtons }
                VStack(spacing: 8) { setupButtons }
            }
            Text("Or drop a wallpaper here")
                .font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(width: 440)
        .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.sheet))
    }

    @ViewBuilder
    private var setupButtons: some View {
        Button(action: chooseFile) {
            Label("Import and Apply to \(screen.name)", systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .adaptiveGlassButton(.prominent, size: .large)
        if let chooseFromLibrary {
            Button(action: chooseFromLibrary) { Label("Choose from Library", systemImage: "square.grid.2x2") }
                .adaptiveGlassButton(size: .large)
        }
        Button { showsWebSetup = true } label: { Label("Web", systemImage: "globe") }
            .adaptiveGlassButton(size: .large)
    }
}
