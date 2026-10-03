#if !LITE_BUILD && DEBUG
import CryptoKit
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

@Suite("Canonical pass raw storage")
struct WPECanonicalPassRawStorageTests {
    private func texture(format: MTLPixelFormat = .rgba8Unorm, bytes: Data) throws -> MTLTexture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 2, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: bytes.count)
        }
        return texture
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func record(_ texture: MTLTexture, recorder: WPECanonicalTraceRecorder) {
        recorder.recordAttachmentOperation(kind: "render-attachment-begin", label: "particle.0", destination: texture)
        recorder.recordParticlePass(
            index: 0, particleCount: 1, sprite: nil, blendMode: "disabled",
            nativeState: .scenePass(blendMode: "disabled", alphaWritePolicy: .all, cullMode: "nocull",
                                    depthAttached: false, depthTest: "disabled", depthWrite: "disabled", reversedZ: false),
            target: texture, spriteSheet: nil, overbright: 1
        )
    }

    private func outputs(_ recorder: WPECanonicalTraceRecorder, texture: MTLTexture, frame: Int = 12) throws -> [[String: Any]] {
        let data = try #require(recorder.finishFrame(outputTexture: texture, runtimeUniforms: nil,
                                                     firstFrameStats: nil, resolutionDiagnostics: .init(events: []), frameOrdinal: frame))
        let trace = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(trace["passes"] as? [[String: Any]]).map { try #require($0["output"] as? [String: Any]) }
    }

    @Test(arguments: [MTLPixelFormat.rgba8Unorm, .bgra8Unorm])
    func straightStorageAndRepeatedPassIDsDoNotCollide(format: MTLPixelFormat) throws {
        let firstBytes = Data([204, 51, 153, 96, 128, 129, 64, 96])
        let secondBytes = Data([103, 26, 76, 48, 1, 0, 76, 48])
        let first = try texture(format: format, bytes: firstBytes)
        let second = try texture(format: format, bytes: secondBytes)
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        let folder = try #require(artifacts.beginSession(workshopID: UUID().uuidString, descriptor: "raw storage tests"))
        defer { artifacts.endSession() }
        let recorder = WPECanonicalTraceRecorder(artifacts: artifacts)
        recorder.beginScene(workshopID: "raw-tests", projectJsonPath: nil, descriptor: "raw")
        record(first, recorder: recorder)
        record(second, recorder: recorder)
        let entries = [(label: "particle.0", texture: first), (label: "particle.0", texture: second)]
        recorder.recordPassOutputs(entries, frameOrdinal: 12)
        recorder.recordPassOutputs(entries, frameOrdinal: 12)
        let result = try outputs(recorder, texture: second)
        #expect(result.count == 2)
        var paths: [String] = []
        for (index, output) in result.enumerated() {
            let receipt = try #require(output["raw"] as? [String: Any])
            let path = try #require(receipt["path"] as? String)
            paths.append(path)
            let actual = try Data(contentsOf: URL(fileURLWithPath: path))
            let expected = index == 0 ? firstBytes : secondBytes
            #expect(actual == expected)
            #expect(receipt["rawStorageSHA256"] as? String == hash(expected))
            #expect(receipt["traceOutputSHA256"] as? String == output["sha256"] as? String)
            #expect(receipt["traceHashRepresentation"] as? String == "raw-storage")
            #expect(receipt["passOrdinal"] as? Int == index)
            #expect(receipt["frameOrdinal"] as? Int == 12)
            #expect(receipt["rowPitch"] as? Int == 8)
            #expect(receipt["byteLength"] as? Int == 8)
            #expect(receipt["bytesPerPixel"] as? Int == 4)
            #expect(receipt["channelOrder"] as? String == (format == .rgba8Unorm ? "RGBA" : "BGRA"))
            #expect(receipt["physicalAttachmentResource"] is String)
            #expect(receipt["physicalAttachmentResource"] as? String == output["physicalResource"] as? String)
            let source = index == 0 ? first : second
            #expect(receipt["physicalAttachmentResource"] as? String == "tex-\(UInt(bitPattern: ObjectIdentifier(source).hashValue))")
            #expect(URL(fileURLWithPath: path).deletingLastPathComponent() == folder)
        }
        #expect(Set(paths).count == 2)
        #expect(result[0]["physicalResource"] as? String != result[1]["physicalResource"] as? String)
        let rawFiles = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["rgba8", "bgra8"].contains($0.pathExtension) }
        #expect(rawFiles.count == 2)

        recorder.beginScene(workshopID: "raw-tests", projectJsonPath: nil, descriptor: "repeat frame")
        record(first, recorder: recorder)
        recorder.recordPassOutputs([(label: "particle.0", texture: first)], frameOrdinal: 12)
        let repeated = try outputs(recorder, texture: first)
        let repeatedRaw = try #require(repeated[0]["raw"] as? [String: Any])
        let repeatedPath = try #require(repeatedRaw["path"] as? String)
        #expect(!paths.contains(repeatedPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == firstBytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[1])) == secondBytes)
        artifacts.endSession()
        #expect(try Data(contentsOf: URL(fileURLWithPath: repeatedPath)) == firstBytes)
    }

    @Test func exportedRawOutputsSurviveSessionPruning() throws {
        let firstBytes = Data([204, 51, 153, 96, 128, 129, 64, 96])
        let secondBytes = Data([103, 26, 76, 48, 1, 0, 76, 48])
        let first = try texture(bytes: firstBytes)
        let second = try texture(bytes: secondBytes)
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        let folder = try #require(artifacts.beginSession(workshopID: UUID().uuidString, descriptor: "raw export"))
        defer { artifacts.endSession() }
        let recorder = WPECanonicalTraceRecorder(artifacts: artifacts)
        recorder.beginScene(workshopID: "raw-export", projectJsonPath: nil, descriptor: "raw")
        record(first, recorder: recorder)
        record(second, recorder: recorder)
        recorder.recordPassOutputs([(label: "particle.0", texture: first), (label: "particle.0", texture: second)], frameOrdinal: 3)
        let data = try #require(recorder.finishFrame(outputTexture: second, runtimeUniforms: nil, firstFrameStats: nil,
                                                     resolutionDiagnostics: .init(events: []), frameOrdinal: 3))
        var trace = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outputRoot = FileManager.default.temporaryDirectory.appendingPathComponent("raw-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        try OracleCorpusCaptureTests.exportRawPassOutputs(in: &trace, outputRoot: outputRoot, directory: "scene-s00-n0-raw")
        artifacts.endSession()
        try FileManager.default.removeItem(at: folder)

        let passes = try #require(trace["passes"] as? [[String: Any]])
        #expect(passes.count == 2)
        for (index, pass) in passes.enumerated() {
            let receipt = try #require((pass["output"] as? [String: Any])?["raw"] as? [String: Any])
            let path = try #require(receipt["path"] as? String)
            #expect(!path.hasPrefix("/"))
            #expect(path.hasPrefix("scene-s00-n0-raw/"))
            let copied = try Data(contentsOf: outputRoot.appendingPathComponent(path))
            #expect(copied == (index == 0 ? firstBytes : secondBytes))
            #expect(receipt["rawStorageSHA256"] as? String == hash(copied))
        }
    }

    @Test func float16PreservesOriginalBitsAndLegacyCanonicalHash() throws {
        let bits: [UInt16] = [0x4000, 0xBC00, 0x3600, 0x7C00, 0x7E01, 0x3800, 0, 0x3C00]
        let bytes = bits.withUnsafeBytes { Data($0) }
        let canonical = Data([255, 0, 96, 0, 0, 128, 0, 255])
        let source = try texture(format: .rgba16Float, bytes: bytes)
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        _ = try #require(artifacts.beginSession(workshopID: UUID().uuidString, descriptor: "float raw storage"))
        defer { artifacts.endSession() }
        let recorder = WPECanonicalTraceRecorder(artifacts: artifacts)
        recorder.beginScene(workshopID: "float-tests", projectJsonPath: nil, descriptor: "raw")
        record(source, recorder: recorder)
        recorder.recordPassOutputs([(label: "particle.0", texture: source)], frameOrdinal: 12)
        let output = try #require(try outputs(recorder, texture: source).first)
        let receipt = try #require(output["raw"] as? [String: Any])
        let path = try #require(receipt["path"] as? String)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(receipt["rawStorageSHA256"] as? String == hash(bytes))
        #expect(receipt["traceOutputSHA256"] as? String == hash(canonical))
        #expect(output["sha256"] as? String == hash(canonical))
        #expect(receipt["rawStorageSHA256"] as? String != receipt["traceOutputSHA256"] as? String)
        #expect(receipt["traceHashRepresentation"] as? String == "clamped-rounded-RGBA8")
        #expect(receipt["componentEncoding"] as? String == "IEEE754-binary16-little-endian")
        #expect(receipt["bytesPerPixel"] as? Int == 8)
        #expect(receipt["rowPitch"] as? Int == 16)
        #expect(receipt["byteLength"] as? Int == 16)
    }

    @Test func disabledArtifactsWriteNothingAndExistingFilesAreNeverOverwritten() throws {
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        let folder = try #require(artifacts.beginSession(workshopID: UUID().uuidString, descriptor: "disabled raw storage"))
        defer { artifacts.endSession() }
        let bytes = Data([204, 51, 153, 96, 128, 129, 64, 96])
        let source = try texture(bytes: bytes)
        let recorder = WPECanonicalTraceRecorder(artifacts: artifacts)
        recorder.beginScene(workshopID: "disabled-tests", projectJsonPath: nil, descriptor: "raw")
        record(source, recorder: recorder)
        artifacts.setEnabledForTesting(false)
        recorder.recordPassOutputs([(label: "particle.0", texture: source)], frameOrdinal: 12)
        #expect(try artifacts.recordPassOutputBytes(name: "disabled.rgba8", bytes: bytes, sessionFolder: folder) == nil)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.allSatisfy { $0.pathExtension != "rgba8" })
        artifacts.setEnabledForTesting(true)
        let path = try #require(try artifacts.recordPassOutputBytes(name: "exclusive.rgba8", bytes: bytes, sessionFolder: folder))
        #expect(throws: (any Error).self) {
            _ = try artifacts.recordPassOutputBytes(name: "exclusive.rgba8", bytes: Data([0]), sessionFolder: folder)
        }
        #expect(try Data(contentsOf: path) == bytes)
        #expect(try artifacts.recordPassOutputBytes(name: "foreign.rgba8", bytes: bytes,
                                                    sessionFolder: folder.deletingLastPathComponent()) == nil)
        for name in ["../scene.pkg", "..\\scene2.pkg", "/absolute/scene3.pkg"] {
            let path = try #require(try artifacts.recordPassOutputBytes(name: name, bytes: bytes, sessionFolder: folder))
            #expect(path.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
            #expect(try Data(contentsOf: path) == bytes)
        }
    }

    @Test func unsupportedStorageDoesNotPublishAZeroFilledArtifact() throws {
        let source = try texture(format: .r8Unorm, bytes: Data([96, 48]))
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        let folder = try #require(artifacts.beginSession(workshopID: UUID().uuidString, descriptor: "unsupported raw storage"))
        defer { artifacts.endSession() }
        let recorder = WPECanonicalTraceRecorder(artifacts: artifacts)
        recorder.beginScene(workshopID: "unsupported-tests", projectJsonPath: nil, descriptor: "raw")
        record(source, recorder: recorder)
        recorder.recordPassOutputs([(label: "particle.0", texture: source)], frameOrdinal: 12)
        let output = try #require(try outputs(recorder, texture: source).first)
        #expect(output["raw"] == nil)
        #expect(output["sha256"] is NSNull)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.allSatisfy { !$0.lastPathComponent.hasPrefix("pass-output-") })
        artifacts.endSession()
        #expect(try artifacts.recordPassOutputBytes(name: "closed.rgba8", bytes: Data([0]), sessionFolder: folder) == nil)
    }

    @Test func sameWorkshopSessionsNeverReuseADirectory() throws {
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        let id = UUID().uuidString
        let first = try #require(artifacts.beginSession(workshopID: id, descriptor: "first"))
        let second = try #require(artifacts.beginSession(workshopID: id, descriptor: "second"))
        defer { artifacts.endSession() }
        #expect(first != second)
        #expect(try artifacts.recordPassOutputBytes(name: "stale.rgba8", bytes: Data([0]), sessionFolder: first) == nil)
        #expect(!FileManager.default.fileExists(atPath: first.appendingPathComponent("stale.rgba8").path))
    }

    @Test func privateStorageUsesExistingCPUStagingWithoutChangingBytes() throws {
        let bytes = Data([204, 51, 153, 96, 128, 129, 64, 96])
        let seed = try texture(bytes: bytes)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 1, mipmapped: false)
        descriptor.storageMode = .private
        let source = try #require(seed.device.makeTexture(descriptor: descriptor))
        let queue = try #require(seed.device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: seed, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 2, height: 1, depth: 1), to: source, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        _ = try #require(artifacts.beginSession(workshopID: UUID().uuidString, descriptor: "private raw storage"))
        defer { artifacts.endSession() }
        let recorder = WPECanonicalTraceRecorder(artifacts: artifacts)
        recorder.beginScene(workshopID: "private-tests", projectJsonPath: nil, descriptor: "raw")
        record(source, recorder: recorder)
        recorder.recordPassOutputs([(label: "particle.0", texture: source)], frameOrdinal: 12)
        let output = try #require(try outputs(recorder, texture: source).first)
        let receipt = try #require(output["raw"] as? [String: Any])
        let path = try #require(receipt["path"] as? String)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(receipt["rawStorageSHA256"] as? String == hash(bytes))
    }
}
#endif
