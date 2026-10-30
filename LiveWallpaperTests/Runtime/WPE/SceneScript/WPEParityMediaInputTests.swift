import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import os
import Testing
import UniformTypeIdentifiers

/// Uses the existing fake external source, never the user's now-playing monitor.
@Suite("WPE parity media inputs", .serialized)
@MainActor
struct WPEParityMediaInputTests {
    @Test("Reload seeds the same uploaded pair to a new loaded consumer")
    func reloadReplaysTheCurrentPairWithoutRotatingIt() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = FakeNowPlayingSource()
        try source.push(.init(phase: .playing, title: "A", artwork: artwork(width: 2, red: 192)))
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let mailbox = dispatcher.mailbox
        let wakes = OSAllocatedUnfairLock(initialState: 0)
        mailbox.beginParityGeneration(1)
        let configuredFirst = dispatcher.configureParity(generation: 1, device: device, textureDemand: true,
                                                         onChange: { wakes.withLock { $0 += 1 } })
        #expect(configuredFirst)
        defer { dispatcher.stop() }
        let first = try #require(mailbox.drainParityInputs(generation: 1).only)
        let firstPair = try #require(first.textures)
        let coverA = try #require(firstPair.current)
        #expect(firstPair.previous == nil)

        try source.push(.init(phase: .playing, title: "B", artwork: artwork(width: 3, red: 48)))
        let change = try #require(mailbox.drainParityInputs(generation: 1).only)
        let changedPair = try #require(change.textures)
        let coverB = try #require(changedPair.current)
        #expect(changedPair.previous === coverA)
        #expect(coverB !== coverA)
        #expect(change.systemProperties["$mediaPreviousThumbnail"] == firstPair.currentSystemName)

