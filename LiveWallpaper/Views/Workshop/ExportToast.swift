#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct ExportToast: View {
    @Binding var isPresented: Bool
    var lingerSeconds: TimeInterval = 3.5
    /// Overridable so the auto-dismiss timer doesn't drive UI in a test runner.
    var clock: ContinuousClock = .continuous

    var body: some View {
        Group {
            if isPresented {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(DesignTokens.Colors.Status.active.opacity(0.18))
                            .frame(width: 28, height: 28)
                        Image(systemName: "checkmark")
                            .font(DesignTokens.Typography.bodyEmphasized)
                            .foregroundStyle(DesignTokens.Colors.Status.active)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostic copied")
                            .font(DesignTokens.Typography.bodyEmphasized)
                        Text("Paste into a GitHub issue — secrets are already redacted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.cardInset)
                .padding(.vertical, 10)
                // Same glass chrome as `DownloadToastHost` — the two toasts share
                // every other metric and had drifted on background material only.
                .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.xl))
                .shadow(color: .black.opacity(DesignTokens.Card.shadowOpacity), radius: 14, x: 0, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: isPresented) {
                    guard isPresented else { return }
                    try? await clock.sleep(for: .milliseconds(Int(lingerSeconds * 1_000)))
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(Text("Diagnostic copied to clipboard. Secrets are already redacted."))
            }
        }
        .animation(.easeOut(duration: 0.2), value: isPresented)
    }
}
#endif
