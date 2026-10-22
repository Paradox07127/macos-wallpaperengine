import Foundation
@testable import LiveWallpaperProWPE
import simd
import Testing

struct WPEWorkshopMdlTests {
    @Test("Workshop puppets with normals and tangents decode unit normals")
    func workshopNormals() throws {
        for (scene, path, format) in [("3647999330", "models/RW_puppet.mdl", UInt32(0x181000E)),
                                      ("2370640409", "models/10_puppet.mdl", UInt32(0x180000F))] {
            let url = try CorpusFixtures.workshopPackage(scene)
            let package = try Data(contentsOf: url)
            let data = try #require(PackageEntries.entries(package)[path])
            let mesh = try #require(WPEMdlParser.parse(data: data).meshes.first)
            #expect(mesh.vertexFormat == format)
            #expect(!mesh.vertices.isEmpty)
            #expect(mesh.vertices.allSatisfy { abs(simd_length($0.normal) - 1) < 1e-3 }, "\(scene) \(path)")
        }
    }
}
