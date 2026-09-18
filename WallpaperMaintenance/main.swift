import Darwin
import Foundation
import Security

final class WallpaperMaintenanceService: NSObject, SystemWallpaperMaintenanceProtocol {
    private static let queue = DispatchQueue(label: "com.loomscreen.wallpaper-maintenance")
    private let engine: WallpaperMaintenanceEngine

    init(engine: WallpaperMaintenanceEngine) {
        self.engine = engine
    }

    func inspect(with reply: @escaping @Sendable (Data) -> Void) {
        let engine = engine
        perform({ try engine.inspect() }, reply: reply)
    }

    func restart(with reply: @escaping @Sendable (Data) -> Void) {
        let engine = engine
        perform({ try engine.restart() }, reply: reply)
    }

    func repair(revision: String, with reply: @escaping @Sendable (Data) -> Void) {
        let engine = engine
        perform({ try engine.repair(revision: revision) }, reply: reply)
    }

    private func perform(_ operation: @escaping @Sendable () throws -> SystemWallpaperMaintenanceReport,
                         reply: @escaping @Sendable (Data) -> Void) {
        Self.queue.async {
            let report: SystemWallpaperMaintenanceReport
            do {
                report = try operation()
            } catch WallpaperMaintenanceEngine.Failure.timeout {
                report = .init(outcome: .timedOut, errorCode: "maintenance.timeout")
            } catch WallpaperMaintenanceEngine.Failure.refused {
                report = .init(outcome: .refused, errorCode: "maintenance.identityRejected")
            } catch {
                report = .init(outcome: .failed, errorCode: "maintenance.operationFailed")
            }
            reply((try? JSONEncoder().encode(report)) ?? Data())
        }
    }
}

final class WallpaperMaintenanceListener: NSObject, NSXPCListenerDelegate {
    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let hostURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().resolvingSymlinksInPath()
        guard connection.effectiveUserIdentifier == getuid(),
              let host = Bundle(url: hostURL), let hostID = host.bundleIdentifier,
              SystemWallpaperRegistrationPolicy.hostIDs.contains(hostID),
              let executable = host.executableURL?.resolvingSymlinksInPath(),
              let homePointer = getpwuid(getuid())?.pointee.pw_dir else { return false }

        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(connection.processIdentifier, &path, UInt32(path.count)) > 0 else { return false }
        guard let callerPath = String(bytes: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8),
              URL(fileURLWithPath: callerPath).resolvingSymlinksInPath() == executable else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var requirementString: CFString?
        guard SecStaticCodeCreateWithPath(hostURL as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &requirementString) == errSecSuccess,
              let requirementString else { return false }
        connection.setCodeSigningRequirement(requirementString as String)
        connection.exportedInterface = NSXPCInterface(with: SystemWallpaperMaintenanceProtocol.self)
        connection.exportedObject = WallpaperMaintenanceService(engine: .init(
            hostPath: hostURL.path, hostID: hostID, home: String(cString: homePointer)
        ))
        connection.resume()
        return true
    }
}

let delegate = WallpaperMaintenanceListener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
