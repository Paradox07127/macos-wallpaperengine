import Foundation
import LiveWallpaperCore
import SwiftUI

enum StatusCapsuleHealth: Equatable {
    case normal, elevated, hot
}

/// Pure headline/dot/thermal mapping — kept static so tests drive it without `SystemMonitor`.
enum StatusCapsuleModel {
    static func health(cpuPercent: Double, memoryFraction: Double, thermal: ProcessInfo.ThermalState) -> StatusCapsuleHealth {
        let cpuFraction = cpuPercent / 100
        let isHot = cpuFraction >= Design.Load.hot || memoryFraction >= Design.Load.hot
            || thermal == .serious || thermal == .critical
        if isHot {
            return .hot
        }
        let isElevated = cpuFraction >= Design.Load.elevated || memoryFraction >= Design.Load.elevated || thermal == .fair
        return isElevated ? .elevated : .normal
    }

    static func headlineKey(for health: StatusCapsuleHealth) -> String {
        switch health {
        case .normal: "System Normal"
        case .elevated: "System Elevated"
        case .hot: "System Overheating"
        }
    }

    static func dotColor(for health: StatusCapsuleHealth) -> Color {
        switch health {
        case .normal: DesignTokens.EditDesk.Colors.success
        case .elevated: DesignTokens.EditDesk.Colors.warning
        case .hot: DesignTokens.EditDesk.Colors.danger
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
    let onOpenPerformanceSettings: () -> Void

    private static let dialSize: CGFloat = 52
    /// Four dials plus their gaps and the panel padding; right-anchored, so it stays in the window.
    private static let panelWidth: CGFloat = 4 * dialSize + 3 * 8 + 20

    @State private var isExpanded = false
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
                .overlay(alignment: .topTrailing) {
                    if isExpanded {
                        expandedPanel
                            .fixedSize()
                            .alignmentGuide(.top) { $0[.top] }
                            .offset(y: 0)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    }
                }
                .onTapGesture {
                    withAnimation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.82)) {
                        isExpanded.toggle()
                    }
                }
        }
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
        headlineRow(showsChevron: true)
            .padding(.horizontal, 10)
            .frame(width: 118, height: 28)
            .background(Capsule().fill(DesignTokens.EditDesk.Colors.panel))
            .overlay(Capsule().strokeBorder(DesignTokens.EditDesk.Colors.strokePanel, lineWidth: 1))
            .contentShape(Capsule())
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.EditDesk.Spacing.s8) {
            headlineRow(showsChevron: true)
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

    /// Two lines, not one: the summary alone is wider than the four dials above it, so a single
    /// row clipped its own text inside the panel.
    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("\(renderingScreenCount) Displays Rendering")
                Text(verbatim: "·")
                Text(batterySaverOn ? "Power Saver" : "Performance")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Button(action: onOpenPerformanceSettings) {
                Text("Performance Settings →")
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(DesignTokens.EditDesk.Typography.metaMono)
        .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
    }

    private func percentText(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
