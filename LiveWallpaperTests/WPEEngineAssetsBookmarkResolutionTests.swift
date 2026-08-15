#if !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import Testing

    /// Behavior guard for the manual-bookmark resolution path. The security-scope
    /// open/close around validation is not observable headless (plain file URLs
    /// no-op startAccessing); these only pin the validation semantics around it.
    @Suite("WPE engine-assets manual bookmark resolution") @MainActor
    struct WPEEngineAssetsBookmarkResolutionTests {
        private func withSavedBookmarkState(_ body: () -> Void) {
            let previousBookmark = SettingsManager.shared.loadWPEEngineAssetsBookmark()
            let previousBuildID = SettingsManager.shared.wpeEngineAssetsManagedBuildID
            defer {
                SettingsManager.shared.wpeEngineAssetsManagedBuildID = previousBuildID
                if let previousBookmark {
                    SettingsManager.shared.saveWPEEngineAssetsBookmark(previousBookmark)
                } else {
                    SettingsManager.shared.clearWPEEngineAssetsBookmark()
                }
            }
            SettingsManager.shared.wpeEngineAssetsManagedBuildID = nil
            SettingsManager.shared.saveWPEEngineAssetsBookmark(Data([0x01]))
            body()
        }

        @Test("A resolved root with an assets folder authorizes and returns the root")
        func resolvedRootWithAssetsAuthorizes() throws {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? fileManager.removeItem(at: root) }
            try fileManager.createDirectory(
                at: root.appendingPathComponent("assets", isDirectory: true),
                withIntermediateDirectories: true
            )

            withSavedBookmarkState {
                let library = WPEEngineAssetsLibrary()
                let resolved = library.resolveAuthorizedRoot(using: { _ in
                    WPEEngineAssetsLibrary.DirectoryBookmarkResolution(url: root, isStale: false)
                })

                #expect(resolved == root.standardizedFileURL.resolvingSymlinksInPath())
                #expect(library.isAuthorized)
            }
        }

        @Test("A resolved root without an assets folder stays unauthorized but keeps the bookmark")
        func resolvedRootWithoutAssetsStaysUnauthorized() throws {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? fileManager.removeItem(at: root) }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

            withSavedBookmarkState {
                let library = WPEEngineAssetsLibrary()
                let resolved = library.resolveAuthorizedRoot(using: { _ in
                    WPEEngineAssetsLibrary.DirectoryBookmarkResolution(url: root, isStale: false)
                })

                #expect(resolved == nil)
                #expect(!library.isAuthorized)
                #expect(SettingsManager.shared.loadWPEEngineAssetsBookmark() != nil)
            }
        }
    }
#endif
