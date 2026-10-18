import AVFoundation
import AppKit
import CoreGraphics
import LiveWallpaperCore

@MainActor
enum DesktopPictureFrameExtractor {
    static var picturesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWallpaper/DesktopPictures", isDirectory: true)
    }

    /// Returning true as soon as the player had an item, before decode/encode/write/install, would let every async failure below reach the log while the UI played a captured animation.
    enum Outcome: Equatable, Sendable {
        case captured
        /// Nothing is playing to capture.
        case noFrameAvailable
        case encodingFailed
        /// macOS refused the new desktop picture, or the file could not be written.
        case installFailed
        /// A later request for the same screen started while this one decoded; that one installs.
        case superseded
    }

    static func applyCurrentFrame(
        from player: AVPlayer,
        screenID: CGDirectDisplayID,
        nsScreen: NSScreen?,
        install: @MainActor (URL, NSScreen) throws -> Void = { url, screen in
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    ) async -> Outcome {
        guard let currentItem = player.currentItem else { return .noFrameAvailable }

        let imageGenerator = AVAssetImageGenerator(asset: currentItem.asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let currentTime = player.currentTime()
        nonisolated(unsafe) let generator = imageGenerator

        return await applyFrame(
            { try await generator.image(at: currentTime).image },
            screenID: screenID,
            nsScreen: nsScreen,
            install: install
        )
    }

    /// Newest request number per screen; a request that finds a larger one after its decode is stale.
    private static var latestRequest: [CGDirectDisplayID: UInt64] = [:]

    /// `frame` and `install` are the two side effects tests replace.
    static func applyFrame(
        _ frame: @MainActor () async throws -> CGImage,
        screenID: CGDirectDisplayID,
        nsScreen: NSScreen?,
        install: @MainActor (URL, NSScreen) throws -> Void
    ) async -> Outcome {
        let request = (latestRequest[screenID] ?? 0) &+ 1
        latestRequest[screenID] = request
        do {
            let cgImage = try await frame()
            guard latestRequest[screenID] == request else { return .superseded }
            let nsImage = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )

            // A fresh URL prevents macOS from reusing a cached image, including after relaunch.
            let pictureURL = picturesDirectory
                .appendingPathComponent("LiveWallpaper_LockScreen_\(screenID)_\(UUID().uuidString).png")

            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                Logger.error("Failed to encode desktop picture frame for screen \(screenID)", category: .screenManager)
                return .encodingFailed
            }

            do {
                // `.atomic` writes a uniquely named sibling and renames it over the target, so the system never reads a half-written PNG.
                try FileManager.default.createDirectory(at: picturesDirectory, withIntermediateDirectories: true)
                try pngData.write(to: pictureURL, options: .atomic)
            } catch {
                // Distinct from the decode failure below: the frame was read
                // fine and the disk refused it.
                Logger.error("Failed to write desktop picture frame: \(error.localizedDescription)", category: .screenManager)
                return .installFailed
            }

            do {
                guard let nsScreen else { throw CocoaError(.fileNoSuchFile) }
                try install(pictureURL, nsScreen)
                removeOlderPictures(for: screenID, keeping: pictureURL)
                Logger.info("Updated desktop picture for screen \(screenID)", category: .screenManager)
                return .captured
            } catch {
                try? FileManager.default.removeItem(at: pictureURL)
                Logger.error("Failed to set desktop picture: \(error.localizedDescription)", category: .screenManager)
                return .installFailed
            }
        } catch {
            Logger.error("Failed to extract desktop picture frame: \(error.localizedDescription)", category: .screenManager)
            return .noFrameAvailable
        }
    }

    /// Keep the installed image and one previous image; failed installs never change either file.
    private static func removeOlderPictures(for screenID: CGDirectDisplayID, keeping current: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let pictures = (try? FileManager.default.contentsOfDirectory(
            at: picturesDirectory, includingPropertiesForKeys: Array(keys)
        )) ?? []
        let previous = pictures.filter {
            $0 != current && $0.lastPathComponent.hasPrefix("LiveWallpaper_LockScreen_\(screenID)_")
                && $0.pathExtension == "png"
        }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for url in previous.dropFirst() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
