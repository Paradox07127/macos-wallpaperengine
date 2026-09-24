import Foundation
import LiveWallpaperCore

/// The wallpaper library's own import: what the user picks joins the library, and no display changes.
@MainActor
struct LibraryImporter {
    struct Outcome: Equatable {
        /// Files now in the library, including ones it already held.
        var added = 0
        var failed = 0
        /// Wallpaper Engine projects and libraries, left for the Workshop importer.
        var projectFolders: [URL] = []

        /// nil when only project folders were chosen: the Workshop importer reports those itself.
        var summary: String? {
            guard added + failed > 0 else { return nil }
            if failed == 0 {
                return String(
                    localized: "Added to the Wallpaper Library: \(added)", bundle: .appLanguage,
                    comment: "Toast after the Wallpaper Library's import. Placeholder is the number of files added."
                )
            }
            return String(
                localized: "Added to the Wallpaper Library: \(added). Couldn't add: \(failed).", bundle: .appLanguage,
                comment: "Toast after the Wallpaper Library's import. Placeholders are the numbers of files added and not added."
            )
        }
    }

    let bookmarks: BookmarkStore
    let sceneCapable: Bool

    func add(_ urls: [URL]) -> Outcome {
        var outcome = Outcome()
        for url in urls {
            // Without scene support a project folder would otherwise route as a web page folder.
            if !sceneCapable,
               WallpaperImportRouter.isWallpaperEngineProjectFolder(url)
               || WallpaperImportRouter.containsWallpaperEngineProjects(url) {
                outcome.failed += 1
                continue
            }
            switch WallpaperImportRouter.route(url, sceneCapable: sceneCapable) {
            case let .video(videoURL):
                addVideo(videoURL, to: &outcome)
            case let .html(source):
                // The router takes any other folder for a site; one without a page is a folder of videos.
                if case .folder = source {
                    // The videos' bookmarks are made under the folder's grant, so its scope has to outlast them.
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer {
                        if didStart {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    if let videos = Self.videosInFolderWithoutPage(url) {
                        if videos.isEmpty {
                            outcome.failed += 1
                        }
                        for video in videos {
                            addVideo(video, to: &outcome)
                        }
                        continue
                    }
                }
                ApplyRouter.saveIfNew(.html(source: source, config: .default), label: url.lastPathComponent, in: bookmarks)
                outcome.added += 1
            case .sceneProject, .sceneLibrary:
                outcome.projectFolders.append(url)
            case .unsupported:
                outcome.failed += 1
            }
        }
        return outcome
    }

    private func addVideo(_ url: URL, to outcome: inout Outcome) {
        guard let data = ResourceUtilities.createVideoBookmark(for: url) else {
            outcome.failed += 1
            return
        }
        ApplyRouter.saveIfNew(.video(bookmarkData: data), label: url.lastPathComponent, in: bookmarks)
        outcome.added += 1
    }

    /// nil when the folder holds a web page; otherwise the videos directly inside it. Runs inside the
    /// caller's scope on `folder`.
    private static func videosInFolderWithoutPage(_ folder: URL) -> [URL]? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        guard !entries.contains(where: { ["html", "htm"].contains($0.pathExtension.lowercased()) }) else { return nil }
        return entries.filter(ResourceUtilities.isSupportedVideoURL)
    }
}
