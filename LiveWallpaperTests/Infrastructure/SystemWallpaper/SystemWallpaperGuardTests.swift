import Foundation
import Testing

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
                exceptions.first == "/Library/Containers/\(sku.hostBundleID)/Data/Library/Application Support/Loomscreen/SystemWallpaper/",
                "\(sku.name): exception must point at its own host's SystemWallpaper directory"
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

    @Test("Each appex target points at its own SKU's plist, entitlements and bundle id")
    func projectWiresEachAppexToItsOwnSKU() throws {
        let project = try XcodeProjectFile()
        #expect(project.configurations == ["Debug", "Release"])
        for sku in Self.skus {
            let other = Self.skus.first { $0.name != sku.name }!
            let ownSettings = try project.target(sku.targetName)["build-settings"] as? [String: Any] ?? [:]
            #expect(
                !ownSettings.values.contains { "\($0)".contains(other.infoPlistPath) || "\($0)".contains(other.entitlementsPath) },
                "\(sku.name): references the other SKU's configuration"
            )
            for configuration in project.configurations {
                let where_ = "\(sku.name)/\(configuration)"
                func setting(_ key: String) throws -> String? {
                    try project.setting(key, target: sku.targetName, configuration: configuration)
                }
                #expect(
                    try setting("PRODUCT_BUNDLE_IDENTIFIER") == sku.appexBundleID,
                    "\(where_): bundle id must be \(sku.appexBundleID) — Xcode also rejects an embedded binary whose id is not prefixed by the host's"
                )
                #expect(try setting("INFOPLIST_FILE") == sku.infoPlistPath, "\(where_): INFOPLIST_FILE must be \(sku.infoPlistPath)")
                #expect(
                    try setting("CODE_SIGN_ENTITLEMENTS") == sku.entitlementsPath,
                    "\(where_): CODE_SIGN_ENTITLEMENTS must be \(sku.entitlementsPath) — without it the appex is unsandboxed and pkd silently drops it"
                )
                #expect(
                    try setting("GENERATE_INFOPLIST_FILE") == "NO",
                    "\(where_): a generated plist would drop EXExtensionPointIdentifier and the appex would never register"
                )
                #expect(try setting("ENABLE_APP_SANDBOX") == "YES", "\(where_): sandbox is the registration gate")
                #expect(
                    try setting("MACOSX_DEPLOYMENT_TARGET") == "26.0",
                    "\(where_): must match LSMinimumSystemVersion 26.0, or the appex is advertised to systems it cannot load on"
                )
                #expect(try setting("SWIFT_VERSION") == "6.0", "\(where_): stay on the app's language mode")
            }
        }
    }

    @Test("Appexes are embedded into Contents/Extensions, not Contents/PlugIns")
    func appexesEmbedIntoExtensionsFolder() throws {
        let project = try XcodeProjectFile()
        for sku in Self.skus {
            let product = try #require(
                Self.fileEntry(path: "<PRODUCTS>/\(sku.targetName).appex", in: project.root["files"]),
                "\(sku.name): no product entry for the appex"
            )
            // Each membership names its phase as "<host target>/copy/<phase name>".
            let phases = (product["target-membership"] as? [[String: Any]] ?? []).compactMap { $0["build-phase"] as? String }
            #expect(!phases.isEmpty, "\(sku.name): appex is not in an embed phase — it would never ship inside the app")
            for phase in phases {
                let parts = phase.split(separator: "/", maxSplits: 2).map(String.init)
                let host = try project.target(parts[0])
                let copy = (host["build-phases"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
                    .first { $0["kind"] as? String == "copy" && $0["name"] as? String == parts.last }
                // pkd only scans Contents/Extensions; the generic-extension template
                // defaults to PlugIns, where the appex is silently invisible.
                #expect(
                    copy?["relative-path"] as? String == "$(EXTENSIONS_FOLDER_PATH)",
                    "\(sku.name): embed phase \(phase) does not target EXTENSIONS_FOLDER_PATH"
                )
            }
        }
    }

    /// Products sit in a nested group of the `files` tree, so the search recurses.
    private static func fileEntry(path: String, in node: Any?) -> [String: Any]? {
        if let entry = node as? [String: Any] {
            if entry["path"] as? String == path {
                return entry
            }
            return fileEntry(path: path, in: entry["children"])
        }
        for child in node as? [Any] ?? [] {
            if let found = fileEntry(path: path, in: child) {
                return found
            }
        }
        return nil
    }

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

}
