#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Drives the two halves of a managed SteamCMD install and records where it
/// landed. Downloading happens in this process, unpacking in the connector —
/// see `SteamCMDBootstrapDownloader` for why that split is forced rather than
/// chosen.
///
/// A managed install is additive. Nothing here replaces the existing
/// package-manager detection or the user's own "Select…" pick; if any step
/// fails the app falls back to the manual instructions unchanged.
@MainActor
@Observable
final class SteamCMDManagedInstallCoordinator {
    enum Status: Equatable {
        case idle
        case downloading
        case installing
        /// Waiting on the connector to delete the payload. A distinct state
        /// because `forget()` suspends for as long as the deletion takes, and
        /// reporting `.idle` across that window let a new `install()` start and
        /// race the removal it knew nothing about.
        case removing
        case installed(path: String)
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// Identifies the top-level operation currently allowed to commit. Bumped
    /// whenever one supersedes another, so a call that was mid-`await` when the
    /// user did something else declines to write its result: `@MainActor`
    /// serialises access between suspension points but does not make `install()`
    /// or `forget()` atomic across them.
    private var generation: UInt64 = 0

    /// "Get the verified archive to this path" — the capability, not the type.
    /// Taking the concrete downloader instead left its digest gate in the way of
    /// any test of the stages after it, which is the half that decides whether a
    /// failed install stays recoverable.
    @ObservationIgnored private let downloadArchive: (URL) async throws -> Void
    @ObservationIgnored private let defaults: UserDefaults
    /// Injected for the same reason the downloader's `fetch` is: the real ones
    /// install to and delete from the machine running them, which is not
    /// something a test may do to whoever is running it.
    @ObservationIgnored private let remove: () async -> SteamCMDManagedRemovalResult?
    @ObservationIgnored private let performInstall: (String) async -> SteamCMDManagedInstallResult?

    /// Path + the bootstrap digest that produced it, so a later run can tell a
    /// managed install apart from a directory the user happened to create.
    static let managedInstallDefaultsKey = "steamcmd.managedInstall.v1"

    init(
        downloadArchive: @escaping (URL) async throws -> Void = { destination in
            _ = try await SteamCMDBootstrapDownloader().download(to: destination)
        },
        defaults: UserDefaults = .standard,
        remove: @escaping () async -> SteamCMDManagedRemovalResult? = {
            await SteamConnectorClient.removeManagedSteamCMD()
        },
        performInstall: @escaping (String) async -> SteamCMDManagedInstallResult? = { path in
            await SteamConnectorClient.installManagedSteamCMD(tarballPath: path)
        }
    ) {
        self.downloadArchive = downloadArchive
        self.defaults = defaults
        self.remove = remove
        self.performInstall = performInstall
        self.managedInstall = Self.recordedInstall(defaults: defaults)
    }

    /// Where the downloaded archive lands: inside the container, because that is
    /// the only place this process may write. Only the connector reads it.
    /// Per-attempt filename. A shared path let a superseded install delete the
    /// archive a newer one had just downloaded and was waiting on.
    static func archiveStagingURL(
        attempt: UInt64,
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SteamCMDBootstrap", isDirectory: true)
            .appendingPathComponent("steamcmd_osx-\(attempt).tar.gz")
    }

    struct ManagedInstallRecord: Codable, Equatable, Sendable {
        let canonicalPath: String
        let bootstrapSHA256: String
    }

    /// Mirrors the defaults record so the UI can observe it. Kept in sync by
    /// `record`/`forget`, which are the only two writers.
    private(set) var managedInstall: ManagedInstallRecord?

