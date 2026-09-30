import os.log

let wpxLog = Logger(subsystem: "com.loomscreen.audit", category: "video")

extension VideoRenderer {
    func fixtureArm(_ callback: @escaping @Sendable (String) -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                requestGeneration &+= 1
                sourceURL = URL(fileURLWithPath: "/fixture.mov")
                failureHandler = callback
                failureReported = false
                didSignalFirstFrame = true
                observeDecodeFailures(generation: requestGeneration)
                continuation.resume()
            }
        }
    }

    func fixtureNotify() {
        NotificationCenter.default.post(name: AVSampleBufferVideoRenderer.didFailToDecodeNotification, object: renderer)
    }

    func fixtureDrain() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    func fixtureHasSource() async -> Bool {
        await withCheckedContinuation { continuation in queue.async { [self] in continuation.resume(returning: sourceURL != nil) } }
    }

    func fixtureSetClock(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let timebase {
                    CMTimebaseSetRate(timebase, rate: 0)
                    CMTimebaseSetTime(timebase, time: CMTime(seconds: seconds, preferredTimescale: 600))
                }
                continuation.resume()
            }
        }
    }

    func fixtureClockSeconds() async -> Double {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: timebase.map { CMTimeGetSeconds(CMTimebaseGetTime($0)) } ?? .nan)
            }
        }
    }

    func fixtureStaleNotificationThenSwitch(_ callback: @escaping @Sendable (String) -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                fixtureNotify()
                requestGeneration &+= 1
                failureHandler = callback
                failureReported = false
                observeDecodeFailures(generation: requestGeneration)
                continuation.resume()
            }
        }
    }
}

final class FailureLog: @unchecked Sendable { // NSLock protects the cross-queue fixture log.
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ code: String) {
        lock.withLock { entries.append(code) }
    }

    var count: Int {
        lock.withLock { entries.count }
    }
}

private func check(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL: \(message)"); exit(1) }
}

@main struct Probe {
    @MainActor static func main() async {
        let video = VideoRenderer()
        let log = FailureLog()
        await video.fixtureArm { log.record($0) }
        video.fixtureNotify()
        await video.fixtureDrain()
        check(log.count == 1, "post-ready async decode failure did not report")
        video.fixtureNotify()
        await video.fixtureDrain()
        check(log.count == 1, "duplicate failure reported twice")
        await video.fixtureArm { log.record($0) }
        await video.fixtureStaleNotificationThenSwitch { log.record($0) }
        await video.fixtureDrain()
        check(log.count == 1, "old notification reached replacement playback")
        video.fixtureNotify()
        await video.fixtureDrain()
        check(log.count == 2, "new generation failure not reported")
        video.stopSync()
        let hasSource = await video.fixtureHasSource()
        check(!hasSource, "stop retains resumable source")
        video.fixtureNotify()
        await video.fixtureDrain()
        check(log.count == 2, "stopped playback received failure")
        await video.fixtureSetClock(123)
        video.start(url: URL(fileURLWithPath: "/loomscreen-fixture-nonexistent.mov"))
        await video.fixtureDrain()
        let restartedSource = await video.fixtureHasSource()
        let restartedClock = await video.fixtureClockSeconds()
        check(restartedSource, "explicit start did not restore the supplied source")
        check(abs(restartedClock) < 0.001, "stop then start retained the previous timeline")
        video.stopSync()
        print("PASS: 8 controlled VideoRenderer lifecycle assertions; notifications target the real AVSampleBufferVideoRenderer")
    }
}
