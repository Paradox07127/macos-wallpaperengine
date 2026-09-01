import LiveWallpaperCore
import SwiftUI
import AVKit

/// Metadata is loaded from `AVURLAsset(url:)` rather than the live player so the overlay can render across the active / poster / unloaded states — playing the preview isn't a prerequisite for showing the badges.
struct VideoInformationOverlay: View {
    let videoURL: URL?
    /// Used solely as a load-trigger identity so toggling preview off and on
    /// doesn't refire a redundant metadata load for the same URL.
    let player: AVPlayer?

    @State private var videoResolution: (width: Int, height: Int)?
    @State private var videoFrameRate: Double = 0
    @State private var fileSize: String = ""
    @State private var formatBadges: [VideoFormatBadge] = []

    @ViewBuilder
    var body: some View {
        if let url = videoURL {
            content
                .task(id: url.absoluteString) {
                    await loadVideoInformation(from: url)
                }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            if !formatBadges.isEmpty {
                HStack(spacing: 4) {
                    // Secondary pill inside the glass info panel; same metrics as
                    // the `tag()` pills in `SceneInformationOverlay` /
                    // `HTMLInformationOverlay` (shared flat-pill standard).
                    ForEach(formatBadges, id: \.self) { badge in
                        Text(verbatim: badge.displayLabel)
                            .font(DesignTokens.Typography.badge)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                DesignTokens.Colors.overlayForeground.opacity(0.18),
                                in: Capsule()
                            )
                    }
                }
            }
            if let res = videoResolution {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.3.group")
                    Text(verbatim: "\(res.width)×\(res.height)")
                }
            }
            if videoFrameRate > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                    Text(verbatim: "\(Int(videoFrameRate)) FPS")
                }
            }
            if !fileSize.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                    Text(verbatim: fileSize)
                }
            }
        }
        .font(DesignTokens.Typography.metric)
        .foregroundStyle(DesignTokens.Colors.overlayForeground)
        .padding(.horizontal, DesignTokens.Spacing.cardInset)
        .padding(.vertical, 8)
        .thumbnailBadgeGlass()
    }

    @MainActor
    private func loadVideoInformation(from url: URL) async {
        resetVideoInformation()
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        fileSize = Self.fileSizeDescription(for: url) ?? ""

        if let info = try? await PlayableVideoLoader.detectFormat(at: url) {
            guard !Task.isCancelled else { return }
            formatBadges = info.badges
        }

        do {
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = videoTracks.first else { return }

            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let nominalFrameRate = try await track.load(.nominalFrameRate)

            guard !Task.isCancelled else { return }
            let transformedSize = naturalSize.applying(preferredTransform)
            videoResolution = (width: abs(Int(transformedSize.width)),
                               height: abs(Int(transformedSize.height)))
            videoFrameRate = Double(nominalFrameRate)
        } catch {
            // Best-effort metadata: the inspector rows stay blank on failure.
            Logger.debug("Video metadata load failed: \(error)", category: .videoPlayer)
        }
    }

    private func resetVideoInformation() {
        videoResolution = nil
        videoFrameRate = 0
        fileSize = ""
        formatBadges = []
    }

    private static func fileSizeDescription(for url: URL) -> String? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return FormatUtils.formatBytes(size.int64Value)
    }
}
