import Foundation
import CoreGraphics
import LiveWallpaperCore

// Kept as an extension rather than its own type because it calls back into
// loadConfigurations()/saveConfiguration() — injecting those as closures would be decoupling in name only.

extension SettingsManager {
    func validateConfiguration(for screenID: CGDirectDisplayID) -> Bool {
        guard let configuration = loadConfigurations().first(where: { $0.screenID == screenID }) else { return false }

        guard let definition = WallpaperSessionDefinition(configuration: configuration) else {
            Logger.error("Malformed wallpaper configuration for screen \(screenID)", category: .settings)
            return false
        }

        switch definition {
        case .video(let bookmarkData, _):
            return validateVideoBookmark(bookmarkData, for: screenID, configuration: configuration)
        case .html(let source, _):
            return validateHTMLSource(source, for: screenID)
        case .scene(let descriptor):
            return !descriptor.workshopID.isEmpty
                && !descriptor.cacheRelativePath.isEmpty
                && !descriptor.entryFile.isEmpty
        }
    }

    private func validateVideoBookmark(
        _ bookmarkData: Data,
        for screenID: CGDirectDisplayID,
        configuration: ScreenConfiguration
    ) -> Bool {
        switch bookmarkResolver.resolve(bookmarkData, target: .transient) {
        case .success(let resolved):
            let url = resolved.url
            if resolved.didRefresh {
                let updatedConfig = configuration.withUpdatedActiveBookmark(resolved.bookmarkData)
                saveConfiguration(updatedConfig)
                Logger.info("Refreshed stale bookmark for screen \(screenID)", category: .fileAccess)
            }

            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard canAccess else {
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    // Fail-open by design: existence-only pass avoids deleting a
                    // config over a transient scope failure.
                    Logger.warning(
                        "Video bookmark for screen \(screenID) passed validation on file existence only (security scope unavailable)",
                        category: .fileAccess
                    )
                    return true
                }
                Logger.error("Cannot access file for screen \(screenID)", category: .fileAccess)
                return false
            }
            return true

        case .failure(let failure):
            Logger.error("Failed to resolve bookmark for screen \(screenID): \(failure.localizedDescription)", category: .fileAccess)
            return false
        }
    }

    private func validateHTMLSource(_ source: HTMLSource, for screenID: CGDirectDisplayID) -> Bool {
        switch source {
        case .inline:
            return true
        case .url(let url):
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                Logger.error("Invalid remote HTML URL for screen \(screenID): unsupported scheme '\(url.scheme ?? "none")'", category: .fileAccess)
                return false
            }
            return true
        case .file(let bookmarkData):
            return validateLocalHTMLBookmark(bookmarkData, indexFileName: nil, for: screenID)
        case .folder(let bookmarkData, let indexFileName):
            return validateLocalHTMLBookmark(bookmarkData, indexFileName: indexFileName, for: screenID)
        }
    }

    private func validateLocalHTMLBookmark(
        _ bookmarkData: Data,
        indexFileName: String?,
        for screenID: CGDirectDisplayID
    ) -> Bool {
        switch bookmarkResolver.resolve(bookmarkData, target: .transient) {
        case .success(let resolved):
            let url = resolved.url
            if resolved.didRefresh {
                persistRefreshedHTMLBookmark(
                    matching: bookmarkData,
                    with: resolved.bookmarkData,
                    for: screenID
                )
            }

            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard canAccess || FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                Logger.error("Cannot access local HTML resource for screen \(screenID)", category: .fileAccess)
                return false
            }
            if !canAccess {
                // Fail-open by design: existence-only pass avoids deleting a
                // config over a transient scope failure.
                Logger.warning(
                    "HTML bookmark for screen \(screenID) passed validation on file existence only (security scope unavailable)",
                    category: .fileAccess
                )
            }

            if let indexFileName {
                let escapedIndex = indexFileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? indexFileName
                guard let requestURL = URL(string: "\(FolderURLSchemeHandler.scheme)://\(FolderURLSchemeHandler.host)/\(escapedIndex)") else {
                    Logger.error("Invalid HTML folder index name for screen \(screenID): \(indexFileName)", category: .fileAccess)
                    return false
                }
                do {
                    let indexURL = try FolderURLSchemeHandler.resolvedFileURL(
                        for: requestURL,
                        inside: url
                    )
                    return FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false))
                } catch {
                    Logger.error("Failed to resolve HTML folder index for screen \(screenID): \(error.localizedDescription)", category: .fileAccess)
                    return false
                }
            }

            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))

        case .failure(let failure):
            Logger.error("Failed to resolve local HTML bookmark for screen \(screenID): \(failure.localizedDescription)", category: .fileAccess)
            return false
        }
    }

    /// Actor-safe persistent owner used by validation.
    @discardableResult
    func persistRefreshedHTMLBookmark(
        matching original: Data,
        with refreshed: Data,
        for screenID: CGDirectDisplayID
    ) -> Bool {
        guard let current = getConfiguration(for: screenID) else { return false }

        let updated: ScreenConfiguration?
        if let origin = current.wpeOrigin,
           origin.sourceFolderBookmark == original {
            updated = current.replacingWPEOriginBookmark(
                workshopID: origin.workshopID,
                matching: original,
                with: refreshed
            )
            _ = replaceWPEHistorySourceBookmark(
                workshopID: origin.workshopID,
                matching: original,
                with: refreshed
            )
            persistWPEBookmarkOwnerRefresh(origin, refreshed)
        } else {
            updated = current.replacingHTMLBookmark(
                matching: original,
                with: refreshed
            )
        }

        guard let updated else {
            Logger.info(
                "[bookmark/screenHTML] skipped stale refresh save — stored bookmark changed between resolve and save",
                category: .fileAccess
            )
            return false
        }
        saveConfiguration(updated)
        return true
    }
}
