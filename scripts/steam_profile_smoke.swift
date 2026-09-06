// Offline process regression for the connector, which is not linked into the
// app's unit-test target. Compile this with the three SteamConnector Swift files.
import Foundation

@main
struct SteamProfileSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SteamProfileSmoke-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var passed = 0
        for scenario in ["saved", "missing", "wrong-identity", "bad-exit"] {
            let home = root.appendingPathComponent(scenario)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("fixture-\(scenario)")
            let identity = scenario == "wrong-identity" ? "8" : "7"
            let exitCode = scenario == "bad-exit" ? "5" : "0"
            let script = """
            #!/bin/sh
            case "$*" in
              *NoPromptForPassword*)
                if [ ! -f "$HOME/saved" ] || [ "\(scenario)" = "missing" ]; then
                  echo 'Cached credentials not found.'
                  echo 'FAILED (No cached credentials and @NoPromptForPassword is set)'
                  exit 5
                fi
                echo 'Logging in using cached credentials.'
                echo "Logging in user 'alice' [U:1:\(identity)] to Steam Public...OK"
                exit \(exitCode)
                ;;
            esac
            echo 'Password:'
            read -r fixture_password
            echo 'Waiting for user info...OK'
            # The old connector killed us here, before the cached session saved.
            sleep 0.3
            printf '%s' '"Accounts" { "alice" { "SteamID" "76561197960265735" } }' > "$HOME/Library/Application Support/Steam/config/config.vdf"
            touch "$HOME/saved"
            echo 'Unloading Steam API...OK'
            exit 0
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let result = SteamConnector.runLoginSession(
                binaryPath: executable.path,
                request: SteamCMDLoginRequest(accountName: "alice", password: "fixture-only"),
                realHome: home.path
            )
            guard (result.outcome == .success) == (scenario == "saved") else {
                fatalError("\(scenario): unexpected outcome \(result.outcome)")
            }
            let privateHome = try SteamCMDProfile.home(accountName: "alice", realHome: home.path)
            guard FileManager.default.fileExists(atPath: privateHome.appendingPathComponent("saved").path) else {
                fatalError("\(scenario): process was terminated before saving")
            }
            guard !FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Steam").path) else {
                fatalError("\(scenario): touched Steam client profile")
            }
            passed += 1
            print("PASS \(scenario)")
        }
        print("Steam profile process regressions: \(passed) passed")
        // Optional real-binary check: point this at a disposable, verified Valve
        // installation. No account is logged in and no user profile is read.
        if CommandLine.arguments.count == 2 {
            let result = SteamConnector.runSteamCMD(
                steamCMDPath: CommandLine.arguments[1], arguments: ["+quit"],
                timeout: 60, realHome: root.path
            )
            let expected = try SteamCMDProfile.steamRoot(accountName: nil, realHome: root.path)
            guard result.exitCode == 0, !result.timedOut,
                  result.output.contains(expected.path),
                  FileManager.default.fileExists(atPath: expected.appendingPathComponent("config/config.vdf").path),
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/Application Support/Steam").path)
            else { fatalError("Real SteamCMD did not use the isolated profile: \(result.output)") }
            print("PASS real SteamCMD isolated startup")
        }
    }
}
