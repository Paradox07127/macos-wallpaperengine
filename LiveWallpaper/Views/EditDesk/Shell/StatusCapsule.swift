import AppKit
import Foundation
import LiveWallpaperCore
import SwiftUI

enum StatusCapsuleHealth: Equatable {
    case noReadings, normal, elevatedLoad, highLoad, memoryWarning, memoryCritical, thermalFair, thermalSerious, thermalCritical
}

enum StatusCapsuleFooterLabel: Equatable {
    case wallpapersOff
    case displaysConfigured(Int)
    case pausesOnBattery
}

/// The sentence beside the headline: which reading set it, whether that reading is the whole system's, and whether to act.
enum StatusCapsuleNote: Equatable {
    case waitingForReadings
    case normal
    /// The kernel reports memory pressure; `appBytes` is this app's own footprint.
    case lowMemory(appBytes: UInt64)
    /// Both in percent of the whole machine, as `SystemMonitor` reports them.
    case systemCPU(percent: Double, appPercent: Double, suggestsAction: Bool)
    case heat(ProcessInfo.ThermalState)
}

/// AppKit reports a click in window coordinates — y up from the content view's bottom edge —
/// while SwiftUI measures the panel down from its own top. The flip lives here so it is testable.
enum StatusCapsuleDismissal {
    static func windowRect(fromTop frame: CGRect, windowHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: windowHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The trigger is excluded alongside the panel: dismissing on it would race the button's own
    /// toggle and reopen the panel the user meant to close.
    static func shouldDismiss(
        clickInWindow: CGPoint,
        panelFrameFromTop: CGRect,
        capsuleFrameFromTop: CGRect,
        windowHeight: CGFloat
    ) -> Bool {
        ![panelFrameFromTop, capsuleFrameFromTop].contains {
            windowRect(fromTop: $0, windowHeight: windowHeight).contains(clickInWindow)
        }
    }
}

/// Pure headline/dot/thermal mapping — kept static so tests drive it without `SystemMonitor`.
enum StatusCapsuleModel {
    /// Memory occupancy only gates the first sample; the kernel's pressure level is what says memory is short.
    static func health(
        cpuPercent: Double, memoryFraction: Double, memoryPressure: SystemMemoryPressureLevel, thermal: ProcessInfo.ThermalState
    ) -> StatusCapsuleHealth {
        let load = cpuPercent / 100
        switch thermal {
        case .critical: return .thermalCritical
        case .serious: return .thermalSerious
        default: break
        }
        // Memory reads 0 until `SystemMonitor`'s first sample; a running Mac never uses none.
        guard memoryFraction > 0 else { return .noReadings }
        switch memoryPressure {
        case .critical: return .memoryCritical
        case .warning: return .memoryWarning
        case .normal: break
        }
        if load >= Design.Load.hot {
            return .highLoad
        }
        if thermal == .fair {
            return .thermalFair
        }
        return load >= Design.Load.elevated ? .elevatedLoad : .normal
    }

    static func note(
        cpuPercent: Double, memoryFraction: Double, memoryPressure: SystemMemoryPressureLevel, thermal: ProcessInfo.ThermalState,
        appCPUPercent: Double, appMemoryBytes: UInt64
    ) -> StatusCapsuleNote {
        let band = Self.health(
            cpuPercent: cpuPercent, memoryFraction: memoryFraction, memoryPressure: memoryPressure, thermal: thermal
        )
        switch band {
        case .noReadings:
            return .waitingForReadings
        case .normal:
            return .normal
        case .thermalFair, .thermalSerious, .thermalCritical:
            return .heat(thermal)
        case .memoryWarning, .memoryCritical:
            return .lowMemory(appBytes: appMemoryBytes)
        case .elevatedLoad, .highLoad:
            return .systemCPU(percent: cpuPercent, appPercent: appCPUPercent, suggestsAction: band == .highLoad)
        }
    }

