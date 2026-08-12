import Foundation
import Testing
import os
@testable import LiveWallpaper

/// Standing proof for the connector's whole reason to exist. Everything the
/// Steam integration plans to do — reusing the shared login, downloading into
/// `steamapps/workshop/content/431960`, pruning the Wallpaper Engine install —
/// depends on SteamCMD running with the user's real `$HOME`. If someone re-adds
/// App Sandbox to the SteamConnector target, that silently stops being true and
/// downloads go back to landing in the app container; this turns red instead.
///
/// Deliberately ONE test holding ONE connection, and `.serialized`: connecting
/// concurrently from parallel tests made launchd tear the test host down
/// mid-run, which truncated the whole suite rather than failing honestly.
@Suite("SteamConnector execution boundary", .serialized)
struct SteamConnectorEnvironmentTests {

    @Test("The connector runs outside the app sandbox with the real home")
    func connectorRunsOutsideTheSandbox() throws {
        let connection = NSXPCConnection(serviceName: "com.loomscreen.pro.SteamConnector")
        connection.remoteObjectInterface = NSXPCInterface(with: (any SteamConnectorProtocol).self)
        connection.resume()
        defer { connection.invalidate() }

        let payload = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            failure.withLock { $0 = error.localizedDescription }
            done.signal()
        } as? any SteamConnectorProtocol
        let connector = try #require(proxy, "SteamConnector proxy unavailable")

        connector.probeEnvironment { data in
            payload.withLock { $0 = data }
            done.signal()
        }

        // launchd has to spawn the service on first connect, so allow a cold
        // start; timing out here means the .xpc was never embedded.
        guard done.wait(timeout: .now() + 30) == .success else {
            Issue.record("SteamConnector did not reply within 30s — is SteamConnector.xpc embedded in the host app?")
            return
        }
        if let reason = failure.withLock({ $0 }) {
            Issue.record(Comment(rawValue: "SteamConnector XPC connection failed: \(reason)"))
            return
        }
        let data = try #require(payload.withLock { $0 }, "empty probe payload")
        let probe = try JSONDecoder().decode(SteamConnectorEnvironmentProbe.self, from: data)

        // Same connection, so account discovery is checked against this Mac's
        // real config.vdf without opening a second one. `SteamAccountsFileTests`
        // covers the grammar; this covers "does it hold on the actual file".
        let accountsPayload = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let accountsDone = DispatchSemaphore(value: 0)
        connector.discoverAccounts { data in
            accountsPayload.withLock { $0 = data }
            accountsDone.signal()
        }
        guard accountsDone.wait(timeout: .now() + 30) == .success else {
            Issue.record("SteamConnector.discoverAccounts did not reply within 30s")
            return
        }
        let accountsData = try #require(accountsPayload.withLock { $0 }, "empty accounts payload")
        let accounts = try JSONDecoder().decode([SteamAccountSummary].self, from: accountsData)
        for account in accounts {
            let steamIDIsNumeric = !account.steamID64.isEmpty
                && account.steamID64.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
            #expect(SteamAccountsFile.isValidAccountName(account.accountName))
            #expect(steamIDIsNumeric, "non-numeric SteamID reached the app: \(account.steamID64)")
        }
        // A profile that exists but parses to nothing means the real file's
        // shape drifted from what the parser expects — worth failing on.
        if probe.steamConfigExists, probe.steamConfigByteCount > 0 {
            #expect(
                !accounts.isEmpty,
                "config.vdf exists but no accounts parsed — the Accounts block shape may have changed"
            )
        }

        // Under the sandbox `NSHomeDirectory()` is rewritten to the container
        // while the POSIX user database is not, so the two agreeing is what
        // says no sandbox is applied — no machine-specific path needed.
        #expect(
            probe.nsHomeDirectory == probe.posixHomeDirectory,
            Comment(rawValue: """
                Connector is sandboxed: $HOME is \(probe.nsHomeDirectory) but the \
                user database reports \(probe.posixHomeDirectory). Check that \
                ENABLE_APP_SANDBOX is NO for the SteamConnector target in BOTH \
                Debug and Release.
                """)
        )
        #expect(
            !probe.nsHomeDirectory.contains("/Library/Containers/"),
            Comment(rawValue: "Connector $HOME is a sandbox container: \(probe.nsHomeDirectory)")
        )
        #expect(probe.uid == getuid())

        // Existence is probed inside the connector: the sandboxed test host
        // cannot even stat that path, so it cannot decide this for itself.
        // Machines with no Steam install legitimately skip the read assertion.
        guard probe.steamConfigExists else { return }
        #expect(
            probe.readErrorDescription == nil,
            Comment(rawValue: """
                Connector could not read \(probe.steamConfigPath) without a \
                security-scoped bookmark: \(probe.readErrorDescription ?? "")
                """)
        )
        #expect(probe.steamConfigByteCount > 0)
    }
}
