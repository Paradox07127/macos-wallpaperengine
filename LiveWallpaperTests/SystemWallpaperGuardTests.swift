import Foundation
import Testing

/// Guards the appex configuration the system-wallpaper feature silently dies
/// without (plan §4.7): pkd refuses unsandboxed plugins with only a log line,
/// and the cross-container exception is the app↔appex data path. Read from
/// disk so a bad edit fails here instead of in manual system testing.
@Suite("System wallpaper extension guard")
struct SystemWallpaperGuardTests {
    private struct SKU {
        let name: String
        let hostBundleID: String
        let appexBundleID: String
        let entitlementsPath: String
        let infoPlistPath: String
        let targetName: String
    }

    private static let skus = [
        SKU(
            name: "Pro",
            hostBundleID: "com.loomscreen.pro",
            appexBundleID: "com.loomscreen.pro.wallpaper",
            entitlementsPath: "SystemWallpaperProviderConfig/SystemWallpaperProvider-Pro.entitlements",
            infoPlistPath: "SystemWallpaperProviderConfig/Info-Pro.plist",
            targetName: "SystemWallpaperProvider"
        ),
        SKU(
            name: "Lite",
            hostBundleID: "com.loomscreen",
            appexBundleID: "com.loomscreen.wallpaper",
            entitlementsPath: "SystemWallpaperProviderConfig/SystemWallpaperProvider-Lite.entitlements",
            infoPlistPath: "SystemWallpaperProviderConfig/Info-Lite.plist",
            targetName: "SystemWallpaperProviderLite"
        )
    ]

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try RepositoryRoot.data(relativePath)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(parsed as? [String: Any], "\(relativePath) is not a dictionary plist")
    }

    @Test("Appex entitlements keep the sandbox and exactly the one container exception")
    func entitlementsKeepSandboxAndException() throws {
        for sku in Self.skus {
            let entitlements = try plist(sku.entitlementsPath)
            #expect(
                entitlements["com.apple.security.app-sandbox"] as? Bool == true,
                "\(sku.name): app-sandbox is the registration gate — without it pkd drops the plugin with only a log line"
            )
            let exceptions = try #require(
                entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-write"] as? [String],
                "\(sku.name): missing the cross-container exception — the appex cannot read the app's shared directory"
            )
            #expect(exceptions.count == 1, "\(sku.name): exactly one exception path is allowed")
            #expect(
                exceptions.first == "/Library/Containers/\(sku.hostBundleID)/Data/Library/Application Support/Loomscreen/",
                "\(sku.name): exception must point at its own host's container"
            )
            #expect(entitlements.count == 2, "\(sku.name): no other entitlements belong on the appex")
        }
    }

    @Test("Appex Info.plist declares the wallpaper extension point and the right bundle id")
    func infoPlistDeclaresExtensionPoint() throws {
        for sku in Self.skus {
            let info = try plist(sku.infoPlistPath)
            let attributes = try #require(
                info["EXAppExtensionAttributes"] as? [String: Any],
                "\(sku.name): missing EXAppExtensionAttributes"
            )
            #expect(
                attributes["EXExtensionPointIdentifier"] as? String == "com.apple.wallpaper",
                "\(sku.name): wrong extension point — the system will never discover the appex"
            )
            #expect(info["CFBundleIdentifier"] as? String == sku.appexBundleID)
        }
    }

    // MARK: - Project wiring

    /// Build settings of one target's Debug+Release configurations, keyed by
    /// configuration name. Parsed from the pbxproj because these four settings
    /// are hand-edited in Xcode and pasting the wrong SKU's value produces a
    /// plausible-looking build that registers under the wrong identity.
    private static func buildConfigurations(
        ofTarget target: String,
        in project: String
    ) throws -> [String: String] {
        let listAnchor = "/* Build configuration list for PBXNativeTarget \"\(target)\" */ = {"
        let listStart = try #require(project.range(of: listAnchor), "no configuration list for target \(target)")
        let listEnd = try #require(project.range(of: "};", range: listStart.upperBound ..< project.endIndex))
        let list = String(project[listStart.upperBound ..< listEnd.lowerBound])

        var result: [String: String] = [:]
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: "/*")
            guard parts.count == 2 else { continue }
            let objectID = parts[0].trimmingCharacters(in: .whitespaces)
            let configName = parts[1]
                .replacingOccurrences(of: "*/", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,\t"))
            guard objectID.count == 24 else { continue }

            let blockAnchor = "\(objectID) /* \(configName) */ = {"
            guard let blockStart = project.range(of: blockAnchor),
                  let blockEnd = project.range(of: "\n\t\t};", range: blockStart.upperBound ..< project.endIndex)
            else { continue }
            result[configName] = String(project[blockStart.upperBound ..< blockEnd.lowerBound])
        }
        #expect(result.count == 2, "\(target): expected Debug and Release configurations, got \(result.keys.sorted())")
        return result
    }

    @Test("Each appex target points at its own SKU's plist, entitlements and bundle id")
    func projectWiresEachAppexToItsOwnSKU() throws {
        let project = try RepositoryRoot.source("LiveWallpaper.xcodeproj/project.pbxproj")
        for sku in Self.skus {
            let configurations = try Self.buildConfigurations(ofTarget: sku.targetName, in: project)
            let other = Self.skus.first { $0.name != sku.name }!
            for (configName, settings) in configurations.sorted(by: { $0.key < $1.key }) {
                let where_ = "\(sku.name)/\(configName)"
                #expect(
                    settings.contains("PRODUCT_BUNDLE_IDENTIFIER = \(sku.appexBundleID);"),
                    "\(where_): bundle id must be \(sku.appexBundleID) — Xcode also rejects an embedded binary whose id is not prefixed by the host's"
                )
                #expect(
                    settings.contains(sku.infoPlistPath),
                    "\(where_): INFOPLIST_FILE must be \(sku.infoPlistPath)"
                )
                #expect(
                    settings.contains(sku.entitlementsPath),
                    "\(where_): CODE_SIGN_ENTITLEMENTS must be \(sku.entitlementsPath) — without it the appex is unsandboxed and pkd silently drops it"
                )
                #expect(
                    !settings.contains(other.infoPlistPath) && !settings.contains(other.entitlementsPath),
                    "\(where_): references the other SKU's configuration"
                )
                #expect(
                    settings.contains("GENERATE_INFOPLIST_FILE = NO;"),
                    "\(where_): a generated plist would drop EXExtensionPointIdentifier and the appex would never register"
                )
                #expect(settings.contains("ENABLE_APP_SANDBOX = YES;"), "\(where_): sandbox is the registration gate")
                #expect(
                    settings.contains("MACOSX_DEPLOYMENT_TARGET = 26.0;"),
                    "\(where_): must match LSMinimumSystemVersion 26.0, or the appex is advertised to systems it cannot load on"
                )
                #expect(settings.contains("SWIFT_VERSION = 6.0;"), "\(where_): stay on the app's language mode")
            }
        }
    }

    /// `connection.remoteObjectProxy` hands back an autoreleased proxy that
    /// nothing else owns, so storing it in a `weak` property observes nil the
    /// moment the pool drains — measured 2026-08-20, which made
    /// `invalidateAgentSnapshots()` a permanent no-op and left removed tiles
    /// on the wallpaper panel. Making the property strong is not the fix
    /// either: the connection already owns the handler via `exportedObject`,
    /// so a strong proxy closes a retain cycle. The proxy has to be derived
    /// per call from a weakly captured connection.
    @Test("The agent proxy is derived per call, never stored")
    func agentProxyIsNotStored() throws {
        let handler = try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCHandler.swift")
        let bridge = try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCBridge.swift")

        #expect(
            !handler.contains("weak var agentProxy"),
            "A weakly stored proxy is nil by the time anything reads it."
        )
        #expect(
            !bridge.contains("handler.agentProxy = connection.remoteObjectProxy"),
            "Assigning the autoreleased proxy into a stored property is the bug."
        )
        #expect(
            handler.contains("agentProxyProvider"),
            "The handler must reach the agent through a provider it calls per use."
        )
        #expect(
            bridge.contains("[weak connection]"),
            "The provider must capture the connection weakly or it retains a cycle."
        )
    }

    @Test("Appexes are embedded into Contents/Extensions, not Contents/PlugIns")
    func appexesEmbedIntoExtensionsFolder() throws {
        let project = try RepositoryRoot.source("LiveWallpaper.xcodeproj/project.pbxproj")
        for sku in Self.skus {
            let reference = "\(sku.targetName).appex in Embed"
            #expect(
                project.contains(reference),
                "\(sku.name): appex is not in an embed phase — it would never ship inside the app"
            )
        }
        // pkd only scans Contents/Extensions; the generic-extension template
        // defaults to PlugIns, where the appex is silently invisible.
        let embedPhases = project.components(separatedBy: "isa = PBXCopyFilesBuildPhase;").dropFirst()
        for phase in embedPhases where phase.contains(".appex in Embed") {
            #expect(
                phase.contains("dstPath = \"$(EXTENSIONS_FOLDER_PATH)\";"),
                "an appex embed phase does not target EXTENSIONS_FOLDER_PATH"
            )
        }
    }
}
