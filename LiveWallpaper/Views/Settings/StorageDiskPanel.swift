#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct StorageDiskItem: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let bytes: UInt64
    let color: Color
    var searchTitles: [LocalizedStringKey] = []
    var icon: String = "folder"
    var url: URL?
    var scopeRootURL: URL?
    var canRevealInFinder: Bool = true
    var canClear: Bool = false
    var status: AppStorageMeasurement.Status = .complete
    var detail: LocalizedStringKey?
    var measurement: AppStorageMeasurement?

    func matchesSearchKey(_ key: String) -> Bool {
        let titleKey = LocalizedStringKey(key)
        return title == titleKey || searchTitles.contains(titleKey)
    }

    func searchTitle(matching marks: SettingsSearchMarks?) -> LocalizedStringKey {
        marks?.rows.first(where: matchesSearchKey).map { LocalizedStringKey($0) } ?? title
    }

    static func summaryStatus(
        inventoryIncomplete: Bool,
        componentStatuses: [AppStorageMeasurement.Status],
        unresolvedSources: Int
    ) -> AppStorageMeasurement.Status {
        // `.missing` is a location with no files yet, so it leaves the sum exact.
        let incomplete = inventoryIncomplete || unresolvedSources > 0
            || componentStatuses.contains { $0 == .partial || $0 == .unavailable }
        return incomplete ? .partial : .complete
    }

    static func abbreviatingHome(_ path: String, home: String) -> String {
        if path == home {
            return "~"
        }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Drops rows measured as empty; a size that is unknown (`.unavailable`, `.partial`) is not zero.
    static func listed(_ items: [StorageDiskItem]) -> [StorageDiskItem] {
        items.filter { $0.bytes > 0 || $0.status == .partial || $0.status == .unavailable }
    }
}

/// Settings search marks are injected inside the Form, below the page view that builds the rows.
struct StorageSearchTitleReader<Content: View>: View {
    let item: StorageDiskItem
    @ViewBuilder let content: (LocalizedStringKey) -> Content
    @Environment(\.settingsSearchMarks) private var marks

    var body: some View {
        content(item.searchTitle(matching: marks))
    }
}

/// Fractions remain proportional even for tiny categories.
struct StorageDiskSlice: Identifiable {
    let id: String
    let start: Double
    let end: Double

    static func partition(_ items: [StorageDiskItem]) -> [StorageDiskSlice] {
        let total = items.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0 else { return [] }
        var cursor = 0.0
        return items.filter { $0.bytes > 0 }.map { item in
            let start = cursor
            cursor += Double(item.bytes) / total
            return StorageDiskSlice(id: item.id, start: start, end: min(1, cursor))
        }
    }
}

private struct StorageDiskWedge: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let inner = radius * 0.84
        let first = Angle.degrees(start * 360 - 90)
        let last = Angle.degrees(min(start + 0.99999, end) * 360 - 90)
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: first, endAngle: last, clockwise: false)
        path.addLine(to: CGPoint(x: center.x + inner * cos(last.radians), y: center.y + inner * sin(last.radians)))
        path.addArc(center: center, radius: inner, startAngle: last, endAngle: first, clockwise: true)
        path.closeSubpath()
        return path
    }
}

struct StorageRingSpec: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let items: [StorageDiskItem]

    var isTotalPartial: Bool {
        StorageDiskItem.summaryStatus(
            inventoryIncomplete: false, componentStatuses: items.map(\.status), unresolvedSources: 0
        ) == .partial
    }

    /// Non-empty items, largest first: the ring's slices and the legend rows, in that order.
    var legend: [StorageDiskItem] {
        items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }
}

private struct StorageDonutRing: View {
    let title: LocalizedStringKey
    let items: [StorageDiskItem]
    let total: UInt64
    /// Includes zero-byte items, which `items` leaves out.
    let isTotalPartial: Bool
    let isLoading: Bool
    let formatBytes: (UInt64) -> String
    @Binding var hoveredItemID: String?
    @Binding var selectedItemID: String?

    private var activeItem: StorageDiskItem? {
        items.first { $0.id == hoveredItemID } ?? items.first { $0.id == selectedItemID }
    }

