import AppKit
import Foundation
import LiveWallpaperCore
import SwiftUI

enum StatusCapsuleHealth: Equatable {
    case normal, elevatedLoad, highLoad, thermalFair, thermalSerious, thermalCritical
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
    static func health(cpuPercent: Double, memoryFraction: Double, thermal: ProcessInfo.ThermalState) -> StatusCapsuleHealth {
        let load = max(cpuPercent / 100, memoryFraction)
        switch thermal {
        case .critical: return .thermalCritical
        case .serious: return .thermalSerious
        default: break
        }
        if load >= Design.Load.hot {
            return .highLoad
        }
        if thermal == .fair {
            return .thermalFair
        }
        return load >= Design.Load.elevated ? .elevatedLoad : .normal
    }

    static func headlineKey(for health: StatusCapsuleHealth) -> String {
        switch health {
        case .normal: "System Normal"
        case .elevatedLoad: "Elevated Load"
        case .highLoad: "High Load"
        case .thermalFair: "Running Warm"
        case .thermalSerious: "Running Hot"
        case .thermalCritical: "Critical Heat"
        }
    }

    static func dotColor(for health: StatusCapsuleHealth) -> Color {
        switch health {
        case .normal: DesignTokens.EditDesk.Colors.success
        case .elevatedLoad, .thermalFair: DesignTokens.EditDesk.Colors.warning
        case .highLoad, .thermalSerious, .thermalCritical: DesignTokens.EditDesk.Colors.danger
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

    /// Displays that keep a wallpaper render it only while the master switch is on.
    static func renderingCount(configured: Int, wallpapersEnabled: Bool) -> Int {
        wallpapersEnabled ? configured : 0
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
    let renderingScreenCount: Int
    let batterySaverOn: Bool

    private static let dialSize: CGFloat = 52
    /// Four dials plus their gaps and the panel padding; right-anchored, so it stays in the window.
    private static let panelWidth: CGFloat = 4 * dialSize + 3 * 8 + 20

    @State private var isExpanded = false
    @State private var panelFrame: CGRect = .zero
    @State private var capsuleFrame: CGRect = .zero
    @FocusState private var panelFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var monitor: SystemMonitor {
        SystemMonitor.shared
    }

    private var health: StatusCapsuleHealth {
        StatusCapsuleModel.health(
            cpuPercent: monitor.systemCpuUsage,
            memoryFraction: monitor.systemMemoryUsage,
            thermal: monitor.thermalState
        )
    }

    var body: some View {
        contentView
            .onAppear { SystemMonitor.shared.startMonitoring() }
            .onDisappear { SystemMonitor.shared.stopMonitoring() }
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
    }

    private var collapsedCapsule: some View {
        Button {
            withAnimation(expansionAnimation) { isExpanded.toggle() }
        } label: {
            headlineRow(showsChevron: true)
                .padding(.horizontal, 10)
                .frame(width: 118, height: 28)
                .background(Capsule().fill(DesignTokens.EditDesk.Colors.panel))
                .overlay(Capsule().strokeBorder(DesignTokens.EditDesk.Colors.strokePanel, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.EditDesk.Spacing.s8) {
            // The panel covers the trigger, so its own headline carries the way back: the chevron
            // is the only affordance still on screen once the dials are up.
            Button(action: collapse) {
                headlineRow(showsChevron: true)
            }
            .buttonStyle(.plain)
            HStack(alignment: .top, spacing: DesignTokens.EditDesk.Spacing.s8) {
                dial("CPU", fraction: monitor.systemCpuUsage / 100) {
                    Text(verbatim: percentText(monitor.systemCpuUsage))
                }
                if let gpu = monitor.gpuUsage {
                    dial("GPU", fraction: gpu / 100) { Text(verbatim: percentText(gpu)) }
                }
                dial("MEM", fraction: monitor.systemMemoryUsage) {
                    Text(verbatim: percentText(monitor.systemMemoryUsage * 100))
                }
                dial("TEMP", fraction: StatusCapsuleModel.thermalBarFraction(monitor.thermalState)) {
                    Image(systemName: "thermometer.medium")
                        .accessibilityLabel(Text(LocalizedStringKey(StatusCapsuleModel.thermalLabelKey(monitor.thermalState))))
                }
            }
            Rectangle()
                .fill(DesignTokens.EditDesk.Colors.strokePanel)
                .frame(height: 1)
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

    private func headlineRow(showsChevron: Bool) -> some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            Circle()
                .fill(StatusCapsuleModel.dotColor(for: health))
                .frame(width: 7, height: 7)
                .shadow(color: StatusCapsuleModel.dotColor(for: health).opacity(0.8), radius: 3)
            Text(LocalizedStringKey(StatusCapsuleModel.headlineKey(for: health)))
                .font(DesignTokens.EditDesk.Typography.metaMono)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textCapsule)
            if showsChevron {
                Spacer(minLength: DesignTokens.EditDesk.Spacing.s8)
                Text(verbatim: isExpanded ? "︿" : "⌄")
                    .font(DesignTokens.EditDesk.Typography.metaMono)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textCapsule)
                    .opacity(0.5)
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
                .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private static func dialColor(_ fraction: Double) -> Color {
        if fraction >= Design.Load.hot {
            return DesignTokens.Colors.Gauge.high
        }
        return fraction >= Design.Load.elevated ? DesignTokens.Colors.Gauge.medium : DesignTokens.Colors.Gauge.low
    }

    private var footerRow: some View {
        HStack(spacing: 4) {
            Text("\(renderingScreenCount) Displays Rendering")
            Text(verbatim: "·")
            Text(batterySaverOn ? "Power Saver" : "Performance")
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(DesignTokens.EditDesk.Typography.metaMono)
        .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
    }

    private func percentText(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
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
