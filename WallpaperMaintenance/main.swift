import Darwin
import Foundation
import os
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
    private static let log = Logger(subsystem: "com.loomscreen.WallpaperMaintenance", category: "connection")
    /// nil for ad-hoc signing, which has no Team ID.
    private static let teamIdentifier: String? = {
        var selfCode: SecCode?
        var selfStaticCode: SecStaticCode?
        var signingInformation: CFDictionary?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStaticCode) == errSecSuccess, let selfStaticCode,
              SecCodeCopySigningInformation(
                  selfStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation
              ) == errSecSuccess else { return nil }
        return (signingInformation as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

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
        let mode: String
        let requirement: String
        if let teamRequirement = SystemWallpaperRegistrationPolicy.callerRequirement(
            hostIdentifier: hostID, teamIdentifier: Self.teamIdentifier
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
                Self.log.error("Refused connection: \(step, privacy: .public) returned OSStatus \(status, privacy: .public)")
                return false
            }
            mode = "hostDesignatedRequirement"
            requirement = requirementString as String
        }
        Self.log.info("Caller requirement \(mode, privacy: .public): \(requirement, privacy: .public)")
        connection.setCodeSigningRequirement(requirement)
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
