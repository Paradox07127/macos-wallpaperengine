import AppKit
import LiveWallpaperCore
import SwiftUI

/// Midnight is at the top, noon at the bottom; angles are clockwise over a full day.
enum ScheduleDialGeometry {
    /// Nearest half hour, 0..<1440.
    static func minute(at point: CGPoint, center: CGPoint) -> Int {
        Int((fractionalHour(at: point, center: center) * 2).rounded()) * 30 % 1440
    }

    static func fractionalHour(at point: CGPoint, center: CGPoint) -> Double {
        let angle = atan2(point.y - center.y, point.x - center.x) + .pi / 2
        let turn = (angle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        return turn / (2 * .pi) * 24
    }

    static func point(hour: Double, radius: Double, center: CGPoint) -> CGPoint {
        let angle = hour / 24 * 2 * .pi - .pi / 2
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    /// Length in hours.
    static func span(_ slot: ScheduleSlot) -> Double {
        guard slot.startMinute != slot.endMinute else { return 0 }
        let minutes = slot.endMinute > slot.startMinute ? slot.endMinute - slot.startMinute : slot.endMinute + 1440 - slot.startMinute
        return Double(minutes) / 60
    }

    /// Edges after the pointer moves to `minute`: at least 30 minutes long, free to cross midnight, and stopped at a neighbouring slot's edge.
    /// `pointer` is the unwrapped pointer this drag's previous call returned; nil on its first event.
    static func draggedMinutes(_ slot: ScheduleSlot, movingEnd: Bool, pointer: Int?, to minute: Int, among slots: [ScheduleSlot]) -> (start: Int, end: Int, pointer: Int) {
        let start = slot.startMinute
        let length = (slot.endMinute % 1440 - start + 1440) % 1440
        // Unwrapped end, so the movable range below is one contiguous interval even across midnight.
        let end = start + (length == 0 ? 1440 : length)
        let others = slots.filter { $0.id != slot.id && $0.startMinute != $0.endMinute }
        let lo: Int, hi: Int
        if movingEnd {
            let gap = others.map { ($0.startMinute - start + 1440) % 1440 }.filter { $0 > 0 }.min()
            lo = start + 30
            hi = start + (gap ?? 1410)
        } else {
            let gap = others.map { (end - $0.endMinute % 1440 + 1440) % 1440 }.filter { $0 > 0 }.min()
            lo = end - (gap ?? 1410)
            hi = end - 30
        }
        let previous = pointer ?? (movingEnd ? end : start)
        // The dial reports an angle, not a delta: adding the shortest step (-720..<720) keeps the pointer unwrapped,
        // so a clamped edge stays put instead of jumping to the far bound when the pointer passes behind it.
        let moved = previous + ((minute - previous) % 1440 + 2160) % 1440 - 720
        guard lo <= hi else { return (slot.startMinute, slot.endMinute, moved) }
        let clamped = min(max(moved, lo), hi)
        return movingEnd
            ? (start, clamped % 1440 == 0 ? 1440 : clamped % 1440, moved)
            : ((clamped % 1440 + 1440) % 1440, slot.endMinute, moved)
    }

    static func midpoint(_ slot: ScheduleSlot) -> Double {
        (Double(slot.startMinute) / 60 + span(slot) / 2).truncatingRemainder(dividingBy: 24)
    }
}

/// Numbers also identify sections when colors repeat.
enum ScheduleDialStyle {
    static let palette: [Color] = DesignTokens.ScheduleDial.palette

    static func number(_ slot: ScheduleSlot, in slots: [ScheduleSlot]) -> Int {
        (slots.sorted { $0.startMinute < $1.startMinute }.firstIndex { $0.id == slot.id } ?? 0) + 1
    }
}

struct ScheduleDial: View {
    private typealias Metrics = DesignTokens.ScheduleDial

    let slots: [ScheduleSlot]
    let now: Date
    var palette: [Color] = ScheduleDialStyle.palette
    @Binding var selectedID: UUID?
    /// Slot ID, new start minute and new end minute (1440 = ends at midnight).
    let onRetimed: (UUID, Int, Int) -> Void
    /// Minute of the day of the empty spot that was double-clicked.
    let onInsert: (Int) -> Void
    var thumbnail: (ScheduleSlot) -> AnyView = { _ in AnyView(Image(systemName: "photo")) }
    /// Wallpaper named after the time in the center capsule; nil shows the time alone.
    var nowPlayingTitle: String?
    /// Wallpaper of the unscheduled hours, labelled in each long gap; nil hides the labels.
    var fallbackTitle: String?
    @State private var draggedMinutes: (id: UUID, movingEnd: Bool, start: Int, end: Int, pointer: Int)?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func shown(_ slot: ScheduleSlot) -> ScheduleSlot {
        guard let drag = draggedMinutes, drag.id == slot.id else { return slot }
        var copy = slot
        copy.startMinute = drag.start
        copy.endMinute = drag.end
        return copy
    }

    private func color(_ slot: ScheduleSlot) -> Color {
        palette.isEmpty ? .accentColor : palette[(ScheduleDialStyle.number(slot, in: slots) - 1) % palette.count]
    }

    private var nowHour: Double {
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        return Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60
    }

    private func motion(_ animation: Animation) -> Animation {
        reduceMotion ? DesignTokens.Motion.reducedMotionFade : animation
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // Hour labels and the drag capsule reach about 64pt beyond the ring.
            let radius = max(Metrics.ringWidth, min(size.width, size.height) / 2 - 64)
            ZStack {
                Canvas { context, _ in
                    drawFace(context: &context, radius: radius, center: center)
                }
                .contentShape(Rectangle())
                .onTapGesture { point in select(at: point, center: center, radius: radius) }
                .onTapGesture(count: 2) { point in
                    guard abs(hypot(point.x - center.x, point.y - center.y) - radius) < 22 else { return }
                    let minute = Int(ScheduleDialGeometry.fractionalHour(at: point, center: center) * 2) * 30
                    if !slots.contains(where: { $0.containsMinute(minute) }) {
                        onInsert(minute)
                    }
                }
                .accessibilityHidden(true)
                Canvas { context, _ in
                    drawSnapTicks(context: &context, radius: radius, center: center)
                }
                .opacity(draggedMinutes == nil ? 0 : 1)
                .animation(motion(DesignTokens.Motion.stateChange), value: draggedMinutes == nil)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                ForEach(slots) { slot in
                    section(slot, radius: radius, center: center)
                }
                Canvas { context, _ in
                    let dot = ScheduleDialGeometry.point(hour: nowHour, radius: radius, center: center)
                    for (size, opacity) in [(18.0, 0.16), (7.0, 1.0)] {
                        let disc = Path(ellipseIn: CGRect(x: dot.x - size / 2, y: dot.y - size / 2, width: size, height: size))
                        context.fill(disc, with: .color(.primary.opacity(opacity)))
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                hourLabels(center: center, radius: radius)
                fallbackLabels(center: center, radius: radius)
                dialCenter(radius: radius).position(center)
                if let slot = slots.first(where: { $0.id == selectedID }) {
                    ForEach([false, true], id: \.self) { end in
                        edgeHandle(slot, end: end, radius: radius, center: center)
                    }
                }
            }.coordinateSpace(name: "schedule-dial")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("24-hour schedule"))
        // The ring is hidden from accessibility, so these actions are how VoiceOver selects a slot.
        .accessibilityActions {
            ForEach(slots.sorted { $0.startMinute < $1.startMinute }) { slot in
                Button { selectedID = slot.id } label: { Text(verbatim: accessibilityName(slot)) }
            }
        }
    }

    private func accessibilityName(_ slot: ScheduleSlot) -> String {
        "\(ScheduleDialStyle.number(slot, in: slots)) · \(slot.rangeText()) · \(slot.wallpaper?.displayTitle ?? slot.localizedLabel)"
    }

    private func select(at point: CGPoint, center: CGPoint, radius: Double) {
        guard abs(hypot(point.x - center.x, point.y - center.y) - radius) < 22 else { return }
        let minute = Int(ScheduleDialGeometry.fractionalHour(at: point, center: center) * 60)
        selectedID = slots.first { $0.containsMinute(minute) }?.id
    }

    /// `offset` moves the path off the ring's centerline while keeping the section's trimmed angles.
    private func arc(_ slot: ScheduleSlot, radius: Double, center: CGPoint, offset: Double = 0) -> Path {
        let span = ScheduleDialGeometry.span(slot)
        guard span > 0 else { return Path() }
        let distance = radius + offset
        if span == 24 {
            return Path(ellipseIn: CGRect(x: center.x - distance, y: center.y - distance, width: distance * 2, height: distance * 2))
        }
        // Trim both ends by the cap radius plus a 2pt gap (18 minutes on the full-size ring). A wrap is one continuous arc, not two sections at midnight.
        let inset = min(span * 15 / 3, asin(min(1, (Metrics.ringWidth / 2 + 2) / radius)) * 180 / .pi)
        var path = Path()
        path.addArc(center: center, radius: distance,
                    startAngle: .degrees(Double(slot.startMinute) / 60 * 15 - 90 + inset),
                    endAngle: .degrees((Double(slot.startMinute) / 60 + span) * 15 - 90 - inset), clockwise: false)
        return path
    }

    private func section(_ slot: ScheduleSlot, radius: Double, center: CGPoint) -> some View {
        let visible = shown(slot)
        let tint = color(slot)
        let selected = selectedID == slot.id
        let lip = Metrics.ringWidth / 2 - 1.5
        return ZStack {
            if slots.count >= 12 {
                sectionShape(visible, radius: radius, center: center, width: Metrics.ringWidth).fill(tint)
            } else {
                arc(visible, radius: radius, center: center)
                    .stroke(tint, style: StrokeStyle(lineWidth: Metrics.ringWidth, lineCap: .round))
                arc(visible, radius: radius, center: center, offset: lip)
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                arc(visible, radius: radius, center: center, offset: -lip)
                    .stroke(Color.black.opacity(0.28), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
            if slots.count > 6 {
                Text(verbatim: String(ScheduleDialStyle.number(slot, in: slots)))
                    .font(DesignTokens.Typography.badge).foregroundStyle(DesignTokens.Colors.pageBackground)
                    .position(ScheduleDialGeometry.point(hour: ScheduleDialGeometry.midpoint(visible), radius: radius, center: center))
            }
        }
        .scaleEffect(selected ? (radius + Metrics.selectionLift) / radius : 1)
        .shadow(color: .black.opacity(selected ? 0.5 : 0), radius: 5, y: selected ? 6 : 0)
        .animation(motion(.snappy(duration: 0.25)), value: selected)
        .zIndex(selected ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawFace(context: inout GraphicsContext, radius: Double, center: CGPoint) {
        func circle(_ distance: Double) -> Path {
            Path(ellipseIn: CGRect(x: center.x - distance, y: center.y - distance, width: distance * 2, height: distance * 2))
        }
        let half = Metrics.ringWidth / 2
        context.stroke(circle(radius), with: .color(.primary.opacity(0.035)), lineWidth: Metrics.ringWidth)
        context.stroke(circle(radius), with: .color(.primary.opacity(0.34)), style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
        for edge in [radius - half, radius + half] {
            context.stroke(circle(edge), with: .color(.primary.opacity(0.06)), lineWidth: 1)
        }
        for hour in 0 ..< 24 {
            let major = hour % 6 == 0
            var tick = Path()
            tick.move(to: ScheduleDialGeometry.point(hour: Double(hour), radius: radius + half + 4, center: center))
            tick.addLine(to: ScheduleDialGeometry.point(hour: Double(hour), radius: radius + half + (major ? 18 : 10), center: center))
            let opacity = contrast == .increased ? 0.8 : (major ? 0.45 : 0.2)
            context.stroke(tick, with: .color(.primary.opacity(opacity)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        var pointer = Path()
        pointer.move(to: center)
        pointer.addLine(to: ScheduleDialGeometry.point(hour: nowHour, radius: radius - 16, center: center))
        context.stroke(pointer, with: .color(.primary.opacity(0.5)), lineWidth: 1)
    }

    /// One tick per half hour just inside the ring; the hour ticks are longer.
    private func drawSnapTicks(context: inout GraphicsContext, radius: Double, center: CGPoint) {
        let inner = radius - Metrics.ringWidth / 2 - 3
        for index in 0 ..< 48 {
            let hour = Double(index) / 2
            var tick = Path()
            tick.move(to: ScheduleDialGeometry.point(hour: hour, radius: inner - (index % 2 == 0 ? 11 : 6), center: center))
            tick.addLine(to: ScheduleDialGeometry.point(hour: hour, radius: inner, center: center))
            context.stroke(tick, with: .color(DesignTokens.Colors.accent.opacity(index % 2 == 0 ? 0.9 : 0.55)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    /// Dense schedules use softly squared section edges, leaving room for short intervals without a bead-like ring.
    private func sectionShape(_ slot: ScheduleSlot, radius: Double, center: CGPoint, width: Double) -> Path {
        let span = ScheduleDialGeometry.span(slot)
        guard span > 0 else { return Path() }
        let start = Double(slot.startMinute) / 60 * 15 - 90 + 0.65
        let end = (Double(slot.startMinute) / 60 + span) * 15 - 90 - 0.65
        let outer = radius + width / 2
        let inner = radius - width / 2
        let corner = 2.0
        let trim = corner / radius * 180 / .pi
        func point(_ angle: Double, _ distance: Double) -> CGPoint {
            CGPoint(x: center.x + cos(angle * .pi / 180) * distance, y: center.y + sin(angle * .pi / 180) * distance)
        }
        var path = Path()
        path.move(to: point(start + trim, outer))
        path.addArc(center: center, radius: outer, startAngle: .degrees(start + trim), endAngle: .degrees(end - trim), clockwise: false)
        path.addQuadCurve(to: point(end, outer - corner), control: point(end, outer))
        path.addLine(to: point(end, inner + corner))
        path.addQuadCurve(to: point(end - trim, inner), control: point(end, inner))
        path.addArc(center: center, radius: inner, startAngle: .degrees(end - trim), endAngle: .degrees(start + trim), clockwise: true)
        path.addQuadCurve(to: point(start, inner + corner), control: point(start, inner))
        path.addLine(to: point(start, outer - corner))
        path.addQuadCurve(to: point(start + trim, outer), control: point(start, outer))
        path.closeSubpath()
        return path
    }

    private func hourLabels(center: CGPoint, radius: Double) -> some View {
        ForEach([0, 6, 12, 18], id: \.self) { hour in
            Text(verbatim: String(format: "%02d", hour)).font(DesignTokens.Typography.metric)
                .foregroundStyle(hour == 0 ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                .position(ScheduleDialGeometry.point(hour: Double(hour), radius: radius + 44, center: center))
                .accessibilityHidden(true)
        }
    }

    /// Midpoint minute of each unscheduled stretch long enough to hold a label.
    private var fallbackGapMidpoints: [Int] {
        let filled = slots.filter { $0.startMinute != $0.endMinute }.map(shown).sorted { $0.startMinute < $1.startMinute }
        guard !filled.isEmpty else { return [720] }
        return filled.indices.compactMap { index in
            let end = filled[index].endMinute % 1440
            let gap = (filled[(index + 1) % filled.count].startMinute - end + 1440) % 1440
            // Two hours is 30°, about one label's width at the label radius.
            return gap >= 120 ? (end + gap / 2) % 1440 : nil
        }
    }

    @ViewBuilder
    private func fallbackLabels(center: CGPoint, radius: Double) -> some View {
        if let fallbackTitle {
            ForEach(fallbackGapMidpoints, id: \.self) { minute in
                VStack(spacing: DesignTokens.Spacing.xxs) {
                    Text("Fallback").font(DesignTokens.Typography.badge).foregroundStyle(DesignTokens.Colors.textSecondary)
                    Text(verbatim: fallbackTitle).font(DesignTokens.Typography.caption).lineLimit(1)
                }
                .frame(maxWidth: 96)
                .position(ScheduleDialGeometry.point(hour: Double(minute) / 60, radius: radius - 46, center: center))
                .allowsHitTesting(false)
            }
        }
    }

    private func dialCenter(radius: Double) -> some View {
        let diameter = Metrics.thumbnailDiameter * radius / Metrics.ringRadius
        let minute = Int(nowHour * 60)
        let current = slots.first { $0.containsMinute(minute) }
        return Group {
            if let current {
                thumbnail(current)
            } else {
                Color.clear
            }
        }
        .frame(width: diameter, height: diameter)
        .background(DesignTokens.Colors.surfaceRaised)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 12)
        .accessibilityHidden(true)
        .overlay(alignment: .bottom) {
            nowCapsule
                // Overlays are proposed the thumbnail's width; this lets the capsule run wider, still inside the snap ticks.
                .frame(width: radius * 1.4)
                .alignmentGuide(.bottom) { $0[.top] - 4 }
        }
    }

    private var nowCapsule: some View {
        HStack(spacing: 6) {
            Text(now, format: .dateTime.hour().minute()).font(DesignTokens.Typography.metric)
            if let nowPlayingTitle {
                Text(verbatim: "·").foregroundStyle(DesignTokens.Colors.textSecondary).accessibilityHidden(true)
                Text("Now playing").foregroundStyle(DesignTokens.Colors.textSecondary)
                Text(verbatim: nowPlayingTitle).font(DesignTokens.Typography.captionEmphasized)
            }
        }
        .font(DesignTokens.Typography.caption)
        .lineLimit(1)
        .padding(.horizontal, 11).padding(.vertical, 5)
        .adaptiveGlassSurface(.capsule)
        .accessibilityElement(children: .combine)
    }

    private func edgeHandle(_ slot: ScheduleSlot, end: Bool, radius: Double, center: CGPoint) -> some View {
        let visible = shown(slot)
        let minute = end ? visible.endMinute : visible.startMinute
        let dragging = draggedMinutes.map { $0.id == slot.id && $0.movingEnd == end } ?? false
        let lifted = radius + Metrics.selectionLift
        return ZStack {
            Color.clear.frame(width: Metrics.handleDiameter, height: Metrics.handleDiameter)
                .adaptiveGlassSurface(.circle, interactive: true)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                .scaleEffect(dragging ? 1.2 : 1)
                .animation(motion(.snappy(duration: 0.2)), value: dragging)
                .frame(width: 28, height: 28).contentShape(Circle())
                .position(ScheduleDialGeometry.point(hour: Double(minute) / 60, radius: lifted, center: center))
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("schedule-dial")).onChanged { value in
                    let previous = draggedMinutes.flatMap { $0.id == slot.id && $0.movingEnd == end ? $0 : nil }
                    let minutes = ScheduleDialGeometry.draggedMinutes(slot, movingEnd: end, pointer: previous?.pointer, to: ScheduleDialGeometry.minute(at: value.location, center: center), among: slots)
                    if let previous, (previous.start, previous.end) != (minutes.start, minutes.end) {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    draggedMinutes = (slot.id, end, minutes.start, minutes.end, minutes.pointer)
                }.onEnded { _ in
                    if let drag = draggedMinutes {
                        onRetimed(drag.id, drag.start, drag.end)
                    }
                    draggedMinutes = nil
                })
            if dragging {
                Text(verbatim: ScheduleSlot.clockText(minute: end && minute == 0 ? 1440 : minute))
                    .font(DesignTokens.Typography.captionEmphasized).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .adaptiveGlassSurface(.capsule, interactive: false)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    // 22pt clear of the handle, plus about half the capsule's height to reach its center.
                    .position(ScheduleDialGeometry.point(hour: Double(minute) / 60, radius: lifted + Metrics.handleDiameter / 2 + 22 + 12, center: center))
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("24-hour Schedule") {
    ScheduleDial(slots: ScheduleSlot.defaultSlots, now: Date(timeIntervalSince1970: 0),
                 selectedID: .constant(nil), onRetimed: { _, _, _ in }, onInsert: { _ in })
        .frame(width: 540, height: 540).padding(20)
}
