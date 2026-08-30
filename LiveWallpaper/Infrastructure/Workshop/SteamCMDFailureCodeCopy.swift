#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

// The XPC helper cannot localize its own failures — `SteamConnector.xpc` ships
// no `.lproj`, so `String(localized:, bundle: .appLanguage)` inside it returns the English default.
// It sends a code instead; the copy lives here, on the app side, where the
// catalog is.
extension SteamCMDFailureCode {
    func localizedMessage(_ arguments: [String]) -> String {
        switch self {
        case .pathNotAbsolute:
            return String(
                localized: "A SteamCMD path must be absolute.",
                bundle: .appLanguage, comment: "Workshop setup error when the chosen SteamCMD path is relative."
            )
        case .bindExpiredInQueue:
            return String(
                localized: "The check expired while another SteamCMD operation was running.",
                bundle: .appLanguage, comment: "Workshop setup error when a manual bind waited too long behind another operation."
            )
        case .notSteamCMDBinary:
            return String(
                localized: "That file isn't SteamCMD, and no SteamCMD binary was found next to it.",
                bundle: .appLanguage, comment: "Workshop setup error when the chosen file does not resolve to SteamCMD."
            )
        case .refusesOwnContainer:
            return String(
                localized: "Loomscreen won't run a SteamCMD from inside its own container.",
                bundle: .appLanguage, comment: "Workshop setup error when the chosen SteamCMD sits in the app's own container."
            )
        case .signatureNotValve:
            return String(
                localized: "That binary isn't signed by Valve.",
                bundle: .appLanguage, comment: "Workshop setup error when the chosen SteamCMD fails the signature check."
            )
        case .binaryQuarantined:
            return String(
                localized: "That binary is quarantined. Open it once in Finder, or remove the quarantine flag.",
                bundle: .appLanguage, comment: "Workshop setup error when the chosen SteamCMD still carries the quarantine flag."
            )
        case .couldNotRecordChoice:
            let detail = arguments.first ?? ""
            return String(
                localized: "Couldn't record the choice: \(detail)",
                bundle: .appLanguage, comment: "Workshop setup error when storing the manual SteamCMD binding fails. Placeholder is the underlying error."
            )
        case .installExpiredInQueue:
            return String(
                localized: "Another SteamCMD operation was running, so the install expired.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the request waited too long behind another operation."
            )
        case .stagingDirectoryFailed:
            return String(
                localized: "Could not create a staging directory.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the temporary unpack directory cannot be created."
            )
        case .manifestFetchFailed:
            return String(
                localized: "Could not fetch Valve's SteamCMD manifest.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when Valve's package manifest cannot be downloaded."
            )
        case .manifestUnexpectedShape:
            return String(
                localized: "Valve's SteamCMD manifest did not list the expected packages.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the manifest parses but names nothing usable."
            )
        case .manifestMalformedPackageName:
            return String(
                localized: "A package name in the manifest is malformed.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when a manifest entry cannot be turned into a URL."
            )
        case .firstRunTimedOut:
            return String(
                localized: "The first SteamCMD run timed out.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the initial bootstrap run does not finish."
            )
        case .couldNotHashBinary:
            return String(
                localized: "Could not hash the installed binary.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the digest of the installed Mach-O cannot be computed."
            )
        case .installRootMismatch:
            return String(
                localized: "The install root is not the managed SteamCMD directory.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the destination is not the directory this service derives."
            )
        case .unpackTimedOut:
            return String(
                localized: "Unpacking timed out.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when tar does not finish."
            )
        case .executableOutsideInstall:
            return String(
                localized: "The archive points its executable outside the install directory.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the unpacked binary resolves outside the payload."
            )
        case .noExecutableInArchive:
            return String(
                localized: "The unpacked archive contains no SteamCMD executable.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when no Mach-O is found in the payload."
            )
        case .codeSignatureInvalid:
            return String(
                localized: "The code signature is not valid.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when codesign rejects the unpacked binary."
            )
        case .unpackedBinaryQuarantined:
            return String(
                localized: "The unpacked binary is quarantined and could not be executed.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the freshly unpacked Mach-O still carries the quarantine flag."
            )
        case .packageDownloadFailed:
            let value = arguments.first ?? ""
            return String(
                localized: "Could not download \(value) from Valve's server.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when a package download fails. Placeholder is the package name."
            )
        case .packageChecksumMismatch:
            let value = arguments.first ?? ""
            return String(
                localized: "\(value) did not match the checksum in the manifest.",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when a downloaded package fails its digest check. Placeholder is the package name."
            )
        case .firstRunExitedNonZero:
            let value = arguments.first ?? ""
            return String(
                localized: "The first SteamCMD run exited \(value).",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the bootstrap run returns non-zero. Placeholder is the exit code."
            )
        case .installPathSymlink:
            let value = arguments.first ?? ""
            return String(
                localized: "A component of the install path is a symbolic link: \(value)",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the destination path walk hits a symlink. Placeholder is the offending path."
            )
        case .installDirectoryCreateFailed:
            let value = arguments.first ?? ""
            return String(
                localized: "Could not create the install directory: \(value)",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the destination cannot be created. Placeholder is the underlying error."
            )
        case .archiveSymlinkEscape:
            let value = arguments.first ?? ""
            return String(
                localized: "The archive contains a symbolic link that escapes the install directory: \(value)",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the payload holds an escaping symlink. Placeholder is its path."
            )
        case .retirePreviousFailed:
            let value = arguments.first ?? ""
            return String(
                localized: "Could not retire the previous install: \(value)",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the displaced install cannot be moved aside. Placeholder is the underlying error."
            )
        case .moveIntoPlaceFailed:
            let value = arguments.first ?? ""
            return String(
                localized: "Could not move the unpacked install into place: \(value)",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the staged payload cannot be moved in. Placeholder is the underlying error."
            )
        case .tarExitedNonZero:
            let code = arguments.first ?? ""
            let output = arguments.count > 1 ? arguments[1] : ""
            return String(
                localized: "tar exited \(code): \(output)",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when unpacking fails. Placeholders are tar's exit code and its output."
            )
        case .signedByUnexpectedTeam:
            let actual = arguments.first ?? ""
            let expected = arguments.count > 1 ? arguments[1] : ""
            return String(
                localized: "Signed by team \(actual), expected \(expected).",
                bundle: .appLanguage, comment: "Managed SteamCMD install error when the binary carries the wrong team identifier. Placeholders are the actual and the expected team."
            )
        }
    }
}

extension SteamCMDManualBindResult {
    /// Localized when the helper sent a code; the English `failureReason` is the
    /// fallback for a payload written before codes existed.
    var localizedFailureReason: String? {
        if let failureCode {
            return failureCode.localizedMessage(failureArguments ?? [])
        }
        return failureReason
    }
}

extension SteamCMDManagedInstallResult {
    /// Localized when the helper sent a code; the English `failureReason` is the
    /// fallback for a payload written before codes existed.
    var localizedFailureReason: String? {
        guard let failureCode else { return failureReason }
        let message = failureCode.localizedMessage(failureArguments ?? [])
        guard let rollbackRetiredPath, let rollbackReason else { return message }
        return String(
            localized: "\(message); the previous install could not be restored and is at \(rollbackRetiredPath): \(rollbackReason)",
            bundle: .appLanguage, comment: "Managed SteamCMD install error when the failed install also could not be rolled back. Placeholders are the original failure, the retired install path, and the rollback error."
        )
    }
}
#endif