        mailbox.beginParityGeneration(2)
        let configuredReload = dispatcher.configureParity(generation: 2, device: device, textureDemand: true,
                                                          onChange: { wakes.withLock { $0 += 1 } })
        #expect(configuredReload)
        let reload = try #require(mailbox.drainParityInputs(generation: 2).only)
        let reloadedPair = try #require(reload.textures)
        #expect(reloadedPair.revision == changedPair.revision)
        #expect(reloadedPair.current === coverB)
        #expect(reloadedPair.previous === coverA)
        #expect(reload.systemProperties == change.systemProperties)
        let reloadCarriesTitleB = reload.events.contains(.propertiesChanged(.init(title: "B")))
        #expect(reloadCarriesTitleB)
        #expect(reload.events.contains {
            if case .thumbnailChanged = $0 {
                true
            } else {
                false
            }
        })
        #expect(source.subscriberCount == 1)
        #expect(dispatcher.replayGeneration(2))
        #expect(mailbox.drainParityInputs(generation: 2).isEmpty)
        #expect(wakes.withLock { $0 } == 3)
        // A previously drained input still owns its pair after reload publishes a new consumer's input.
        #expect(firstPair.texture(for: .thumbnail) === coverA)
    }

    @Test("Script-only covers keep identities and same-palette changes; enabling demand uploads that pair")
    func scriptOnlyArtworkChangesPropertiesBeforeTexturesAreRequested() throws {
        let source = FakeNowPlayingSource()
        let a = try artwork(width: 2, red: 128)
        let b = try artwork(width: 3, red: 128)
        #expect(a != b)
        var palette = WPEMediaArtworkPaletteCache()
        let paletteA = palette.thumbnail(for: MonitorNowPlayingArtwork(a))
        let paletteB = palette.thumbnail(for: MonitorNowPlayingArtwork(b))
        #expect(paletteA.hasThumbnail && paletteA == paletteB, "The source images have identical palette payloads")
        source.push(.init(phase: .playing, title: "Same title", artwork: a))
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let mailbox = dispatcher.mailbox
        mailbox.beginParityGeneration(1)
        let configuredScripts = dispatcher.configureParity(generation: 1, device: nil, textureDemand: false, onChange: {})
        #expect(configuredScripts)
        defer { dispatcher.stop() }
        let first = try #require(mailbox.drainParityInputs(generation: 1).only)
        let firstPair = try #require(first.textures)
        let firstName = try #require(firstPair.currentSystemName)
        #expect(firstPair.current == nil && firstPair.previous == nil)
        #expect(first.systemProperties["$mediaThumbnail"] == firstName)

        source.push(.init(phase: .playing, title: "Same title", artwork: b))
        let change = try #require(mailbox.drainParityInputs(generation: 1).only)
        let namePair = try #require(change.textures)
        let secondName = try #require(namePair.currentSystemName)
        #expect(secondName != firstName)
        #expect(namePair.previousSystemName == firstName)
        #expect(namePair.current == nil && namePair.previous == nil)
        #expect(change.systemProperties["$mediaThumbnail"] == secondName)
        #expect(change.systemProperties["$mediaPreviousThumbnail"] == firstName)
        #expect(change.events.contains(.thumbnailChanged(paletteB)))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let configuredTextures = dispatcher.configureParity(generation: 1, device: device, textureDemand: true, onChange: {})
        #expect(configuredTextures)
        let demand = try #require(mailbox.drainParityInputs(generation: 1).only)
        let uploaded = try #require(demand.textures)
        let current = try #require(uploaded.texture(for: .thumbnail))
        let previous = try #require(uploaded.texture(for: .previousThumbnail))
        #expect(current.width == 3 && previous.width == 2)
        #expect(uploaded.revision == namePair.revision)
        #expect(uploaded.currentSystemName == secondName && uploaded.previousSystemName == firstName)
        #expect(demand.systemProperties == change.systemProperties)
        #expect(source.subscriberCount == 1)
    }

    @Test("A retired loaded consumer cannot be revived by delayed configuration")
    func retiredLoadCannotConfigureOrConsumeAnotherLoadsInputs() throws {
        let source = FakeNowPlayingSource()
        try source.push(.init(phase: .playing, title: "Current", artwork: artwork(width: 2, red: 64)))
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let mailbox = dispatcher.mailbox
        mailbox.beginParityGeneration(1)
        let configuredFirst = dispatcher.configureParity(generation: 1, device: nil, textureDemand: false, onChange: {})
        #expect(configuredFirst)
        defer { dispatcher.stop() }
        _ = try #require(mailbox.drainParityInputs(generation: 1).only)
        mailbox.beginParityGeneration(2)
        let rejectedRetired = dispatcher.configureParity(generation: 1, device: nil, textureDemand: false, onChange: {})
        #expect(!rejectedRetired)
        mailbox.invalidateParityGeneration(1)
        let configuredCurrent = dispatcher.configureParity(generation: 2, device: nil, textureDemand: false, onChange: {})
        #expect(configuredCurrent)
        #expect(mailbox.drainParityInputs(generation: 1).isEmpty)
        let current = try #require(mailbox.drainParityInputs(generation: 2).only)
        #expect(current.generation == 2)
        mailbox.invalidateParityGeneration(2)
        let rejectedInvalidated = dispatcher.configureParity(generation: 2, device: nil, textureDemand: false, onChange: {})
        #expect(!rejectedInvalidated)
        #expect(!dispatcher.replayGeneration(2))
    }

    @Test("A decodable transparent cover still has an identity when palette analysis has no samples")
    func transparentCoverDoesNotBecomeUndecodableArtwork() throws {
        let source = FakeNowPlayingSource()
        let bytes = try artwork(width: 2, red: 192, alpha: 32)
        var palette = WPEMediaArtworkPaletteCache()
        #expect(!palette.thumbnail(for: MonitorNowPlayingArtwork(bytes)).hasThumbnail, "The palette excludes samples below alpha .5")
        source.push(.init(phase: .playing, title: "Transparent", artwork: bytes))
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let mailbox = dispatcher.mailbox
        mailbox.beginParityGeneration(1)
        let configuredTransparent = dispatcher.configureParity(generation: 1, device: nil, textureDemand: false, onChange: {})
        #expect(configuredTransparent)
        defer { dispatcher.stop() }
        let input = try #require(mailbox.drainParityInputs(generation: 1).only)
        let pair = try #require(input.textures)
        let name = try #require(pair.currentSystemName)
        #expect(input.systemProperties["$mediaThumbnail"] == name)
        #expect(pair.current == nil)
        #expect(input.events.contains {
            if case let .thumbnailChanged(thumbnail) = $0 {
                thumbnail.hasThumbnail
            } else {
                false
            }
        })
        #expect(input.diagnostics.contains { $0.contains("palette-unavailable") })
        #expect(!input.diagnostics.contains { $0.contains("undecodable") })
    }

    @Test("Absent, empty and undecodable artwork rotate raw names without uploaded textures")
    func unavailableArtworkRotatesRawSystemNames() throws {
        let source = FakeNowPlayingSource()
        source.push(.init(phase: .playing, title: "No cover"))
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let mailbox = dispatcher.mailbox
        mailbox.beginParityGeneration(1)
        let configuredUnavailable = dispatcher.configureParity(generation: 1, device: nil, textureDemand: false, onChange: {})
        #expect(configuredUnavailable)
        defer { dispatcher.stop() }
        let absent = try #require(mailbox.drainParityInputs(generation: 1).only)
        #expect(absent.diagnostics.contains { $0.contains("absent") })
        #expect(!absent.events.contains {
            if case .thumbnailChanged = $0 {
                true
            } else {
                false
            }
        })
        var previousName = try #require(absent.textures?.currentSystemName)
        for (bytes, reason) in [(Data(), "empty"), (Data([1, 2, 3, 4]), "undecodable")] {
            source.push(.init(phase: .playing, title: "No cover", artwork: bytes))
            let input = try #require(mailbox.drainParityInputs(generation: 1).only)
            let pair = try #require(input.textures)
            #expect(pair.current == nil && pair.previous == nil)
            let name = try #require(pair.currentSystemName)
            #expect(name != previousName && pair.previousSystemName == previousName)
            #expect(input.systemProperties == ["$mediaThumbnail": name, "$mediaPreviousThumbnail": previousName])
            #expect(input.diagnostics.contains { $0.contains(reason) })
            previousName = name
        }
    }

    private func artwork(width: Int, red: UInt8, alpha: UInt8 = 255) throws -> Data {
        let bytes = Data((0 ..< width * 2).flatMap { _ in [red, UInt8(24), UInt8(48), alpha] })
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: width, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

private extension [WPESceneParityMediaInput] {
    var only: Element? {
        count == 1 ? first : nil
    }
}
