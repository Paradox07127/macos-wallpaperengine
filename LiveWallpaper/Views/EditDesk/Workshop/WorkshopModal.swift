#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// SCREENS.md S8b: the Workshop variant of the S4 modal. Same chrome as the library's, different
/// body — a square animated preview on the left, the item's write-up scrolling on the right, and a
/// bar that turns one download into "apply to the display I picked upstairs".
@MainActor
struct WorkshopModal: View {
    let content: WorkshopModalContent
    let doctor: SteamCMDDoctorService
    let targets: [ModalDisplayTarget]
    let download: WorkshopDownloadPresentation
    let primaryTitle: String
    let isPrimaryEnabled: Bool
    /// The button beside the primary one, shown until the item is in the library.
    let secondaryTitle: String
    let isSecondaryEnabled: Bool
    /// The mature reveal lives in the page's `MatureRevealState`, so it survives closing this modal.
    let isRevealed: Bool
    /// The same state, for the dependency and preset rows: R-24 ④ shares one reveal set.
    let matureReveal: MatureRevealState?
    /// The stage's own `bounds.size`. A `GeometryReader` here would measure one title bar short.
    let windowSize: CGSize
    /// Height the scrim leaves untouched so the traffic lights and window drag still work.
    let titlebarInset: CGFloat
    let onDismiss: () -> Void
    let actions: WorkshopModalActions

    @AppStorage(MatureContentSettings.blursThumbnails, store: .appScoped()) private var blursMature = true
    @State private var showingAgeConfirm = false

    /// SCREENS.md S8b: a 340pt square preview with the write-up beside it.
    private static let previewSide: CGFloat = 340
    /// Two rows: the status line over the bar, then the bar and the buttons.
    private static let bottomBarHeight: CGFloat = 84
    private static let barPadding: CGFloat = 20
    private static let buttonHeight: CGFloat = 38

    private var item: WorkshopQueryItem {
        content.item
    }

    private var shouldBlurPreview: Bool {
        blursMature && item.isMatureRated && !isRevealed
    }

    var body: some View {
        EditDeskModalChrome(
            windowSize: windowSize,
            titlebarInset: titlebarInset,
            onDismiss: onDismiss,
            onTargetShortcut: selectTargetByShortcut
        ) { _ in
            panelBody
        }
    }

    // MARK: Panel

