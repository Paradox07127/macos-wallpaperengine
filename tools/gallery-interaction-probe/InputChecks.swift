import AppKit

// Coordinates are in this probe's fixed 960×720 content layout, verified against
// ScreenCaptureKit captures. Events go only to the probe's own window.
@MainActor func runInputChecks(window: NSWindow, model: Model) async throws -> [[String: Any]] {
    try await Task.sleep(for: .seconds(2))
    var results: [[String: Any]] = []
    func click(_ point: NSPoint) async throws {
        let now = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: now, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: now + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        try await Task.sleep(for: .milliseconds(300))
    }
    try await click(NSPoint(x: 406, y: 692))
    results.append(["action": "filter", "passed": model.filter])
    try await click(NSPoint(x: 406, y: 692))
    results.append(["action": "clear-filter", "passed": !model.filter])
    try await click(NSPoint(x: 500, y: 692))
    results.append(["action": "leave", "passed": !model.visible])
    try await click(NSPoint(x: 500, y: 692))
    results.append(["action": "return", "passed": model.visible])
    if ["bookmarks", "schemes", "mixed"].contains(model.mode) {
        try await click(NSPoint(x: 612, y: 692))
        results.append(["action": "rename", "passed": model.renaming == 0])
        try await click(NSPoint(x: 612, y: 692))
        results.append(["action": "close-rename", "passed": model.renaming == nil])
    }
    let before = NSApp.windows.filter(\.isVisible).count
    try await click(NSPoint(x: 454, y: 453))
    let after = NSApp.windows.filter(\.isVisible).count
    if model.mode == "candidates" {
        results.append(["action": "select-card", "passed": model.selected == 0])
    } else if model.mode == "system" {
        results.append(["action": "card-menu", "windowCountIncreased": after > before,
                        "needsCompositedVerification": true, "windowsBefore": before, "windowsAfter": after])
    } else {
        results.append(["action": "card-menu", "passed": after > before, "windowsBefore": before, "windowsAfter": after])
    }
    return results
}
