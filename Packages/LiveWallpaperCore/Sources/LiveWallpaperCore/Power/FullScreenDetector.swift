import AppKit
import Combine
import Observation

@MainActor @Observable
public final class FullScreenDetector {
    // MARK: - Observed State

    public private(set) var hiddenScreens: [CGDirectDisplayID: Bool] = [:]

    /// Per-display: do other apps' windows blanket ≥ 85% of the display by
    /// *union* area (overlaps counted once)? Distinct from `hiddenScreens`,
    /// which needs a single ≥95% window. Drives `pauseOnWindowOcclusion`.
    public private(set) var occludedScreens: [CGDirectDisplayID: Bool] = [:]

    /// Continuous union-coverage fraction (0…1) behind `occludedScreens`,
    /// quantized to `occlusionFractionStep` so adaptive-frame-rate observers
    /// only wake on meaningful change (this updates far more often than the
    /// ≥0.85 boolean as windows move).
    public private(set) var occlusionFractions: [CGDirectDisplayID: CGFloat] = [:]

    @ObservationIgnored private static let occlusionFractionStep: CGFloat = 0.05

    /// Cap on how many windows feed the union-area calculation per display.
    /// The union sweep is ~O(n² log n) over the x-strips; keeping only the
    /// largest few dozen windows bounds the cost while losing negligible
    /// coverage (tiny windows barely move 85%).
    @ObservationIgnored private nonisolated static let occlusionWindowCap = 80

    // MARK: - Private Properties

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var pollTimer: AnyCancellable?
    @ObservationIgnored private let pollInterval: TimeInterval

    // MARK: - Initialization

    public init(pollInterval: TimeInterval = 30.0) {
        self.pollInterval = pollInterval
        setupNotifications()
        checkFullScreenState()
    }

    /// Platform-owned surfaces do not represent user-visible window occlusion.
    /// Finder is intentionally included: `.excludeDesktopElements` removes its
    /// desktop surface, while ordinary Finder windows must participate in the
    /// same 85-percent union-area policy as every other application window.
    public nonisolated static func shouldExcludeWindowOwner(_ ownerName: String) -> Bool {
        ownerName == "Dock" || ownerName == "Window Server" || ownerName == "SystemUIServer"
    }

    // MARK: - Setup

