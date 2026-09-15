import AppKit
import SwiftUI
import Observation
import LiveWallpaperCore
import QuartzCore

func arg(_ name: String, _ fallback: String) -> String {
    guard let i = CommandLine.arguments.firstIndex(of: "--" + name), i + 1 < CommandLine.arguments.count else { return fallback }
    return CommandLine.arguments[i + 1]
}

@MainActor @Observable final class InteractionModel {
    var armed = true
    var html = HTMLConfig.default
    var displayID: UInt32 = 1
    var runtime = ScreenManager()
    var stored = 360.0
    var live: Double?
    var visible = true
    var previews = 0
    var commits = 0
    var closes = 0
    var slots = [ScheduleSlot(startHour: 2, endHour: 6, label: "Video"), ScheduleSlot(startHour: 10, endHour: 14, label: "Scene"), ScheduleSlot(startHour: 22, endHour: 1, label: "Night")]
    var timeCommits: [[Int]] = []
    var widthBinding: Binding<Double> { Binding(get: { self.stored }, set: { self.stored = $0; self.commits += 1 }) }
    var liveBinding: Binding<Double?> { Binding(get: { self.live }, set: { self.live = $0; self.previews += 1 }) }
    func close() { visible = false; closes += 1 }
}

struct Root: View {
    let model: InteractionModel
    let scene: ProbeModel
    let schema: WallpaperEngineProjectPropertySchema
    let variant: String
    let mode: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if mode == "web" {
            WebTransformCanvas(screen: Screen(id: model.displayID), config: Binding(get: { model.html }, set: { model.html = $0 }), isArmed: model.armed, baseIncludesTransform: false) {
                Rectangle().fill(.blue).frame(width: 400, height: 300)
            }.environment(model.runtime)
        } else if mode == "timeline" {
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)
                TimelineEditor(slots: model.slots, currentHour: 8, palette: [.blue, .orange, .purple], onCommitTimeChange: { id, start, end in
                    model.timeCommits.append([start, end])
                    if let index = model.slots.firstIndex(where: { $0.id == id }) { model.slots[index].startHour = start; model.slots[index].endHour = end }
                }, onRequestInsert: { _ in })
                .frame(width: 720, height: 46).offset(x: 24, y: 100)
            }
        } else if variant == "native" {
            NativeInspectorSplit(isMounted: true, isVisible: model.visible, animationTrigger: model.visible, reduceMotion: reduceMotion, storedWidth: model.widthBinding, liveWidth: model.liveBinding, onClose: model.close) {
                Color(nsColor: .windowBackgroundColor)
            } inspector: { _ in SceneProbeView(model: scene, schema: schema, variant: "quantized") }
        } else {
            InspectorSplit(isMounted: true, isVisible: model.visible, animationTrigger: model.visible, reduceMotion: reduceMotion, storedWidth: model.widthBinding, liveWidth: model.liveBinding, onClose: model.close) {
                Color(nsColor: .windowBackgroundColor)
            } inspector: { _ in SceneProbeView(model: scene, schema: schema, variant: "quantized") }
        }
    }
}

