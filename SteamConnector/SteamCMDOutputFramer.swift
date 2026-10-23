import Foundation

/// Parses SteamCMD's progress lines.
///
/// Shared so the connector and the app's own probe runner cannot drift into two
/// different readings of the same output. Format:
/// `Update state (0x61) downloading, progress: 42.34 (12345 / 67890)`.
enum SteamCMDProgressLine {
    static func parse(_ line: String) -> SteamOperationProgress? {
        guard let marker = line.range(of: "progress:") else { return nil }
        let tail = line[marker.upperBound...]
        let phase: SteamOperationProgress.Phase = line.contains("verifying")
            ? .verifying
            : (line.contains("downloading") ? .downloading : .connecting)

        // Preferred form carries byte detail; SteamCMD often omits it.
        if let open = tail.firstIndex(of: "("), let close = tail.firstIndex(of: ")"), open < close {
            let percentText = tail[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            let bytes = tail[tail.index(after: open) ..< close]
                .split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if bytes.count == 2,
               let percent = Double(percentText),
               let downloaded = UInt64(bytes[0]),
               let total = UInt64(bytes[1]) {
                return SteamOperationProgress(
                    phase: phase,
                    fraction: clampedFraction(percent),
                    downloadedBytes: downloaded,
                    totalBytes: total
                )
            }
        }

        let numeric = tail.prefix { $0.isNumber || $0 == "." || $0 == " " }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percent = Double(numeric), percent.isFinite, percent >= 0 else { return nil }
        return SteamOperationProgress(
            phase: phase,
            fraction: clampedFraction(percent),
            downloadedBytes: nil,
            totalBytes: nil
        )
    }

    private static func clampedFraction(_ percent: Double) -> Double? {
        guard percent.isFinite, percent >= 0 else { return nil }
        return min(max(percent / 100, 0), 1)
    }
}

/// UTF-8 byte framing shared by pipe and PTY readers. Once a line exceeds the
/// budget, none of it is eligible for semantic parsing, including its suffix.
struct SteamCMDOutputFramer {
    static let maxLineBytes = 64 * 1024
    private var pending = Data()
    private var dropping = false
    private var previousWasCR = false
    private(set) var discardedByteCount = 0
    var pendingByteCount: Int {
        pending.count
    }

    var partialLine: String? {
        dropping ? nil : Self.text(pending)
    }

    mutating func append(_ chunk: Data) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if byte == 10, previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = byte == 13
            if byte == 10 || byte == 13 {
                if !dropping {
                    lines.append(Self.text(pending))
                }
                pending.removeAll(keepingCapacity: true)
                dropping = false
            } else if dropping {
                discardedByteCount += 1
            } else if pending.count == Self.maxLineBytes {
                discardedByteCount += pending.count + 1
                pending.removeAll(keepingCapacity: true)
                dropping = true
            } else {
                pending.append(byte)
            }
        }
        return lines
    }

    mutating func finish() -> [String] {
        defer {
            pending.removeAll(keepingCapacity: true)
            dropping = false
            previousWasCR = false
        }
        return dropping || pending.isEmpty ? [] : [Self.text(pending)]
    }

    /// Strip terminal decoration only after assembling bytes: a split UTF-8
    /// scalar or ANSI escape remains intact until more bytes arrive.
    private static func text(_ data: Data) -> String {
        enum Escape { case none, start, csi, osc, oscEnd }
        var state = Escape.none
        var plain: [UInt8] = []
        plain.reserveCapacity(data.count)
        for byte in data {
            switch state {
            case .none:
                if byte == 27 {
                    state = .start
                } else {
                    plain.append(byte)
                }
            case .start:
                if byte == 91 {
                    state = .csi
                } else if byte == 93 {
                    state = .osc
                } else {
                    state = .none
                }
            case .csi:
                if (0x40 ... 0x7E).contains(byte) {
                    state = .none
                }
            case .osc:
                if byte == 7 {
                    state = .none
                } else if byte == 27 {
                    state = .oscEnd
                }
            case .oscEnd:
                state = byte == 92 || byte == 7 ? .none : .osc
            }
        }
        // Terminal bytes may be malformed; preserve readable replacement characters.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: plain, as: UTF8.self)
    }
}

