#if DEBUG
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("QA asynchronous applies", .serialized)
@MainActor
struct QAApplyOperationsTests {
    @Test("A bounded wait times out without stopping work and concurrent same-screen applies are refused")
    func waitAndOwnership() async throws {
        let operations = QAApplyOperations()
        defer { operations.shutdown() }
        var continuation: CheckedContinuation<[String: Any], Never>?
        let first = try operations.start(screenID: 1, requestID: "same", target: "a", revision: "r") {
            await withCheckedContinuation { continuation = $0 }
        }
        while continuation == nil {
            await Task.yield()
        }
        let timed = try await operations.wait(["operationID": first.id, "timeoutMs": 0])
        #expect(timed["waitTimedOut"] as? Bool == true)
        #expect(first.status == "running")
        #expect(throws: (any Error).self) {
            try operations.start(screenID: 1, requestID: nil, target: "b", revision: "r") { ["confirmed": true] }
        }
        let second = try operations.start(screenID: 2, requestID: nil, target: "b", revision: "r") { ["confirmed": false, "code": "test.failed"] }
        #expect(try operations.previous(requestID: "same", screenID: 1, target: "a", revision: "r") === first)
        #expect(throws: (any Error).self) { try operations.previous(requestID: "same", screenID: 2, target: "a", revision: "r") }
        continuation?.resume(returning: ["confirmed": true])
        continuation = nil
        #expect(try await operations.wait(["operationID": first.id, "timeoutMs": 1000])["status"] as? String == "completed")
        #expect(try await operations.wait(["operationID": second.id, "timeoutMs": 1000])["status"] as? String == "failed")
        #expect(first.json["completionLevel"] as? String == "committed")
    }

    @Test("History evicts completed results and malformed waits cannot start or cancel work")
    func boundedHistory() async throws {
        let operations = QAApplyOperations(capacity: 1)
        defer { operations.shutdown() }
        let first = try operations.start(screenID: 1, requestID: nil, target: "a", revision: "r") { ["confirmed": true] }
        _ = try await operations.wait(["operationID": first.id, "timeoutMs": 1000])
        let second = try operations.start(screenID: 1, requestID: nil, target: "b", revision: "r") { ["confirmed": true] }
        #expect(throws: (any Error).self) { try operations.get(["operationID": first.id]) }
        for raw: Any in [true, -1, 10001, 1.5, "100"] {
            do {
                _ = try await operations.wait(["operationID": second.id, "timeoutMs": raw])
                Issue.record("Accepted invalid wait")
            } catch {}
        }
        #expect(try await operations.wait(["operationID": second.id, "timeoutMs": 1000])["status"] as? String == "completed")
    }
}
#endif
