#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import os

enum WPEFrameOccupancyMeter {
    static let isEnabled: Bool = {
        // XCTest hosts `appSuite` as the real `com.loomscreen.pro` domain, so a
        // live occupancy session would leak into tests. Isolated scratch only.
        let suites: [UserDefaults] = NSClassFromString("XCTestCase") != nil
            ? [UserDefaults.appScoped()]
            : [UserDefaults.appSuite, UserDefaults.standard]
        for suite in suites where suite.object(forKey: "WPEFrameOccupancyLog") != nil {
            return suite.bool(forKey: "WPEFrameOccupancyLog")
        }
        return false
    }()

    enum Kind: Int, CaseIterable {
        case sceneCommandBuffer
        case renderPassEncoder
        case helperEncoder
        case particleEncoder
        case bloomEncoder
        case colorCorrectionEncoder
        case presentEncoder
        case textEncoder
        case videoMarkerCommandBuffer
        case aliasHeapTextureCreate
        case largeUniformBufferCreate
        /// One per uniform slot resolved this frame.
        case uniformSlotResolved
        /// One per String-keyed dictionary probe a resolution plan actually ran.
        case uniformDictProbe
        case jscCall
        case jscSetObject
        case jscRead
        case audioBandWrite
        case reflectionCapture
        case reflectionMipGeneration

        var label: String {
            switch self {
            case .sceneCommandBuffer: "cb"
            case .renderPassEncoder: "passEnc"
            case .helperEncoder: "helperEnc"
            case .particleEncoder: "particleEnc"
            case .bloomEncoder: "bloomEnc"
            case .colorCorrectionEncoder: "ccEnc"
            case .presentEncoder: "presentEnc"
            case .textEncoder: "textEnc"
            case .videoMarkerCommandBuffer: "videoMarkCB"
            case .aliasHeapTextureCreate: "aliasTex"
            case .largeUniformBufferCreate: "bigUniformBuf"
            case .uniformSlotResolved: "uSlot"
            case .uniformDictProbe: "uProbe"
            case .jscCall: "jscCall"
            case .jscSetObject: "jscSet"
            case .jscRead: "jscRead"
            case .audioBandWrite: "audioBand"
            case .reflectionCapture: "reflectionCopy"
            case .reflectionMipGeneration: "reflectionMip"
            }
        }
    }

    private static let reportInterval: CFTimeInterval = 10

    struct State {
        var counts = [Int](repeating: 0, count: Kind.allCases.count)
        var windowStart: CFTimeInterval?

        mutating func count(_ kind: Kind, by amount: Int, now: CFTimeInterval) -> String? {
            counts[kind.rawValue] += amount
            guard let start = windowStart else {
                windowStart = now
                return nil
            }
            guard now - start >= WPEFrameOccupancyMeter.reportInterval else { return nil }
            let report = Self.report(counts: counts, elapsed: now - start)
            counts = [Int](repeating: 0, count: Kind.allCases.count)
            windowStart = now
            return report
        }

        static func report(counts: [Int], elapsed: CFTimeInterval) -> String {
            var line = String(format: "[occupancy] %.1fs", elapsed)
            for kind in Kind.allCases where counts[kind.rawValue] > 0 {
                let total = counts[kind.rawValue]
                let rate = String(format: "%.1f", Double(total) / elapsed)
                line += " \(kind.label)=\(total)(\(rate)/s)"
            }
            return line
        }
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func count(_ kind: Kind, by amount: Int = 1) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let report: String? = state.withLock { $0.count(kind, by: amount, now: now) }
        if let report {
            Logger.notice(report, category: .wpeRender)
        }
    }

    static func countsForTesting() -> [Int] {
        state.withLock { $0.counts }
    }
}
#endif
