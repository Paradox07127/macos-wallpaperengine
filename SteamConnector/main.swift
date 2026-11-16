import Foundation
import os
import Security

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    /// nil when no requirement could be built; every connection is then refused for the process's lifetime.
    private static let callerRequirement: String? = {
        let log = Logger(subsystem: "com.loomscreen.pro.SteamConnector", category: "connection")
        let hostURL = Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var selfCode: SecCode?
        var selfStaticCode: SecStaticCode?
        var signingInformation: CFDictionary?
        var teamIdentifier: String?
        if SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
           SecCodeCopyStaticCode(selfCode, [], &selfStaticCode) == errSecSuccess, let selfStaticCode,
           SecCodeCopySigningInformation(
               selfStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation
           ) == errSecSuccess {
            teamIdentifier = (signingInformation as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        }

        let mode: String
        let requirement: String
        if let hostIdentifier = Bundle(url: hostURL)?.bundleIdentifier,
           let teamRequirement = SteamConnectorCallerRequirement.requirement(
               hostIdentifier: hostIdentifier, teamIdentifier: teamIdentifier
           ) {
            mode = "teamRequirement"
            requirement = teamRequirement
        } else {
            // Ad-hoc builds have no Team ID; the host's on-disk designated requirement is the only identity left.
            var code: SecStaticCode?
            var designatedRequirement: SecRequirement?
            var requirementString: CFString?
            var step = "SecStaticCodeCreateWithPath"
            var status = SecStaticCodeCreateWithPath(hostURL as CFURL, [], &code)
            if status == errSecSuccess, let code {
                step = "SecStaticCodeCheckValidity"
                status = SecStaticCodeCheckValidity(code, [], nil)
                if status == errSecSuccess {
                    step = "SecCodeCopyDesignatedRequirement"
                    status = SecCodeCopyDesignatedRequirement(code, [], &designatedRequirement)
                }
                if status == errSecSuccess, let designatedRequirement {
                    step = "SecRequirementCopyString"
                    status = SecRequirementCopyString(designatedRequirement, [], &requirementString)
                }
            }
            guard status == errSecSuccess, let requirementString else {
                log.error("Refused connection: \(step, privacy: .public) returned OSStatus \(status, privacy: .public)")
                return nil
            }
            mode = "hostDesignatedRequirement"
            requirement = requirementString as String
        }
        log.info("Caller requirement \(mode, privacy: .public): \(requirement, privacy: .public)")
        return requirement
    }()

    func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard let callerRequirement = Self.callerRequirement else { return false }
        newConnection.setCodeSigningRequirement(callerRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: (any SteamConnectorProtocol).self)

        // Reverse channel for progress. Installing Wallpaper Engine runs for
        // minutes; without this the app would sit on one reply block with
        // nothing to show.
        newConnection.remoteObjectInterface = NSXPCInterface(with: (any SteamConnectorProgressProtocol).self)

        let exportedObject = SteamConnector()
        exportedObject.progressSink = newConnection.remoteObjectProxy as? any SteamConnectorProgressProtocol
        newConnection.exportedObject = exportedObject
        // The connection is the client's interest in its work: an app that
        // cancelled, quit, or crashed must not leave SteamCMD downloading for
        // nobody. Strong capture: the connection is the only other owner and XPC
        // releases it on invalidation, so a weak one can be nil before this runs.
        newConnection.invalidationHandler = { [exportedObject] in
            exportedObject.clientWentAway()
        }
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