    var body: some View {
        ZStack {
            StorageDiskWedge(start: 0, end: 1)
                .fill(DesignTokens.Colors.textTertiary.opacity(DesignTokens.Opacity.hoverFill))

            ForEach(StorageDiskSlice.partition(items)) { slice in
                if let item = items.first(where: { $0.id == slice.id }) {
                    let isSelected = selectedItemID == item.id
                    let isHighlighted = hoveredItemID == item.id || (hoveredItemID == nil && isSelected)
                    let opacity = isHighlighted ? 1.0 : (hoveredItemID != nil ? DesignTokens.Opacity.fadedSegment : DesignTokens.Opacity.restingSegment)
                    let wedge = StorageDiskWedge(start: slice.start, end: slice.end)

                    Button {
                        selectedItemID = (selectedItemID == item.id ? nil : item.id)
                    } label: {
                        wedge.fill(item.color.opacity(opacity))
                            .overlay(wedge.stroke(DesignTokens.Colors.surfaceRaised, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .contentShape(wedge)
                    .settledHover { isHov in
                        hoveredItemID = isHov ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
                    }
                    .help(Text(item.title) + Text(verbatim: " · " + formatBytes(item.bytes)))
                    .accessibilityLabel(Text(item.title))
                    .accessibilityValue(Text(verbatim: formatBytes(item.bytes)))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            VStack(spacing: DesignTokens.Spacing.xxs) {
                if isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(Text("Calculating storage footprint…"))
                } else if let activeItem {
                    Text(verbatim: (activeItem.status == .partial ? "≥ " : "") + formatBytes(activeItem.bytes))
                        .font(DesignTokens.Typography.bodyEmphasized)
                        .monospacedDigit()
                    Text(activeItem.title)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(1)
                    Text(verbatim: (total > 0 ? Double(activeItem.bytes) / Double(total) : 0).formatted(.percent.precision(.fractionLength(1))))
                        .font(DesignTokens.Typography.badge)
                        .foregroundStyle(activeItem.color)
                } else {
                    Text(verbatim: (isTotalPartial ? "≥ " : "") + formatBytes(total))
                        .font(DesignTokens.Typography.pageTitle)
                        .monospacedDigit()
                    Text(title)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            .minimumScaleFactor(0.7)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .allowsHitTesting(false)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A ring beside a legend that names each of its slices in full.
private struct StorageLegendRing: View {
    let spec: StorageRingSpec
    let isLoading: Bool
    let formatBytes: (UInt64) -> String
    @Binding var hoveredItemID: String?
    @Binding var selectedItemID: String?

    private static let diameter: CGFloat = 128

    var body: some View {
        let legend = spec.legend
        HStack(spacing: DesignTokens.Spacing.lg) {
            StorageDonutRing(title: spec.title, items: legend, total: spec.items.reduce(0) { $0 + $1.bytes },
                             isTotalPartial: spec.isTotalPartial, isLoading: isLoading,
                             formatBytes: formatBytes, hoveredItemID: $hoveredItemID, selectedItemID: $selectedItemID)
                .frame(width: Self.diameter, height: Self.diameter)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                if !isLoading {
                    ForEach(legend) { legendRow($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendRow(_ item: StorageDiskItem) -> some View {
        let isActive = hoveredItemID == item.id || selectedItemID == item.id
        return Button {
            selectedItemID = (selectedItemID == item.id ? nil : item.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                Text(Image(systemName: "circle.fill"))
                    .foregroundStyle(item.color)
                    .imageScale(.small)
                Text(item.title)
                    .foregroundStyle(isActive ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: DesignTokens.Spacing.sm)
                Text(verbatim: formatBytes(item.bytes))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(DesignTokens.Typography.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settledHover { isHov in
            hoveredItemID = isHov ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
        }
        .help(Text(item.title))
        .accessibilityLabel(Text(item.title))
        .accessibilityValue(Text(verbatim: formatBytes(item.bytes)))
        .accessibilityAddTraits(selectedItemID == item.id ? .isSelected : [])
    }
}

struct StorageRingsCard: View {
    let rings: [StorageRingSpec]
    let isLoading: Bool
    let formatBytes: (UInt64) -> String
    @Binding var hoveredItemID: String?
    @Binding var selectedItemID: String?

    var body: some View {
        GroupBox {
            HStack(spacing: DesignTokens.Spacing.md) {
                ForEach(Array(rings.enumerated()), id: \.element.id) { index, spec in
                    if index > 0 {
                        Divider()
                    }
                    StorageLegendRing(spec: spec, isLoading: isLoading, formatBytes: formatBytes,
                                      hoveredItemID: $hoveredItemID, selectedItemID: $selectedItemID)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
}
#endif
