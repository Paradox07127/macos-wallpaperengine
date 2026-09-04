#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

/// Test-only evidence manifest for selecting a Windows oracle scene before any
/// per-object camera routing is implemented. It reads the authored JSON rather
/// than the app's parsed schema so an unsupported `perspective` field cannot
/// disappear before the capture gate observes it.
struct WPECameraEvidenceManifest: Codable, Equatable {
    struct Projection: Codable, Equatable {
        let isOrthographic: Bool
        let width: Double?
        let height: Double?
        let zoom: Double?
        let perspectiveOverrideFOV: Double?
        let nearZ: Double?
        let farZ: Double?
        let fov: Double?
    }

    struct PerspectiveObject: Codable, Equatable {
        let id: String
        let name: String
        let image: String?
        let material: String?
        let effectCount: Int
    }

    struct Scene: Codable, Equatable {
        let sceneID: String
        let entryFile: String
        let projection: Projection
        let perspectiveObjects: [PerspectiveObject]

        var isObjectPerspectiveCandidate: Bool {
            projection.isOrthographic && !perspectiveObjects.isEmpty
        }
    }

    let schemaVersion: Int
    let generatedAtUTC: String
    let scenes: [Scene]
    let requiredWindowsGates: [String]

    static let gates = [
        "Capture the exact scene package represented by this manifest; do not pair matrices with another scene's JSON.",
        "Correlate every perspective:true objectID with its Windows draw ordinals and record which image/effect/composite passes inherit perspective.",
        "Record g_ModelViewProjectionMatrix plus depth compare, depth clear, color target, and viewport for every correlated draw.",
        "Mutate perspectiveoverridefov and zoom independently while holding object transforms and output size fixed; one unmutated capture is not a formula oracle."
    ]

    static func scene(sceneID: String, entryFile: String, data: Data) throws -> Scene {
        let json = try JSONSerialization.jsonObject(with: data)
        let root = try #require(json as? [String: Any])
        let general = root["general"] as? [String: Any] ?? [:]
        let camera = root["camera"] as? [String: Any] ?? [:]
        let ortho = general["orthogonalprojection"] as? [String: Any]
        let projection = Projection(
            isOrthographic: ortho != nil,
            width: authoredDouble(ortho?["width"]),
            height: authoredDouble(ortho?["height"]),
            zoom: authoredDouble(general["zoom"]),
            perspectiveOverrideFOV: authoredDouble(general["perspectiveoverridefov"]),
            nearZ: authoredDouble(general["nearz"] ?? camera["nearz"]),
            farZ: authoredDouble(general["farz"] ?? camera["farz"]),
            fov: authoredDouble(general["fov"] ?? camera["fov"])
        )
        let objects = root["objects"] as? [[String: Any]] ?? []
        let perspectiveObjects = objects.compactMap { object -> PerspectiveObject? in
            guard authoredBool(object["perspective"]) == true else { return nil }
            let image = nonEmptyString(object["image"] ?? object["model"])
            guard image != nil || nonEmptyString(object["shape"]) == "quad" else { return nil }
            let id = scalarString(object["id"])
                ?? nonEmptyString(object["name"])
                ?? image
                ?? "<unknown>"
            return PerspectiveObject(
                id: id,
                name: nonEmptyString(object["name"]) ?? id,
                image: image,
                material: nonEmptyString(object["material"]),
                effectCount: (object["effects"] as? [Any])?.count ?? 0
            )
        }
        return Scene(
            sceneID: sceneID,
            entryFile: entryFile,
            projection: projection,
            perspectiveObjects: perspectiveObjects
        )
    }

