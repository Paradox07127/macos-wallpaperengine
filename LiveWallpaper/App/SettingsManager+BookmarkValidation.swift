import Foundation
import CoreGraphics
import LiveWallpaperCore


extension SettingsManager {
    func validateConfiguration(for screenID: CGDirectDisplayID) -> Bool {
        guard let configuration = getConfiguration(for: screenID) else { return false }
        return validateConfiguration(configuration)
    }

    func validateConfiguration(_ configuration: ScreenConfiguration) -> Bool {
        let screenID = configuration.screenID
        guard let definition = WallpaperSessionDefinition(configuration: configuration) else {
            Logger.error("Malformed wallpaper configuration for screen \(screenID)", category: .settings)
            return false
        }

        switch definition {
        case .video(let bookmarkData, _):
            return validateVideoBookmark(bookmarkData, for: screenID, configuration: configuration)
        case .html(let source, _):
            return validateHTMLSource(source, configuration: configuration)
        case .scene(let descriptor):
            return !descriptor.workshopID.isEmpty
                && !descriptor.cacheRelativePath.isEmpty
                && !descriptor.entryFile.isEmpty
        }
    }

    /// True only when the bookmark records a non-root volume that is not currently reachable; unknown volume -> false.
    nonisolated static func isBookmarkVolumeUnavailable(_ bookmarkData: Data) -> Bool {
        guard let volumeURL = URL.resourceValues(forKeys: [.volumeURLKey], fromBookmarkData: bookmarkData)?.volume,
              volumeURL.path(percentEncoded: false) != "/" else { return false }
        return (try? volumeURL.checkResourceIsReachable()) != true
    }

    private func keepsConfigurationForUnavailableVolume(_ bookmarkData: Data, for screenID: CGDirectDisplayID) -> Bool {
        guard bookmarkVolumeIsUnavailable(bookmarkData) else { return false }
        Logger.warning(
            "Keeping wallpaper configuration for screen \(screenID): its bookmark's volume is not mounted",
            category: .fileAccess
        )
        return true
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
                replacePersistedRow(with: configuration.withUpdatedActiveBookmark(resolved.bookmarkData))
                SchemeStore.shared.replaceVideoBookmark(matching: bookmarkData, with: resolved.bookmarkData)
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
                if keepsConfigurationForUnavailableVolume(bookmarkData, for: screenID) {
                    return true
                }
                Logger.error("Cannot access file for screen \(screenID)", category: .fileAccess)
                return false
            }
            return true

        case .failure(let failure):
            if keepsConfigurationForUnavailableVolume(bookmarkData, for: screenID) {
                return true
            }
            Logger.error("Failed to resolve bookmark for screen \(screenID): \(failure.localizedDescription)", category: .fileAccess)
            return false
        }
    }

    private func validateHTMLSource(_ source: HTMLSource, configuration: ScreenConfiguration) -> Bool {
        let screenID = configuration.screenID
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
            return validateLocalHTMLBookmark(bookmarkData, indexFileName: nil, configuration: configuration)
        case .folder(let bookmarkData, let indexFileName):
            return validateLocalHTMLBookmark(bookmarkData, indexFileName: indexFileName, configuration: configuration)
        }
    }

    private func validateLocalHTMLBookmark(
        _ bookmarkData: Data,
        indexFileName: String?,
        configuration: ScreenConfiguration
    ) -> Bool {
        let screenID = configuration.screenID
        switch bookmarkResolver.resolve(bookmarkData, target: .transient) {
        case .success(let resolved):
            let url = resolved.url
            if resolved.didRefresh {
                persistRefreshedHTMLBookmark(
                    matching: bookmarkData,
                    with: resolved.bookmarkData,
                    configuration: configuration
                )
            }

            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard canAccess || FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                if keepsConfigurationForUnavailableVolume(bookmarkData, for: screenID) {
                    return true
                }
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
                        || keepsConfigurationForUnavailableVolume(bookmarkData, for: screenID)
                } catch {
                    Logger.error("Failed to resolve HTML folder index for screen \(screenID): \(error.localizedDescription)", category: .fileAccess)
                    return false
                }
            }

            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                || keepsConfigurationForUnavailableVolume(bookmarkData, for: screenID)

        case .failure(let failure):
            if keepsConfigurationForUnavailableVolume(bookmarkData, for: screenID) {
                return true
            }
            Logger.error("Failed to resolve local HTML bookmark for screen \(screenID): \(failure.localizedDescription)", category: .fileAccess)
            return false
        }
    }

    @discardableResult
    func persistRefreshedHTMLBookmark(
        matching original: Data,
        with refreshed: Data,
        for screenID: CGDirectDisplayID
    ) -> Bool {
        guard let configuration = getConfiguration(for: screenID) else { return false }
        return persistRefreshedHTMLBookmark(matching: original, with: refreshed, configuration: configuration)
    }

    @discardableResult
    private func persistRefreshedHTMLBookmark(
        matching original: Data,
        with refreshed: Data,
        configuration: ScreenConfiguration
    ) -> Bool {
        guard let current = loadConfigurations().first(where: {
            $0.screenID == configuration.screenID && $0.displayFingerprint == configuration.displayFingerprint
        }) else { return false }

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
        replacePersistedRow(with: updated)
        return true
    }

    /// saveConfiguration overwrites the first row with this screenID; an imported table can hold several, told apart by fingerprint.
    private func replacePersistedRow(with updated: ScreenConfiguration) {
        var configs = loadConfigurations()
        guard let index = configs.firstIndex(where: {
            $0.screenID == updated.screenID && $0.displayFingerprint == updated.displayFingerprint
        }) else { return }
        configs[index] = updated
        replaceAllConfigurations(configs)
    }
}