    /// Readable without owning a coordinator, so a fresh coordinator restores
    /// the same install state.
    /// Deliberately does not stat `canonicalPath`: it lives outside the
    /// container, so every filesystem check from this process answers "no"
    /// regardless of what is really there. Whether the binary still works is the
    /// connector's question, and the connector answers it from its own derived
    /// install root — this record never travels there as an executable path.
    static func recordedInstall(defaults: UserDefaults = .standard) -> ManagedInstallRecord? {
        guard let data = defaults.data(forKey: managedInstallDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(ManagedInstallRecord.self, from: data)
    }

    @discardableResult
    func install() async -> Status {
        // Two concurrent installs share one archive path and one payload
        // directory: the second one's extract wipes the directory the first is
        // still running `+quit` inside.
        switch status {
        case .downloading, .installing:
            return status
        case .removing:
            // Starting now would race a deletion already in flight: the two use
            // separate short-lived XPC connections, so whichever replies last
            // wins — either the new record is wiped, or the removal takes the
            // install that just succeeded.
            return status
        case .idle, .installed, .failed:
            break
        }
        let attempt = generation
        guard let archive = Self.archiveStagingURL(attempt: attempt) else {
            return finish(.failed("No Application Support directory available"))
        }

        status = .downloading
        do {
            try await downloadArchive(archive)
        } catch {
            guard attempt == generation, !Task.isCancelled else { return status }
            return finish(.failed(Self.message(for: error)))
        }
        guard attempt == generation else { return status }

        status = .installing
        let result = await performInstall(archive.path(percentEncoded: false))
        // The archive is only an input to the connector; keeping it around would
        // be 2.4 MB of container for nothing.
        try? FileManager.default.removeItem(at: archive)
        guard attempt == generation else { return status }

        guard let result else {
            return finish(.failed(String(
                localized: "The Steam connector did not respond.",
                comment: "Managed SteamCMD install failure: the XPC service was unreachable."
            )))
        }
        guard result.outcome == .installed, let path = result.canonicalPath else {
            return finish(.failed(Self.message(for: result.outcome)))
        }

        record(ManagedInstallRecord(
            canonicalPath: path,
            bootstrapSHA256: SteamCMDBootstrapPackage.sha256
        ))
        return finish(.installed(path: path))
    }

    /// Abandons an install in flight. Bumping the generation is what makes the
    /// suspended `install()` decline to commit; the caller cancels its own Task
    /// to stop the download itself. Only meaningful while downloading — once
    /// the connector has the archive it is unpacking in a process this one
    /// cannot interrupt.
    func cancelInstall() {
        guard status == .downloading else { return }
        generation &+= 1
        status = .idle
    }

    /// Removes the install through the connector — the payload sits outside this
    /// container, so this process can neither see nor delete it. Bumps the
    /// generation first so an install still in flight cannot commit over it.
    /// Never touches the user's own "Select…" pick or a package-manager install.
    ///
    /// The record is dropped only once the connector confirms the files are
    /// gone. Dropping it first meant a refused or unreachable removal left the
    /// copy on disk with nothing pointing at it: the Remove command disappears
    /// with `managedInstall`, and resolution no longer offers the path, so the
    /// user could neither retry nor rediscover it.
    @discardableResult
    func forget() async -> Bool {
        generation &+= 1
        let attempt = generation
        status = .removing
        let result = await remove()
        // A newer operation took over while this was suspended; it owns the
        // state and the record now.
        guard attempt == generation else { return false }
        status = .idle
        guard result?.outcome == .removed || result?.outcome == .notInstalled else {
            return false
        }
        defaults.removeObject(forKey: Self.managedInstallDefaultsKey)
        managedInstall = nil
        return true
    }

    /// `Status.failed` is rendered verbatim in Settings, so everything that
    /// reaches it has to be localized. The underlying values are wire enums and
    /// English diagnostic strings — fine in a log, not on screen.
    private static func message(for error: Error) -> String {
        guard let download = error as? SteamCMDBootstrapDownloader.DownloadError else {
            return String(
                localized: "The SteamCMD download failed.",
                comment: "Managed SteamCMD install failure: unclassified download error."
            )
        }
        switch download {
        case .transport:
            return String(
                localized: "Couldn't reach Valve's download server.",
                comment: "Managed SteamCMD install failure: network transport error."
            )
        case .httpStatus(let code):
            return String(
                localized: "Valve's download server returned HTTP \(code).",
                comment: "Managed SteamCMD install failure; %lld is an HTTP status code."
            )
        case .sizeMismatch, .digestMismatch:
            return String(
                localized: "The downloaded SteamCMD archive didn't match its published checksum, so it was discarded.",
                comment: "Managed SteamCMD install failure: the archive failed the integrity gate."
            )
        case .couldNotStore:
            return String(
                localized: "Couldn't save the downloaded archive.",
                comment: "Managed SteamCMD install failure: writing to disk failed."
            )
        }
    }

    private static func message(for outcome: SteamCMDManagedInstallResult.Outcome) -> String {
        switch outcome {
        case .installed:
            return String(
                localized: "SteamCMD was installed.",
                comment: "Managed SteamCMD install outcome (not normally shown as an error)."
            )
        case .tarballRejected:
            return String(
                localized: "The downloaded SteamCMD archive didn't match its published checksum, so it was discarded.",
                comment: "Managed SteamCMD install failure: the connector's own re-hash disagreed."
            )
        case .extractionFailed:
            return String(
                localized: "The SteamCMD archive couldn't be unpacked.",
                comment: "Managed SteamCMD install failure: extraction failed."
            )
        case .binaryNotFound:
            return String(
                localized: "The unpacked files didn't contain the SteamCMD program.",
                comment: "Managed SteamCMD install failure: no executable in the payload."
            )
        case .signatureRejected:
            return String(
                localized: "The unpacked program isn't signed by Valve, so it was not installed.",
                comment: "Managed SteamCMD install failure: code signature check failed."
            )
        case .selfUpdateFailed:
            return String(
                localized: "SteamCMD was installed but its first run didn't finish.",
                comment: "Managed SteamCMD install failure: the +quit self-update did not complete."
            )
        case .unavailable:
            return String(
                localized: "SteamCMD can't be installed automatically right now.",
                comment: "Managed SteamCMD install failure: the connector refused the request."
            )
        }
    }

    private func record(_ installRecord: ManagedInstallRecord) {
        guard let data = try? JSONEncoder().encode(installRecord) else { return }
        defaults.set(data, forKey: Self.managedInstallDefaultsKey)
        managedInstall = installRecord
    }

    private func finish(_ status: Status) -> Status {
        self.status = status
        return status
    }
}
#endif