    private func setupNotifications() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scanIfDemanded() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scanIfDemanded() }
            .store(in: &cancellables)
    }

    /// Workspace/space churn only matters while something consumes the result
    /// — the same demand gate as the fallback timer. Explicit `checkNow()`
    /// bypasses this, and `setFallbackPollingEnabled(true)` rescans, so state
    /// catches up as soon as a consumer appears.
    private func scanIfDemanded() {
        guard isFallbackPollingEnabled else { return }
        checkFullScreenState()
    }

    public var isFallbackPollingEnabled: Bool {
        pollTimer != nil
    }

    public func setFallbackPollingEnabled(_ enabled: Bool) {
        if enabled {
            startPollingIfNeeded()
            checkFullScreenState()
        } else {
            stopPolling()
        }
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }

        // pollInterval/6 = 5s leeway at the shipped 30s interval, letting the
        // OS coalesce the fallback tick with other wakeups.
        pollTimer = Timer.publish(every: pollInterval, tolerance: pollInterval / 6, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkFullScreenState() }
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    public func stop() {
        stopPolling()
        cancellables.removeAll()
    }

    // MARK: - Detection

    private func checkFullScreenState() {
        var result: [CGDirectDisplayID: Bool] = [:]
        var occlusion: [CGDirectDisplayID: Bool] = [:]
        var fractions: [CGDirectDisplayID: CGFloat] = [:]
        let screens = NSScreen.screens

        for screen in screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                result[id] = false
                occlusion[id] = false
                fractions[id] = 0
            }
        }

        if !NSScreen.screensHaveSeparateSpaces {
            let isFullScreen = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
            for key in result.keys {
                result[key] = isFullScreen; occlusion[key] = isFullScreen; fractions[key] = isFullScreen ? 1 : 0
            }
            updateIfChanged(result, occlusion, fractions)
            return
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            let isFullScreen = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
            for key in result.keys {
                result[key] = isFullScreen; occlusion[key] = isFullScreen; fractions[key] = isFullScreen ? 1 : 0
            }
            updateIfChanged(result, occlusion, fractions)
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        let screenFrames: [(id: CGDirectDisplayID, frame: CGRect)] = screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return (id, CGDisplayBounds(id))
        }

        // Clipped window rectangles per display, used for the union-area
        // occlusion test after the full-screen pass.
        var windowsByScreen: [CGDirectDisplayID: [CGRect]] = [:]

        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }

            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            if Self.shouldExcludeWindowOwner(ownerName) {
                continue
            }

            // Transparent panels (e.g. invisible overlays) don't occlude the
            // wallpaper, so they must not count toward coverage/occlusion.
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.1 {
                continue
            }

            let windowFrame = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            for (screenID, cgScreenFrame) in screenFrames {
                let intersection = windowFrame.intersection(cgScreenFrame)
                guard !intersection.isNull, !intersection.isEmpty else { continue }
                let coverage = intersection.width * intersection.height
                let screenArea = cgScreenFrame.width * cgScreenFrame.height
                if screenArea > 0, coverage >= screenArea * 0.95 {
                    result[screenID] = true
                }
                windowsByScreen[screenID, default: []].append(intersection)
            }
        }

        // Always synchronous: callers (reconcileMonitorOverlays,
        // setupFullScreenDetection) read the published state in the same turn,
        // and the sweep-line union is cheap even at the 80-window cap.
        applyOcclusionScan(
            fullScreen: result,
            seedOcclusion: occlusion,
            seedFractions: fractions,
            coverage: Self.unionCoverage(windowsByScreen: windowsByScreen, screenFrames: screenFrames)
        )
    }

    /// Raw (unquantized) union-coverage fraction per display.
    private static func unionCoverage(
        windowsByScreen: [CGDirectDisplayID: [CGRect]],
        screenFrames: [(id: CGDirectDisplayID, frame: CGRect)]
    ) -> [CGDirectDisplayID: CGFloat] {
        var coverage: [CGDirectDisplayID: CGFloat] = [:]
        for (screenID, cgScreenFrame) in screenFrames {
            let screenArea = cgScreenFrame.width * cgScreenFrame.height
            guard screenArea > 0 else { continue }
            let rects = windowsByScreen[screenID] ?? []
            coverage[screenID] = unionArea(of: rects) / screenArea
        }
        return coverage
    }

    /// Quantization + threshold decision for one scan.
    private func applyOcclusionScan(
        fullScreen: [CGDirectDisplayID: Bool],
        seedOcclusion: [CGDirectDisplayID: Bool],
        seedFractions: [CGDirectDisplayID: CGFloat],
        coverage: [CGDirectDisplayID: CGFloat]
    ) {
        var occlusion = seedOcclusion
        var fractions = seedFractions
        for (screenID, fraction) in coverage {
            // Floor (not round) to the step so a quantized value never exceeds
            // the true coverage — keeps the policy's 0.5/0.4 thresholds honest
            // instead of effectively shifting them to ~0.475/0.375.
            let quantized = (fraction / Self.occlusionFractionStep).rounded(.down) * Self.occlusionFractionStep
            fractions[screenID] = min(1, max(0, quantized))
            occlusion[screenID] = fraction >= 0.85
        }
        updateIfChanged(fullScreen, occlusion, fractions)
    }

    /// Area of the union of `rects` (overlaps counted once): sweep the
    /// compressed x-edges left→right and, per strip, merge the active
    /// y-intervals into covered length. Only the largest `occlusionWindowCap`
    /// rectangles are considered to bound the cost.
    nonisolated static func unionArea(of rects: [CGRect]) -> CGFloat {
        let rects = rects
            .filter { $0.width > 0 && $0.height > 0 }
            .sorted { ($0.width * $0.height) > ($1.width * $1.height) }
            .prefix(occlusionWindowCap)
        guard !rects.isEmpty else { return 0 }

        var xSet = Set<CGFloat>()
        for r in rects {
            xSet.insert(r.minX); xSet.insert(r.maxX)
        }
        let xs = xSet.sorted()

        var area: CGFloat = 0
        var intervals: [(lo: CGFloat, hi: CGFloat)] = []
        for i in 0 ..< (xs.count - 1) {
            let x0 = xs[i], x1 = xs[i + 1]
            let w = x1 - x0
            if w <= 0 {
                continue
            }
            // Strips never straddle an x-edge, so a rect is active for the
            // whole strip or none of it.
            intervals.removeAll(keepingCapacity: true)
            for r in rects where r.minX <= x0 && x1 <= r.maxX {
                intervals.append((r.minY, r.maxY))
            }
            if intervals.isEmpty {
                continue
            }
            intervals.sort { $0.lo < $1.lo }
            var covered: CGFloat = 0
            var runLo = intervals[0].lo
            var runHi = intervals[0].hi
            for interval in intervals.dropFirst() {
                if interval.lo <= runHi {
                    runHi = max(runHi, interval.hi)
                } else {
                    covered += runHi - runLo
                    runLo = interval.lo
                    runHi = interval.hi
                }
            }
            covered += runHi - runLo
            area += w * covered
        }
        return area
    }

    private func updateIfChanged(
        _ newFullScreen: [CGDirectDisplayID: Bool],
        _ newOcclusion: [CGDirectDisplayID: Bool],
        _ newFractions: [CGDirectDisplayID: CGFloat]
    ) {
        if newFullScreen != hiddenScreens {
            hiddenScreens = newFullScreen
        }
        if newOcclusion != occludedScreens {
            occludedScreens = newOcclusion
        }
        if newFractions != occlusionFractions {
            occlusionFractions = newFractions
        }
    }

    // MARK: - Public API

    public func isDesktopHidden(for screenID: CGDirectDisplayID) -> Bool {
        hiddenScreens[screenID] ?? false
    }

    public func isDesktopOccluded(for screenID: CGDirectDisplayID) -> Bool {
        occludedScreens[screenID] ?? false
    }

    public func occlusionFraction(for screenID: CGDirectDisplayID) -> Double {
        Double(occlusionFractions[screenID] ?? 0)
    }

    public func checkNow() {
        checkFullScreenState()
    }
}
