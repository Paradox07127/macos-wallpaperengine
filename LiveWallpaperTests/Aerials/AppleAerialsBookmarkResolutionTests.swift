import Foundation
@testable import LiveWallpaper
import Testing

/// Behavior guard for the granted-bookmark resolution path. The security-scope
/// open/close around the stale refresh is not observable headless; these pin
/// the resolution and refresh semantics around it.
@Suite("Apple Aerials bookmark resolution") @MainActor
struct AppleAerialsBookmarkResolutionTests {
    private func withSavedBookmarkState(_ body: () -> Void) {
        let previous = SettingsManager.shared.loadAerialsDirectoryBookmark()
        defer {
            if let previous {
                SettingsManager.shared.saveAerialsDirectoryBookmark(previous)
            } else {
                SettingsManager.shared.clearAerialsDirectoryBookmark()
            }
        }
        SettingsManager.shared.saveAerialsDirectoryBookmark(Data([0x01]))
        body()
    }

    @Test("A resolved directory bookmark authorizes and returns the URL")
    func resolvedBookmarkAuthorizes() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        withSavedBookmarkState {
            let library = AppleAerialsLibrary()
            let resolved = library.resolveAuthorizedDirectory(using: { _ in
                DirectoryBookmarkResolution(url: directory, isStale: false)
            })

            #expect(resolved == directory)
            #expect(library.isAuthorized)
            // Non-stale resolution must not rewrite the stored bookmark.
            #expect(SettingsManager.shared.loadAerialsDirectoryBookmark() == Data([0x01]))
        }
    }

    @Test("A stale bookmark refreshes the stored bookmark in place")
    func staleBookmarkRefreshesStoredBookmark() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // This host may be unable to mint a security-scoped bookmark for a plain
        // temp directory; skip rather than assert a false failure.
        guard (try? DirectoryBookmarks.createReadOnlyBookmark(for: directory)) != nil else { return }

        withSavedBookmarkState {
            let library = AppleAerialsLibrary()
            let resolved = library.resolveAuthorizedDirectory(using: { _ in
                DirectoryBookmarkResolution(url: directory, isStale: true)
            })

            #expect(resolved == directory)
            #expect(library.isAuthorized)
            let stored = SettingsManager.shared.loadAerialsDirectoryBookmark()
            #expect(stored != nil)
            #expect(stored != Data([0x01]))
        }
    }
}
