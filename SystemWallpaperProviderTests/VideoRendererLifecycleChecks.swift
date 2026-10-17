import AppKit
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

    /// Returns whether the pump continues and whether the terminal latch is now set.
    func fixturePumpStatus(_ status: AVQueuedSampleBufferRenderingStatus, requiresFlush: Bool) async -> (Bool, Bool) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let continues = pumpMayContinue(status: status, requiresFlush: requiresFlush)
                continuation.resume(returning: (continues, failureReported))
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

private func colorFrame(red: Bool) -> CVReadOnlyPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
    check(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          "could not create a raw scene frame")
    let pixel = buffer!
    CVPixelBufferLockBaseAddress(pixel, [])
    let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
    for y in 0 ..< 64 {
        for x in 0 ..< 64 {
            let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
            bytes[offset] = red ? 0 : 255
            bytes[offset + 1] = 0
            bytes[offset + 2] = red ? 255 : 0
            bytes[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    return CVReadOnlyPixelBuffer(unsafeBuffer: pixel)
}

private func snapshotIsRed(_ surface: IOSurface) -> Bool {
    IOSurfaceLock(surface, .readOnly, nil)
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
    return bytes[2] > 200 && bytes[0] < 30
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
        let reclaimLog = FailureLog()
        await video.fixtureArm { reclaimLog.record($0) }
        let (reclaimContinues, reclaimLatched) = await video.fixturePumpStatus(.failed, requiresFlush: true)
        check(!reclaimContinues, "pump kept feeding a reclaimed decoder")
        check(!reclaimLatched && reclaimLog.count == 0, "decoder reclaim latched a terminal failure and blocks flush recovery")
        let (failedContinues, failedLatched) = await video.fixturePumpStatus(.failed, requiresFlush: false)
        check(!failedContinues && failedLatched && reclaimLog.count == 1, "terminal decode failure was not reported")
        video.stopSync()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        window.contentView?.layer = video.layer
        window.orderFrontRegardless()
        defer { video.stopSync(); window.orderOut(nil) }
        let rawReady = FailureLog()
        video.enqueueRenderedFrame(colorFrame(red: true), first: true, isCurrent: { true }, onFirstFrame: { rawReady.record("ready") })
        for _ in 0 ..< 100 where rawReady.count == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        check(rawReady.count == 1, "raw scene frame never became ready")
        // Renderer readiness precedes the compositor publishing its displayed pixel buffer.
        var displayed: IOSurface?
        for _ in 0 ..< 100 where displayed == nil {
            displayed = video.snapshot()
            if displayed == nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard let surface = displayed else { check(false, "displayed scene frame has no snapshot"); return }
        check(snapshotIsRed(surface), "snapshot does not match the displayed scene frame")
        video.enqueueRenderedFrame(colorFrame(red: false), first: false, isCurrent: { false }, onFirstFrame: {})
        await video.fixtureDrain()
        guard let unchanged = video.snapshot() else { check(false, "stale frame discarded the displayed snapshot"); return }
        check(snapshotIsRed(unchanged), "a stale scene task replaced the displayed frame")
        print("PASS: 14 controlled VideoRenderer lifecycle assertions, including raw scene presentation and snapshots")
    }
}
