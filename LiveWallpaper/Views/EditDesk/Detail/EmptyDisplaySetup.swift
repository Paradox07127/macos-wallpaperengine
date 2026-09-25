import AppKit
import LiveWallpaperCore
import SwiftUI

/// One calm entry point over the selected display's macOS wallpaper.
struct EmptyDisplaySetup: View {
    let screen: Screen
    let chooseFile: () -> Void
    let applyWebSource: (HTMLSource) -> Void
    /// nil while the wallpaper library is empty.
    var chooseFromLibrary: (() -> Void)?
    @State private var wallpaper: CGImage?
    @State private var showsWebSetup = false
    @State private var loading = true
    @State private var refreshID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let wallpaper {
                    Image(decorative: wallpaper, scale: 1)
                        .resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(0.12))
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    if showsWebSetup {
                        HTMLEmptyState(screen: screen, config: .default, apply: applyWebSource)
                            .frame(width: min(540, proxy.size.width - 64), height: min(380, proxy.size.height - 100))
                            .adaptiveGlassSurface(.roundedRectangle(24))
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
            }
            .overlay(alignment: .topTrailing) { backgroundControl.padding(16) }
            .clipped()
        }
        .task(id: refreshID) { await refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in
            refreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshID = UUID()
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: showsWebSetup)
    }

    private var introduction: some View {
        VStack(spacing: 20) {
            Image(systemName: "display")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Set up this display")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
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
        .adaptiveGlassSurface(.roundedRectangle(24))
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

    @ViewBuilder
    private var backgroundControl: some View {
        if loading {
            ProgressView().controlSize(.small).padding(8)
        } else if wallpaper != nil || CGPreflightScreenCaptureAccess() {
            HStack(spacing: 8) {
                if wallpaper == nil {
                    Text("Preview unavailable").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                }
                GlassIconButton("arrow.clockwise") { refreshID = UUID() }
                    .help(Text("Refresh macOS wallpaper"))
                    .accessibilityLabel(Text("Refresh macOS wallpaper"))
            }
        } else {
            Button("Show macOS wallpaper") {
                if CGRequestScreenCaptureAccess() {
                    refreshID = UUID()
                } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .adaptiveGlassButton(size: .small)
            .help(Text("Screen recording access is used only to preview this display’s wallpaper."))
        }
    }

    @MainActor
    private func refresh() async {
        loading = true
        let image = await DesktopWallpaperPreview.load(for: screen)
        guard !Task.isCancelled else { return }
        wallpaper = image
        loading = false
    }
}