    private var panelBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Self.barPadding) {
                preview
                details
            }
            .padding(.horizontal, ModalGeometry.previewMargin)
            .padding(.top, ModalGeometry.previewMargin)
            .frame(maxHeight: .infinity, alignment: .top)
            bottomBar
        }
        .alert("Show mature content?", isPresented: $showingAgeConfirm) {
            Button(role: .cancel) {} label: { Text("Cancel") }
            Button(role: .destructive) {
                MatureContentSettings.confirm()
                actions.reveal()
            } label: {
                Text("I am 18 or older")
            }
        } message: {
            Text("This wallpaper is tagged Mature and may contain explicit adult content. By revealing it you confirm you are at least 18 years old, or of legal age in your region.")
        }
    }

    // MARK: Preview

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panelLarge, style: .continuous)
    }

    private var preview: some View {
        // A Button keeps one view identity across the reveal: branching on the blur would rebuild
        // the thumbnail and lose its unblur animation. Hit-testing gates instead of `.disabled`.
        Button {
            guard shouldBlurPreview else { return }
            if MatureContentSettings.isConfirmed {
                actions.reveal()
            } else {
                showingAgeConfirm = true
            }
        } label: {
            AnimatedGIFThumbnail(
                url: item.previewImageURL,
                playbackMode: .autoPlay,
                showsPlayingBadge: false,
                previewSize: .hero,
                isBlurred: shouldBlurPreview
            )
            .frame(width: Self.previewSide, height: Self.previewSide)
            .clipShape(previewShape)
            .overlay(previewShape.strokeBorder(DesignTokens.EditDesk.Colors.strokeBadge, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                mediaChip(Text("▶ GIF preview"))
                    .padding(DesignTokens.EditDesk.Spacing.s8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(shouldBlurPreview)
        .accessibilityHidden(!shouldBlurPreview)
        .accessibilityLabel(Text("Show mature content?"))
    }

    private func mediaChip(_ label: Text) -> some View {
        label
            .font(DesignTokens.EditDesk.Typography.metaMono)
            .foregroundStyle(DesignTokens.Colors.overlayForeground)
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.s8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.chip, style: .continuous)
                    .fill(DesignTokens.EditDesk.Colors.mediaChipFill)
            )
    }

    // MARK: Details

    private var details: some View {
        ScrollView {
            WorkshopDetailsContent(
                item: item,
                doctor: doctor,
                identityStyle: .modal,
                // GAP_ANALYSIS §6: two lines folded, and the expanded text scrolls inside 120pt so
                // a long description cannot push the presets out of the column.
                descriptionCollapsedLineLimit: 2,
                descriptionExpandedMaxHeight: 120,
                onBrowseCreator: actions.browseCreator,
                onSelectTag: actions.selectTag,
                onOpenItem: actions.openItem,
                matureReveal: matureReveal
            )
            .padding(.trailing, DesignTokens.EditDesk.Spacing.s8)
            .padding(.bottom, DesignTokens.EditDesk.Spacing.s12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: DesignTokens.EditDesk.Spacing.s8) {
            statusLine
            HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
                progressBar
                Spacer(minLength: DesignTokens.EditDesk.Spacing.s12)
                barButtons
            }
        }
        .padding(.horizontal, Self.barPadding)
        .frame(height: Self.bottomBarHeight)
    }

    @ViewBuilder
    private var statusLine: some View {
        if !download.status.isEmpty || !download.detail.isEmpty {
            HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
                Text(verbatim: download.status)
                    .font(DesignTokens.EditDesk.Typography.body)
                    .foregroundStyle(
                        download.isFailure
                            ? DesignTokens.EditDesk.Colors.danger
                            : DesignTokens.EditDesk.Colors.textSecondary
                    )
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.EditDesk.Spacing.s12)
                Text(verbatim: download.detail)
                    .font(DesignTokens.EditDesk.Typography.metaMono)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        switch download.progress {
        case .none:
            EmptyView()
        case .indeterminate:
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel(Text("Download progress"))
        case let .fraction(value):
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .accessibilityLabel(Text("Download progress"))
                .accessibilityValue(Text(verbatim: download.detail))
        }
    }

    private var barButtons: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
            WorkshopBarButton(fill: DesignTokens.EditDesk.Colors.primaryButtonFill, action: actions.primary) {
                Text(verbatim: primaryTitle)
                    .font(DesignTokens.EditDesk.Typography.button)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.primaryButtonText)
                    .lineLimit(1)
                    .padding(.horizontal, DesignTokens.EditDesk.Spacing.s14)
            }
            .disabled(!isPrimaryEnabled)
            .opacity(isPrimaryEnabled ? 1 : DesignTokens.Opacity.dimmedIcon)
            if !content.isInstalled {
                WorkshopBarButton(fill: DesignTokens.EditDesk.Colors.fillSecondaryButton, action: actions.saveOnly) {
                    Text(verbatim: secondaryTitle)
                        .font(DesignTokens.EditDesk.Typography.button)
                        .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, DesignTokens.EditDesk.Spacing.s14)
                }
                .disabled(!isSecondaryEnabled)
                .opacity(isSecondaryEnabled ? 1 : DesignTokens.Opacity.dimmedIcon)
            }
            if let connectSteam = actions.connectSteam {
                WorkshopBarButton(fill: DesignTokens.EditDesk.Colors.fillSecondaryButton, action: connectSteam) {
                    Text("Connect Steam")
                        .font(DesignTokens.EditDesk.Typography.button)
                        .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, DesignTokens.EditDesk.Spacing.s14)
                }
            }
            if let cancelDownload = actions.cancelDownload {
                WorkshopBarButton(fill: DesignTokens.EditDesk.Colors.fillTertiaryButton, action: cancelDownload) {
                    Text("Cancel download")
                        .font(DesignTokens.EditDesk.Typography.button)
                        .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, DesignTokens.EditDesk.Spacing.s14)
                }
            }
            WorkshopBarButton(fill: DesignTokens.EditDesk.Colors.fillTertiaryButton, action: actions.openInSteam) {
                Text(verbatim: "↗")
                    .font(DesignTokens.EditDesk.Typography.button)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                    .frame(width: Self.buttonHeight)
            }
            .help(Text("Open in Steam"))
            .accessibilityLabel(Text("Open in Steam"))
        }
    }

    // MARK: Keyboard

    /// ⌘1…⌘9 pick the display the finished download will land on. Nothing is applied here: the
    /// wallpaper is not on this Mac yet, and for one that is, the bar's own button applies it.
    private func selectTargetByShortcut(_ index: Int) {
        guard let target = ModalKeyMap.target(forShortcut: index, in: targets) else { return }
        actions.selectTarget(target.id)
    }
}

/// SCREENS.md S8b's bottom-bar button skin: a flat token fill, so hover and press are drawn here
/// rather than inherited from a system style.
private struct WorkshopBarButton<Label: View>: View {
    let fill: Color
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    private static var height: CGFloat {
        38
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(height: Self.height)
                .background(shape.fill(fill))
                .overlay(
                    shape.strokeBorder(DesignTokens.EditDesk.Colors.strokeRegular, lineWidth: 1)
                        .opacity(isHovering ? 1 : 0)
                )
                .contentShape(shape)
        }
        .buttonStyle(WorkshopBarPressStyle())
        .onHover { isHovering = $0 }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.button, style: .continuous)
    }
}

private struct WorkshopBarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? DesignTokens.Opacity.dimmedIcon : 1)
    }
}
#endif
