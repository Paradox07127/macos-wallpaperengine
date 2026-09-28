#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("SteamCMD streamed output boundaries", .serialized)
struct SteamCMDOutputStreamTests {
    @Test("Eight MiB from a real child cannot grow an unfinished output line")
    func realChildLongLine() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = ["-e", "print 'x' x (8*1024*1024); print qq(Logging in using cached credentials. Logging in user 'fixture' [U:1:123] to Steam Public...OK\\n); print qq(Steam Console Client (c) Valve Corporation - version 1700000000\\n)"]
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
            }; child.waitUntilExit()
        }
        var output = SteamCMDOutputAccumulator()
        var peak = 0
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
            _ = output.append(chunk)
            peak = max(peak, output.pendingByteCount)
        }
        output.finish()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #expect(peak <= 65536)
        #expect(output.retainedByteCount <= 1 << 20)
        #expect(output.discardedLineByteCount >= 8 * 1024 * 1024)
        #expect(SteamCachedLoginParser.parse(stdout: output.output).outcome != .sessionValid)
        #expect(output.output.contains("version 1700000000"))
    }

    @Test("Chunking preserves UTF8, CRLF, bare CR and ANSI-wrapped output")
    func byteAtATime() {
        var output = SteamCMDOutputAccumulator()
        var lines: [String] = []
        let input = "\u{1b}[32m中文🙂\u{1b}[0m\r\nsecond\rthird\n"
        for byte in input.utf8 {
            lines += output.append(Data([byte]))
        }
        output.finish()
        #expect(lines == ["中文🙂", "second", "third"])
    }

    @Test("Login keeps a bounded prompt window and discards overlong success-shaped lines")
    func loginNoise() {
        var login = SteamCMDLoginOutputAccumulator()
        let chunk = Data(repeating: 0x78, count: 4096)
        for _ in 0 ..< 2048 {
            login.append(chunk)
        }
        #expect(login.retainedByteCount <= 65536)
        login.append(Data("Logged in OK\n".utf8))
        #expect(login.event == nil)
        for byte in "\u{1b}[32mpassword:\u{1b}[0m".utf8 {
            login.append(Data([byte]))
        }
        #expect(login.event == .passwordPrompt)
    }

    @Test("The byte limit is inclusive, discarded counts are exact, and EOF retains only a short final line")
    func exactLimitAndEOF() {
        var output = SteamCMDOutputAccumulator()
        let atLimit = Data(repeating: 0x61, count: 65536)
        #expect(output.append(atLimit).isEmpty)
        #expect(output.pendingByteCount == 65536)
        #expect(output.append(Data([10])).first?.utf8.count == 65536)
        _ = output.append(atLimit)
        _ = output.append(Data("b\r\nfinal🙂".utf8))
        #expect(output.discardedLineByteCount == 65537)
        output.finish()
        #expect(output.pendingByteCount == 0)
        #expect(output.output.hasSuffix("final🙂\n"))
        output.finish()
        #expect(output.output.components(separatedBy: "final🙂").count == 2)
    }

    @Test("A success-shaped unfinished line cannot become terminal before its size is known")
    func terminalWaitsForLineBoundary() {
        var login = SteamCMDLoginOutputAccumulator()
        login.append(Data("Logged in OK".utf8))
        #expect(login.event == nil)
        login.append(Data(repeating: 0x78, count: 65536))
        login.append(Data([10]))
        #expect(login.event == nil)
        login.append(Data("ERROR (No Connection)".utf8))
        login.finish()
        #expect(login.event == .noConnection)
    }

    @Test("Normal version, download and public build facts survive a rejected line")
    func resumesAtNextLine() {
        var output = SteamCMDOutputAccumulator()
        _ = output.append(Data(repeating: 0x78, count: 65537))
        _ = output.append(Data("Success. Downloaded item 999\n".utf8))
        let normal = "Steam Console Client (c) Valve Corporation - version 1700000000\n"
            + "Success. Downloaded item 123\n"
            + #""branches" { "public" { "buildid" "42" } }"# + "\n"
        for byte in normal.utf8 {
            _ = output.append(Data([byte]))
        }
        #expect(!output.output.contains("Downloaded item 999"))
        #expect(output.output.contains("Downloaded item 123"))
        #expect(output.output.contains("version 1700000000"))
        #expect(SteamConnectorBuildInfo.parsePublicBuildID(from: output.output) == "42")
    }

    @Test("Many short output lines retain only a fixed tail, not all callback batches")
    func manyShortLines() {
        var output = SteamCMDOutputAccumulator()
        let batch = Data(String(repeating: "plain line\n", count: 1024).utf8)
        for _ in 0 ..< 200 {
            #expect(output.append(batch).count == 1024)
        }
        #expect(output.retainedByteCount <= 1 << 20)
        #expect(output.pendingByteCount == 0)
        #expect(output.discardedLineByteCount == 0)
    }

    @Test("Unterminated refusals remain immediate while success waits for a complete line")
    func unterminatedRefusals() {
        for (text, expected) in [
            ("ERROR (No Connection)", SteamCMDLoginOutputClassifier.Event.noConnection),
            ("FAILED (Account Disabled)", .refused(reason: "Account Disabled")),
            ("FAILED (Invalid Password)", .invalidPassword),
            ("FAILED (Invalid Login Auth Code)", .invalidGuardCode),
            ("FAILED (Rate Limit Exceeded)", .rateLimited),
        ] {
            var login = SteamCMDLoginOutputAccumulator()
            for byte in text.utf8 {
                login.append(Data([byte]))
            }
            #expect(login.event == expected)
        }
    }

    @Test("Password, Guard and terminal output retain normal precedence across chunks")
    func loginPrompts() {
        var login = SteamCMDLoginOutputAccumulator()
        for part in ["pass", "word:", "\r\nSteam Guard ", "code:"] {
            login.append(Data(part.utf8))
        }
        #expect(login.event == .guardCodeEmailPrompt)
        login.append(Data("\r\nFAILED (Invalid Login Auth Code)\n".utf8))
        #expect(login.event == .invalidGuardCode)
    }
}
#endif
