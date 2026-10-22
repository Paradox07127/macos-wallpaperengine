import Foundation
@testable import LiveWallpaperProWPE

/// Explicit caller-owned inputs. No discovery in Steam, the user's home or another checkout.
enum CorpusFixtures {
    struct MissingInput: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }

    static func url(_ key: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty,
              !path.contains("\0") else {
            throw MissingInput("External corpus NOT EXECUTED: set \(key) to the required input root")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MissingInput("External corpus NOT EXECUTED: missing \(key) input at \(url.path)")
        }
        return url
    }

    /// WPE_WORKSHOP_ROOT contains <Workshop ID>/scene.pkg, independently of Steam's install location.
    static func workshopPackage(_ id: String) throws -> URL {
        let package = try url("WPE_WORKSHOP_ROOT").appendingPathComponent("\(id)/scene.pkg")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw MissingInput("External corpus NOT EXECUTED: missing Workshop \(id)/scene.pkg")
        }
        return package
    }
}

extension ParityCameraFixture {
    /// Scene 3660962877 from the HLSL capture: 3840×2160, V = I, object 935 rotated −90°.
    static func scene3660962877() throws -> WPESceneDocument {
        try captured("3660962877")
    }

    static func captured(_ sceneID: String) throws -> WPESceneDocument {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"] else {
            throw CorpusFixtures.MissingInput("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing scene-sources/")
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("scene-sources/\(sceneID)/scene.json")
        return try WPESceneDocumentParser.parse(data: Data(contentsOf: url), userValues: [:])
    }
}
