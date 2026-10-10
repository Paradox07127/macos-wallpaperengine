import Foundation
import Testing

@Suite("System wallpaper renderer guard")
struct SystemWallpaperRendererGuardTests {

    private func renderer() throws -> String {
        try RepositoryRoot.source("SystemWallpaperProvider/VideoRenderer.swift")
    }

    private func handler() throws -> String {
        try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCHandler.swift")
    }

    private func member(_ source: String, from marker: String) throws -> String {
        let start = try #require(source.range(of: marker), "no \(marker) in source")
        let body = source[start.lowerBound...]
        guard let end = body.range(of: "\n    }\n") else { return String(body) }
        return String(body[..<end.upperBound])
    }

    @Test("Every registry access runs on the lifecycle queue")
    func selectedChoicesDidChangeHopsToTheLifecycleQueue() throws {
        let source = try handler()
        let body = try member(source, from: "func selectedChoicesDidChange")
        let hop = try #require(body.range(of: "Self.queue.async"), "the body never reaches the lifecycle queue")
        let heartbeat = try #require(body.range(of: "Self.writeActiveHeartbeat("))
        #expect(
            hop.lowerBound < heartbeat.lowerBound,
            "registry.all is read before the queue hop — that is the race"
        )
    }

    @Test("The loop seam ignores zero-sample marker buffers")
    func loopSeamIgnoresMarkerBuffers() throws {
        let source = try renderer()
        let shift = try member(source, from: "private func shift(")
        #expect(
            shift.contains("CMSampleBufferGetNumSamples(sample) > 0"),
            "maxSampleEnd must only count buffers that actually carry media"
        )
    }

    @Test("Losing the decoder is observed and recovered with a flush")
    func decoderLossIsObservedAndFlushed() throws {
        let source = try renderer()
        #expect(
            source.contains("requiresFlushToResumeDecodingDidChangeNotification"),
            "nothing observes the renderer losing its decoder"
        )
        let recovery = try member(source, from: "private func handleDecoderLoss")
        #expect(recovery.contains("renderer.flush()"), "only a flush clears the failed status")
        #expect(recovery.contains("openReader("), "after a flush the supply has to restart at a sync sample")
    }

    @Test("Deep pause drops the queued frames it is about to re-read")
    func deepPauseFlushesTheQueue() throws {
        let source = try renderer()
        let enter = try member(source, from: "private func enterDeepPause")
        #expect(enter.contains("renderer.flush()"), "the queued future frames survive into the resume")
    }
}
