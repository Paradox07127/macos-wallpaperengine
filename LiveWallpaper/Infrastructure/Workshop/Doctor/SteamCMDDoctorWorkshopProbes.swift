#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// The Workshop-wide checks, as opposed to the SteamCMD-specific ones. All three are advisory: `downloadBlocker` does not read them, so nothing here can take a command away from the user.
/// They exist because each one fails silently in production — a stale assets bookmark simply skips layers, an unreachable connector only surfaces as "the download did nothing".
extension SteamCMDDoctorService {

    // MARK: - Workshop content folder

    /// Whether the Workshop items Steam has already downloaded are reachable. Separate from `workingDirectory`, which only proves `config.vdf` is readable: a Steam profile with no Wallpaper Engine subscriptions has a perfectly good config and no content folder at all.
    /// That difference is exactly what a user staring at an empty library needs told.
    func runWorkshopContentProbe() {
        guard workdirBookmarkData != nil else {
            setProbe(.workshopContent, status: .yellow(
                message: String(
                    localized: "Authorize your Steam library folder to check this.",
                    bundle: .appLanguage, comment: "Workshop content diagnostic when the Steam library has not been authorized."
                ),
                command: nil
            ))
            return
        }
        do {
            let workdir = try resolveWorkdirURL()
            let didStart = workdir.startAccessingSecurityScopedResource()
            defer { if didStart { workdir.stopAccessingSecurityScopedResource() } }

            let content = SteamLibraryPaths.workshopContentRoot(steamRoot: workdir)
            let path = content.path(percentEncoded: false)
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                setProbe(.workshopContent, status: .yellow(
                    message: String(
                        localized: "No Wallpaper Engine Workshop folder yet. It appears once the first item is downloaded.",
                        bundle: .appLanguage, comment: "Workshop content diagnostic when the content folder does not exist."
                    ),
                    command: nil
                ))
                return
            }
            guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else {
                setProbe(.workshopContent, status: .red(
                    message: redacted(String(
                        localized: "The Workshop content folder can't be read.",
                        bundle: .appLanguage, comment: "Workshop content diagnostic when the folder exists but is unreadable."
                    )),
                    command: nil
                ))
                return
            }
            let items = entries.filter { SteamLibraryPaths.isSafeWorkshopID($0) }.count
            setProbe(.workshopContent, status: .green(detail: String(
                localized: "\(items) Workshop items readable.",
                bundle: .appLanguage, comment: "Workshop content diagnostic detail; %lld is how many downloaded items were found."
            )))
        } catch {
            setProbe(.workshopContent, status: .red(message: redacted(error.localizedDescription), command: nil))
        }
    }

    // MARK: - Scene resources

    /// Whether the Wallpaper Engine shared assets are actually reachable. A bookmark that no longer resolves is the failure worth catching: scenes still render, they just quietly drop every layer that referenced the shared assets, so nothing else in the app reports it.
    func runSceneResourcesProbe() {
        let library = WPEEngineAssetsLibrary.shared
        guard library.isAuthorized || WPEEngineAssetsLibrary.managedInstallRoot() != nil else {
            setProbe(.sceneResources, status: .yellow(
                message: String(
                    localized: "Not linked. Scenes render, but layers that need Wallpaper Engine's shared assets are skipped.",
                    bundle: .appLanguage, comment: "Scene resources diagnostic when no Wallpaper Engine install is linked."
                ),
                command: nil
            ))
            return
        }
        guard let root = WPEEngineAssetsLibrary.managedInstallRoot() ?? library.resolveAuthorizedRoot() else {
            setProbe(.sceneResources, status: .red(
                message: String(
                    localized: "The linked Wallpaper Engine folder can no longer be opened. Link it again.",
                    bundle: .appLanguage, comment: "Scene resources diagnostic when the stored bookmark no longer resolves."
                ),
                command: nil
            ))
            return
        }
        let didStart = root.startAccessingSecurityScopedResource()
        defer { if didStart { root.stopAccessingSecurityScopedResource() } }
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false)) else {
            setProbe(.sceneResources, status: .red(
                message: redacted(String(
                    localized: "The linked Wallpaper Engine folder is missing.",
                    bundle: .appLanguage, comment: "Scene resources diagnostic when the linked folder no longer exists."
                )),
                command: nil
            ))
            return
        }
        setProbe(.sceneResources, status: .green(detail: redacted(String(
            localized: "Shared assets are readable.",
            bundle: .appLanguage, comment: "Scene resources diagnostic detail when the assets folder is reachable."
        ))))
    }

    // MARK: - Connector

    /// Whether the unsandboxed helper answers at all. `locateSteamCMDBinary` returns nil only when the XPC connection fails (a successful call that finds nothing still decodes a result), so it separates "the helper is not running" from "there is no SteamCMD".
    /// Every other failure in this list confuses those two.
    func runConnectorProbe() async {
        guard await SteamConnectorClient.locateSteamCMDBinary() != nil else {
            setProbe(.connector, status: .red(
                message: String(
                    localized: "Loomscreen's background Steam helper didn't answer. Downloads won't run until it does — quitting and reopening Loomscreen usually starts it.",
                    bundle: .appLanguage, comment: "Connector diagnostic when the XPC service is unreachable."
                ),
                command: nil
            ))
            return
        }
        setProbe(.connector, status: .green(detail: String(
            localized: "The background helper answered.",
            bundle: .appLanguage, comment: "Connector diagnostic detail when the XPC service replies."
        )))
    }
}
#endif
