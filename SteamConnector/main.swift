//
//  main.swift
//  SteamConnector
//

import Foundation

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: (any SteamConnectorProtocol).self)

        // Reverse channel for progress. Installing Wallpaper Engine runs for
        // minutes; without this the app would sit on one reply block with
        // nothing to show.
        newConnection.remoteObjectInterface = NSXPCInterface(with: (any SteamConnectorProgressProtocol).self)

        let exportedObject = SteamConnector()
        exportedObject.progressSink = newConnection.remoteObjectProxy as? any SteamConnectorProgressProtocol
        newConnection.exportedObject = exportedObject
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
