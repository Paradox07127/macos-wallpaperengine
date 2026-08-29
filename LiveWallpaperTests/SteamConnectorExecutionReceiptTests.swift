#if !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import Testing

    /// The connector resolves which SteamCMD it runs on every operation, so the
    /// app can only ever learn the executed binary from the operation result
    /// itself — the execution receipt (`executedBinaryPath`).
    @Suite("Steam connector execution receipts")
    struct SteamConnectorExecutionReceiptTests {
        @Test("payloads from an older connector (no receipt key) still decode")
        func legacyPayloadsDecodeWithoutReceipt() throws {
            let login = try JSONDecoder().decode(SteamCachedLoginResult.self, from: Data("""
            {"outcome":"sessionValid","steamID64":"76561197960265728","diagnosticTail":""}
            """.utf8))
            #expect(login.executedBinaryPath == nil)
            #expect(login.outcome == .sessionValid)

            let download = try JSONDecoder().decode(SteamWorkshopDownloadResult.self, from: Data("""
            {"outcome":"downloaded","itemPath":"/tmp/item","diagnosticTail":""}
            """.utf8))
            #expect(download.executedBinaryPath == nil)
            #expect(download.itemPath == "/tmp/item")

            let assets = try JSONDecoder().decode(SteamEngineAssetsResult.self, from: Data("""
            {"outcome":"installed","assetsPath":"/tmp/assets","diagnosticTail":""}
            """.utf8))
            #expect(assets.executedBinaryPath == nil)

            let probe = try JSONDecoder().decode(SteamCMDProbeRun.self, from: Data("""
            {"output":"ok","exitCode":0,"timedOut":false}
            """.utf8))
            #expect(probe.executedBinaryPath == nil)
        }

        /// Control for the compat test above: proves the key actually travels
        /// when set, so nil-on-legacy is "key absent", not "field never encoded".
        @Test("a set receipt survives the wire encoding")
        func receiptRoundTrips() throws {
            let sent = SteamCachedLoginResult(
                outcome: .sessionValid,
                steamID64: nil,
                diagnosticTail: "",
                executedBinaryPath: "/opt/homebrew/Caskroom/steamcmd/1.0/steamcmd"
            )
            let decoded = try JSONDecoder().decode(
                SteamCachedLoginResult.self, from: JSONEncoder().encode(sent)
            )
            #expect(decoded.executedBinaryPath == "/opt/homebrew/Caskroom/steamcmd/1.0/steamcmd")
        }

        @Test("Doctor records the binary the connector reported executing")
        @MainActor
        func doctorRecordsExecutedBinary() throws {
            let defaults = UserDefaults(
                suiteName: "LiveWallpaperTests.ExecutionReceipt.\(UUID().uuidString)"
            )!
            let doctor = SteamCMDDoctorService(defaults: defaults)
            #expect(doctor.lastExecutedBinaryPath == nil)

            doctor.applyCachedLoginOutcome(
                SteamCachedLoginResult(
                    outcome: .sessionValid,
                    steamID64: nil,
                    diagnosticTail: "",
                    executedBinaryPath: "/managed/steamcmd"
                ),
                username: "user",
                binary: URL(fileURLWithPath: "/displayed/steamcmd")
            )
            #expect(doctor.lastExecutedBinaryPath == "/managed/steamcmd")

            // A result without a receipt must not erase the last known one.
            doctor.applyCachedLoginOutcome(
                SteamCachedLoginResult(outcome: .timedOut, steamID64: nil, diagnosticTail: ""),
                username: "user",
                binary: URL(fileURLWithPath: "/displayed/steamcmd")
            )
            #expect(doctor.lastExecutedBinaryPath == "/managed/steamcmd")
        }
    }
#endif
