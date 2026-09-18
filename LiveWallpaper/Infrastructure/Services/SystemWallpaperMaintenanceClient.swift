import Foundation

@MainActor
enum SystemWallpaperMaintenanceClient {
    static let serviceName = "com.loomscreen.WallpaperMaintenance"

    static var isAvailable: Bool {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/WallpaperMaintenance.xpc")
        return FileManager.default.fileExists(atPath: url.path)
    }

    enum Operation: Sendable { case inspect, restart, repair(String) }

    static func perform(_ operation: Operation) async -> SystemWallpaperMaintenanceReport {
        guard isAvailable else {
            return .init(outcome: .unavailable, errorCode: "maintenance.helperMissing")
        }
        let data: Data? = await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(serviceName: serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: SystemWallpaperMaintenanceProtocol.self)
            let ticket = Reply(continuation, connection: connection)
            let fail: @Sendable () -> Void = { Task { @MainActor in ticket.finish(nil) } }
            connection.invalidationHandler = fail
            connection.interruptionHandler = fail
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in fail() })
                as? any SystemWallpaperMaintenanceProtocol else { ticket.finish(nil); return }
            let receive: @Sendable (Data) -> Void = { data in
                Task { @MainActor in ticket.finish(data) }
            }
            ticket.timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                ticket.finish(nil)
            }
            switch operation {
            case .inspect: proxy.inspect(with: receive)
            case .restart: proxy.restart(with: receive)
            case let .repair(revision): proxy.repair(revision: revision, with: receive)
            }
        }
        guard let data, let report = try? JSONDecoder().decode(SystemWallpaperMaintenanceReport.self, from: data) else {
            return .init(outcome: .failed, errorCode: "maintenance.connectionFailed")
        }
        return report
    }

    @MainActor
    private final class Reply {
        private var continuation: CheckedContinuation<Data?, Never>?
        private let connection: NSXPCConnection
        var timeout: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Data?, Never>, connection: NSXPCConnection) {
            self.continuation = continuation
            self.connection = connection
        }

        func finish(_ data: Data?) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            connection.invalidationHandler = nil
            connection.interruptionHandler = nil
            connection.invalidate()
            continuation.resume(returning: data)
        }
    }
}
