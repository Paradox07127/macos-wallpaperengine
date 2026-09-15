// AppKit timer callbacks own each operation. No async task spans the UI workflow.
// Concatenated after main.swift's shared helpers by prepare.py.
enum WheelInputJournal {
    private static let state = OSAllocatedUnfairLock(initialState: [[Double]]())
    static func reset() { state.withLock { $0.removeAll(keepingCapacity: true) } }
    static func record(_ delta: Int32, phase: Int64) {
        state.withLock { $0.append([CACurrentMediaTime(), Double(delta), Double(phase)]) }
    }
    static func snapshot() -> [[Double]] { state.withLock { $0 } }
}

@MainActor final class EventLoopDriver: NSObject {
    private var timer: Timer?
    private var libraries: [String: Library] = [:]
    private var originals: [String: [CardState]] = [:]
    private var cases: [(String, String)] = []
    private var index = 0
    private var stage = -1
    private var stageStart = 0.0
    private var stageSign: OSSignpostIntervalState?
    private let signposter = OSSignposter(subsystem: "com.loomscreen.workflow-probe", category: "Workflow")
    private var session: Session?
    private var hoverStep = -1
    private var initialClicks = 0
    private var initialHovers = 0
    private var results: [[String: Any]] = []
    private var errors: [String] = []
    private var phases: [[String: Any]] = []
    private var started = 0.0
    private var finished = false
    private var wheelTask: Task<Void, Never>?
    private var wheelSamples: [[Double]] = []
    private let savedPointer = CGEvent(source: nil)?.location ?? .zero
    private var caseLabel: String { cases[index].0 + "-" + cases[index].1 }

    func prepare() async throws {
        for mode in ["online", "installed"] {
            let (library, _) = try await loadLibrary(mode: mode, count: 100)
            libraries[mode] = library; originals[mode] = library.cards
        }
        // Every recorded case starts with the same encoded-byte cache state.
        let urls = Set(libraries["online"]!.cards.compactMap { $0.item.previewImageURL })
        for url in urls.sorted(by: { $0.absoluteString < $1.absoluteString }) {
            _ = await WorkshopPreviewImageLoader.shared.loadAsset(url)
        }
        LocalImageCacheRegistry.shared.purgeAll()
        let variants = ["lazy", "windowed", "collection"]
        let rotation = Int(arg("rotation", "0")) ?? 0
        let ordered = Array(variants[(rotation % 3)...] + variants[..<(rotation % 3)])
        let pages = arg("page", "both") == "both"
            ? (rotation % 2 == 0 ? ["online", "installed"] : ["installed", "online"])
            : [arg("page", "installed")]
        for mode in pages {
            cases += ordered.map { (mode, $0) }
        }
        timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        print("READY \(getpid())"); fflush(stdout)
    }

    private func begin(_ next: Int) {
        if let stageSign {
            signposter.endInterval("phase", stageSign)
            phases.append(["stage": stage, "wallMs": (CACurrentMediaTime() - stageStart) * 1000])
        }
        stage = next; stageStart = CACurrentMediaTime()
        let names = ["cold-open", "short-scroll", "hover-click", "filter-restore", "inspector-width", "close"]
        stageSign = signposter.beginInterval("phase", "\(self.caseLabel, privacy: .public):\(names[next], privacy: .public)")
    }

