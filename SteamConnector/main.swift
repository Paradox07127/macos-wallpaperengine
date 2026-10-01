import Foundation
import Security

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let hostURL = Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var requirementString: CFString?
        guard SecStaticCodeCreateWithPath(hostURL as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &requirementString) == errSecSuccess,
              let requirementString else { return false }
        newConnection.setCodeSigningRequirement(requirementString as String)
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
