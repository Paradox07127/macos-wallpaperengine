import Foundation

public enum LoginItemFailure: Sendable {
    case registrationFailed(Error)
    case requiresApproval
    case registrationSilentlyFailed

    public var userFacingMessage: String {
        switch self {
        case .requiresApproval:
            return String(
                localized: "Open System Settings → General → Login Items and turn on Loomscreen.",
                comment: "Login item needs user approval in System Settings."
            )
        case .registrationSilentlyFailed:
            return String(
                localized: "Couldn't add to Login Items. Move Loomscreen to the /Applications folder, then try again.",
                comment: "Login item registration failed; app may not be in /Applications."
            )
        case .registrationFailed(let error):
            return String(
                localized: "Login Items registration failed: \(error.localizedDescription)",
                comment: "Login item registration failed with system error. Placeholder is the error description."
            )
        }
    }
}