    @objc private func tick() {
        if finished {
            if CACurrentMediaTime() - stageStart > 20 {
                timer?.invalidate(); NSApp.terminate(nil)
            }
            return
        }
        if stage == -1 {
            guard FileManager.default.fileExists(atPath: arg("wait-file", "/private/tmp/workflow-eventloop-go")),
                  ProcessInfo.processInfo.thermalState == .nominal else { return }
            startCase(); return
        }
        let elapsed = CACurrentMediaTime() - stageStart
        guard let session else { return }
        let library = libraries[cases[index].0]!
        switch stage {
        case 0:
            let expected = Set(originals[cases[index].0]!.prefix(12).map(\.previewKey))
            if expected.isSubset(of: Metrics.ready) {
                begin(1)
                wheelSamples = []
                if arg("real-wheel", "false") == "true" {
                    WheelInputJournal.reset()
                    let point = session.point(column: 1)
                    mouse(.mouseMoved, at: point)
                    wheelTask = Task.detached(priority: .high) {
                        let clock = ContinuousClock()
                        let start = clock.now.advanced(by: .milliseconds(30))
                        var sent: Int32 = 0
                        for step in 0 ... 120 {
                            guard !Task.isCancelled else { break }
                            try? await clock.sleep(until: start.advanced(by: .seconds(Double(step) / 60)))
                            guard !Task.isCancelled else { break }
                            let f = Double(step) / 120
                            let target = Int32((1000 * (f <= 0.5 ? 2 * f : 2 * (1 - f))).rounded())
                            let delta = target - sent; sent = target
                            // CGScrollPhase differs from NSEvent.Phase: began=1, changed=2, ended=4.
                            let phase: Int64 = step == 0 ? 1 : (step == 120 ? 4 : 2)
                            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                                   wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0) {
                                event.location = point
                                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                                event.post(tap: .cghidEventTap)
                                WheelInputJournal.record(delta, phase: phase)
                            }
                        }
                    }
                }
            } else if elapsed > 8 { errors.append("viewport not ready"); begin(1) }
        case 1:
            if arg("real-wheel", "false") == "true" {
                let y = session.scroll.contentView.bounds.minY
                wheelSamples.append([elapsed, y])
                session.updateVisibility(y: y)
                if elapsed >= 2.4 {
                    if (wheelSamples.map { $0[1] }.max() ?? 0) < 700 { errors.append("wheel travel too short") }
                    if abs(y) > 30 { errors.append("wheel failed to return: \(y)") }
                    wheelTask?.cancel(); wheelTask = nil
                    if arg("scroll-only", "false") == "true" {
                        begin(5); session.close(); LocalImageCacheRegistry.shared.purgeAll()
                        return
                    }
                    hoverStep = -1; initialClicks = Metrics.clicks; initialHovers = Metrics.hoverTimes.count
                    begin(2)
                }
                return
            }
            // Constant wall-clock velocity, coalescing late ticks into the current position.
            let extent = min(1000, max(0, session.scroll.documentView!.frame.height - session.scroll.contentSize.height))
            let fraction = min(1, elapsed / 2)
            let y = extent * (fraction <= 0.5 ? fraction * 2 : (1 - fraction) * 2)
            session.move(to: y)
            if elapsed >= 2 {
                session.move(to: 0); session.preheater.cancel()
                hoverStep = -1; initialClicks = Metrics.clicks; initialHovers = Metrics.hoverTimes.count
                begin(2)
            }
        case 2:
            let step = min(8, Int(elapsed / 0.22))
            if step != hoverStep {
                hoverStep = step
                let column = step / 3
                switch step % 3 {
                case 0: mouse(.mouseMoved, at: session.point(column: column))
                case 1: mouse(.leftMouseDown, at: session.point(column: column))
                default: mouse(.leftMouseUp, at: session.point(column: column))
                }
            }
            if elapsed >= 2.15 {
                if Metrics.clicks - initialClicks != 3 { errors.append("click count mismatch") }
                if library.selectedID != originals[cases[index].0]![2].id { errors.append("selected ID mismatch") }
                if Metrics.hoverTimes.count - initialHovers != 3 { errors.append("hover count mismatch") }
                mouse(.mouseMoved, at: CGPoint(x: 20, y: 20)); begin(3)
                library.cards = originals[cases[index].0]!.filter { $0.id.isMultiple(of: 2) }; session.reload()
            }
        case 3:
            if elapsed >= 0.2, library.cards.count != 100 {
                library.cards = originals[cases[index].0]!; session.reload()
            }
            if elapsed >= 0.4 { begin(4); session.resize(620) }
        case 4:
            if elapsed >= 0.2, session.window.contentLayoutRect.width < 800 { session.resize(900) }
            if elapsed >= 0.4 { begin(5); session.close(); LocalImageCacheRegistry.shared.purgeAll() }
        default:
            if elapsed >= 1 { endCase() }
        }
    }

    private func startCase() {
        let library = libraries[cases[index].0]!
        library.cards = originals[cases[index].0]!
        library.selectedID = nil
        for card in library.cards { card.selected = false; card.materialized = true }
        Metrics.ready.removeAll(); Metrics.frames = 0
        errors = []; phases = []; stageSign = nil
        mouse(.mouseMoved, at: CGPoint(x: 20, y: 20))
        started = CACurrentMediaTime(); begin(0)
        session = Session(library: library, variant: cases[index].1)
        session!.show()
    }

    private func endCase() {
        if let stageSign { signposter.endInterval("phase", stageSign) }
        stageSign = nil
        results.append(["label": caseLabel, "errors": errors, "phases": phases, "frames": Metrics.frames,
                        "wheelPositions": wheelSamples,
                        "wheelInputEvents": WheelInputJournal.snapshot(),
                        "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
                        "wallSeconds": CACurrentMediaTime() - started, "cacheAfterClose": cacheStats()])
        session = nil; index += 1
        if index == cases.count {
            finished = true; stageStart = CACurrentMediaTime()
            let result: [String: Any] = ["cases": results, "pid": getpid(), "driver": "AppKit Timer state machine",
                                        "scroll": arg("real-wheel", "false") == "true" ? "background CGEvent producer at 60Hz, continuous pixel wheel, 1000 points down/up" : "2 seconds, fixed time-based velocity, coalesced late ticks",
                                        "preheat": arg("preheat", "off"), "rotation": arg("rotation", "0"),
                                        "scrollOnly": arg("scroll-only", "false") == "true",
                                        "configurationTouched": false, "renderSessionIncluded": false]
            do {
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: arg("output", "/private/tmp/eventloop-result.json")))
                print("RESULT \(results.count) cases"); fflush(stdout)
            } catch { print("FAILED \(error)") }
            mouse(.mouseMoved, at: savedPointer)
        } else { stage = -1; startCase() }
    }
}

@MainActor final class WorkflowDelegate: NSObject, NSApplicationDelegate {
    let driver = EventLoopDriver()
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in do { try await driver.prepare() } catch { print("FAILED", error); NSApp.terminate(nil) } }
    }
}

let app = NSApplication.shared
let delegate = WorkflowDelegate()
app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
