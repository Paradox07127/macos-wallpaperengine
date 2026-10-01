import Foundation
#if !LITE_BUILD
import Darwin
import LiveWallpaperProWPE
#endif
@testable import LiveWallpaper
import Testing

@Suite("WPE project property untrusted inputs")
struct WPEProjectPropertyInputSafetyTests {
    @Test("Locale collisions prefer canonical spelling with stable fallback")
    func deterministicLocaleCollision() throws {
        let manifest = #"{"general":{"localization":{"EN-US":{"title":"Upper"},"en-us":{"title":"Canonical"},"FR":{"title":"French"}},"properties":{"caption":{"type":"text","text":"title"}}}}"#
        for _ in 0 ..< 20 {
            let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data(manifest.utf8), preferredLanguages: ["en-US"])
            #expect(schema.properties.first?.displayText == "Canonical")
            let fallback = try WallpaperEngineProjectPropertySchema.parse(data: Data(manifest.utf8), preferredLanguages: ["ja"])
            #expect(fallback.properties.first?.displayText == "Canonical")
            let french = try WallpaperEngineProjectPropertySchema.parse(data: Data(manifest.utf8), preferredLanguages: ["fr"])
            #expect(french.properties.first?.displayText == "French")
        }
        let uppercaseOnly = manifest.replacingOccurrences(of: #","en-us":{"title":"Canonical"}"#, with: "")
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data(uppercaseOnly.utf8), preferredLanguages: ["ja"])
        #expect(schema.properties.first?.displayText == "Upper")
    }

    @Test("Author labels decode entities once without loading HTML")
    func plainTextEntities() throws {
        let manifest: [String: Any] = ["general": ["properties": [
            "caption": ["type": "text", "text": "<b>&quot;猫&quot; &#39; &#x1F431; &amp;lt; &apos; &unknown;</b>"],
        ]]]
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: JSONSerialization.data(withJSONObject: manifest))
        #expect(schema.properties.first?.displayText == "\"猫\" ' 🐱 &lt; ' &unknown;")
        #expect(WPEPropertyLabelText.clean("&#0; &#xD800; &#1114112; &#999999999999999999999; &#xZZ;") == "&#0; &#xD800; &#1114112; &#999999999999999999999; &#xZZ;")
        #expect(WPEPropertyLabelText.clean("＜猫＞") == "＜猫＞")
        #expect(WPEPropertyLabelText.clean("A<img src='https://example.com/a.png'>B<br/>C") == "A B C")
    }

    @Test("Chinese author translations respect script and region aliases")
    func chineseLocaleAliases() throws {
        let manifest = #"{"general":{"localization":{"zh-cht":{"title":"繁體"},"zh-chs":{"title":"简体"},"zh":{"title":"Generic"},"en-us":{"title":"English"}},"properties":{"caption":{"type":"text","text":"title"}}}}"#
        for language in ["zh-Hant", "zh-TW", "zh-HK", "zh-MO", "zh-Hant-CN"] {
            let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data(manifest.utf8), preferredLanguages: [language])
            #expect(schema.properties.first?.displayText == "繁體")
        }
        for language in ["zh-Hans", "zh-CN", "zh-SG", "zh-Hans-TW"] {
            let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data(manifest.utf8), preferredLanguages: [language])
            #expect(schema.properties.first?.displayText == "简体")
        }
        let exact = manifest.replacingOccurrences(of: #""zh-cht":{"title":"繁體"}"#, with: #""zh-hant":{"title":"Exact"},"zh-cht":{"title":"繁體"}"#)
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data(exact.utf8), preferredLanguages: ["zh-Hant"])
        #expect(schema.properties.first?.displayText == "Exact")
        let generic = try WallpaperEngineProjectPropertySchema.parse(data: Data(manifest.utf8), preferredLanguages: ["zh"])
        #expect(generic.properties.first?.displayText == "Generic")
        let fallback = try WallpaperEngineProjectPropertySchema.parse(data: Data(manifest.utf8), preferredLanguages: ["ko"])
        #expect(fallback.properties.first?.displayText == "English")
    }

    #if !LITE_BUILD
    @Test("Nonfinite author colors never reach the native color picker")
    func nonfiniteColorComponents() {
        for raw in ["nan 0 0", "0 inf 0", "0 0 -inf", "0 0 0 nan", "1e999 0 0"] {
            #expect(PropertyValueLogic.colorComponents(from: raw).isEmpty)
            let components = PropertyValueLogic.cgColor(from: raw).components ?? []
            #expect(components == [1, 1, 1, 1])
        }
        #expect(PropertyValueLogic.colorComponents(from: "0.25 0.5 1") == [0.25, 0.5, 1])
        #expect(PropertyValueLogic.colorComponents(from: "#ff0000") == [1, 0, 0])
        #expect(PropertyValueLogic.colorComponents(from: "-1 2 0.5") == [0, 1, 0.5])
    }

    @Test("Nonfinite slider metadata cannot construct an invalid range", arguments: ["NaN", "nan", "Infinity", "-Infinity", "1e999"])
    func nonfiniteSliderMetadata(raw: String) throws {
        let property = try slider(["min": raw, "max": raw, "step": raw, "order": raw])
        #expect(property.minimum == nil)
        #expect(property.maximum == nil)
        #expect(property.step == nil)
        #expect(property.order.isFinite)
        #expect(PropertyValueLogic.sliderRange(for: property) == 0 ... 100)
        #expect(PropertyValueLogic.sliderStep(for: property) == 1)
        #expect(PropertyValueLogic.normalizedSliderValue(.nan, for: property) == 0)
    }

    @Test("Slider fallback keeps finite width and valid authored grids")
    func sliderBoundaryFallbacks() throws {
        for metadata: [String: Any] in [
            ["min": 10, "max": 1], ["min": "1e308", "max": "1e308"],
            ["min": "-1e308", "max": "1e308"], ["min": "1e308"],
        ] {
            let range = try PropertyValueLogic.sliderRange(for: slider(metadata))
            #expect(range.lowerBound.isFinite && range.upperBound.isFinite)
            #expect(range.upperBound > range.lowerBound)
            #expect((range.upperBound - range.lowerBound).isFinite)
        }
        let property = try slider(["min": -2, "max": 3, "step": 0.25, "fraction": true])
        #expect(PropertyValueLogic.sliderRange(for: property) == -2 ... 3)
        #expect(PropertyValueLogic.sliderStep(for: property) == 0.25)
        #expect(PropertyValueLogic.normalizedSliderValue(0.37, for: property) == 0.25)
        #expect(try PropertyValueLogic.sliderStep(for: slider(["step": -1])) == 1)
    }

    @Test("Directory assets reject FIFOs before attempting to read")
    func rejectsNonRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WPE-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("blocked.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let provider = WPEDirectorySceneAssetProvider(rootURL: root)
        try #require(!provider.exists(atRelativePath: "blocked.json"))
        #expect(throws: WPESceneAssetProviderError.self) { try provider.data(atRelativePath: "blocked.json") }
        #expect(throws: WPESceneAssetProviderError.self) { try provider.stagedURL(atRelativePath: "blocked.json") }
        try Data("regular".utf8).write(to: root.appendingPathComponent("regular.json"))
        #expect(provider.exists(atRelativePath: "regular.json"))
        #expect(try provider.data(atRelativePath: "regular.json") == Data("regular".utf8))
    }

    @Test("NUL input never aliases a root or a truncated filesystem path")
    func rejectsNULPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WPE-NUL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ordinary".utf8).write(to: root.appendingPathComponent("regular.json"))
        let provider = WPEDirectorySceneAssetProvider(rootURL: root)
        for path in ["\0", "regular.json\0suffix", "sub/\0file"] {
            #expect(!WPEPathSafety.isSafePathComponent(path))
            #expect(!WPEPathSafety.isSafeProjectID(path))
            #expect(!WPEPathSafety.isSafeRelativePath(path))
            #expect(!WPEPathSafety.isStrictSafeRelativePath(path))
            #expect(!WPEPathSafety.isSafeCacheRelativePath("wpe-cache/" + path))
            #expect(WPEPathSafety.resourceURL(root: root, relativePath: path) == nil)
            #expect(WPEPathSafety.strictResourceURL(root: root, relativePath: path) == nil)
            #expect(!provider.exists(atRelativePath: path))
            #expect(throws: WPESceneAssetProviderError.invalidRelativePath(path)) { try provider.data(atRelativePath: path) }
            #expect(throws: WPESceneAssetProviderError.invalidRelativePath(path)) { try provider.stagedURL(atRelativePath: path) }
        }
        #expect(try provider.data(atRelativePath: "regular.json") == Data("ordinary".utf8))
        try Data("literal percent".utf8).write(to: root.appendingPathComponent("literal%00.json"))
        #expect(try provider.data(atRelativePath: "literal%00.json") == Data("literal percent".utf8))
    }

    @Test("A missing leaf does not hide an escaping parent symlink")
    func rejectsEscapingMissingLeaf() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("WPE-missing-leaf-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("root-sibling", isDirectory: true)
        let inside = root.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("exists.json"))
        try Data("inside".utf8).write(to: inside.appendingPathComponent("exists.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("internal"), withDestinationURL: inside)
        let provider = WPEDirectorySceneAssetProvider(rootURL: root)
        for path in ["escape/exists.json", "escape/missing.json", "escape/missing/sub/file.json"] {
            #expect(WPEPathSafety.resourceURL(root: root, relativePath: path) == nil)
            #expect(WPEPathSafety.strictResourceURL(root: root, relativePath: path) == nil)
            #expect(!provider.exists(atRelativePath: path))
            #expect(throws: WPESceneAssetProviderError.invalidRelativePath(path)) { try provider.data(atRelativePath: path) }
        }
        #expect(try provider.data(atRelativePath: "internal/exists.json") == Data("inside".utf8))
        let expected = inside.resolvingSymlinksInPath().appendingPathComponent("missing/sub/file.json")
        #expect(WPEPathSafety.strictResourceURL(root: root, relativePath: "internal/missing/sub/file.json") == expected)
    }

    private func slider(_ metadata: [String: Any]) throws -> WallpaperEngineProjectPropertySchema.Property {
        let row = metadata.merging(["type": "slider", "text": "Amount"]) { value, _ in value }
        let manifest: [String: Any] = ["general": ["properties": ["amount": row]]]
        return try #require(WallpaperEngineProjectPropertySchema.parse(data: JSONSerialization.data(withJSONObject: manifest)).properties.first)
    }
    #endif
}