/// Only accepted lines reach both the diagnostic tail and downstream parsers.
/// Keeping a raw suffix of a rejected line here would reintroduce false success
/// through the callers' contains-based parsers even if the summary rejected it.
struct SteamCMDOutputAccumulator {
    private var framer = SteamCMDOutputFramer()
    private var tail = SteamCMDOutputTail(maxBytes: 1 << 20)
    private var summary = SteamCMDOutputSemanticSummary()
    var pendingByteCount: Int {
        framer.pendingByteCount
    }

    var retainedByteCount: Int {
        tail.retainedByteCount
    }

    var discardedLineByteCount: Int {
        framer.discardedByteCount
    }

    mutating func append(_ chunk: Data) -> [String] {
        let lines = framer.append(chunk)
        retain(lines)
        return lines
    }

    mutating func finish() {
        retain(framer.finish())
    }

    private mutating func retain(_ lines: [String]) {
        for line in lines {
            summary.consume(line)
            tail.append(Data((line + "\n").utf8))
        }
    }

    var output: String {
        let omitted = discardedLineByteCount == 0 ? ""
            : "[\(discardedLineByteCount) bytes in overlong output lines omitted]\n"
        return omitted + summary.rendered(with: tail)
    }
}

/// Retains one unfinished line plus classified state, never the login transcript.
/// Prompts and refusals work without a newline. Success is committed only once
/// the line ends (or EOF), so an overlong line cannot leave a success behind.
struct SteamCMDLoginOutputAccumulator {
    private var framer = SteamCMDOutputFramer()
    private var completedEvent: SteamCMDLoginOutputClassifier.Event?
    var retainedByteCount: Int {
        framer.pendingByteCount
    }

    mutating func append(_ chunk: Data) {
        consume(framer.append(chunk))
    }

    mutating func finish() {
        consume(framer.finish())
    }

    private mutating func consume(_ lines: [String]) {
        for line in lines {
            completedEvent = preferred(completedEvent, SteamCMDLoginOutputClassifier.event(inTranscript: line))
        }
    }

    var event: SteamCMDLoginOutputClassifier.Event? {
        guard let partial = framer.partialLine,
              let candidate = SteamCMDLoginOutputClassifier.event(inTranscript: partial) else {
            return completedEvent
        }
        switch candidate {
        case .loggedIn:
            return completedEvent
        default:
            // A refusal can stop the child immediately without manufacturing success.
            return preferred(completedEvent, candidate)
        }
    }

    /// Match the existing classifier's precedence without retaining old text.
    private func preferred(
        _ first: SteamCMDLoginOutputClassifier.Event?, _ second: SteamCMDLoginOutputClassifier.Event?
    ) -> SteamCMDLoginOutputClassifier.Event? {
        guard let first else { return second }
        guard let second else { return first }
        func priority(_ event: SteamCMDLoginOutputClassifier.Event) -> Int {
            switch event {
            case .loggedIn: 0
            case .rateLimited: 1
            case .noConnection: 2
            case .invalidGuardCode: 3
            case .invalidPassword: 4
            case .refused: 5
            case .waitingForMobileConfirmation: 6
            case .guardCodeTotpPrompt: 7
            case .guardCodeEmailPrompt: 8
            case .passwordPrompt: 9
            }
        }
        return priority(first) <= priority(second) ? first : second
    }
}

/// Bounded retention for a child process's output — a ring buffer, not an
/// ever-growing `Data`: SteamCMD can emit hundreds of megabytes on a bad
/// day, and "accumulate everything, take the last 500 characters" is the
/// wrong place to be generous with memory. Ported from the retired in-app
/// process runner when the spawn moved into the connector.
struct SteamCMDOutputTail: Sendable {
    let maxBytes: Int

