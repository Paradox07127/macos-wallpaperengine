import Foundation
import LiveWallpaperProWPE
import XCTest

/// Workshop 3660962877 binds 252 property scripts, 27 of them importing WEMath, WEColor or WEVector.
final class ParityScriptWorkshopTests: XCTestCase {
    private struct Loaded {
        let document: WPESceneDocument
        let assets: WPEParityProgramAssets
        let canvas: SIMD2<Float>
    }

    private static func loadScene() throws -> Loaded {
        let package = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/workshop/content/431960/3660962877/scene.pkg"
        )
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: ParityScriptEngineTests.install.path) else {
            throw XCTSkip("No workshop 3660962877 scene.pkg or Wallpaper Engine assets")
        }
        let bytes = try Data(contentsOf: package, options: .alwaysMapped)
        let entries = Self.entries(bytes)
        let read: @Sendable (String) -> Data? = { path in entries[path].map { bytes.subdata(in: $0) } }
        let scene = try XCTUnwrap(read("scene.json"))
        let document = try WPESceneDocumentParser.parse(data: scene, userValues: [:])
        let projection = document.resolvedGeneralJSON["orthogonalprojection"]
        let canvas = SIMD2(Float(Self.number(projection?["width"]) ?? 1920),
                           Float(Self.number(projection?["height"]) ?? 1080))
        let assets = WPEParityProgramAssets(sources: [
            .lookup(package.deletingLastPathComponent(), read), .directory(ParityScriptEngineTests.install),
        ])
        return Loaded(document: document, assets: assets, canvas: canvas)
    }

    private static func number(_ value: WPESceneJSONValue?) -> Double? {
        if case let .number(number)? = value {
            return number
        }
        return nil
    }

    private static func entries(_ bytes: Data) -> [String: Range<Int>] {
        var offset = bytes.startIndex
        func uint32() -> Int {
            defer { offset += 4 }
            return (0 ..< 4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        func string() -> String {
            let count = uint32()
            defer { offset += count }
            return String(bytes: bytes[offset ..< offset + count], encoding: .utf8) ?? ""
        }
        _ = string()
        let list = (0 ..< uint32()).map { _ in (string(), uint32(), uint32()) }
        var result: [String: Range<Int>] = [:]
        for (name, start, size) in list {
            result[name] = offset + start ..< offset + start + size
        }
        return result
    }

    private static func engine(_ loaded: Loaded, state: WPEParitySceneState) throws -> WPEParityScriptEngine {
        try WPEParityScriptEngine(document: loaded.document, state: state, configuration: .init(
            assets: loaded.assets, canvasSize: loaded.canvas, screenResolution: loaded.canvas
        ))
    }

    /// Every script compiles, init runs once, 60 ticks raise no JS exception.
    func testWorkshopScriptsCompileInitOnceAndTickCleanly() throws {
        let loaded = try Self.loadScene()
        var state = WPEParitySceneState(document: loaded.document, hdr: false)
        let engine = try Self.engine(loaded, state: state)
        XCTAssertGreaterThan(engine.bindings.count, 200)
        XCTAssertEqual(engine.bindings.filter { !$0.compiled }.map(\.name), [])
        try engine.start(state: &state)
        try engine.start(state: &state)
        XCTAssertEqual(engine.dispatchCount(.initialize), 1)
        for _ in 0 ..< 60 {
            engine.tick(dt: 1 / 60, state: &state)
        }
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    /// Mean CPU time of one tick over 60 ticks, printed for the report.
    func testWorkshopTickCPUTime() throws {
        let loaded = try Self.loadScene()
        var state = WPEParitySceneState(document: loaded.document, hdr: false)
        let engine = try Self.engine(loaded, state: state)
        try engine.start(state: &state)
        var total: UInt64 = 0
        for _ in 0 ..< 60 {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            engine.tick(dt: 1 / 60, state: &state)
            total += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
        }
        print("parity script tick CPU mean: \(Double(total) / 60 / 1000) us over \(engine.bindings.count) bindings")
        XCTAssertEqual(engine.exceptionCount, 0)
    }
}
