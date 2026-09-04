import AVFoundation
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("OggAudioTranscoder cancellation")
struct OggAudioTranscoderCancellationTests {
    /// Small PCM source. `transcode` sniffs content, so a CAF works and keeps
    /// the test independent of the host's Ogg decoder availability.
    private func makePCMSource(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        buffer.frameLength = 44100
        if let channels = buffer.floatChannelData {
            memset(channels[0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
        try file.write(from: buffer)
        return url
    }

    @Test("A set cancellation flag aborts the transcode and leaves no artifacts")
    func cancelledTranscodeLeavesNoArtifacts() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let source = try makePCMSource(in: root)
        let destination = root.appendingPathComponent("out.m4a")

        let produced = OggAudioTranscoder.shared.transcode(source, to: destination, isCancelled: { true })

        #expect(produced == nil)
        #expect(!fileManager.fileExists(atPath: destination.path))
        #expect(!fileManager.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }

    @Test("Control: the same source transcodes when the flag stays clear")
    func uncancelledTranscodeProducesDestination() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let source = try makePCMSource(in: root)
        let destination = root.appendingPathComponent("out.m4a")

        let produced = OggAudioTranscoder.shared.transcode(source, to: destination, isCancelled: { false })

        #expect(produced == destination)
        #expect(fileManager.fileExists(atPath: destination.path))
        #expect(!fileManager.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }
}