    static func headlineKey(for health: StatusCapsuleHealth) -> String {
        switch health {
        case .noReadings: "Waiting for readings"
        case .normal: "System Normal"
        case .elevatedLoad: "Elevated Load"
        case .highLoad: "High Load"
        case .memoryWarning: "Low Memory"
        case .memoryCritical: "Critical Memory"
        case .thermalFair: "Running Warm"
        case .thermalSerious: "Running Hot"
        case .thermalCritical: "Critical Heat"
        }
    }

    static func dotColor(for health: StatusCapsuleHealth) -> Color {
        switch health {
        case .noReadings: DesignTokens.EditDesk.Colors.textTertiary
        case .normal: DesignTokens.EditDesk.Colors.success
        case .elevatedLoad, .memoryWarning, .thermalFair: DesignTokens.EditDesk.Colors.warning
        case .highLoad, .memoryCritical, .thermalSerious, .thermalCritical: DesignTokens.EditDesk.Colors.danger
        }
    }

    static func thermalLabelKey(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Thermal Nominal"
        case .fair: return "Thermal Fair"
        case .serious: return "Thermal Serious"
        case .critical: return "Thermal Critical"
        @unknown default: return "Thermal Nominal"
        }
    }

    /// `pausesOnBattery` is the user's preference, not a claim that playback is paused right now.
    static func footerLabels(configured: Int, wallpapersEnabled: Bool, pausesOnBattery: Bool) -> [StatusCapsuleFooterLabel] {
        var labels: [StatusCapsuleFooterLabel] = [wallpapersEnabled ? .displaysConfigured(configured) : .wallpapersOff]
        if pausesOnBattery {
            labels.append(.pausesOnBattery)
        }
        return labels
    }

    /// SF Symbols has no zero- or three-screen variant: 0 shares the single screen, 3+ the pair.
    static func displaysSymbol(count: Int) -> String {
        count >= 2 ? "display.2" : "display"
    }

    /// `scope` is `RAMScopePicker`'s value: "app" reads this process, anything else the whole system.
    static func memoryReadout(
        scope: String, systemFraction: Double, appBytes: UInt64, totalBytes: UInt64
    ) -> (fraction: Double, text: String) {
        let total = FormatUtils.formatBytes(totalBytes)
        if scope == "app" {
            // `SystemMonitor` reports 0 total until its first sample.
            let fraction = totalBytes > 0 ? Double(appBytes) / Double(totalBytes) : 0
            return (fraction, "\(FormatUtils.formatBytes(appBytes)) / \(total)")
        }
        let used = UInt64(Double(totalBytes) * systemFraction)
        return (systemFraction, "\(FormatUtils.formatBytes(used)) / \(total)")
    }

    static func scopeLabelKey(for scope: String) -> String {
        scope == "app" ? "App" : "System"
    }

    /// Only CPU and memory have a per-process reading; health is judged on the system's either way.
    static func cpuReadout(scope: String, systemPercent: Double, appPercent: Double) -> Double {
        scope == "app" ? appPercent : systemPercent
    }

    /// nil on external power: the footer names the battery only while the Mac runs on it.
    static func batteryReadout(_ source: PowerMonitor.PowerSource) -> (symbol: String, text: String)? {
        guard case let .battery(level) = source else { return nil }
        return (source.iconName, FormatUtils.formatFractionAsPercent(level))
    }

    /// SCREENS S1: TEMP bar fills in four fixed steps, one per thermal state.
    static func thermalBarFraction(_ state: ProcessInfo.ThermalState) -> Double {
        switch state {
        case .nominal: return 0.25
        case .fair: return 0.5
        case .serious: return 0.75
        case .critical: return 1
        @unknown default: return 0.25
        }
    }
}

struct StatusCapsule: View {
    let content: StatusCapsuleContent
    let footerLabels: [StatusCapsuleFooterLabel]
    /// Read whenever the `SystemMonitor` readings redraw the capsule; the source is not observable.
    let memoryPressure: () -> SystemMemoryPressureLevel