@MainActor func run() async throws {
    let variant = arg("variant", "swiftui"), mode = arg("mode", "inspector")
    let model = InteractionModel(), scene = ProbeModel()
    let url = URL(fileURLWithPath: arg("project", "/Users/taijial/Library/Application Support/Steam/steamapps/workshop/content/431960/3351072238/project.json"))
    let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data(contentsOf: url), preferredLanguages: ["en"])
    scene.values = schema.defaultValues
    scene.expanded = Set(WPEProjectSettingsPresentation(schema: schema, overrides: [:], excludedKeys: ["schemecolor"]).sections.map(\.id))
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 960, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: Root(model: model, scene: scene, schema: schema, variant: variant, mode: mode))
    window.contentView = host
    window.title = "Gallery Probe – interaction " + variant
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .seconds(1))
    var eventNumber = 0
    func event(_ type: NSEvent.EventType, _ point: NSPoint) {
        eventNumber += 1
        let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        NSApp.postEvent(e, atStart: false)
    }
    guard window.isKeyWindow, NSApp.isActive else { throw NSError(domain: "Probe focus", code: 1) }
    var phases: [[String: Any]] = [], checks: [[String: Any]] = []
    let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
    func drag(_ start: NSPoint, dx: CGFloat, name: String) async throws {
        let beforeCommits = model.commits + model.timeCommits.count
        event(.leftMouseDown, start)
        try await Task.sleep(for: .milliseconds(30))
        var gaps: [Double] = [], submissions: [Double] = []
        let steps = Int(arg("steps", "40"))!
        for step in 1 ... steps {
            let t = CACurrentMediaTime()
            event(.leftMouseDragged, NSPoint(x: start.x + dx * Double(step) / Double(steps), y: start.y))
            try await Task.sleep(for: .milliseconds(16))
            gaps.append((CACurrentMediaTime() - t) * 1000)
            let layout = CACurrentMediaTime()
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            submissions.append((CACurrentMediaTime() - layout) * 1000)
        }
        checks.append(["action": name + "-no-early-commit", "passed": model.commits + model.timeCommits.count == beforeCommits])
        event(.leftMouseUp, NSPoint(x: start.x + dx, y: start.y))
        try await Task.sleep(for: .milliseconds(150))
        phases.append(["phase": name, "submissionMs": submissions, "mainActorGapMs": gaps, "stored": model.stored, "live": model.live as Any? ?? NSNull(), "visible": model.visible, "commits": model.commits, "closes": model.closes, "timeCommits": model.timeCommits])
    }
    if mode == "web" {
        let start = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        print("web geometry", host.bounds, window.contentLayoutRect, start)
        event(.leftMouseDown, start)
        try await Task.sleep(for: .milliseconds(30))
        for offset in stride(from: 10, through: 60, by: 10) {
            event(.leftMouseDragged, NSPoint(x: start.x + CGFloat(offset), y: start.y))
            try await Task.sleep(for: .milliseconds(30))
        }
        print("web live", TransformTrace.translation, TransformTrace.manipulating, model.runtime.writes.count)
        checks.append(["action": "web-drag-live", "passed": TransformTrace.translation.width > 40 && model.runtime.writes.isEmpty])
        model.armed = false
        try await Task.sleep(for: .milliseconds(150))
        checks.append(["action": "web-disarm-resets-preview", "passed": TransformTrace.translation == .zero && !TransformTrace.manipulating && model.runtime.writes.isEmpty])
        event(.leftMouseUp, NSPoint(x: start.x + 60, y: start.y))
        try await Task.sleep(for: .milliseconds(100))
        model.armed = true
        try await Task.sleep(for: .milliseconds(100))
        event(.leftMouseDown, start)
        try await Task.sleep(for: .milliseconds(30))
        for offset in stride(from: 10, through: 40, by: 10) {
            event(.leftMouseDragged, NSPoint(x: start.x + CGFloat(offset), y: start.y))
            try await Task.sleep(for: .milliseconds(30))
        }
        model.displayID = 2
        try await Task.sleep(for: .milliseconds(150))
        event(.leftMouseDragged, NSPoint(x: start.x + 50, y: start.y))
        try await Task.sleep(for: .milliseconds(50))
        checks.append(["action": "web-screen-switch-resets-preview", "passed": TransformTrace.translation == .zero && !TransformTrace.manipulating && model.runtime.writes.isEmpty])
        event(.leftMouseUp, NSPoint(x: start.x + 40, y: start.y))
        try await Task.sleep(for: .milliseconds(100))
        checks.append(["action": "web-no-cross-screen-commit", "passed": model.runtime.writes.isEmpty])
        event(.leftMouseDown, start)
        try await Task.sleep(for: .milliseconds(30))
        for offset in stride(from: 10, through: 40, by: 10) {
            event(.leftMouseDragged, NSPoint(x: start.x + CGFloat(offset), y: start.y))
            try await Task.sleep(for: .milliseconds(30))
        }
        event(.leftMouseUp, NSPoint(x: start.x + 40, y: start.y))
        try await Task.sleep(for: .milliseconds(150))
        checks.append(["action": "web-next-gesture-commits-once", "passed": model.runtime.writes.count == 1 && abs(model.html.transformTranslateX - 96) < 1 && TransformTrace.translation == .zero && !TransformTrace.manipulating])
    } else if mode == "timeline" {
        try await drag(NSPoint(x: 144, y: 598), dx: 60, name: "translate")
        checks.append(["action": "translate-two-hours", "passed": model.timeCommits.last == [4, 8]])
        try await drag(NSPoint(x: 24 + 4 * 30 + 3, y: 598), dx: -30, name: "leading-edge")
        checks.append(["action": "leading-edge-one-hour", "passed": model.timeCommits.last == [3, 8]])
        try await drag(NSPoint(x: 24 + 8 * 30 - 3, y: 598), dx: 30, name: "trailing-edge")
        checks.append(["action": "trailing-edge-one-hour", "passed": model.timeCommits.last == [3, 9]])
    } else {
        for index in 0 ..< 4 {
            model.stored = 360; model.live = nil; model.visible = true
            if index == 1, let p = schema.properties.first(where: { $0.type == .bool }) { scene.values[p.key] = .bool(!(scene.values[p.key]?.boolValue ?? false)) }
            if index == 2 { scene.expanded = [] }
            if index == 3 { model.visible = false; try await Task.sleep(for: .milliseconds(400)); model.visible = true }
            try await Task.sleep(for: .milliseconds(400))
            let commits = model.commits
            try await drag(NSPoint(x: host.bounds.width - 360, y: 360), dx: -80, name: ["initial", "changed-option", "collapsed-groups", "reopened"][index])
            checks.append(["action": "resize-\(index)", "passed": abs(model.stored - 440) < 2 && model.live == nil && model.commits == commits + 1])
        }
        model.stored = 360; model.live = nil
        try await Task.sleep(for: .milliseconds(250))
        try await drag(NSPoint(x: host.bounds.width - 360, y: 360), dx: 320, name: "drag-close")
        checks.append(["action": "drag-close", "passed": !model.visible && model.closes == 1 && model.live == nil])
    }
    let output: [String: Any] = ["variant": variant, "mode": mode, "project": url.path, "properties": schema.properties.count, "thermalBefore": thermalStart, "thermalAfter": ProcessInfo.processInfo.thermalState.rawValue, "checks": checks, "phases": phases]
    try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arg("output", "/private/tmp/interaction.json")))
    print("checks \(checks.count), failed \(checks.filter { ($0["passed"] as? Bool) != true }.count)")
    if let hold = Double(arg("hold", "0")), hold > 0 { try await Task.sleep(for: .seconds(hold)) }
    NSApp.terminate(nil)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
Task { @MainActor in
    do { try await run() } catch { print(error); exit(1) }
}
app.run()
