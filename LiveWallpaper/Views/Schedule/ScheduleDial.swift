import AppKit
import LiveWallpaperCore
import SwiftUI

/// Midnight is at the top, noon at the bottom; angles are clockwise over a full day.
enum ScheduleDialGeometry {
    static func hour(at point: CGPoint, center: CGPoint) -> Int {
        Int(fractionalHour(at: point, center: center).rounded()) % 24
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

    static func span(_ slot: ScheduleSlot) -> Double {
        guard slot.startHour != slot.endHour else { return 0 }
        return Double(slot.endHour > slot.startHour ? slot.endHour - slot.startHour : slot.endHour + 24 - slot.startHour)
    }

    static func midpoint(_ slot: ScheduleSlot) -> Double {
        (Double(slot.startHour) + span(slot) / 2).truncatingRemainder(dividingBy: 24)
    }

    struct Callout: Identifiable {
        let slot: ScheduleSlot
        let anchor: CGPoint
        let frame: CGRect
        let left: Bool
        var id: UUID {
            slot.id
        }
    }

    /// Order-preserving lanes keep adjacent sections apart, including an uneven distribution on either half.
    static func callouts(slots: [ScheduleSlot], selectedID: UUID?, size: CGSize, radius: Double, cardWidth: Double) -> [Callout] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var result: [Callout] = []
        for left in [true, false] {
            let entries = slots.filter {
                (point(hour: midpoint($0), radius: radius, center: center).x < center.x) == left
            }.sorted {
                point(hour: midpoint($0), radius: radius, center: center).y < point(hour: midpoint($1), radius: radius, center: center).y
            }
            let available = max(0, size.height - 40)
            let capacity = max(1, Int(available / 34))
            var visible = Array(entries.prefix(capacity))
            if let selected = entries.first(where: { $0.id == selectedID }), !visible.contains(where: { $0.id == selectedID }) {
                visible[visible.count - 1] = selected
                visible.sort {
                    point(hour: midpoint($0), radius: radius, center: center).y < point(hour: midpoint($1), radius: radius, center: center).y
                }
            }
            guard !visible.isEmpty else { continue }
            let height = min(56, available / Double(visible.count) - 6)
            let stride = height + 6
            // Anchor toward the arc when there is room; pack only as far as collision avoidance requires.
            var centers = visible.map {
                min(size.height - 20 - height / 2, max(20 + height / 2, point(hour: midpoint($0), radius: radius + 20, center: center).y))
            }
            for index in centers.indices.dropFirst() {
                centers[index] = max(centers[index], centers[index - 1] + stride)
            }
            let overflow = max(0, centers.last! + height / 2 + 20 - size.height)
            centers = centers.map { $0 - overflow }
            for index in centers.indices.reversed().dropFirst() {
                centers[index] = min(centers[index], centers[index + 1] - stride)
            }
            for (index, slot) in visible.enumerated() {
                let x = left ? 10 : size.width - cardWidth - 10
                result.append(Callout(slot: slot, anchor: point(hour: midpoint(slot), radius: radius + 13, center: center),
                                      frame: CGRect(x: x, y: centers[index] - height / 2, width: cardWidth, height: height), left: left))
            }
        }
        return result
    }
}

/// Muted, appearance-aware section colors; numbers also identify sections when colors repeat.
enum ScheduleDialStyle {
    static let palette: [Color] = [tone(0.52, 0.68, 0.82), tone(0.49, 0.71, 0.67), tone(0.67, 0.63, 0.80),
                                   tone(0.78, 0.66, 0.48), tone(0.74, 0.57, 0.64), tone(0.54, 0.65, 0.73)]

    private static func tone(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let factor = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 1.0 : 0.67
            return NSColor(srgbRed: red * factor, green: green * factor, blue: blue * factor, alpha: 1)
        })
    }

    static func number(_ slot: ScheduleSlot, in slots: [ScheduleSlot]) -> Int {
        (slots.sorted { $0.startHour < $1.startHour }.firstIndex { $0.id == slot.id } ?? 0) + 1
    }
}

