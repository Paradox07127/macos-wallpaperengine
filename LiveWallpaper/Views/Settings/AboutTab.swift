import AppKit
import LiveWallpaperCore
import SwiftUI

extension GeneralSettingsView {
    /// The About page must fit whatever height the settings window has (floor:
    /// `SettingsWindowMetrics.minimumContentSize`) — at the floor the roomy layout overflowed
    /// and put a scroller on a page of six static elements. `ViewThatFits` picks the largest
    /// layout that fits instead — no height thresholds to sync with translations or Dynamic Type, since it measures the real content.
    @ViewBuilder
    var aboutTab: some View {
        ViewThatFits(in: .vertical) {
            aboutContent(.roomy)
            aboutContent(.standard)
            aboutContent(.compact)
            aboutContent(.minimal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.pageBackground)
    }

    private func aboutContent(_ layout: AboutLayout) -> some View {
        VStack(spacing: layout.sectionSpacing) {
            aboutHero(layout)
            aboutTagline
            aboutActionGrid(layout)
            aboutFooter
        }
        .frame(maxWidth: layout.contentWidth)
        .padding(.horizontal, 32)
        .padding(.vertical, layout.verticalPadding)
    }

    private func aboutHero(_ layout: AboutLayout) -> some View {
        VStack(spacing: layout.heroSpacing) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: layout.heroHalo, height: layout.heroHalo)
                    .blur(radius: layout.heroHalo * 0.14)

                Image(systemName: "play.rectangle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: layout.heroIcon, height: layout.heroIcon)
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(verbatim: BundleIdentity.productDisplayName)
                    .font(layout.titleFont)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Text(verbatim: versionString)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(versionString, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(Text("Copy version to clipboard"))
                    .accessibilityLabel(Text("Copy version"))
                }

                UpdateStatusLine()
                    .padding(.top, 2)
            }
        }
    }

    private var aboutTagline: some View {
        Text("Live wallpapers for macOS: videos, web pages, and compatible imported scenes across every connected display.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
    }

    /// Two rows of two when there is height to spend, one row of four when
    /// there isn't — the tiles are the tallest block on the page, so folding
    /// them into a single row is what buys back the most vertical space.
    private func aboutActionGrid(_ layout: AboutLayout) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 10),
                count: layout.tileColumns
            ),
            spacing: 10
        ) {
            ForEach(aboutActions, id: \.id) { action in
                aboutTile(action, layout: layout)
            }
        }
        .frame(maxWidth: layout.gridWidth)
    }

    private var aboutActions: [AboutAction] {
        [
            AboutAction(
                id: "github",
                title: "View on GitHub",
                systemImage: "chevron.left.forwardslash.chevron.right",
                accent: .blue,
                url: URL(string: "https://github.com/Paradox07127/macos-wallpaperengine")
            ),
            AboutAction(
                id: "discussions",
                title: "Discussions",
                systemImage: "bubble.left.and.bubble.right",
                accent: .indigo,
                url: URL(string: "https://github.com/Paradox07127/macos-wallpaperengine/discussions")
            ),
            AboutAction(
                id: "bug",
                title: "Report a Bug",
                systemImage: "ladybug",
                accent: .red,
                action: presentBugReport
            ),
            AboutAction(
                id: "tour",
                title: "Welcome Tour",
                systemImage: "sparkles",
                accent: .purple,
                action: { NotificationCenter.default.post(name: .showOnboarding, object: nil) }
            )
        ]
    }

    private func aboutTile(_ action: AboutAction, layout: AboutLayout) -> some View {
        Button {
            if let handler = action.action {
                handler()
            } else if let url = action.url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(spacing: layout.tileSpacing) {
                Image(systemName: action.systemImage)
                    .font(.system(size: layout.tileIcon, weight: .regular))
                    .foregroundStyle(action.accent)
                    .frame(height: layout.tileIcon + 4)

                Text(action.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .marqueeOnHover(truncationMode: .tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, layout.tilePadding)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                    .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                    .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: DesignTokens.Card.strokeWidth)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(action.action == nil && action.url == nil)
    }

    private var aboutFooter: some View {
        VStack(spacing: 4) {
            Text("Made by Paradox07127")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(verbatim: "© 2026 Loomscreen contributors · MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return String(localized: "Version \(version) (\(build))", bundle: .appLanguage, comment: "About tab version line. Placeholders are marketing version and build number.")
    }
}

struct AboutAction {
    let id: String
    let title: LocalizedStringKey
    let systemImage: String
    let accent: Color
    var url: URL?
    var action: (() -> Void)?
}

/// The three rungs `aboutTab` steps down through. Only sizes and the tile
/// column count change — every element stays on the page at every rung.
struct AboutLayout {
    let contentWidth: CGFloat
    let verticalPadding: CGFloat
    let sectionSpacing: CGFloat
    let heroHalo: CGFloat
    let heroIcon: CGFloat
    let heroSpacing: CGFloat
    let titleFont: Font
    let tileColumns: Int
    let gridWidth: CGFloat
    let tileIcon: CGFloat
    let tileSpacing: CGFloat
    let tilePadding: CGFloat

    static let roomy = AboutLayout(
        contentWidth: 480,
        verticalPadding: 36,
        sectionSpacing: 28,
        heroHalo: 128,
        heroIcon: 88,
        heroSpacing: 14,
        titleFont: DesignTokens.Typography.hero,
        tileColumns: 2,
        gridWidth: 360,
        tileIcon: 22,
        tileSpacing: 8,
        tilePadding: 16
    )

    static let standard = AboutLayout(
        contentWidth: 480,
        verticalPadding: 24,
        sectionSpacing: 18,
        heroHalo: 100,
        heroIcon: 64,
        heroSpacing: 10,
        titleFont: .title,
        tileColumns: 2,
        gridWidth: 360,
        tileIcon: 20,
        tileSpacing: 6,
        tilePadding: 12
    )

    static let compact = AboutLayout(
        contentWidth: 480,
        verticalPadding: 14,
        sectionSpacing: 10,
        heroHalo: 84,
        heroIcon: 54,
        heroSpacing: 8,
        titleFont: .title2,
        tileColumns: 2,
        gridWidth: 360,
        tileIcon: 18,
        tileSpacing: 4,
        tilePadding: 10
    )

    /// Last rung: the tiles fold into a single row, which is the only move left
    /// that buys a whole tile's height back.
    static let minimal = AboutLayout(
        contentWidth: 560,
        verticalPadding: 12,
        sectionSpacing: 8,
        heroHalo: 64,
        heroIcon: 40,
        heroSpacing: 6,
        titleFont: .title3,
        tileColumns: 4,
        gridWidth: 560,
        tileIcon: 16,
        tileSpacing: 4,
        tilePadding: 8
    )
}
