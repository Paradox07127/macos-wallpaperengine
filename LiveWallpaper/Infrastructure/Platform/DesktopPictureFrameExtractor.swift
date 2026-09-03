import AVFoundation
import AppKit
import CoreGraphics
import LiveWallpaperCore

@MainActor
enum DesktopPictureFrameExtractor {
    /// Reads the playing frame and installs it as the desktop picture,
    /// answering with what actually happened.
    ///
    /// This used to return `true` as soon as the player had an item, before the
    /// frame was decoded, encoded, written or installed — so every async
    /// failure below reached the log while the UI played its "captured"
    /// animation, and nothing ever took that animation back.
    enum Outcome: Equatable, Sendable {
        case captured
        /// Nothing is playing to capture.
        case noFrameAvailable
        case encodingFailed
        /// macOS refused the new desktop picture, or the file could not be written.
        case installFailed
    }

    static func applyCurrentFrame(
        from player: AVPlayer,
        screenID: CGDirectDisplayID,
        nsScreen: NSScreen?
    ) async -> Outcome {
        guard let currentItem = player.currentItem else { return .noFrameAvailable }

        let imageGenerator = AVAssetImageGenerator(asset: currentItem.asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let currentTime = player.currentTime()
        nonisolated(unsafe) let generator = imageGenerator

        do {
            let (cgImage, _) = try await generator.image(at: currentTime)
            let nsImage = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LiveWallpaper_LockScreen_\(screenID).png")

            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                Logger.error("Failed to encode desktop picture frame for screen \(screenID)", category: .screenManager)
                return .encodingFailed
            }

            do {
                try pngData.write(to: tempURL)
            } catch {
                // Distinct from the decode failure below: the frame was read
                // fine and the disk refused it.
                Logger.error("Failed to write desktop picture frame: \(error.localizedDescription)", category: .screenManager)
                return .installFailed
            }

            guard let nsScreen else { return .installFailed }
            do {
                try NSWorkspace.shared.setDesktopImageURL(tempURL, for: nsScreen, options: [:])
                Logger.info("Updated desktop picture for screen \(screenID)", category: .screenManager)
                return .captured
            } catch {
                Logger.error("Failed to set desktop picture: \(error.localizedDescription)", category: .screenManager)
                return .installFailed
            }
        } catch {
            Logger.error("Failed to extract desktop picture frame: \(error.localizedDescription)", category: .screenManager)
            return .noFrameAvailable
        }
    }
}
