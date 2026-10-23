import Foundation
import os

/// All waits are bounded; suspended render/teardown continuations are released before returning.
enum SceneLifecycleChecks {
    static func run() async throws {
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            FileHandle.standardOutput.write(Data("\(condition ? "PASS" : "FAIL"): \(name)\n".utf8))
            if !condition {
                failures.append(name)
            }
        }
        let now = ContinuousClock.now
        for phase in ["load", "videoAdmission", "preparePendingVideos"] {
            let admission = WallpaperSceneAdmission()
            let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
            let session = WallpaperSceneLifecycle(running: true, admission: admission, now: now,
                                                  onFailure: { code in failure.withLock { $0 = code } })
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            let waiting = OSAllocatedUnfairLock(initialState: false)
            let task = Task {
                await withCheckedContinuation { (parked: CheckedContinuation<Void, Never>) in
                    waiting.withLock { $0 = true }
                    Task { for await _ in stream {}; parked.resume() }
                }
            }
            for _ in 0 ..< 100 where !waiting.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            session.install(task: task)
            try await session.acquireSlot(clock: { now })
            session.checkDeadline(now: now.advanced(by: .seconds(30)))
            check(waiting.withLock { $0 } && task.isCancelled && failure.withLock { $0 } == "scene.stalled"
                && !session.isActive && admission.activeCount == 0,
                "watchdog cancels suspended \(phase) and releases its slot")
            session.finish()
            continuation.finish()
        }
        do {
            let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
            let session = WallpaperSceneLifecycle(running: true, admission: WallpaperSceneAdmission(), now: now.advanced(by: .seconds(-30)),
                                                  onFailure: { code in failure.withLock { $0 = code } })
            try await session.acquireSlot(clock: { now.advanced(by: .seconds(-30)) })
            for _ in 0 ..< 100 where failure.withLock({ $0 }) == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            check(failure.withLock { $0 } == "scene.stalled", "watchdog timer fires without renderer progress")
            session.finish()
        }
        do {
            let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
            let session = WallpaperSceneLifecycle(running: true, now: now,
                                                  onFailure: { code in failure.withLock { $0 = code } })
            session.framePresented(now: now)
            session.setRunning(false, now: now.advanced(by: .seconds(4)))
            session.checkDeadline(now: now.advanced(by: .seconds(100)))
            check(failure.withLock { $0 } == nil, "paused time does not consume the frame deadline")
            session.setRunning(true, now: now.advanced(by: .seconds(100)))
            session.checkDeadline(now: now.advanced(by: .seconds(106)))
            check(failure.withLock { $0 } == "scene.stalled", "running frame watchdog preserves elapsed time across pause")
            session.finish()
        }
        do {
            let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
            let session = WallpaperSceneLifecycle(running: true, admission: WallpaperSceneAdmission(), now: now.advanced(by: .seconds(-100)),
                                                  onFailure: { code in failure.withLock { $0 = code } })
            session.checkDeadline(now: now)
            check(failure.withLock { $0 } == nil && session.isActive, "work before admission does not consume the first-frame deadline")
            try await session.acquireSlot(clock: { now })
            session.checkDeadline(now: now.advanced(by: .seconds(29)))
            check(failure.withLock { $0 } == nil, "the first-frame deadline starts when the slot is acquired")
            session.checkDeadline(now: now.advanced(by: .seconds(30)))
            check(failure.withLock { $0 } == "scene.stalled", "no first frame 30 s after admission is a stall")
            session.finish()
        }
        do {
            let admission = WallpaperSceneAdmission()
            let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
            let session = WallpaperSceneLifecycle(running: true, admission: admission, now: now,
                                                  onFailure: { code in failure.withLock { $0 = code } })
            try await session.acquireSlot(clock: { now })
            session.framePresented(now: now)
            session.releaseSlot()
            for _ in 0 ..< 4 {
                _ = try admission.acquire()
            }
            let waiter = Task { try await session.acquireSlot() }
            try await Task.sleep(for: .milliseconds(50))
            session.checkDeadline(now: ContinuousClock.now.advanced(by: .seconds(20)))
            check(failure.withLock { $0 } == nil && session.isActive,
                  "waiting for a slot after hibernation does not consume the frame deadline")
            admission.release()
            _ = try? await waiter.value
            check(session.isActive && admission.activeCount == 4, "the woken scene takes the freed slot")
            session.finish()
            for _ in 0 ..< 3 {
                admission.release()
            }
        }
        do {
            let admission = WallpaperSceneAdmission()
            for _ in 0 ..< 4 {
                _ = try admission.acquire()
            }
            var codes: [String?] = []
            for _ in 0 ..< 2 {
                let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
                let session = WallpaperSceneLifecycle(running: true, admission: admission, now: now,
                                                      onFailure: { code in failure.withLock { $0 = code } })
                _ = session.setCapsule("busy")
                _ = try? await session.acquireSlot(timeout: .milliseconds(200))
                codes.append(failure.withLock { $0 })
            }
            check(codes == ["scene.busy", "scene.busy"] && !admission.isBlocked("busy"),
                  "waiting for a busy slot is not a failure of the waiting scene")
            for _ in 0 ..< 4 {
                admission.release()
            }
        }
        do {
            let admission = WallpaperSceneAdmission()
            for _ in 0 ..< 4 {
                _ = try admission.acquire()
            }
            let clock = OSAllocatedUnfairLock(initialState: now)
            let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
            let session = WallpaperSceneLifecycle(running: true, admission: admission, now: now,
                                                  onFailure: { code in failure.withLock { $0 = code } })
            let waiter = Task { try await session.acquireSlot(clock: { clock.withLock { $0 } }) }
            try await Task.sleep(for: .milliseconds(50))
            let granted = now.advanced(by: .seconds(29))
            clock.withLock { $0 = granted }
            admission.release()
            try await waiter.value
            session.checkDeadline(now: granted.advanced(by: .milliseconds(29900)))
            check(failure.withLock { $0 } == nil && session.isActive,
                  "queueing for a slot before the first load does not consume the first-frame deadline")
            session.checkDeadline(now: granted.advanced(by: .seconds(30)))
            check(failure.withLock { $0 } == "scene.stalled" && !session.isActive,
                  "no first frame 30 s after a queued admission is a stall")
            for _ in 0 ..< 3 {
                admission.release()
            }
        }
        do {
            let admission = WallpaperSceneAdmission()
            for _ in 0 ..< 4 {
                _ = try admission.acquire()
            }
            let clock = OSAllocatedUnfairLock(initialState: now)
            let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
            let session = WallpaperSceneLifecycle(running: true, admission: admission, now: now,
                                                  onFailure: { code in failure.withLock { $0 = code } })
            _ = session.setCapsule("queued")
            let waiter = Task { try await session.acquireSlot(clock: { clock.withLock { $0 } }) }
            try await Task.sleep(for: .milliseconds(50))
            session.checkDeadline(now: now.advanced(by: .seconds(31)))
            let stillQueued = failure.withLock { $0 } == nil && session.isActive
            clock.withLock { $0 = now.advanced(by: .seconds(30)) }
            _ = try? await waiter.value
            check(stillQueued && failure.withLock { $0 } == "scene.busy" && !admission.isBlocked("queued")
                && admission.activeCount == 4,
                "queueing past the admission timeout reports busy, not a stall")
            for _ in 0 ..< 4 {
                admission.release()
            }
        }
        do {
            let admission = WallpaperSceneAdmission()
            let session = WallpaperSceneLifecycle(running: true, admission: admission, onFailure: { _ in })
            let entered = OSAllocatedUnfairLock(initialState: false)
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            session.installShutdown {
                entered.withLock { $0 = true }
                for await _ in stream {}
                return false
            } awaitExit: {
                false
            }
            try await session.acquireSlot()
            session.finish()
            for _ in 0 ..< 100 where !entered.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            check(entered.withLock { $0 } && admission.activeCount == 0, "slot released before suspended teardown")
            continuation.finish()
            for _ in 0 ..< 100 where admission.leakedRenderThreadCount == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            var refused = false
            do {
                if try admission.acquire() {
                    admission.release()
                }
            } catch { refused = true }
            check(admission.leakedRenderThreadCount == 1 && refused, "leaked thread closes live scene admission")
        }
        do {
            let admission = WallpaperSceneAdmission()
            let session = WallpaperSceneLifecycle(running: true, admission: admission, onFailure: { _ in })
            let (exit, exited) = AsyncStream<Void>.makeStream()
            session.installShutdown {
                false
            } awaitExit: {
                for await _ in exit {}
                return true
            }
            try await session.acquireSlot()
            session.finish()
            for _ in 0 ..< 100 where admission.leakedRenderThreadCount == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            let leaked = admission.leakedRenderThreadCount == 1
            exited.finish()
            for _ in 0 ..< 100 where admission.leakedRenderThreadCount != 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            let reopened = (try? admission.acquire()) == true
            check(leaked && admission.leakedRenderThreadCount == 0 && reopened,
                  "a slow teardown reopens live scene admission once its thread exits")
            admission.release()
        }
        do {
            let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
            let session = WallpaperSceneLifecycle(running: true, admission: WallpaperSceneAdmission(), now: now,
                                                  onFailure: { code in failure.withLock { $0 = code } })
            try await session.acquireSlot(clock: { now })
            session.framePresented(now: now)
            session.restartLoad(now: now.advanced(by: .seconds(40)))
            session.checkDeadline(now: now.advanced(by: .seconds(65)))
            check(failure.withLock { $0 } == nil && session.isActive,
                  "reloading after hibernation has the first-frame budget, not the running-frame one")
            session.checkDeadline(now: now.advanced(by: .seconds(70)))
            check(failure.withLock { $0 } == "scene.stalled", "a reload with no frame for 30 s is a stall")
            session.finish()
        }
        do {
            let admission = WallpaperSceneAdmission()
            let date = Date(timeIntervalSince1970: 1000)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let configuration = root.appendingPathComponent("configuration.json")
            try Data("original".utf8).write(to: configuration)
            let capsule = try WallpaperSceneCapsule.fingerprint(at: root)
            try Data("original".utf8).write(to: configuration, options: .atomic)
            let identical = try WallpaperSceneCapsule.fingerprint(at: root)
            try Data("changed".utf8).write(to: configuration, options: .atomic)
            let changed = try WallpaperSceneCapsule.fingerprint(at: root)
            check(!admission.recordFailure(capsule, now: date), "first capsule failure permits retry")
            check(admission.recordFailure(identical, now: date.addingTimeInterval(600)), "two failures within ten minutes open circuit")
            check(admission.isBlocked(capsule) && !admission.isBlocked(changed), "circuit stays open until capsule content changes")
            let refusal = OSAllocatedUnfairLock<String?>(initialState: nil)
            let blocked = WallpaperSceneLifecycle(running: true, admission: admission,
                                                  onFailure: { code in refusal.withLock { $0 = code } })
            check(!blocked.setCapsule(identical) && refusal.withLock { $0 } == "scene.circuit.open",
                  "blocked capsule request reports circuit failure without loading")
            blocked.finish()
            let other = WallpaperSceneAdmission()
            other.recordFailure("capsule", now: date)
            check(!other.recordFailure("capsule", now: date.addingTimeInterval(601)), "old failure expires outside ten minutes")
        }
        do {
            let data = Data(#"{"version":1,"items":[],"hideClockCalendarOnLockScreen":false}"#.utf8)
            let manifest = try SystemWallpaperCoding.decoder.decode(SystemWallpaperManifest.self, from: data)
            let encoded = try SystemWallpaperCoding.encoder.encode(manifest)
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            check(object?["hideClockCalendarOnLockScreen"] as? Bool == false, "manifest preserves disabled lock screen clock hiding")
            let legacy = try SystemWallpaperCoding.decoder.decode(SystemWallpaperManifest.self, from: Data(#"{"version":1,"items":[]}"#.utf8))
            let legacyObject = try JSONSerialization.jsonObject(with: SystemWallpaperCoding.encoder.encode(legacy)) as? [String: Any]
            check(legacyObject?["hideClockCalendarOnLockScreen"] as? Bool == true, "legacy manifest enables lock screen clock hiding")
            let beat = try SystemWallpaperCoding.decoder.decode(SystemWallpaperHeartbeat.self,
                                                                from: Data(#"{"timestamp":0,"leakedRenderThreadCount":2}"#.utf8))
            let beatObject = try JSONSerialization.jsonObject(with: SystemWallpaperCoding.encoder.encode(beat)) as? [String: Any]
            check(beatObject?["leakedRenderThreadCount"] as? Int == 2, "heartbeat preserves leaked render thread count")
        }
        guard failures.isEmpty else { throw NSError(domain: "SceneLifecycleChecks", code: failures.count) }
    }
}
