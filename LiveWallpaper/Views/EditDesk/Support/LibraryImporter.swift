import Foundation
import LiveWallpaperCore

/// The wallpaper library's own import: what the user picks joins the library, and no display changes.
@MainActor
struct LibraryImporter {
    struct Failure: Equatable {
        enum Reason: Equatable {
            case unsupportedFormat
            case scenesUnavailable
            case noWallpaperInFolder
            case folderUnreadable
            case noAccess
        }

        let url: URL
        let reason: Reason

        var name: String {
            url.lastPathComponent
        }

        var reasonText: String {
            switch reason {
            case .unsupportedFormat:
                String(
                    localized: "The Wallpaper Library can't add this kind of file.", bundle: .appLanguage,
                    comment: "Why one item of the Wallpaper Library's import wasn't added: not a video, web page or wallpaper folder."
                )
            case .scenesUnavailable:
                String(
                    localized: "Wallpaper Engine projects aren't available in this edition.", bundle: .appLanguage,
                    comment: "Why one item of the Wallpaper Library's import wasn't added: the app edition can't play Wallpaper Engine scenes."
                )
            case .noWallpaperInFolder:
                String(
                    localized: "The folder has no videos or web page.", bundle: .appLanguage,
                    comment: "Why one folder of the Wallpaper Library's import wasn't added: nothing inside it can be a wallpaper."
                )
            case .folderUnreadable:
                String(
                    localized: "Couldn't open the folder to look inside.", bundle: .appLanguage,
                    comment: "Why one folder of the Wallpaper Library's import wasn't added: reading its contents failed, for example without permission."
                )
            case .noAccess:
                String(
                    localized: "Couldn't keep access to the file.", bundle: .appLanguage,
                    comment: "Why one video of the Wallpaper Library's import wasn't added: the app couldn't save permission to reopen it."
                )
            }
        }
    }

    struct Outcome: Equatable {
        /// Files now in the library, including ones it already held.
        var added = 0
        /// Equals `failures.count` for an import; settable alone so a summary can be built from counts.
        var failed = 0
        var failures: [Failure] = []
        /// Wallpaper Engine projects and libraries, left for the Workshop importer.
        var projectFolders: [URL] = []

        mutating func fail(_ url: URL, _ reason: Failure.Reason) {
            failures.append(Failure(url: url, reason: reason))
            failed += 1
        }

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

        /// One line per failed item, at most two lines; nil when nothing failed.
        var failureSummary: String? {
            guard let first = failures.first else { return nil }
            var lines = [Self.line(first)]
            if failures.count == 2 {
                lines.append(Self.line(failures[1]))
            } else if failures.count > 2 {
                let more = failures.count - 1
                lines.append(String(
                    localized: "+\(more) more", bundle: .appLanguage,
                    comment: "Wallpaper Library import failure summary. The placeholder is the number of failed items not listed."
                ))
            }
            return lines.joined(separator: "\n")
        }

        private static func line(_ failure: Failure) -> String {
            let name = failure.name
            let reason = failure.reasonText
            return String(
                localized: "\(name): \(reason)", bundle: .appLanguage,
                comment: "Line of the Wallpaper Library's import failures. The first placeholder is the item's name, the second why it wasn't added."
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
                outcome.fail(url, .scenesUnavailable)
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
                    guard let entries = try? FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                    ) else {
                        outcome.fail(url, .folderUnreadable)
                        continue
                    }
                    if let videos = Self.videosWithoutPage(in: entries) {
                        if videos.isEmpty {
                            outcome.fail(url, .noWallpaperInFolder)
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
                outcome.fail(url, .unsupportedFormat)
            }
        }
        return outcome
    }

    private func addVideo(_ url: URL, to outcome: inout Outcome) {
        guard let data = ResourceUtilities.createVideoBookmark(for: url) else {
            outcome.fail(url, .noAccess)
            return
        }
        ApplyRouter.saveIfNew(.video(bookmarkData: data), label: url.lastPathComponent, in: bookmarks)
        outcome.added += 1
    }

    /// nil when the entries include a web page; otherwise the videos among them.
    private static func videosWithoutPage(in entries: [URL]) -> [URL]? {
        guard !entries.contains(where: { ["html", "htm"].contains($0.pathExtension.lowercased()) }) else { return nil }
        return entries.filter(ResourceUtilities.isSupportedVideoURL)
    }
}
