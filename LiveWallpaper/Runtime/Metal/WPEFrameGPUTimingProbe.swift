#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import os

/// Opt-in via `WPEFrameGPUTimingLog`. Disabled cost is one cached bool check.
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

    private struct State {
        var values: [Double] = []
        var next = 0
        var lastReport: CFTimeInterval?

        mutating func add(_ value: Double) {
            if values.count < WPEFrameGPUTimingProbe.windowSize {
                values.append(value)
            } else {
                values[next] = value
                next = (next + 1) % WPEFrameGPUTimingProbe.windowSize
            }
        }
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func recordScene(gpuStart: CFTimeInterval, gpuEnd: CFTimeInterval) {
        guard gpuEnd > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let report: String? = state.withLock { s in
            s.add((gpuEnd - gpuStart) * 1000)
            guard let last = s.lastReport else {
                s.lastReport = now
                return nil
            }
            guard now - last >= reportInterval else { return nil }
            s.lastReport = now
            let sorted = s.values.sorted()
            guard !sorted.isEmpty else { return nil }
            let p50 = sorted[(sorted.count - 1) / 2]
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            return String(
                format: "[gpu-timing] scene p50=%.2fms p95=%.2fms frames=%d",
                p50, p95, s.values.count
            )
        }
        if let report {
            Logger.notice(report, category: .wpeRender)
        }
    }
}
#endif
