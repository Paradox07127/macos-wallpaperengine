//
//  main.swift
//  SteamConnector
//
//  Created by Taijia Liang on 7/31/2026.
//

import Foundation

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    
    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        
        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: (any SteamConnectorProtocol).self)

        // Reverse channel for progress. Installing Wallpaper Engine runs for
        // minutes; without this the app would sit on one reply block with
        // nothing to show.
        newConnection.remoteObjectInterface = NSXPCInterface(with: (any SteamConnectorProgressProtocol).self)

        let exportedObject = SteamConnector()
        exportedObject.progressSink = newConnection.remoteObjectProxy as? any SteamConnectorProgressProtocol
        newConnection.exportedObject = exportedObject
        
        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()
        
        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }
}

// Create the delegate for the service.
let delegate = ServiceDelegate()

// Set up the one NSXPCListener for this service. It will handle all incoming connections.
let listener = NSXPCListener.service()
listener.delegate = delegate

// Resuming the serviceListener starts this service. This method does not return.
listener.resume()