    private static let dialSize: CGFloat = 52
    /// Four dials plus their gaps and the panel padding; right-anchored, so it stays in the window.
    private static let panelWidth: CGFloat = 4 * dialSize + 3 * 8 + 20

    @State private var isExpanded = false
    @State private var panelFrame: CGRect = .zero
    @State private var capsuleFrame: CGRect = .zero
    @FocusState private var panelFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("Dashboard.RAMScope", store: .appScoped()) private var ramScope = "system"
    @State private var powerSource = PowerMonitor.shared.currentPowerSource

    private var monitor: SystemMonitor {
        SystemMonitor.shared
    }

    private var health: StatusCapsuleHealth {
        StatusCapsuleModel.health(
            cpuPercent: monitor.systemCpuUsage,
            memoryFraction: monitor.systemMemoryUsage,
            memoryPressure: memoryPressure(),
            thermal: monitor.thermalState
        )
    }

    private var note: StatusCapsuleNote {
        StatusCapsuleModel.note(
            cpuPercent: monitor.systemCpuUsage,
            memoryFraction: monitor.systemMemoryUsage,
            memoryPressure: memoryPressure(),
            thermal: monitor.thermalState,
            appCPUPercent: monitor.cpuUsage,
            appMemoryBytes: monitor.memoryUsage
        )
    }

    private var memory: (fraction: Double, text: String) {
        StatusCapsuleModel.memoryReadout(
            scope: ramScope, systemFraction: monitor.systemMemoryUsage,
            appBytes: monitor.memoryUsage, totalBytes: monitor.totalMemory
        )
    }

    private var cpuPercent: Double {
        StatusCapsuleModel.cpuReadout(scope: ramScope, systemPercent: monitor.systemCpuUsage, appPercent: monitor.cpuUsage)
    }

