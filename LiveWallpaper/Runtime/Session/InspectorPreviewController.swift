import AppKit
@preconcurrency import AVFoundation
import Combine
import Observation

struct InspectorPosterLoadState {
    struct Token: Equatable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var activeToken: Token?

    mutating func begin() -> Token {
        generation &+= 1
        let token = Token(generation: generation)
        activeToken = token
        return token
    }

    mutating func invalidate() {
        generation &+= 1
        activeToken = nil
    }

    func isCurrent(_ token: Token) -> Bool {
        activeToken == token
    }

    mutating func finish(_ token: Token) -> Bool {
        guard isCurrent(token) else { return false }
        activeToken = nil
        return true
    }
}

@MainActor @Observable
final class InspectorPreviewController {
    private(set) var player: AVPlayer?
    private(set) var posterImage: NSImage?
    private(set) var isLoading = false
    private(set) var isPlaying = false
    private(set) var currentPosition: Double = 0
    private(set) var duration: Double = 1
    private(set) var lastError: String?
    /// Last URL for loadPoster/startPlaybackPreview (info overlay can load metadata without the player).
    private(set) var assetURL: URL?

    @ObservationIgnored private var playerObserver: AnyCancellable?
    @ObservationIgnored private var itemStatusObserver: AnyCancellable?
    @ObservationIgnored private var positionTask: Task<Void, Never>?
    @ObservationIgnored private var posterTask: Task<Void, Never>?
    @ObservationIgnored private var posterLoadState = InspectorPosterLoadState()
    @ObservationIgnored private var securityScopedURL: URL?

    var hasPreviewContent: Bool {
        player != nil || posterImage != nil
    }

    deinit {
        // deinit backstop if cleanup() skipped — cancels the 500 ms position poll.
        positionTask?.cancel()
        posterTask?.cancel()
    }

    func loadPoster(from url: URL, syncTime: CMTime? = nil) {
        guard player == nil else { return }

        assetURL = url
        posterTask?.cancel()
        let token = posterLoadState.begin()
        isLoading = true
        lastError = nil

        let targetTime: CMTime
        if let syncTime, syncTime.isValid, !syncTime.seconds.isNaN {
            targetTime = syncTime
        } else {
            targetTime = .zero
        }

        posterTask = Task { [weak self] in
            let didStartScope = url.startAccessingSecurityScopedResource()
            defer {
                if didStartScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
                // Poster only fills the inspector preview pane / monitor backdrop,
                // so don't decode a 4K/8K frame; aspect-fit is preserved.
                generator.maximumSize = CGSize(width: 1280, height: 1280)

                let loadedDuration = try? await asset.load(.duration)
                let (cgImage, actualTime) = try await generator.image(at: targetTime)

                guard !Task.isCancelled,
                      let self,
                      self.player == nil,
                      self.posterLoadState.finish(token) else { return }

                self.posterTask = nil
                self.posterImage = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                self.currentPosition = Self.validSeconds(actualTime.seconds, fallback: 0)
                self.duration = Self.validSeconds(loadedDuration?.seconds, fallback: 1)
                self.isLoading = false
            } catch is CancellationError {
                guard let self, self.posterLoadState.finish(token) else { return }
                self.posterTask = nil
                self.isLoading = false
            } catch {
                guard let self,
                      self.player == nil,
                      self.posterLoadState.finish(token) else { return }
                self.posterTask = nil
                self.lastError = error.localizedDescription
                self.posterImage = nil
                self.isLoading = false
            }
        }
    }

    func startPlaybackPreview(from url: URL, syncTo wallpaperPlayer: AVPlayer?) {
        cleanupPlayer()
        posterLoadState.invalidate()
        posterTask?.cancel()
        posterTask = nil
        assetURL = url
        isLoading = true
        lastError = nil

        retainSecurityScope(for: url)

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 2.0

        let previewPlayer = AVPlayer(playerItem: playerItem)
        previewPlayer.volume = 0
        previewPlayer.isMuted = true
        previewPlayer.automaticallyWaitsToMinimizeStalling = false
        disableAudioTracks(for: playerItem)

        player = previewPlayer
        posterImage = nil
        isLoading = false

        if let wallpaperPlayer {
            sync(to: wallpaperPlayer)
        }

        configureItemStatusObserver(playerItem)
        configurePlayerObserver(previewPlayer)
        startPositionUpdates(for: previewPlayer)
        previewPlayer.play()
        isPlaying = true
    }

    func updateScrubPosition(_ position: Double) {
        currentPosition = min(max(position, 0), max(1, duration))
    }

    func seekToCurrentPosition() {
        player?.seek(to: CMTime(seconds: currentPosition, preferredTimescale: 600))
    }

    func togglePlayback() {
        guard let player else { return }
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func cleanup() {
        posterLoadState.invalidate()
        posterTask?.cancel()
        posterTask = nil
        posterImage = nil
        assetURL = nil
        currentPosition = 0
        duration = 1
        lastError = nil
        isLoading = false
        cleanupPlayer()
    }

    private func configurePlayerObserver(_ player: AVPlayer) {
        playerObserver = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = status == .playing
            }
    }

    private func configureItemStatusObserver(_ playerItem: AVPlayerItem) {
        itemStatusObserver = playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak playerItem] status in
                guard status == .failed else { return }
                guard let self else { return }
                self.lastError = playerItem?.error?.localizedDescription ?? "The preview could not be played."
                self.cleanupPlayer()
                self.isLoading = false
            }
    }

    private func startPositionUpdates(for player: AVPlayer) {
        positionTask?.cancel()
        positionTask = Task { [weak self, weak player] in
            while !Task.isCancelled {
                guard let self else { return }
                if let player {
                    let time = player.currentTime().seconds
                    self.currentPosition = Self.validSeconds(time, fallback: self.currentPosition)

                    let itemDuration = player.currentItem?.duration.seconds
                    self.duration = Self.validSeconds(itemDuration, fallback: self.duration)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func sync(to wallpaperPlayer: AVPlayer) {
        let wallpaperTime = wallpaperPlayer.currentTime()
        if wallpaperTime.isValid, !wallpaperTime.seconds.isNaN {
            player?.seek(to: wallpaperTime, toleranceBefore: .zero, toleranceAfter: .zero)
            currentPosition = wallpaperTime.seconds
        }
    }

    private func cleanupPlayer() {
        playerObserver?.cancel()
        playerObserver = nil
        itemStatusObserver?.cancel()
        itemStatusObserver = nil
        positionTask?.cancel()
        positionTask = nil
        player?.pause()
        player = nil
        isPlaying = false
        releaseSecurityScope()
    }

    private func retainSecurityScope(for url: URL) {
        releaseSecurityScope()
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
    }

    private func releaseSecurityScope() {
        if let securityScopedURL {
            securityScopedURL.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
    }

    private func disableAudioTracks(for playerItem: AVPlayerItem) {
        playerItem.tracks
            .filter { $0.assetTrack?.mediaType == .audio }
            .forEach { $0.isEnabled = false }
    }

    private static func validSeconds(_ value: Double?, fallback: Double) -> Double {
        guard let value, !value.isNaN, !value.isInfinite, value > 0 else {
            return fallback
        }
        return value
    }
}