struct ScheduleDial: View {
    let slots: [ScheduleSlot]
    let now: Date
    var palette: [Color] = ScheduleDialStyle.palette
    @Binding var selectedID: UUID?
    let onRetimed: (UUID, Int, Int) -> Void
    let onInsert: (Int) -> Void
    var thumbnail: (ScheduleSlot) -> AnyView = { _ in AnyView(Image(systemName: "photo")) }
    @State private var draggedHours: (id: UUID, start: Int, end: Int)?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    private func shown(_ slot: ScheduleSlot) -> ScheduleSlot {
        guard let drag = draggedHours, drag.id == slot.id else { return slot }
        var copy = slot
        copy.startHour = drag.start
        copy.endHour = drag.end
        return copy
    }

    private func color(_ slot: ScheduleSlot) -> Color {
        palette.isEmpty ? .accentColor : palette[(ScheduleDialStyle.number(slot, in: slots) - 1) % palette.count]
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width * (size.width < 560 ? 0.20 : 0.225), (size.height - 96) / 2)
            let cardWidth = min(148.0, size.width * 0.225)
            let callouts = ScheduleDialGeometry.callouts(slots: slots, selectedID: selectedID, size: size, radius: radius, cardWidth: cardWidth)
            ZStack {
                Circle().fill(DesignTokens.Colors.surfaceRaised.opacity(0.4))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.035), lineWidth: 1))
                    .frame(width: max(0, radius * 2 - 46), height: max(0, radius * 2 - 46)).position(center)
                Canvas { context, _ in
                    drawDial(context: &context, size: size, radius: radius, center: center, callouts: callouts)
                }
                .contentShape(Rectangle())
                .onTapGesture { point in select(at: point, center: center, radius: radius) }
                .onTapGesture(count: 2) { point in
                    guard abs(hypot(point.x - center.x, point.y - center.y) - radius) < 22 else { return }
                    let hour = Int(ScheduleDialGeometry.fractionalHour(at: point, center: center))
                    if !slots.contains(where: { $0.containsHour(hour) }) {
                        onInsert(hour)
                    }
                }
                .accessibilityHidden(true)
                dialLabels(center: center, radius: radius)
                dialCenter(radius: radius).position(center)
                ForEach(callouts) { callout in
                    calloutCard(callout, compact: size.width < 560)
                        .position(x: callout.frame.midX, y: callout.frame.midY)
                }
                if let slot = slots.first(where: { $0.id == selectedID }) {
                    ForEach([false, true], id: \.self) { end in
                        edgeHandle(slot, end: end, radius: radius, center: center)
                    }
                }
            }.coordinateSpace(name: "schedule-dial")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("24-hour schedule"))
    }

    private func select(at point: CGPoint, center: CGPoint, radius: Double) {
        guard abs(hypot(point.x - center.x, point.y - center.y) - radius) < 22 else { return }
        let hour = Int(ScheduleDialGeometry.fractionalHour(at: point, center: center))
        selectedID = slots.first { $0.containsHour(hour) }?.id
    }

    private func arc(_ slot: ScheduleSlot, radius: Double, center: CGPoint) -> Path {
        let span = ScheduleDialGeometry.span(slot)
        guard span > 0 else { return Path() }
        if span == 24 {
            return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        // Trim both ends by the cap radius plus a hairline gap. A wrap is one continuous arc, not two sections at midnight.
        let halfWidth = radius < 110 ? 5.0 : 7.0
        let inset = min(span * 15 / 3, asin(min(1, halfWidth / radius)) * 180 / .pi + 1.2)
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(Double(slot.startHour) * 15 - 90 + inset),
                    endAngle: .degrees((Double(slot.startHour) + span) * 15 - 90 - inset), clockwise: false)
        return path
    }

    private func drawDial(context: inout GraphicsContext, size _: CGSize, radius: Double, center: CGPoint, callouts: [ScheduleDialGeometry.Callout]) {
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let ringWidth = radius < 110 ? 10.0 : 14.0
        context.stroke(circle, with: .color(.primary.opacity(0.04)), lineWidth: ringWidth)
        for hour in 0 ..< 24 {
            let from = ScheduleDialGeometry.point(hour: Double(hour), radius: radius - (hour % 3 == 0 ? 33 : 28), center: center)
            let to = ScheduleDialGeometry.point(hour: Double(hour), radius: radius - 24, center: center)
            var tick = Path(); tick.move(to: from); tick.addLine(to: to)
            context.stroke(tick, with: .color(.secondary.opacity(contrast == .increased ? 0.8 : 0.38)), lineWidth: hour % 3 == 0 ? 1 : 0.6)
        }
        for slot in slots {
            let visible = shown(slot)
            let conflict = draggedHours?.id == slot.id && SchedulePolicy.firstProblem(in: slots.map { $0.id == slot.id ? visible : $0 }) != nil
            let tint = conflict ? Color.red : color(slot)
            let shading = GraphicsContext.Shading.linearGradient(Gradient(colors: [tint, tint.opacity(scheme == .light ? 1 : 0.88)]),
                                                                 startPoint: CGPoint(x: center.x, y: center.y - radius), endPoint: CGPoint(x: center.x, y: center.y + radius))
            if slots.count >= 12 {
                let path = sectionShape(visible, radius: radius, center: center, width: ringWidth)
                if selectedID == slot.id {
                    context.stroke(path, with: .color(tint.opacity(0.15)), style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                }
                context.fill(path, with: shading)
            } else {
                let path = arc(visible, radius: radius, center: center)
                if selectedID == slot.id {
                    context.stroke(path, with: .color(tint.opacity(0.13)), style: StrokeStyle(lineWidth: ringWidth + 7, lineCap: .round))
                }
                context.stroke(path, with: shading, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
            }
            if slots.count > 6, radius >= 110 || selectedID == slot.id {
                let label = Text(verbatim: String(ScheduleDialStyle.number(slot, in: slots)))
                    .font(DesignTokens.Typography.badge).foregroundStyle(radius < 110 ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.pageBackground)
                context.draw(label, at: ScheduleDialGeometry.point(hour: ScheduleDialGeometry.midpoint(visible), radius: radius < 110 ? radius - 17 : radius, center: center))
            }
        }
        for callout in callouts {
            let start = ScheduleDialGeometry.point(hour: ScheduleDialGeometry.midpoint(shown(callout.slot)), radius: radius + 13, center: center)
            let end = CGPoint(x: callout.left ? callout.frame.maxX + 6 : callout.frame.minX - 6, y: callout.frame.midY)
            let direction = callout.left ? -1.0 : 1.0
            let reach = min(34, abs(start.x - end.x) / 2)
            var line = Path(); line.move(to: start)
            line.addCurve(to: end, control1: CGPoint(x: start.x + direction * reach, y: start.y),
                          control2: CGPoint(x: end.x - direction * reach, y: end.y))
            let selected = selectedID == callout.id
            context.stroke(line, with: .color(selected ? color(callout.slot).opacity(0.7) : .secondary.opacity(contrast == .increased ? 0.65 : 0.25)),
                           style: StrokeStyle(lineWidth: selected ? 1.2 : 0.75, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: start.x - 1.5, y: start.y - 1.5, width: 3, height: 3)), with: .color(color(callout.slot)))
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let time = Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60
        let marker = ScheduleDialGeometry.point(hour: time, radius: radius - 13, center: center)
        context.fill(Path(ellipseIn: CGRect(x: marker.x - 2, y: marker.y - 2, width: 4, height: 4)), with: .color(.primary))
    }

    /// Dense schedules use softly squared section edges, leaving room for short intervals without a bead-like ring.
    private func sectionShape(_ slot: ScheduleSlot, radius: Double, center: CGPoint, width: Double) -> Path {
        let span = ScheduleDialGeometry.span(slot)
        guard span > 0 else { return Path() }
        let start = Double(slot.startHour) * 15 - 90 + 0.65
        let end = (Double(slot.startHour) + span) * 15 - 90 - 0.65
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

    private func dialLabels(center: CGPoint, radius: Double) -> some View {
        ForEach(Array(stride(from: 0, to: 24, by: radius >= 125 ? 3 : 6)), id: \.self) { hour in
            Text(verbatim: String(format: "%02d", hour)).font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                .position(ScheduleDialGeometry.point(hour: Double(hour), radius: radius - 46, center: center))
        }
    }

    private func dialCenter(radius: Double) -> some View {
        VStack(spacing: 8) {
            Text(now, format: .dateTime.hour().minute())
                .font(radius < 120 ? DesignTokens.Typography.caption : DesignTokens.Typography.modalTitle.weight(.regular)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            if radius >= 120 {
                Text("Repeats every day").font(DesignTokens.Typography.caption).foregroundStyle(.tertiary)
            }
        }.frame(width: radius * (radius < 120 ? 0.6 : 1.0))
    }

    private func calloutCard(_ callout: ScheduleDialGeometry.Callout, compact: Bool) -> some View {
        let slot = callout.slot
        let selected = selectedID == slot.id
        let dense = callout.frame.height < 48
        return Button { selectedID = slot.id } label: {
            HStack(spacing: compact || dense ? 6 : 8) {
                if dense, !compact {
                    Text(verbatim: String(ScheduleDialStyle.number(slot, in: slots))).font(DesignTokens.Typography.badge)
                        .foregroundStyle(color(slot)).frame(width: 18)
                }
                thumbnail(slot).frame(width: compact || dense ? 26 : 42, height: dense ? 20 : 30).clipped()
                    .background(color(slot).opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
                    .overlay(alignment: .topLeading) {
                        if !compact, !dense {
                            Text(verbatim: String(ScheduleDialStyle.number(slot, in: slots))).font(DesignTokens.Typography.badge)
                                .foregroundStyle(.primary).frame(width: 16, height: 16)
                                .background(DesignTokens.Colors.surfaceRaised, in: Circle()).offset(x: -4, y: -4)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    if !dense, !compact {
                        Text(verbatim: slot.wallpaper?.displayTitle ?? slot.localizedLabel)
                            .font(DesignTokens.Typography.captionEmphasized).lineLimit(1)
                    }
                    Text(verbatim: range(slot, compact: compact)).font(DesignTokens.Typography.caption).monospacedDigit()
                        .foregroundStyle(selected ? .primary : .secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).frame(width: callout.frame.width, height: callout.frame.height)
                .background(DesignTokens.Colors.surfaceRaised.opacity(selected ? 0.9 : 0.55), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Corner.md).strokeBorder(selected ? color(slot).opacity(0.55) : Color.primary.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: slot.wallpaper?.displayTitle ?? slot.localizedLabel))
        .accessibilityLabel(Text(verbatim: "\(ScheduleDialStyle.number(slot, in: slots)) · \(range(slot)) · \(slot.wallpaper?.displayTitle ?? slot.localizedLabel)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func edgeHandle(_ slot: ScheduleSlot, end: Bool, radius: Double, center: CGPoint) -> some View {
        let visible = shown(slot)
        return Circle().fill(DesignTokens.Colors.pageBackground).frame(width: 9, height: 9)
            .overlay(Circle().stroke(color(slot), lineWidth: 2))
            .frame(width: 28, height: 28).contentShape(Circle())
            .position(ScheduleDialGeometry.point(hour: Double(end ? visible.endHour : visible.startHour), radius: radius, center: center))
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("schedule-dial")).onChanged { value in
                let hour = ScheduleDialGeometry.hour(at: value.location, center: center)
                draggedHours = (slot.id, end ? slot.startHour : hour, end ? (hour == 0 ? 24 : hour) : slot.endHour)
            }.onEnded { _ in
                if let drag = draggedHours {
                    onRetimed(drag.id, drag.start, drag.end)
                }
                draggedHours = nil
            })
            .accessibilityHidden(true)
    }

    private func range(_ slot: ScheduleSlot, compact: Bool = false) -> String {
        String(format: compact ? "%02d–%02d" : "%02d:00–%02d:00", slot.startHour, slot.endHour == 0 ? 24 : slot.endHour)
    }
}

#Preview("24-hour Schedule") {
    ScheduleDial(slots: ScheduleSlot.defaultSlots, now: Date(timeIntervalSince1970: 0),
                 selectedID: .constant(nil), onRetimed: { _, _, _ in }, onInsert: { _ in })
        .frame(width: 650, height: 460).padding(20)
}