    private(set) var retainedByteCount = 0
    private(set) var discardedByteCount = 0
    private var buffer: Data
    private var writeIndex = 0

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
        buffer = Data(repeating: 0, count: max(0, maxBytes))
    }

    mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        guard maxBytes > 0 else {
            discardedByteCount += chunk.count
            return
        }

        if chunk.count >= maxBytes {
            discardedByteCount += retainedByteCount + chunk.count - maxBytes
            buffer.replaceSubrange(0 ..< maxBytes, with: chunk.suffix(maxBytes))
            writeIndex = 0
            retainedByteCount = maxBytes
            return
        }

        let overflow = max(0, retainedByteCount + chunk.count - maxBytes)
        discardedByteCount += overflow
        retainedByteCount = min(maxBytes, retainedByteCount + chunk.count)

        let firstWriteCount = min(chunk.count, maxBytes - writeIndex)
        buffer.replaceSubrange(
            writeIndex ..< (writeIndex + firstWriteCount),
            with: chunk.prefix(firstWriteCount)
        )
        let remaining = chunk.count - firstWriteCount
        if remaining > 0 {
            buffer.replaceSubrange(0 ..< remaining, with: chunk.suffix(remaining))
        }
        writeIndex = (writeIndex + chunk.count) % maxBytes
    }

    var data: Data {
        guard retainedByteCount > 0 else { return Data() }
        guard retainedByteCount == maxBytes else {
            return Data(buffer.prefix(retainedByteCount))
        }
        guard writeIndex > 0 else { return buffer }

        var result = Data()
        result.reserveCapacity(maxBytes)
        result.append(buffer[writeIndex...])
        result.append(buffer[..<writeIndex])
        return result
    }

    var string: String {
        let bytes = data
        // swiftlint:disable:next optional_data_string_conversion
        return String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }
}

/// Facts worth keeping even after the tail has evicted them. The diagnostic
/// tail is small on purpose, so a long run can push the version banner, the
/// "Success. Downloaded item" line, or the public `buildid` out of it — and
/// those are exactly the lines callers parse. Holds a fixed number of
/// independent slots so verbose output can't starve them.
struct SteamCMDOutputSemanticSummary: Sendable {
    private static let maxLineBytes = 4 * 1024

    private var identityLine: String?
    private var cachedLoginLine: String?
    private var loginResultLine: String?
    private var cachedCredentialsMissingLine: String?
    private var failureLine: String?
    private var downloadResultLine: String?
    private var subscriptionLine: String?
    private var teamIdentifierLine: String?
    private var codeFlagsLine: String?
    private var publicBranchContext: [String] = []
    private var publicBranchContextLinesRemaining = 0

    mutating func consume(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .newlines)
        guard line.utf8.count <= Self.maxLineBytes else { return }
        let startsPublicContext = line.contains(#""public""#)
        if startsPublicContext {
            publicBranchContextLinesRemaining = 16
            publicBranchContext = []
        }

        if publicBranchContextLinesRemaining > 0 {
            publicBranchContext.append(line)
            publicBranchContextLinesRemaining -= 1
        }

        // Independent fixed slots prevent one repeated/fabricated marker class
        // from exhausting storage needed by later real facts. Latest wins so
        // the process's terminal state supersedes startup chatter.
        if line.contains("Steam Console Client (c) Valve Corporation") {
            identityLine = line
        }
        if line.contains("Logging in using cached credentials.") {
            cachedLoginLine = line
        }
        if line.contains("Logging in user '") {
            loginResultLine = line
        }
        if line.contains("Cached credentials not found.") {
            cachedCredentialsMissingLine = line
        }
        if line.contains("FAILED (") {
            failureLine = line
        }
        if line.contains("Success. Downloaded item ") || line.contains("ERROR! Download item ") {
            downloadResultLine = line
        }
        if line.contains("No subscription") {
            subscriptionLine = line
        }
        if line.contains("TeamIdentifier=") {
            teamIdentifierLine = line
        }
        if line.contains("flags=0x") {
            codeFlagsLine = line
        }
    }

    func rendered(with tail: SteamCMDOutputTail) -> String {
        guard tail.discardedByteCount > 0 else { return tail.string }
        let facts = [
            identityLine,
            cachedLoginLine,
            loginResultLine,
            cachedCredentialsMissingLine,
            failureLine,
            downloadResultLine,
            subscriptionLine,
            teamIdentifierLine,
            codeFlagsLine,
        ].compactMap(\.self) + publicBranchContext
        let summary = facts.isEmpty ? "" : facts.joined(separator: "\n") + "\n"
        let marker = "[... \(tail.discardedByteCount) output bytes omitted; showing semantic lines and tail ...]\n"
        return summary + marker + tail.string
    }
}
