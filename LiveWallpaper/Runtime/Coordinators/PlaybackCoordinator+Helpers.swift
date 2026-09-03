import AVFoundation
import CoreGraphics
import Foundation
import LiveWallpaperCore

@MainActor
extension PlaybackCoordinator {
    // MARK: - Helpers

    func save(_ configuration: ScreenConfiguration) {
        advanceSceneMutationIntent(configuration.screenID)
        configurationStore.save(configuration)
        notifyConfigurationChanged(configuration.screenID)
    }

    func removeConfiguration(for screenID: CGDirectDisplayID) {
        configurationStore.remove(for: screenID)
        notifyConfigurationChanged(screenID)
    }

    static func clampedVideoVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0), 1)
    }

    func syncVideoAudioLeadership() {
        let screens = screensProvider()
        let entries = screens.compactMap { screen -> VideoAudioLeadershipPolicy.Entry? in
            guard let player = screen.videoPlayer,
                  let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                  configuration.wallpaperType == .video else { return nil }
            return VideoAudioLeadershipPolicy.Entry(
                screenID: screen.id,
                urlKey: Self.videoAudioURLKey(
                    for: player.videoURL,
                    packageEntryName: player.packageEntryName
                ),
                userMuted: configuration.muted
            )
        }
        let effectiveMutedStates = VideoAudioLeadershipPolicy.effectiveMutedStates(for: entries)

        for screen in screens {
            guard let player = screen.videoPlayer,
                  let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                  configuration.wallpaperType == .video else { continue }
            player.setVolume(configuration.videoVolume)
            player.setMuted(effectiveMutedStates[screen.id] ?? configuration.muted)
        }
    }

    func applyVideoSpanLayout() {
        let screens = screensProvider()
        let candidates = screens.compactMap { screen -> (screen: Screen, player: WallpaperVideoPlayer, urlKey: String)? in
            guard let player = screen.videoPlayer,
                  let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                  configuration.wallpaperType == .video,
                  configuration.videoDisplayMode == .spanAllDisplays,
                  let urlKey = Self.videoAudioURLKey(
                    for: player.videoURL,
                    packageEntryName: player.packageEntryName
                  ) else {
                return nil
            }
            return (screen, player, urlKey)
        }

        let groups = Dictionary(grouping: candidates) { $0.urlKey }
        var spannedScreenIDs = Set<CGDirectDisplayID>()
        var spannedGroupDescriptions: [String] = []
        var spanDeclinedReasons: [CGDirectDisplayID: String] = [:]

        for group in groups.values where group.count > 1 {
            let renderConfigurations = VideoSpanLayout.renderConfigurations(
                for: group.map { item in
                    VideoSpanLayout.Entry(screenID: item.screen.id, frame: item.screen.frame)
                }
            )
            guard !renderConfigurations.isEmpty else {
                for item in group {
                    spanDeclinedReasons[item.screen.id] =
                        "span layout produced no canvas (fewer than two displays in the group have a non-empty frame)"
                }
                continue
            }

            synchronizeSpanGroupPlaybackTimes(group)

            for item in group {
                item.player.setSpanRenderConfiguration(renderConfigurations[item.screen.id])
                spannedScreenIDs.insert(item.screen.id)
            }
            let canvas = renderConfigurations.values.first?.canvasFrame ?? .zero
            let ids = group.map(\.screen.id).sorted().map(String.init).joined(separator: ", ")
            spannedGroupDescriptions.append(
                "[\(ids)] on a \(Int(canvas.width))×\(Int(canvas.height)) canvas"
            )
        }

        for screen in screens where !spannedScreenIDs.contains(screen.id) {
            screen.videoPlayer?.setSpanRenderConfiguration(nil)
        }

        for item in candidates where !spannedScreenIDs.contains(item.screen.id) {
            guard spanDeclinedReasons[item.screen.id] == nil else { continue }
            let title = LogPrivacyRedactor.sanitizedTitle(
                item.player.videoURL?.lastPathComponent ?? "unknown"
            )
            spanDeclinedReasons[item.screen.id] =
                "no other display is playing the same file (\(title)), so the group has one member"
        }

        // A screen that asked to span but never became a candidate is only
        // inspected when the log is going to be written anyway, and only through
        // the pure-read `get(for:)`. The `fingerprint:` overload above can
        // migrate/back-fill and bump the store revision, which is exactly the
        // condition `isCandidateStillCurrent` kills in-flight candidates on —
        // diagnostics must not be able to manufacture that.
        if !spanDeclinedReasons.isEmpty || (candidates.isEmpty && screens.count > 1) {
            for screen in screens where spanDeclinedReasons[screen.id] == nil {
                guard let configuration = configurationStore.get(for: screen.id),
                      configuration.wallpaperType == .video,
                      configuration.videoDisplayMode == .spanAllDisplays else { continue }
                guard let player = screen.videoPlayer else {
                    spanDeclinedReasons[screen.id] = "no live video player on this screen"
                    continue
                }
                if Self.videoAudioURLKey(
                    for: player.videoURL,
                    packageEntryName: player.packageEntryName
                ) == nil {
                    spanDeclinedReasons[screen.id] = "the player has no resolved video URL yet"
                }
            }
        }

        // Success is silent: this runs once per commit on every screen.
        if !spanDeclinedReasons.isEmpty {
            let declined = spanDeclinedReasons
                .sorted { $0.key < $1.key }
                .map { "screen \($0.key): \($0.value)" }
                .joined(separator: "; ")
            let spanned = spannedGroupDescriptions.isEmpty
                ? "none"
                : spannedGroupDescriptions.joined(separator: ", ")
            Logger.notice(
                "Span across displays requested but not applied — \(declined). Spanned groups: \(spanned).",
                category: .screenManager
            )
        }
    }

    private func synchronizeSpanGroupPlaybackTimes(
        _ group: [(screen: Screen, player: WallpaperVideoPlayer, urlKey: String)]
    ) {
        guard group.count > 1,
              let leaderPlayer = group.first?.player.player else { return }

        let leaderTime = leaderPlayer.currentTime()
        guard leaderTime.isValid else { return }

        for item in group.dropFirst() {
            guard let followerPlayer = item.player.player else { continue }
            let delta = CMTimeGetSeconds(CMTimeSubtract(followerPlayer.currentTime(), leaderTime))
            guard delta.isFinite, abs(delta) > 0.20 else { continue }
            followerPlayer.seek(to: leaderTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    static func videoAudioURLKey(for url: URL?, packageEntryName: String? = nil) -> String? {
        guard let url else { return nil }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        // Distinct .pkg entries are distinct media (path-only keys shared leadership).
        guard let packageEntryName else { return path }
        return path + "#" + packageEntryName
    }

    func bookmarkResolves(to url: URL, bookmark: Data?) -> Bool {
        guard let bookmark else { return false }
        guard case .success(let resolved) = bookmarkResolver.resolve(
            bookmark,
            target: .transient
        ) else { return false }
        return Self.videoAudioURLKey(for: resolved.url) == Self.videoAudioURLKey(for: url)
    }
}
