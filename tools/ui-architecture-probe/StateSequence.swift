import AppKit
import LiveWallpaperCore
import QuartzCore

/// Same-window state transitions. These exercise presentation bindings, without a render session.
@MainActor func runSceneStateSequence(
    window: NSWindow, scroll: NSScrollView, model: ProbeModel,
    schema: WallpaperEngineProjectPropertySchema
) async throws -> [[String: Any]] {
    typealias Property = WallpaperEngineProjectPropertySchema.Property
    func presentation() -> WPEProjectSettingsPresentation {
        WPEProjectSettingsPresentation(schema: schema, overrides: model.values, excludedKeys: ["schemecolor"])
    }
    func properties() -> [Property] {
        presentation().sections.flatMap(\.properties)
    }
    func rows() -> [Property] {
        presentation().rows(expandedSectionIDs: model.expanded).compactMap {
            if case let .property(property) = $0 {
                return property
            }; return nil
        }
    }
    let defaults = model.values
    let initialExpanded = model.expanded
    /// Pick the visible bool/combo producing the largest change in conditional rows.
    /// This selection runs outside the timed transitions and is saved in the output.
    func choice(_ type: WallpaperEngineProjectPropertySchema.PropertyType) -> (Property, WallpaperEngineProjectPropertyValue)? {
        let baseline = presentation().visibleKeys
        var best: (Property, WallpaperEngineProjectPropertyValue)?
        var largest = -1
        for property in properties() where property.type == type {
            let alternatives: [WallpaperEngineProjectPropertyValue] = type == .bool
                ? [.bool(!(model.values[property.key]?.boolValue ?? false))]
                : property.options.map(\.value).filter { $0 != model.values[property.key] }
            for value in alternatives {
                var overrides = model.values; overrides[property.key] = value
                let next = WPEProjectSettingsPresentation(schema: schema, overrides: overrides, excludedKeys: ["schemecolor"])
                let delta = baseline.symmetricDifference(next.visibleKeys).count
                if delta > largest {
                    largest = delta; best = (property, value)
                }
            }
        }
        return best
    }
    let boolChoice = choice(.bool)
    let comboChoice = choice(.combo)
    let sliderChoice = properties().first { $0.type == .slider }
    let names = ["initial-scroll", "repeat-scroll", "collapsed-scroll", "reexpanded-scroll",
                 "after-bool-scroll", "after-combo-scroll", "after-slider-scroll", "restored-scroll"]
    let count = max(2, Int(ProbeConfig.arg("steps", "100")) ?? 100)
    var results: [[String: Any]] = []
    for name in names {
        let beforeKeys = rows().map(\.key)
        var changed: [String] = []
        let transitionStart = CACurrentMediaTime()
        switch name {
        case "collapsed-scroll": model.expanded = []
        case "reexpanded-scroll": model.expanded = initialExpanded
        case "after-bool-scroll":
            if let (property, value) = boolChoice {
                model.values[property.key] = value; changed = [property.key]
            }
        case "after-combo-scroll":
            if let (property, value) = comboChoice {
                model.values[property.key] = value; changed = [property.key]
            }
        case "after-slider-scroll":
            if let property = sliderChoice {
                let range = PropertyValueLogic.sliderRange(for: property)
                let old = model.values[property.key]?.numberValue ?? range.lowerBound
                model.binding(property).wrappedValue = old == range.upperBound ? range.lowerBound : range.upperBound
                changed = [property.key]
            }
        case "restored-scroll": model.values = defaults; model.expanded = initialExpanded
        default: break
        }
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        let transitionSubmissionMs = (CACurrentMediaTime() - transitionStart) * 1000
        // SwiftUI may schedule updates for a subsequent run-loop turn.
        try await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        let phaseProperties = rows()
        let phaseCPU = usage().0
        var samples: [Double] = []
        var positions: [Double] = []
        var heights: [Double] = []
        var peak = resident()
        let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        for index in 0 ..< count {
            let begin = CACurrentMediaTime()
            autoreleasepool {
                let height = scroll.documentView?.frame.height ?? 0
                let maxY = max(0, height - scroll.contentSize.height)
                let y = maxY * Double(index) / Double(count - 1)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                positions.append(scroll.contentView.bounds.origin.y)
                heights.append(height)
            }
            samples.append((CACurrentMediaTime() - begin) * 1000)
            peak = max(peak, resident())
            try await Task.sleep(for: .milliseconds(16))
        }
        results.append([
            "phase": name, "changedKeys": changed,
            "conditionalVisibleKeys": presentation().visibleKeys.sorted(),
            "displayedPropertyKeys": phaseProperties.map(\.key),
            "previousDisplayedPropertyKeys": beforeKeys,
            "controlTypes": Dictionary(grouping: phaseProperties, by: { String(describing: $0.type) }).mapValues(\.count),
            "expandedSections": model.expanded.sorted(), "sectionIDs": presentation().sections.map(\.id),
            "valuesDescription": model.values.mapValues { String(describing: $0) },
            "transitionSubmissionMs": transitionSubmissionMs,
            "transitionIncludesDeferredUpdates": false,
            "samples": samples, "positions": positions, "documentHeights": heights,
            "layoutDisplayMs": ["p50": quantile(samples, 0.5), "p95": quantile(samples, 0.95), "p99": quantile(samples, 0.99)],
            "cpuSeconds": usage().0 - phaseCPU, "rssPeakSampled": peak,
            "thermalStart": thermalStart, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
            "nativeSlidersMaterializedAtEnd": window.contentView.map { allViews($0).filter { $0 is NSSlider }.count } ?? 0,
        ])
    }
    return results
}
