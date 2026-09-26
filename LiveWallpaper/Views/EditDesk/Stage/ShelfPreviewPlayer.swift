import AppKit
import LiveWallpaperCore
import QuartzCore

/// When a shelf card animates its preview on hover.
enum ShelfPreviewPlayback {
    /// `displaysGIF`: the picture on the card is its scene's own `.gif` preview. A saved cover, a video
    /// poster or a web snapshot never plays, whatever the scene's preview is.
    static func plays(displaysGIF: Bool, hoverSettled: Bool, autoplayEnabled: Bool, reduceMotion: Bool, covered: Bool) -> Bool {
        displaysGIF && hoverSettled && autoplayEnabled && !reduceMotion && !covered
    }

    static func displaysGIF(_ card: StageCard) -> Bool {
        card.thumbnail != nil && card.previewOrigin?.previewFileName?.lowercased().hasSuffix(".gif") == true
    }
}

/// Plays one card's GIF preview as a keyframe animation over its thumbnail's `contents`: the render
/// server keeps the frame times, and removing the animation shows the card's own first frame again.
@MainActor
final class ShelfPreviewPlayer {
    /// `settledHover`'s delay, the pause before a SwiftUI tile starts its GIF.
    static let settleDelay: Duration = .milliseconds(150)
    static let animationKey = "hoverPreview"

    var load: @MainActor (WPEOrigin, Int) async -> ShelfPreviewFrames? = { origin, maxPixelSize in
        await ShelfPreviewFrames.load(origin, maxPixelSize: maxPixelSize)
    }

    /// The card this player waits on or plays; nil when idle.
    private(set) var cardID: StageCard.ID?
    private var task: Task<Void, Never>?
    private weak var layer: CALayer?

    /// Plays `card`'s preview on `layer` once the pointer has rested `settleDelay`, if `allowed` still
    /// says so both before the frames are decoded and after.
    func play(_ card: StageCard, on layer: CALayer, maxPixelSize: Int, when allowed: @escaping @MainActor () -> Bool) {
        stop()
        cardID = card.id
        guard let origin = card.previewOrigin else { return }
        self.layer = layer
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.settleDelay)
            } catch {
                return
            }
            guard allowed(), let load = self?.load, let frames = await load(origin, maxPixelSize),
                  !Task.isCancelled, allowed() else { return }
            layer.add(Self.animation(frames), forKey: Self.animationKey)
        }
    }

    /// Leaves the model `contents`, the card's own first frame, showing.
    func stop() {
        task?.cancel()
        task = nil
        layer?.removeAnimation(forKey: Self.animationKey)
        layer = nil
        cardID = nil
    }

    /// Discrete keyframes need one more key time than values: each frame holds until the next one's time.
    static func animation(_ frames: ShelfPreviewFrames) -> CAKeyframeAnimation {
        let total = frames.delays.reduce(0, +)
        var elapsed = 0.0
        var keyTimes: [NSNumber] = [0]
        for delay in frames.delays.dropLast() {
            elapsed += delay
            keyTimes.append(NSNumber(value: elapsed / total))
        }
        keyTimes.append(1)
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames.images
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        return animation
    }
}
