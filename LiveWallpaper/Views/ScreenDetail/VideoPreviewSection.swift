import LiveWallpaperCore
import AVKit
import SwiftUI

struct VideoPreviewSection: View {
    var previewController: InspectorPreviewController
    let hasPreviewSource: Bool
    let selectedFitMode: VideoFitMode
    let startPreview: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            if let player = previewController.player {
                activePreview(player: player)
            } else if let posterImage = previewController.posterImage {
                posterPreview(posterImage)
            } else if hasPreviewSource {
                unloadedPreview
            }

            VStack {
                HStack {
                    VideoInformationOverlay(videoURL: previewController.assetURL)
                    Spacer()
                }
                Spacer()
            }
            .padding(16)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            if previewController.player != nil {
                previewController.togglePlayback()
            } else {
                startPreview()
            }
        }
    }

    private func activePreview(player: AVPlayer) -> some View {
        ZStack(alignment: .bottom) {
            CustomVideoPlayer(player: player, fitMode: selectedFitMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .screenPreviewChrome()

            playbackControls
                // PreviewArea floats the fit/speed command bar over this same
                // bottom edge; without the clearance it draws on top of the
                // scrubber and swallows its hits.
                .padding(.bottom, 64)
        }
    }

    private var playbackControls: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { previewController.currentPosition },
                    set: { previewController.updateScrubPosition($0) }
                ),
                in: 0...max(1, previewController.duration),
                onEditingChanged: { editing in
                    if !editing {
                        previewController.seekToCurrentPosition()
                    }
                }
            )
            .padding(.horizontal, 24)
            .controlSize(.small)
            .accessibilityLabel(Text("Video position"))
            .accessibilityValue(Text("\(FormatUtils.formatDuration(previewController.currentPosition)) of \(FormatUtils.formatDuration(previewController.duration))"))
            .accessibilityHint(Text("Scrub through the video timeline"))

            HStack {
                Text(FormatUtils.formatDuration(previewController.currentPosition))
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(DesignTokens.Colors.overlayForeground)

                Spacer()

                PlaybackToggleButton(isPlaying: previewController.isPlaying) {
                    previewController.togglePlayback()
                }
                .foregroundStyle(DesignTokens.Colors.overlayForeground)

                Spacer()

                Text(FormatUtils.formatDuration(previewController.duration))
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(DesignTokens.Colors.overlayForeground)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0), Color.black.opacity(0.8)]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: DesignTokens.Corner.preview, bottomTrailingRadius: DesignTokens.Corner.preview))
    }

    private func posterPreview(_ posterImage: NSImage) -> some View {
        ZStack {
            Image(nsImage: posterImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Color.black.opacity(0.18))

            Button(action: startPreview) {
                Label("Play Preview", systemImage: "play.fill")
            }
            .adaptiveGlassButton(.prominent, size: .large)
            .accessibilityLabel(Text("Play preview"))
            .accessibilityHint(Text("Starts a temporary video preview for this settings panel"))
        }
        .screenPreviewChrome(shadow: false)
    }

    @ViewBuilder
    private var unloadedPreview: some View {
        let errorMessage = previewController.lastError.map(LogPrivacyRedactor.scrub)
        VStack(spacing: 14) {
            Image(systemName: errorMessage == nil ? (previewController.isLoading ? "hourglass" : "photo") : "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(errorMessage == nil ? Color.secondary : DesignTokens.Colors.Status.warning)
            previewMessage(errorMessage)
                .font(.subheadline)
                .foregroundStyle(errorMessage == nil ? Color.secondary : Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button(action: startPreview) {
                if errorMessage == nil { Text("Load Preview") } else { Text("Retry Preview") }
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(errorMessage == nil ? Text("Load preview") : Text("Retry preview"))
                .accessibilityHint(Text("Starts a temporary video preview for this settings panel"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .screenPreviewChrome(stroke: true, shadow: false)
    }

    /// Branches into separate `Text` values so the two idle states keep their catalog
    /// lookup; a ternary would collapse them to `String` and render English forever.
    private func previewMessage(_ errorMessage: String?) -> Text {
        if let errorMessage {
            return Text(verbatim: errorMessage)
        }
        return previewController.isLoading ? Text("Loading preview…") : Text("Preview paused")
    }
}
