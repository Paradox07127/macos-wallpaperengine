#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import os

/// Per-frame GPU timing (scene CB, present CB, scene→present gap), usable in
/// Release. Opt-in via `WPEFrameGPUTimingLog`; the flag is read once, so when
/// disabled the only per-frame cost is the cached `isEnabled` check.
enum WPEFrameGPUTimingProbe {
    static let isEnabled: Bool = {
        for suite in [UserDefaults.appSuite, UserDefaults.standard]
        where suite.object(forKey: "WPEFrameGPUTimingLog") != nil {
            return suite.bool(forKey: "WPEFrameGPUTimingLog")
        }
        return false
    }()

    private static let windowSize = 600
    private static let reportInterval: CFTimeInterval = 10

    private struct Window {
        var values: [Double] = []
        var next = 0
        mutating func add(_ value: Double) {
            if values.count < WPEFrameGPUTimingProbe.windowSize {
                values.append(value)
            } else {
                values[next] = value
                next = (next + 1) % WPEFrameGPUTimingProbe.windowSize
            }
        }
    }

    private struct State {
        var scene = Window()
        var present = Window()
        var gap = Window()
        // Keyed by executor identity: with one wallpaper per display, two
        // executors interleave their completions here, and cross-display
        // scene→present pairing would produce garbage gaps.
        var lastSceneGPUEndByExecutor: [ObjectIdentifier: CFTimeInterval] = [:]
        var lastReport: CFTimeInterval?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func recordScene(executor: ObjectIdentifier, gpuStart: CFTimeInterval, gpuEnd: CFTimeInterval) {
        // GPU times are 0 when the buffer never executed (error / unsupported).
        guard gpuEnd > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let report: String? = state.withLock { s in
            s.scene.add((gpuEnd - gpuStart) * 1000)
            // On the merged path `recordPresent` never fires, so these entries
            // are never consumed; drop them wholesale rather than let the map
            // grow with every executor the session ever built (a recycled
            // ObjectIdentifier would otherwise pair across instances).
            if s.lastSceneGPUEndByExecutor.count > 8 {
                s.lastSceneGPUEndByExecutor.removeAll(keepingCapacity: true)
            }
            s.lastSceneGPUEndByExecutor[executor] = gpuEnd
            // Report from here too: on the merged continuous path the scene
            // buffer carries the present blit and `recordPresent` never fires
            // (its present/gap columns then read n/a).
            return reportIfDue(&s, now: now)
        }
        if let report {
            Logger.notice(report, category: .wpeRender)
        }
    }

    static func recordPresent(executor: ObjectIdentifier, gpuStart: CFTimeInterval, gpuEnd: CFTimeInterval) {
        guard gpuEnd > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let report: String? = state.withLock { s in
            s.present.add((gpuEnd - gpuStart) * 1000)
            if let sceneEnd = s.lastSceneGPUEndByExecutor.removeValue(forKey: executor) {
                // Negative = the present CB started before the scene CB retired
                // (queue overlap); kept as-is so the aggregate shows real overlap
                // rather than a clamped zero.
                s.gap.add((gpuStart - sceneEnd) * 1000)
            }
            return reportIfDue(&s, now: now)
        }
        if let report {
            Logger.notice(report, category: .wpeRender)
        }
    }

    private static func reportIfDue(_ s: inout State, now: CFTimeInterval) -> String? {
        guard let last = s.lastReport else {
            s.lastReport = now
            return nil
        }
        guard now - last >= reportInterval else { return nil }
        s.lastReport = now
        return formatReport(s)
    }

    private static func formatReport(_ s: State) -> String {
        func stats(_ window: Window) -> String {
            let sorted = window.values.sorted()
            guard !sorted.isEmpty else { return "p50=n/a p95=n/a" }
            let p50 = sorted[(sorted.count - 1) / 2]
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            return String(format: "p50=%.2fms p95=%.2fms", p50, p95)
        }
        // Scene count, not present: on the merged continuous path the present
        // rides the scene buffer and the present window stays empty.
        return "[gpu-timing] scene \(stats(s.scene)) | present \(stats(s.present)) "
            + "| gap \(stats(s.gap)) | frames=\(max(s.scene.values.count, s.present.values.count))"
    }
}
#endif