    var body: some View {
        contentView
            .onReceive(NotificationCenter.default.publisher(for: PowerMonitor.powerSourceDidChangeNotification)) { notification in
                if let source = notification.userInfo?["newSource"] as? PowerMonitor.PowerSource {
                    powerSource = source
                }
            }
    }

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case .hidden:
            EmptyView()
        case .wallpapersOnly:
            wallpapersOnlyPanel
        case .systemHealth:
            // The capsule keeps its slot in the top bar and the panel hangs off it as an overlay:
            // swapping them in place shoves the search field and pushes the panel off a small window.
            collapsedCapsule
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { capsuleFrame = $0 })
                .overlay(alignment: .topTrailing) {
                    if isExpanded {
                        expandedPanel
                            .fixedSize()
                            .alignmentGuide(.top) { $0[.top] }
                            .offset(y: 0)
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { panelFrame = $0 })
                            // Focused so Escape reaches it at all: a click does not move macOS
                            // keyboard focus, and `onKeyPress` only fires for the focused subtree.
                            .focusable()
                            .focusEffectDisabled()
                            .focused($panelFocused)
                            .onKeyPress(.escape) {
                                collapse()
                                return .handled
                            }
                            .onAppear { panelFocused = true }
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    }
                }
                .background(StatusPanelDismissMonitor(
                    isExpanded: isExpanded,
                    panelFrame: panelFrame,
                    capsuleFrame: capsuleFrame,
                    dismiss: { collapse() }
                ))
        }
    }

    private var expansionAnimation: Animation {
        reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.82)
    }

    private func collapse() {
        guard isExpanded else { return }
        withAnimation(expansionAnimation) { isExpanded = false }
    }

    private var wallpapersOnlyPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.EditDesk.Spacing.s8) {
            headlineRow(showsChevron: false)
            footerRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, DesignTokens.EditDesk.Spacing.s8)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.statusExpanded, style: .continuous)
                .fill(DesignTokens.EditDesk.Colors.panel)
        )
        .help(noteText)
    }

    private var collapsedCapsule: some View {
        Button {
            withAnimation(expansionAnimation) { isExpanded.toggle() }
        } label: {
            HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
                statusDot
                Text(LocalizedStringKey(StatusCapsuleModel.scopeLabelKey(for: ramScope)))
                    .font(DesignTokens.EditDesk.Typography.metaMono)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.s12)
            .frame(height: DesignTokens.LibraryFilterBar.controlHeight)
            .adaptiveGlassSurface(.capsule, interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(noteText)
        // The dot's colour is the only health cue on screen, so the label has to say it.
        .accessibilityLabel(Text(LocalizedStringKey(StatusCapsuleModel.headlineKey(for: health))))
        .accessibilityValue(noteText)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.EditDesk.Spacing.s8) {
            RAMScopePicker(selection: $ramScope)
            // The panel covers the trigger, so its own headline carries the way back: the chevron
            // is the only affordance still on screen once the dials are up.
            Button(action: collapse) {
                headlineRow(showsChevron: true)
            }
            .buttonStyle(.plain)
            HStack(alignment: .top, spacing: DesignTokens.EditDesk.Spacing.s8) {
                dial("CPU", fraction: cpuPercent / 100) {
                    Text(verbatim: percentText(cpuPercent))
                }
                if let gpu = monitor.gpuUsage {
                    dial("GPU", fraction: gpu / 100) { Text(verbatim: percentText(gpu)) }
                }
                dial("MEM", fraction: memory.fraction) {
                    Text(verbatim: percentText(memory.fraction * 100))
                }
                dial("TEMP", fraction: StatusCapsuleModel.thermalBarFraction(monitor.thermalState)) {
                    Image(systemName: "thermometer.medium")
                        .accessibilityLabel(Text(LocalizedStringKey(StatusCapsuleModel.thermalLabelKey(monitor.thermalState))))
                }
            }
            memoryRow
            footerRow
        }
        .padding(10)
        .frame(width: Self.panelWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.statusExpanded, style: .continuous)
                .fill(DesignTokens.EditDesk.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.statusExpanded, style: .continuous)
                .strokeBorder(DesignTokens.EditDesk.Colors.strokePanel, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.statusExpanded, style: .continuous))
    }

    private var statusDot: some View {
        Circle()
            .fill(StatusCapsuleModel.dotColor(for: health))
            .frame(width: 7, height: 7)
            .shadow(color: StatusCapsuleModel.dotColor(for: health).opacity(0.8), radius: 3)
    }

    private func headlineRow(showsChevron: Bool) -> some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            statusDot
            Text(LocalizedStringKey(StatusCapsuleModel.headlineKey(for: health)))
                .font(DesignTokens.EditDesk.Typography.metaMono)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if showsChevron {
                Spacer(minLength: DesignTokens.EditDesk.Spacing.s8)
                Text(verbatim: "︿")
                    .font(DesignTokens.EditDesk.Typography.metaMono)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
            }
        }
    }

    /// Reuses the Monitor board's gauge so the app has one dial, not two.
    private func dial(_ label: String, fraction: Double, @ViewBuilder readout: () -> some View) -> some View {
        let clamped = min(max(fraction, 0), 1)
        let centre = readout()
        return VStack(spacing: 4) {
            ArcGauge(value: clamped, color: Self.dialColor(clamped), lineWidth: 4) {
                centre
                    .font(DesignTokens.EditDesk.Typography.metaMono)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(width: Self.dialSize, height: Self.dialSize)
            Text(verbatim: label)
                .font(DesignTokens.EditDesk.Typography.metaMono)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private static func dialColor(_ fraction: Double) -> Color {
        if fraction >= Design.Load.hot {
            return DesignTokens.Colors.Gauge.high
        }
        return fraction >= Design.Load.elevated ? DesignTokens.Colors.Gauge.medium : DesignTokens.Colors.Gauge.low
    }

    private var memoryRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "memorychip")
            Text(verbatim: memory.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(DesignTokens.EditDesk.Typography.metaMono)
        .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
    }

    private var footerRow: some View {
        HStack(spacing: 4) {
            ForEach(Array(footerLabels.enumerated()), id: \.offset) { index, label in
                if index > 0 {
                    Text(verbatim: "·")
                }
                footerItem(label)
            }
            if let battery = StatusCapsuleModel.batteryReadout(powerSource) {
                Text(verbatim: "·")
                HStack(spacing: 2) {
                    Image(systemName: battery.symbol)
                    Text(verbatim: battery.text)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(
                    "Battery at \(battery.text)",
                    comment: "Power source accessibility summary. The placeholder is the formatted battery percent."
                ))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        // Also used directly in the toolbar: keep the footer intrinsic so the
        // wallpapers-only panel cannot consume the navigation's width.
        .font(DesignTokens.EditDesk.Typography.metaMono)
        .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
    }

    @ViewBuilder
    private func footerItem(_ label: StatusCapsuleFooterLabel) -> some View {
        switch label {
        case .wallpapersOff: Text("Wallpapers Off")
        case let .displaysConfigured(count):
            HStack(spacing: 2) {
                Image(systemName: StatusCapsuleModel.displaysSymbol(count: count))
                Text(verbatim: "\(count)")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(count) Displays Configured"))
        case .pausesOnBattery: Text("Pauses on Battery")
        }
    }

    private func percentText(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private var noteText: Text {
        switch note {
        case .waitingForReadings:
            return Text("Waiting for the first system readings.")
        case .normal:
            return Text("System CPU, memory and heat are normal. No action needed.")
        case let .lowMemory(appBytes):
            let app = FormatUtils.formatBytes(appBytes)
            return Text("The Mac is low on memory; Loomscreen uses \(app). Quitting apps you are not using frees memory.")
        case let .systemCPU(percent, appPercent, suggestsAction):
            let busy = percentText(percent)
            let app = percentText(appPercent)
            return suggestsAction
                ? Text("System CPU is \(busy) busy; Loomscreen uses \(app). If the Mac slows down, quit apps you are not using.")
                : Text("System CPU is \(busy) busy; Loomscreen uses \(app). No action needed.")
        case .heat(.fair):
            return Text("The Mac is running warm. No action needed.")
        case .heat(.serious):
            return Text("The Mac is running hot. Quitting apps you are not using helps it cool down.")
        case .heat:
            return Text("The Mac is too hot. Wallpapers pause until it cools down.")
        }
    }
}

/// Follows `ShortcutsView`'s `KeyCaptureMonitor`: the coordinator owns the token so `deinit`
/// can drop it from a nonisolated context, and SwiftUI's teardown drops it too.
private struct StatusPanelDismissMonitor: NSViewRepresentable {
    let isExpanded: Bool
    let panelFrame: CGRect
    let capsuleFrame: CGRect
    let dismiss: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context _: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isExpanded, let window = nsView.window else {
            context.coordinator.stop()
            return
        }
        context.coordinator.start(
            in: window, panelFrame: panelFrame, capsuleFrame: capsuleFrame, dismiss: dismiss
        )
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private var clickMonitor: Any?
        private var observers: [any NSObjectProtocol] = []

        func start(
            in window: NSWindow,
            panelFrame: CGRect,
            capsuleFrame: CGRect,
            dismiss: @escaping @MainActor () -> Void
        ) {
            stop()
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                let elsewhere = event.window !== window || StatusCapsuleDismissal.shouldDismiss(
                    clickInWindow: event.locationInWindow,
                    panelFrameFromTop: panelFrame,
                    capsuleFrameFromTop: capsuleFrame,
                    windowHeight: window.contentView?.bounds.height ?? 0
                )
                if elsewhere {
                    dismiss()
                }
                // Handed back untouched: swallowing it would cost the user a second click.
                return event
            }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { dismiss() }
                },
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        // Key may only have moved to another of this app's own panels.
                        if NSApp.keyWindow !== window {
                            dismiss()
                        }
                    }
                },
            ]
        }

        func stop() {
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
                self.clickMonitor = nil
            }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }
}
