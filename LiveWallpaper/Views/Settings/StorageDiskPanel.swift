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

/// Fractions remain proportional even for tiny categories; the menu exposes zero-size items.
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
}

/// One label beside a ring, joined to its segment by a leader line.
struct StorageCallout: Identifiable {
    let id: String
    let isTrailing: Bool
    /// Leader start on the ring's outer edge.
    let anchor: CGPoint
    /// Vertical center of the label in the card.
    let labelY: CGFloat

    /// Places one callout per arc (fractions of a full turn, 0 = 12 o'clock, clockwise) on the arc's side of the ring,
    /// then spreads each side's labels evenly over `height`, top to bottom in the order of their arcs.
    static func layout(arcs: [(id: String, start: Double, end: Double)], center: CGPoint, radius: CGFloat,
                       height: CGFloat) -> [StorageCallout] {
        let placed = arcs.map { arc -> (id: String, trailing: Bool, anchor: CGPoint) in
            let angle = ((arc.start + arc.end) / 2) * 2 * .pi - .pi / 2
            let anchor = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            return (arc.id, cos(angle) >= 0, anchor)
        }
        return [true, false].flatMap { trailing in
            let side = placed.filter { $0.trailing == trailing }.sorted { $0.anchor.y < $1.anchor.y }
            let slot = height / CGFloat(max(side.count, 1))
            return side.enumerated().map { index, callout in
                StorageCallout(id: callout.id, isTrailing: trailing, anchor: callout.anchor,
                               labelY: slot * (CGFloat(index) + 0.5))
            }
        }
    }
}

private struct StorageDonutRing: View {
    let title: LocalizedStringKey
    let items: [StorageDiskItem]
    /// Turn fraction added to every slice, so the layout can choose where the first slice sits.
    let rotation: Double
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
                    let wedge = StorageDiskWedge(start: slice.start + rotation, end: slice.end + rotation)

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

/// A ring with its largest categories labelled on either side; smaller ones fold into "Other Items".
private struct StorageCalloutRing: View {
    let spec: StorageRingSpec
    let isLoading: Bool
    let formatBytes: (UInt64) -> String
    @Binding var hoveredItemID: String?
    @Binding var selectedItemID: String?

    /// Largest categories named beside the ring.
    private static let calloutLimit = 4
    private static let otherID = "storage.other"

    private var ranked: [StorageDiskItem] {
        spec.items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    private var total: UInt64 {
        spec.items.reduce(0) { $0 + $1.bytes }
    }

    /// Centers the largest slice at 3 o'clock so the small slices gather on the left, where their labels stack.
    private var rotation: Double {
        guard let first = StorageDiskSlice.partition(ranked).first else { return 0 }
        return 0.25 - first.end / 2
    }

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.height - DesignTokens.Spacing.sm, proxy.size.width * 0.42)
            let radius = diameter / 2
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let callouts = isLoading ? [] : StorageCallout.layout(
                arcs: arcs, center: center, radius: radius + 2, height: proxy.size.height
            )
            let labelWidth = max(0, proxy.size.width / 2 - radius - 28)

            ZStack(alignment: .topLeading) {
                StorageDonutRing(title: spec.title, items: ranked, rotation: rotation, total: total,
                                 isTotalPartial: spec.items.contains { $0.status == .partial }, isLoading: isLoading,
                                 formatBytes: formatBytes, hoveredItemID: $hoveredItemID, selectedItemID: $selectedItemID)
                    .frame(width: diameter, height: diameter)
                    .position(center)

                ForEach(callouts) { callout in
                    let labelX = center.x + (callout.isTrailing ? 1 : -1) * (radius + 24)
                    let color = color(for: callout.id)
                    let scale = (radius + 8) / (radius + 2)
                    Path { path in
                        path.move(to: callout.anchor)
                        // Leave the ring radially first so the straight run to the label stays outside it.
                        path.addLine(to: CGPoint(x: center.x + (callout.anchor.x - center.x) * scale,
                                                 y: center.y + (callout.anchor.y - center.y) * scale))
                        path.addLine(to: CGPoint(x: labelX - (callout.isTrailing ? 4 : -4), y: callout.labelY))
                    }
                    .stroke(color.opacity(0.7), lineWidth: 1)
                    .allowsHitTesting(false)

                    label(for: callout.id, alignment: callout.isTrailing ? .leading : .trailing)
                        .frame(width: labelWidth, alignment: callout.isTrailing ? .leading : .trailing)
                        .position(x: labelX + (callout.isTrailing ? 1 : -1) * labelWidth / 2, y: callout.labelY)
                }
            }
        }
    }

    private var arcs: [(id: String, start: Double, end: Double)] {
        let slices = StorageDiskSlice.partition(ranked)
        let named = slices.prefix(slices.count > Self.calloutLimit + 1 ? Self.calloutLimit : slices.count)
        var arcs = named.map { (id: $0.id, start: $0.start + rotation, end: $0.end + rotation) }
        if let firstRest = slices.dropFirst(named.count).first {
            arcs.append((id: Self.otherID, start: firstRest.start + rotation, end: 1 + rotation))
        }
        return arcs
    }

    private func color(for id: String) -> Color {
        ranked.first { $0.id == id }?.color ?? DesignTokens.Colors.textTertiary
    }

    @ViewBuilder
    private func label(for id: String, alignment: HorizontalAlignment) -> some View {
        if let item = ranked.first(where: { $0.id == id }) {
            let isActive = hoveredItemID == item.id || selectedItemID == item.id
            Button {
                selectedItemID = (selectedItemID == item.id ? nil : item.id)
            } label: {
                labelText(Text(item.title), bytes: item.bytes, alignment: alignment, isActive: isActive)
            }
            .buttonStyle(.plain)
            .settledHover { isHov in
                hoveredItemID = isHov ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
            }
        } else {
            let named = Set(arcs.map(\.id))
            labelText(Text("Other Items"), bytes: ranked.filter { !named.contains($0.id) }.reduce(0) { $0 + $1.bytes },
                      alignment: alignment, isActive: false)
        }
    }

    private func labelText(_ title: Text, bytes: UInt64, alignment: HorizontalAlignment, isActive: Bool) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            title
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(isActive ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(verbatim: formatBytes(bytes))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
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
            HStack(spacing: 0) {
                ForEach(rings) { spec in
                    StorageCalloutRing(spec: spec, isLoading: isLoading, formatBytes: formatBytes,
                                       hoveredItemID: $hoveredItemID, selectedItemID: $selectedItemID)
                }
            }
            .frame(height: 196)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
}
#endif