    private static func authoredDouble(_ raw: Any?) -> Double? {
        if let envelope = raw as? [String: Any] {
            return authoredDouble(envelope["value"])
        }
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    private static func authoredBool(_ raw: Any?) -> Bool? {
        if let envelope = raw as? [String: Any] {
            return authoredBool(envelope["value"])
        }
        if let bool = raw as? Bool { return bool }
        if let number = raw as? NSNumber { return number.intValue != 0 }
        if let string = raw as? String {
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func scalarString(_ raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }
}

@Suite("WPE camera evidence capture")
struct WPECameraEvidenceCaptureTests {
    private struct Config: Decodable {
        let corpusRoot: String
        var label: String = "camera-evidence"
        var scenes: [String]?

        private enum CodingKeys: String, CodingKey { case corpusRoot, label, scenes }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            corpusRoot = try container.decode(String.self, forKey: .corpusRoot)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? "camera-evidence"
            scenes = try container.decodeIfPresent([String].self, forKey: .scenes)
        }
    }

    private static var configURL: URL? {
        if let path = ProcessInfo.processInfo.environment["WPE_ORACLE_CAPTURE_CONFIG"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let temporary = URL(fileURLWithPath: "/private/tmp/livewallpaper-oracle-evidence.json")
        return FileManager.default.fileExists(atPath: temporary.path) ? temporary : nil
    }

    @Test("Raw authored camera evidence keeps object perspective separate from scene projection")
    func rawAuthoredCameraEvidenceContract() throws {
        let payload: [String: Any] = [
            "camera": ["nearz": 0.01, "farz": 10_000, "fov": 50],
            "general": [
                "orthogonalprojection": ["width": 2560, "height": 1440],
                "zoom": ["value": 1.25, "user": "zoom"],
                "perspectiveoverridefov": ["value": 95, "user": "fov"]
            ],
            "objects": [
                [
                    "id": 42,
                    "name": "Perspective Water",
                    "image": "models/water.json",
                    "material": "materials/water.json",
                    "perspective": ["value": true],
                    "effects": [["name": "Ripple"], ["name": "Blur"]]
                ],
                ["id": 43, "name": "HUD", "image": "models/hud.json", "perspective": false]
            ]
        ]
        let scene = try WPECameraEvidenceManifest.scene(
            sceneID: "fixture",
            entryFile: "scene.json",
            data: JSONSerialization.data(withJSONObject: payload)
        )

        #expect(scene.projection.isOrthographic)
        #expect(scene.projection.width == 2560)
        #expect(scene.projection.height == 1440)
        #expect(scene.projection.zoom == 1.25)
        #expect(scene.projection.perspectiveOverrideFOV == 95)
        #expect(scene.projection.nearZ == 0.01)
        #expect(scene.projection.farZ == 10_000)
        #expect(scene.projection.fov == 50)
        #expect(scene.isObjectPerspectiveCandidate)
        #expect(scene.perspectiveObjects == [
            .init(
                id: "42",
                name: "Perspective Water",
                image: "models/water.json",
                material: "materials/water.json",
                effectCount: 2
            )
        ])
    }

    @Test(
        "Emit a paired camera-input manifest for Windows capture candidates",
        .enabled(if: configURL != nil)
    )
    func emitCameraEvidenceManifest() throws {
        let configURL = try #require(Self.configURL)
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
        let corpusRoot = URL(fileURLWithPath: config.corpusRoot, isDirectory: true)
        let filter = config.scenes.map(Set.init)
        let folders = try FileManager.default.contentsOfDirectory(
            at: corpusRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var scenes: [WPECameraEvidenceManifest.Scene] = []
        for folder in folders {
            let sceneID = folder.lastPathComponent
            if let filter, !filter.contains(sceneID) { continue }
            guard let project = try? WallpaperEngineProject.read(from: folder), project.type == .scene else {
                continue
            }
            let entryFile = project.entryFile.isEmpty ? "scene.json" : project.entryFile
            guard let data = try sceneData(folder: folder, entryFile: entryFile) else { continue }
            scenes.append(try WPECameraEvidenceManifest.scene(
                sceneID: sceneID,
                entryFile: entryFile,
                data: data
            ))
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let manifest = WPECameraEvidenceManifest(
            schemaVersion: 1,
            generatedAtUTC: formatter.string(from: Date()),
            scenes: scenes,
            requiredWindowsGates: WPECameraEvidenceManifest.gates
        )
        let outputRoot = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("LiveWallpaper/oracle-out/\(config.label)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let output = outputRoot.appendingPathComponent("camera-evidence-manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: output, options: .atomic)

        let candidates = scenes.filter(\.isObjectPerspectiveCandidate)
        print("[camera-evidence] scenes=\(scenes.count) objectPerspectiveCandidates=\(candidates.count) → \(output.path)")
        for candidate in candidates {
            let ids = candidate.perspectiveObjects.map(\.id).joined(separator: ",")
            let overrideFOV = candidate.projection.perspectiveOverrideFOV.map { String($0) } ?? "nil"
            print("[camera-evidence] candidate=\(candidate.sceneID) objects={\(ids)} overrideFOV=\(overrideFOV)")
        }
        #expect(!scenes.isEmpty, "camera manifest found no readable scene JSON")
    }

    private func sceneData(folder: URL, entryFile: String) throws -> Data? {
        let loose = folder.appendingPathComponent(entryFile)
        if FileManager.default.fileExists(atPath: loose.path) {
            return try Data(contentsOf: loose)
        }
        let packageURL = folder.appendingPathComponent("scene.pkg")
        guard FileManager.default.fileExists(atPath: packageURL.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: packageURL)
        defer { try? handle.close() }
        let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
        guard let entry = package.nameIndex[entryFile.lowercased()], entry.dataSize <= 64 * 1024 * 1024 else {
            return nil
        }
        try handle.seek(toOffset: package.dataStart + entry.dataOffset)
        guard let data = try handle.read(upToCount: Int(entry.dataSize)), data.count == Int(entry.dataSize) else {
            return nil
        }
        return data
    }
}
#endif
