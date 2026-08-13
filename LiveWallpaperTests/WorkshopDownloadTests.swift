#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Workshop download script + output parsing")
struct WorkshopDownloadTests {

    @Test("Repository mutation blocks the same item while unrelated items remain available")
    @MainActor
    func repositoryMutationScope() async throws {
        let coordinator = WorkshopRepositoryCoordinator()

        let value = try await coordinator.withExclusiveMutation(workshopID: "100") {
            #expect(coordinator.isMutating(workshopID: "100"))
            #expect(!coordinator.isMutating(workshopID: "200"))

            do {
                _ = try await coordinator.withExclusiveMutation(workshopID: "100") { 0 }
                Issue.record("A second writer for the same Workshop item must be rejected")
            } catch {
                #expect(error as? WorkshopRepositoryCoordinator.MutationError == .itemAlreadyMutating("100"))
            }

            return try await coordinator.withExclusiveMutation(workshopID: "200") { 42 }
        }

        #expect(value == 42)
        #expect(!coordinator.isMutating(workshopID: "100"))
        #expect(!coordinator.isMutating(workshopID: "200"))
    }



    @Test("SteamCMD output retention is a bounded tail")
    func steamCMDOutputTailIsBounded() {
        var tail = SteamCMDOutputTail(maxBytes: 32)
        tail.append(Data("discard-me-".utf8))
        tail.append(Data("0123456789abcdefghijklmnopqrstuv-final".utf8))

        #expect(tail.retainedByteCount == 32)
        #expect(tail.discardedByteCount > 0)
        #expect(tail.string == "6789abcdefghijklmnopqrstuv-final")
    }

    @Test("SteamCMD output tail stays bounded across 100 MiB of streamed chunks")
    func steamCMDOutputTailStaysBoundedForHostileOutput() {
        let limit = 1 << 20
        let chunk = Data(repeating: 0x41, count: limit)
        var tail = SteamCMDOutputTail(maxBytes: limit)

        for _ in 0..<100 {
            tail.append(chunk)
            #expect(tail.retainedByteCount <= limit)
        }
        tail.append(Data("FINAL-DIAGNOSTIC".utf8))

        #expect(tail.retainedByteCount == limit)
        #expect(tail.discardedByteCount > 99 * limit)
        #expect(tail.string.hasSuffix("FINAL-DIAGNOSTIC"))
    }

    @Test("SteamCMD output tail has fixed capacity under one-byte chunks")
    func steamCMDOutputTailHandlesTinyChunks() {
        var tail = SteamCMDOutputTail(maxBytes: 1_024)
        for value in 0..<250_000 {
            tail.append(Data([UInt8(truncatingIfNeeded: value)]))
        }

        #expect(tail.retainedByteCount == 1_024)
        #expect(tail.data.count == 1_024)
        #expect(tail.discardedByteCount == 250_000 - 1_024)
    }

    @Test("SteamCMD semantic facts survive diagnostic-tail eviction")
    func steamCMDSemanticFactsSurviveTailEviction() {
        var summary = SteamCMDOutputSemanticSummary()
        summary.consume("Steam Console Client (c) Valve Corporation - version 1700000000")
        summary.consume(#"Success. Downloaded item 123 to "/tmp/item""#)
        var tail = SteamCMDOutputTail(maxBytes: 32)
        tail.append(Data(repeating: 0x78, count: 4_096))

        let output = summary.rendered(with: tail)
        #expect(output.contains("Steam Console Client (c) Valve Corporation"))
        #expect(output.contains("Success. Downloaded item 123"))
        #expect(output.contains("output bytes omitted"))
    }

    @Test("Repeated public contexts cannot exhaust independent semantic slots")
    func repeatedPublicContextsCannotExhaustSemanticSlots() {
        var summary = SteamCMDOutputSemanticSummary()
        for value in 0..<1_000 {
            summary.consume(#""public""#)
            summary.consume(#""buildid" "\#(value)""#)
        }
        summary.consume("Steam Console Client (c) Valve Corporation - version 1700000000")
        summary.consume(#"Success. Downloaded item 123 to "/tmp/item""#)
        var tail = SteamCMDOutputTail(maxBytes: 16)
        tail.append(Data(repeating: 0x78, count: 1_024))

        let output = summary.rendered(with: tail)
        #expect(output.contains("Steam Console Client (c) Valve Corporation"))
        #expect(output.contains("Success. Downloaded item 123"))
    }
}

@Suite("SteamCMD binary resolution")
struct SteamCMDBinaryResolutionTests {

    private func makeHomebrewLayout() throws -> (root: URL, wrapper: URL, binSymlink: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lw-steamcmd-\(UUID().uuidString)", isDirectory: true)
        let macOSDir = root.appendingPathComponent("MacOS", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        let machO = macOSDir.appendingPathComponent("steamcmd", isDirectory: false)
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]).write(to: machO)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: machO.path)

        let wrapper = root.appendingPathComponent("steamcmd.wrapper.sh", isDirectory: false)
        try "#!/bin/sh\nexec '\(macOSDir.path)/steamcmd.sh' \"$@\"\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)

        let binSymlink = binDir.appendingPathComponent("steamcmd", isDirectory: false)
        try fm.createSymbolicLink(at: binSymlink, withDestinationURL: wrapper)
        return (root, wrapper, binSymlink)
    }

    @Test("Wrapper script resolves to the sibling MacOS/steamcmd Mach-O")
    func resolvesWrapperToMachO() throws {
        let layout = try makeHomebrewLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        guard case .success(let url) = SteamCMDBinaryResolver.resolveCanonicalBinary(at: layout.wrapper) else {
            Issue.record("Expected the wrapper to resolve to the Mach-O binary")
            return
        }
        #expect(url.path.hasSuffix("MacOS/steamcmd"))
    }

    @Test("A bin/steamcmd symlink (Homebrew-style) resolves through the wrapper")
    func resolvesSymlinkThroughWrapper() throws {
        let layout = try makeHomebrewLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        guard case .success(let url) = SteamCMDBinaryResolver.resolveCanonicalBinary(at: layout.binSymlink) else {
            Issue.record("Expected the symlink to resolve through the wrapper to the Mach-O")
            return
        }
        #expect(url.path.hasSuffix("MacOS/steamcmd"))
    }

    @Test("A directory is rejected, not treated as a binary")
    func rejectsDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lw-empty-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        if case .success = SteamCMDBinaryResolver.resolveCanonicalBinary(at: dir) {
            Issue.record("A directory must not resolve as a SteamCMD binary")
        }
    }
}
#endif
