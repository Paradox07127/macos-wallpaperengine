import SwiftUI
import LiveWallpaperCore

struct CPUWidgetView: View {
    let context: MonitorWidgetContext

    private var system: MonitorSystemSnapshot? { context.snapshot.system }
    private var history: MonitorHistorySnapshot { context.history }
    private var placement: MonitorWidgetPlacement { context.placement }

    var body: some View {
        GeometryReader { geo in
            let rowSpan: CGFloat = placement.size == .large ? 2 : 1
            let cellHeight = geo.size.height / (2 * rowSpan)
            content(cellHeight: cellHeight)
        }
    }

    @ViewBuilder
    private func content(cellHeight: CGFloat) -> some View {
        switch placement.size {
        case .small: smallBody(cellHeight: cellHeight)
        case .medium: mediumBody(cellHeight: cellHeight)
        case .large: largeBody(cellHeight: cellHeight)
        }
    }

    // MARK: - Derived values

    private var cpuFraction: Double {
        system?.cpuTotal ?? 0
    }

    private var peakFraction: Double {
        history.values(history.cpuTotal, in: trendWindow).max() ?? cpuFraction
    }

    /// The trend chart's window, anchored on the context's clock so a pause
    /// leaves a gap instead of compressing the curve.
    private var trendWindow: MonitorChartWindow {
        history.chartWindow(reference: context.now, seconds: Double(historyWindow))
    }

    private var trendPoints: [MonitorHistoryPoint] {
        history.points(history.cpuTotal, in: trendWindow)
    }

    private var cpuTempC: Double? { system?.sensors?.cpuTempC ?? system?.sensors?.socTempC }
    /// The fastest installed fan is the most useful compact cooling indicator
    /// on machines with independently controlled fans.
    private var fanRPM: Double? { system?.sensors?.fanRPM?.max() }

    private var showSensors: Bool { MonitorCPUDraft.showSensors(placement) }
    private var showHeatmap: Bool { MonitorCPUDraft.showHeatmap(placement) }
    private var showComposition: Bool { MonitorCPUDraft.showComposition(placement) }
    private var showTrend: Bool { MonitorCPUDraft.showTrend(placement) }
    private var historyWindow: Int { MonitorCPUDraft.historyWindow(placement) }

    /// Sensor UI is only ever drawn when the reading exists AND the option is on.
    private var sensorsVisible: Bool { showSensors && (cpuTempC != nil || fanRPM != nil) }
    private var tempCapsuleTemp: Double? { showSensors ? cpuTempC : nil }

    // MARK: - S (1×1)

    @ViewBuilder
    private func smallBody(cellHeight: CGFloat) -> some View {
        let scale = Design.TypeScale(cellHeight: cellHeight)
        WidgetContainer(
            label: "CPU",
            systemImage: WidgetFactory.icon(.cpu),
            cellHeight: cellHeight,
            status: { CPUStateDot(fraction: cpuFraction) }
        ) {
            VStack(spacing: scale.label * 0.55) {
                Spacer(minLength: 0)
                let hasTemp = tempCapsuleTemp != nil
                ArcGauge(value: cpuFraction, peak: peakFraction) {
                    heroReadout(fraction: cpuFraction, baseSize: scale.hero * (hasTemp ? 0.9 : 1))
                }
                .frame(maxWidth: hasTemp ? 126 : 138)

                if let temp = tempCapsuleTemp {
                    temperatureCapsule(temp, scale: scale)
                }

                Spacer(minLength: 0)

                if showTrend {
                    Sparkline(points: trendPoints, window: trendWindow, domain: 0 ... 1, bandColored: true, guides: [0.4, 0.8])
                        .frame(maxWidth: .infinity)
                        .frame(height: max(cellHeight * 0.24, 20))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - M (2×1)

    @ViewBuilder
    private func mediumBody(cellHeight: CGFloat) -> some View {
        let scale = Design.TypeScale(cellHeight: cellHeight)
        let user = system?.cpuUser ?? 0
        let sys = system?.cpuSystem ?? 0
        let (userPct, sysPct, _) = Self.compositionPercents(user: user, system: sys)
        WidgetContainer(
            label: "CPU",
            systemImage: WidgetFactory.icon(.cpu),
            cellHeight: cellHeight,
            status: { CPUStateDot(fraction: cpuFraction) }
        ) {
            let identity = Self.identityLine(system?.cpuInfo)
            VStack(alignment: .leading, spacing: scale.label * 0.5) {
                if let identity {
                    identityRow(identity, scale: scale)
                }

                HStack(alignment: .center, spacing: scale.label * 0.7) {
                    VStack(alignment: .leading, spacing: scale.label * 0.45) {
                        ArcGauge(
                            value: cpuFraction,
                            bands: showComposition
                                ? [ArcBand(user, Design.signalAmber), ArcBand(sys, Design.signalSteel)]
                                : nil
                        ) {
                            heroReadout(fraction: cpuFraction, baseSize: scale.hero * 1.05)
                        }
                        // Height cap, so the ring is the same size it has always
                        // been; the column beside it is pinned by `gaugeSide`.
                        .frame(maxHeight: Self.gaugeSideCap)
                        if showComposition {
                            compositionLegend(userPct: userPct, sysPct: sysPct, scale: scale)
                        }
                    }
                    .frame(
                        width: Self.gaugeSide(
                            cellHeight: cellHeight, rows: 1,
                            hasIdentityRow: identity != nil,
                            hasCompositionLegend: showComposition
                        ),
                        alignment: .leading
                    )

                    VStack(alignment: .leading, spacing: scale.label * 0.5) {
                        if showHeatmap {
                            coreHeatStrip(scale: scale)
                        }
                        Sparkline(points: trendPoints, window: trendWindow, domain: 0 ... 1, bandColored: true, guides: [0.4, 0.8])
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(minHeight: max(cellHeight * 0.18, 20))
                            .overlay(alignment: .topTrailing) { peakInlineTag(scale: scale) }
                        if sensorsVisible { sensorRow(scale: scale) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - L (2×2)

    @ViewBuilder
    private func largeBody(cellHeight: CGFloat) -> some View {
        let scale = Design.TypeScale(cellHeight: cellHeight)
        WidgetContainer(
            label: "CPU",
            systemImage: WidgetFactory.icon(.cpu),
            cellHeight: cellHeight,
            status: { CPUStateDot(fraction: cpuFraction) }
        ) {
            let identity = Self.identityLine(system?.cpuInfo)
            VStack(alignment: .leading, spacing: scale.label * 0.6) {
                if let identity {
                    identityRow(identity, scale: scale)
                }

                // Keep the header aligned to the standard content inset.
                HStack(alignment: .center, spacing: scale.label * 0.7) {
                    ArcGauge(value: cpuFraction, peak: peakFraction) {
                        heroReadout(fraction: cpuFraction, baseSize: scale.hero * 0.92)
                    }
                    .frame(maxHeight: Self.gaugeSideCap)
                    .frame(
                        width: Self.gaugeSide(
                            cellHeight: cellHeight, rows: 2,
                            hasIdentityRow: identity != nil,
                            hasCompositionLegend: showComposition
                        ),
                        alignment: .leading
                    )

                    VStack(alignment: .leading, spacing: scale.label * 0.45) {
                        if showComposition {
                            compositionBar(scale: scale, centeredLegend: false, legendScale: 1)
                        }
                        HStack(spacing: scale.label * 0.5) {
                            thermalPill(scale: scale)
                            loadStatus(scale: scale, triple: true)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)

                CPUStackChart(
                    user: history.windowed(history.cpuUser, seconds: historyWindow),
                    system: history.windowed(history.cpuSystem, seconds: historyWindow)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: max(cellHeight * 0.32, 32))
                .overlay(alignment: .topTrailing) { peakInlineTag(scale: scale) }

                let groups = showHeatmap
                    ? Self.coreGroupLoads(perCore: system?.perCore, cpuInfo: system?.cpuInfo)
                    : nil
                let procs = Self.topCPUProcesses(system?.topProcesses, limit: 4)
                if groups != nil || procs?.isEmpty == false {
                    HStack(alignment: .top, spacing: scale.label * 0.9) {
                        if let groups {
                            VStack(alignment: .leading, spacing: scale.label * 0.4) {
                                sectionLabel("Cores · \(Self.coreCountText(groups))", scale: scale)
                                coreHeatStripTall(groups: groups, scale: scale)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        if let procs, !procs.isEmpty {
                            VStack(alignment: .leading, spacing: scale.label * 0.4) {
                                sectionLabel("Top by CPU", scale: scale)
                                procRows(procs, scale: scale)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }

                if sensorsVisible { sensorStrip(scale: scale) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Shared subviews

    private func heroReadout(fraction: Double, baseSize: CGFloat) -> some View {
        let text = Self.wholeNumber(fraction)
        let heroSize = Self.heroSize(base: baseSize, digits: text.count)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: text)
                .font(Design.heroFont(size: heroSize))
                .monospacedDigit()
                .foregroundStyle(Design.inkPrimary)
            Text(verbatim: "%")
                .font(Design.heroFont(size: heroSize * Self.heroUnitRatio))
                .foregroundStyle(Design.inkFaint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    /// Whisper section header (L's "Cores · N" / "Top by CPU" column titles).
    @ViewBuilder
    private func sectionLabel(_ text: String, scale: Design.TypeScale) -> some View {
        Text(verbatim: text)
            .font(Design.labelFont(size: scale.label))
            .tracking(Design.labelTracking(size: scale.label))
            .foregroundStyle(Design.inkFaint)
            .lineLimit(1)
    }

    /// B-tier temperature capsule (S) — cool→warm dot plus the reading in the user's unit.
    @ViewBuilder
    private func temperatureCapsule(_ celsius: Double, scale: Design.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.5) {
            Circle()
                .fill(Design.temperatureColor(celsius))
                .frame(width: scale.caption * 0.62, height: scale.caption * 0.62)
                .shadow(color: Design.temperatureColor(celsius).opacity(0.7), radius: 2)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(verbatim: MonitorTemperature.valueText(celsius))
                    .font(Design.subFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(Design.inkPrimary)
                Text(verbatim: MonitorTemperature.symbol)
                    .font(Design.captionFont(size: scale.caption * 0.68))
                    .foregroundStyle(Design.inkFaint)
            }
            Text("Sensor")
                .font(Design.labelFont(size: scale.label * 0.94))
                .tracking(scale.label * 0.12)
                .foregroundStyle(Design.inkFaint)
        }
        .padding(.vertical, scale.label * 0.3)
        .padding(.leading, scale.label * 0.55)
        .padding(.trailing, scale.label * 0.7)
        .background(
            Capsule(style: .continuous)
                .fill(Design.bg2.opacity(0.5))
                .overlay(Capsule(style: .continuous).strokeBorder(Design.hairlineHi.opacity(0.55), lineWidth: 1))
        )
    }

    @ViewBuilder
    private func compositionBar(scale: Design.TypeScale, centeredLegend: Bool, legendScale: CGFloat) -> some View {
        let user = system?.cpuUser ?? 0
        let sys = system?.cpuSystem ?? 0
        let (userPct, sysPct, idlePct) = Self.compositionPercents(user: user, system: sys)
        VStack(alignment: centeredLegend ? .center : .leading, spacing: scale.label * 0.4) {
            GeometryReader { g in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(LinearGradient(colors: [Design.oklch(0.6, 0.05, 78), Design.signalAmber],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * CGFloat(min(max(user, 0), 1)))
                    Rectangle()
                        .fill(LinearGradient(colors: [Design.oklch(0.5, 0.03, 235), Design.signalSteel],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * CGFloat(min(max(sys, 0), 1)))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: max(scale.caption * 0.72, 6))
            .background(Design.track)
            .clipShape(Capsule(style: .continuous))

            HStack(spacing: scale.label * 0.9) {
                compLegendItem("USER", value: userPct, dot: Design.signalAmber, scale: scale, sizeScale: legendScale)
                compLegendItem("SYS", value: sysPct, dot: Design.signalSteel, scale: scale, sizeScale: legendScale)
                compLegendItem("IDLE", value: idlePct, dot: Design.oklch(0.4, 0.01, 74), scale: scale, sizeScale: legendScale)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: centeredLegend ? .center : .leading)
        }
    }

    @ViewBuilder
    private func compLegendItem(_ label: String, value: Int, dot: Color,
                                scale: Design.TypeScale, sizeScale: CGFloat) -> some View {
        let size = scale.label * sizeScale
        HStack(spacing: size * 0.4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(dot)
                .frame(width: size * 0.6, height: size * 0.6)
            Text(verbatim: "\(label) \(value)%")
                .font(Design.labelFont(size: size))
                .foregroundStyle(Design.inkFaint)
        }
    }

    /// Compact user/sys legend under the M arc (the arc's own two-tone wedges are the primary encoding; this just labels the split with percentages).
    @ViewBuilder
    private func compositionLegend(userPct: Int, sysPct: Int, scale: Design.TypeScale) -> some View {
        VStack(alignment: .leading, spacing: scale.label * 0.3) {
            legendValue("USER", value: userPct, color: Design.signalAmber, scale: scale)
            legendValue("SYS", value: sysPct, color: Design.signalSteel, scale: scale)
        }
        .lineLimit(1)
        .monitorChip(scale)
    }

    @ViewBuilder
    private func legendValue(_ label: String, value: Int, color: Color, scale: Design.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.35) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: scale.label * 0.6, height: scale.label * 0.6)
            Text(verbatim: "\(label) \(value)%")
                .font(Design.labelFont(size: scale.label * 0.95))
                .foregroundStyle(Design.inkFaint)
                .monospacedDigit()
        }
    }

    /// "PEAK n%" tag pinned inside the top-right of the M load curve (was a separate row under the arc).
    @ViewBuilder
    private func peakInlineTag(scale: Design.TypeScale) -> some View {
        let size = scale.label * 0.9
        HStack(alignment: .firstTextBaseline, spacing: size * 0.3) {
            Text(verbatim: "PEAK")
                .font(Design.labelFont(size: size))
                .tracking(size * 0.1)
                .foregroundStyle(Design.inkFaint)
            Text(verbatim: Self.wholePercent(peakFraction))
                .font(Design.subFont(size: size))
                .monospacedDigit()
                .foregroundStyle(Design.inkMuted)
        }
        .monitorChip(scale)
        .padding(size * 0.3)
    }

    /// Per-core heat strip (M, compact): clusters side by side.
    @ViewBuilder
    private func coreHeatStrip(scale: Design.TypeScale) -> some View {
        if let groups = Self.coreGroupLoads(perCore: system?.perCore, cpuInfo: system?.cpuInfo), !groups.isEmpty {
            let rowCounts = groups.map {
                Self.coreStripRows(coreCount: $0.loads.count, cap: Self.compactCoreCellsPerRow)
            }
            let bandHeight = Self.coreStripBandHeight(
                base: max(scale.caption * 1.25, 13),
                rows: rowCounts.max() ?? 1,
                gap: Self.compactCoreCellGap
            )
            HStack(alignment: .top, spacing: scale.label * 0.9) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    let rows = rowCounts[index]
                    VStack(alignment: .leading, spacing: scale.label * 0.3) {
                        clusterLabel(group, scale: scale)
                        heatCellGrid(
                            group.loads,
                            rows: rows,
                            rowHeight: (bandHeight - Self.compactCoreCellGap * CGFloat(rows - 1)) / CGFloat(rows),
                            gap: Self.compactCoreCellGap
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Lay a cluster's cells into `rows` rows of `rowHeight`, padding the short last row so cells stay column-aligned with the rows above.
    @ViewBuilder
    private func heatCellGrid(_ loads: [Double], rows: Int, rowHeight: CGFloat, gap: CGFloat) -> some View {
        let rowCount = max(rows, 1)
        let perRow = Self.coreStripCellsPerRow(coreCount: loads.count, rows: rowCount)
        VStack(spacing: gap) {
            ForEach(0..<rowCount, id: \.self) { row in
                let slice = Array(loads.dropFirst(row * perRow).prefix(perRow))
                HStack(spacing: gap) {
                    ForEach(Array(slice.enumerated()), id: \.offset) { _, load in
                        HeatCell(load: load, height: rowHeight)
                    }
                    if slice.count < perRow {
                        ForEach(0..<(perRow - slice.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: rowHeight)
                        }
                    }
                }
            }
        }
    }

    /// Per-core heat strip (L, tall): clusters stacked, each wrapping into as
    /// many full-width rows as its core count needs.
    @ViewBuilder
    private func coreHeatStripTall(groups: [CoreGroupLoads], scale: Design.TypeScale) -> some View {
        VStack(alignment: .leading, spacing: scale.label * 0.5) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: scale.label * 0.3) {
                    clusterLabel(group, scale: scale)
                    heatCellGrid(
                        group.loads,
                        rows: Self.coreStripRows(coreCount: group.loads.count, cap: Self.tallCoreCellsPerRow),
                        rowHeight: max(scale.caption * 1.35, 14),
                        gap: Self.tallCoreCellGap
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func clusterLabel(_ group: CoreGroupLoads, scale: Design.TypeScale) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.label * 0.5) {
            Text(verbatim: group.name.uppercased())
                .font(Design.labelFont(size: scale.label * 0.86))
                .tracking(scale.label * 0.16)
                .foregroundStyle(Design.inkFaint)
                .opacity(0.72)
            Text(verbatim: "·\(group.loads.count)")
                .font(Design.labelFont(size: scale.label * 0.86))
                .monospacedDigit()
                .foregroundStyle(Design.inkFaint)
                .opacity(0.72)
        }
    }

    @ViewBuilder
    private func sensorRow(scale: Design.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.7) {
            Spacer(minLength: 0)
            if let temp = cpuTempC { sensorReading(dot: Design.temperatureColor(temp),
                                                    value: MonitorTemperature.valueText(temp), unit: MonitorTemperature.symbol, scale: scale) }
            if let rpm = fanRPM { sensorReading(dot: Design.signalSteel,
                                                value: Self.rpmValue(rpm), unit: "RPM", scale: scale) }
        }
    }

    @ViewBuilder
    private func sensorStrip(scale: Design.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.9) {
            // `inkMuted` for the same reason as the GPU card's sensor row:
            // the strip sits on the darkest end of the panel falloff, where
            // `inkFaint` (L=0.505) reads as cut off rather than as quiet.
            Text(verbatim: "SMC")
                .font(Design.labelFont(size: scale.label))
                .tracking(Design.labelTracking(size: scale.label))
                .foregroundStyle(Design.inkMuted)
            if let temp = cpuTempC { sensorReading(dot: Design.temperatureColor(temp),
                                                   value: MonitorTemperature.valueText(temp), unit: MonitorTemperature.symbol, scale: scale) }
            if cpuTempC != nil && fanRPM != nil {
                Text(verbatim: "·").font(Design.captionFont(size: scale.caption)).foregroundStyle(Design.inkFaint).opacity(0.5)
            }
            if let rpm = fanRPM { sensorReading(dot: Design.signalSteel,
                                                value: Self.rpmValue(rpm), unit: "RPM", scale: scale) }
            Spacer(minLength: 0)
        }
        .padding(.top, scale.label * 0.4)
        .overlay(alignment: .top) {
            Rectangle().fill(Design.hairline.opacity(0.45)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func sensorReading(dot: Color, value: String, unit: String, scale: Design.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.4) {
            Circle().fill(dot)
                .frame(width: scale.label * 0.55, height: scale.label * 0.55)
                .shadow(color: dot.opacity(0.6), radius: 2)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(verbatim: value)
                    .font(Design.subFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(Design.inkPrimary)
                Text(verbatim: unit)
                    .font(Design.captionFont(size: scale.caption * 0.7))
                    .foregroundStyle(Design.inkMuted)
            }
        }
    }

    @ViewBuilder
    private func thermalPill(scale: Design.TypeScale) -> some View {
        let state = system?.thermalState ?? "nominal"
        HStack(spacing: scale.label * 0.45) {
            Circle().fill(Design.signalAmber)
                .frame(width: scale.label * 0.5, height: scale.label * 0.5)
                .shadow(color: Design.signalAmber.opacity(0.6), radius: 2)
            Text(verbatim: "thermal")
                .font(Design.labelFont(size: scale.label * 0.92))
                .tracking(scale.label * 0.1)
                .foregroundStyle(Design.inkFaint)
            Text(verbatim: state.capitalized)
                .font(Design.subFont(size: scale.label))
                .foregroundStyle(Design.inkPrimary)
        }
        .monitorChip(scale)
    }

    @ViewBuilder
    private func procRows(_ procs: [MonitorProcessSample], scale: Design.TypeScale) -> some View {
        let maxCPU = procs.map(\.cpuPercent).max() ?? 1
        VStack(spacing: scale.label * 0.35) {
            ForEach(Array(procs.enumerated()), id: \.offset) { _, proc in
                HStack(spacing: scale.label * 0.5) {
                    HStack(spacing: scale.label * 0.4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Design.inkFaint.opacity(0.7))
                            .frame(width: scale.label * 0.5, height: scale.label * 0.5)
                        Text(verbatim: proc.name)
                            .font(Design.captionFont(size: scale.caption))
                            .foregroundStyle(Design.inkPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    GeometryReader { g in
                        Capsule(style: .continuous).fill(Design.track2)
                            .overlay(alignment: .leading) {
                                Capsule(style: .continuous)
                                    .fill(LinearGradient(colors: [Design.oklch(0.6, 0.05, 78), Design.signalAmber],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: g.size.width * CGFloat(Self.barFraction(proc.cpuPercent, maxCPU: maxCPU)))
                            }
                    }
                    .frame(width: scale.caption * 2, height: max(scale.caption * 0.42, 4))

                    Text(verbatim: Self.cpuText(proc.cpuPercent))
                        .font(Design.subFont(size: scale.caption))
                        .monospacedDigit()
                        .foregroundStyle(Design.signalAmber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: scale.caption * 2.1, alignment: .trailing)

                    Text(verbatim: Format.bytes(proc.memBytes))
                        .font(Design.captionFont(size: scale.caption * 0.94))
                        .monospacedDigit()
                        .foregroundStyle(Design.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: scale.caption * 3.4, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func loadStatus(scale: Design.TypeScale, triple: Bool) -> some View {
        if let text = Self.loadText(system: system, triple: triple) {
            (Text("load") + Text(verbatim: " \(text)"))
                .font(Design.subFont(size: scale.label))
                .monospacedDigit()
                .foregroundStyle(Design.inkMuted)
                .monitorChip(scale)
        }
    }

    /// Identity row — device name (emphasised) + whispered core-group summary.
    @ViewBuilder
    private func identityRow(_ identity: CPUIdentity, scale: Design.TypeScale) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.label * 0.5) {
            if let device = identity.deviceName {
                Text(verbatim: device)
                    .font(Design.subFont(size: scale.sub * 0.92))
                    .foregroundStyle(Design.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            if let summary = identity.coreSummary {
                Text(verbatim: "· \(summary)")
                    .font(Design.labelFont(size: scale.label))
                    .tracking(scale.label * 0.06)
                    .foregroundStyle(Design.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

// MARK: - Small components

private struct HeatCell: View {
    var load: Double
    var height: CGFloat? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        let base = shape
            .fill(Design.track2)
            .overlay(shape.fill(Self.loadColor(load)).opacity(0.32 + min(1, max(0, load)) * 0.62))
            .overlay(shape.strokeBorder(Color.black.opacity(0.3), lineWidth: 1))
            .frame(maxWidth: .infinity)
        if let height {
            base.frame(height: height)
        } else {
            base.aspectRatio(1, contentMode: .fit)
        }
    }

    /// Per-core UTILISATION ramp: green (idle) → amber → red (busy), by rotating the OKLCH hue 150°→30° with load.
    static func loadColor(_ value: Double) -> Color {
        let x = min(1, max(0, value))
        return Design.oklch(0.72, 0.15, 150 - 120 * x)
    }
}

private struct CPUStackChart: View {
    var user: [Double]
    var system: [Double]

    var body: some View {
        GeometryReader { geo in
            let n = min(user.count, system.count)
            if n >= 2 {
                let w = geo.size.width, h = geo.size.height
                let u = Array(user.suffix(n)), s = Array(system.suffix(n))
                ZStack {
                    Canvas { ctx, size in draw(ctx, size: size, u: u, s: s, n: n) }
                    let head = min(max(u[n - 1] + s[n - 1], 0), 1)
                    Circle()
                        .fill(Design.signalAmber)
                        .frame(width: 6, height: 6)
                        .shadow(color: Design.signalAmber.opacity(0.6), radius: 3)
                        .position(x: w - 3, y: h - CGFloat(head) * (h - 3) - 1.5)
                }
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, u: [Double], s: [Double], n: Int) {
        let W = size.width, H = size.height
        func X(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(n - 1) * W }
        func Y(_ f: Double) -> CGFloat { H - CGFloat(min(max(f, 0), 1)) * (H - 3) - 1.5 }

        for g in [0.25, 0.5, 0.75] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: Y(g)))
            p.addLine(to: CGPoint(x: W, y: Y(g)))
            ctx.stroke(p, with: .color(Design.hairlineHi.opacity(0.28)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        var uTop = [CGPoint](), sTop = [CGPoint]()
        for i in 0..<n {
            uTop.append(CGPoint(x: X(i), y: Y(u[i])))
            sTop.append(CGPoint(x: X(i), y: Y(u[i] + s[i])))
        }

        func area(_ tops: [CGPoint]) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: Y(0)))
            for point in tops { p.addLine(to: point) }
            p.addLine(to: CGPoint(x: W, y: Y(0)))
            p.closeSubpath()
            return p
        }
        ctx.fill(area(sTop), with: .linearGradient(
            Gradient(colors: [Design.signalSteel.opacity(0.32), Design.signalSteel.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: H)))
        ctx.fill(area(uTop), with: .linearGradient(
            Gradient(colors: [Design.signalAmber.opacity(0.5), Design.signalAmber.opacity(0.03)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: H)))

        var sLine = Path(); sLine.addLines(sTop)
        ctx.stroke(sLine, with: .color(Design.signalSteel.opacity(0.8)),
                   style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        var uLine = Path(); uLine.addLines(uTop)
        ctx.stroke(uLine, with: .color(Design.signalAmber),
                   style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }
}

private struct CPUStateDot: View {
    var fraction: Double

    var body: some View {
        let pct = fraction * 100
        let color: Color = pct > 85 ? Design.signalCoral
            : (pct > 60 ? Design.signalAmber : Design.signalIdle)
        BreathingDot(color: color, size: 6, animated: pct > 60)
    }
}

// MARK: - Per-widget options (read side + pure draft mutations, unit-tested)

enum MonitorCPUDraft {
    static let historyWindowKey = "historyWindow"
    static let showHeatmapKey = "showHeatmap"
    static let showCompositionKey = "showComposition"
    static let showSensorsKey = "showSensors"
    static let showTrendKey = "showTrend"

    static let historyWindowChoices = [30, 60, 120]

    static func defaultHistoryWindow(for size: MonitorWidgetSize) -> Int {
        switch size {
        case .small: return 30
        case .medium: return 60
        case .large: return 120
        }
    }

    static func historyWindow(_ placement: MonitorWidgetPlacement) -> Int {
        guard let value = placement.options[historyWindowKey]?
            .intValue(clampedTo: 0 ... Int.max) else {
            return defaultHistoryWindow(for: placement.size)
        }
        return historyWindowChoices.contains(value) ? value : defaultHistoryWindow(for: placement.size)
    }

    static func settingHistoryWindow(_ value: Int, on placement: MonitorWidgetPlacement) -> MonitorWidgetPlacement {
        let clamped = historyWindowChoices.contains(value) ? value : defaultHistoryWindow(for: placement.size)
        var next = placement
        next.options[historyWindowKey] = .number(Double(clamped))
        return next
    }

    static func showHeatmap(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[showHeatmapKey]?.boolValue ?? true
    }

    static func showComposition(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[showCompositionKey]?.boolValue ?? true
    }

    static func showSensors(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[showSensorsKey]?.boolValue ?? true
    }

    static func showTrend(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[showTrendKey]?.boolValue ?? true
    }
}

// MARK: - Pure layout logic (tested)

extension CPUWidgetView {
    struct CPUIdentity: Equatable {
        var deviceName: String?
        var coreSummary: String?
    }

    struct CoreGroupLoads: Equatable {
        var name: String
        var loads: [Double]
    }

    nonisolated static func wholePercent(_ fraction: Double) -> String {
        "\(wholeNumber(fraction))%"
    }

    /// 0…1 → whole-number string with no "%" ("37"); same clamp/round as
    /// `wholePercent`, for callers that append their own separately-styled unit.
    nonisolated static func wholeNumber(_ fraction: Double) -> String {
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return "\(Int((f * 100).rounded()))"
    }

    /// The "%" is drawn at this fraction of the digits' size at every call site.
    nonisolated static let heroUnitRatio: CGFloat = 0.4

    /// Tallest ring the M and L tiles draw, at every board scale.
    nonisolated static let gaugeSideCap: CGFloat = 96

    /// Chrome stacked above the M ring at the smallest type size the scale
    /// produces: 22 pt of `WidgetContainer` vertical inset, its header, and the
    /// row spacing under it. Measured headless, board scales 0.7…2.0.
    nonisolated static let gaugeChromeBase: CGFloat = 41
    /// What the identity row and its spacing add to `gaugeChromeBase`.
    nonisolated static let gaugeChromeIdentityRow: CGFloat = 19
    /// What the composition legend and its spacing add to `gaugeChromeBase`.
    nonisolated static let gaugeChromeCompositionLegend: CGFloat = 38.3
    /// Legend chip width as a multiple of `scale.label`. Measured at its widest
    /// reading ("USER 100%" / "SYS 100%", both `Text(verbatim:)`, so no locale
    /// widens them): 80.00 pt at the 10 pt label, 81.72 at 10.625, 91.90 at 12 —
    /// ratios 8.00 / 7.69 / 7.66, the peak being the 10 pt label where the 0.95×
    /// legend font is still clamped up. 8.05 rather than a knife-edge 8.00 so
    /// the chip is never a rounding error away from truncating.
    nonisolated static let gaugeLegendSlots: CGFloat = 8.05

    /// Width the arc-gauge column reserves. Pure in these inputs, so the trend
    /// (M) / detail (L) column beside it holds still while the reading changes.
    ///
    /// It is an upper BOUND of the ring, not the ring: `ArcGauge` is
    /// `aspectRatio(1, .fit)` and draws whatever height its row is left with,
    /// so a column that reported that height moved every time the ring did.
    /// The ring keeps its `gaugeSideCap` height cap and comes out the same size
    /// as before at every board scale measured (M 20.70 / 45.20 / 67.70 / 96 /
    /// 96 / 96 pt at 0.7 … 2.0).
    ///
    /// M subtracts the chrome from the tile's own height (`cellHeight * 2`),
    /// taking the chrome at its smallest: chrome only grows with type size, so
    /// the minimum can only over-reserve, never clip the ring. That term alone
    /// strands at most 4.0 pt (board scale 1.0), against the 28.3 pt the
    /// `maxWidth: 96` this replaced stranded there. The legend floor is what
    /// actually sets the column below board scale 1.25, where the legend chip is
    /// wider than the ring — and where its own width used to swing 13.0 pt as
    /// the reading went from one digit to three, dragging the trend curve with
    /// it. Column at 0.7 … 2.0 is 80.50 / 80.50 / 80.50 / 96 / 96 / 96 pt.
    ///
    /// L takes the cap flat: its ring already reaches 96 pt whenever the core
    /// strip or the process list is absent (the row's residual measured 101.1 pt
    /// at board scale 0.7 with both gone), and both come and go, so nothing
    /// tighter holds for every L tile.
    nonisolated static func gaugeSide(
        cellHeight: CGFloat, rows: Int,
        hasIdentityRow: Bool, hasCompositionLegend: Bool
    ) -> CGFloat {
        guard rows == 1 else { return gaugeSideCap }
        var chrome = gaugeChromeBase
        if hasIdentityRow {
            chrome += gaugeChromeIdentityRow
        }
        if hasCompositionLegend {
            chrome += gaugeChromeCompositionLegend
        }
        let legend = hasCompositionLegend
            ? Design.TypeScale(cellHeight: cellHeight).label * gaugeLegendSlots
            : 0
        return min(gaugeSideCap, max(0, legend, cellHeight * 2 - chrome))
    }

    /// Size the hero digits shrink to once the reading needs three of them.
    ///
    /// "100%" is 1.382× as wide as "20%" at the same size (CTLine, semibold
    /// monospaced-digit system font, measured across the whole 21.6…48.3 pt
    /// hero range this widget produces). The M ring's centre box is
    /// `side * 0.62` = 41.97 pt on a 356×170 tile, so "100%" at the unshrunk
    /// 32.13 pt needed a 0.561 scale — under `minimumScaleFactor(0.6)`, and
    /// SwiftUI truncates rather than overshooting the floor: the reading came
    /// out as "1…". At 0.68 the tightest tile over board scales 0.85…2.0 needs
    /// 0.62, and the desktop board's own M tile needs 0.82.
    nonisolated static let threeDigitHeroShrink: CGFloat = 0.68

    /// Hero size for a `digits`-digit readout. Only full load reaches three.
    nonisolated static func heroSize(base: CGFloat, digits: Int) -> CGFloat {
        digits >= 3 ? base * threeDigitHeroShrink : base
    }

    nonisolated static func rpmValue(_ rpm: Double) -> String {
        let value = rpm.isFinite ? max(rpm, 0) : 0
        return "\(Int(value.rounded()))"
    }

    nonisolated static func loadAvg(_ value: Double) -> String {
        String(format: "%.2f", value.isFinite ? max(value, 0) : 0)
    }

    /// Header load readout: 1-min average (M) or the 1·5·15 triple (L). Prefers
    /// `cpuLoadAvg`, falls back to `loadAverage1`; nil when nothing is reported.
    nonisolated static func loadText(system: MonitorSystemSnapshot?, triple: Bool) -> String? {
        guard let system else { return nil }
        if triple, let avg = system.cpuLoadAvg, !avg.isEmpty {
            return avg.prefix(3).map { loadAvg($0) }.joined(separator: " · ")
        }
        if let one = system.loadAverage1 ?? system.cpuLoadAvg?.first {
            return loadAvg(one)
        }
        return nil
    }

    nonisolated static func cpuText(_ cpuPercent: Double) -> String {
        let v = cpuPercent.isFinite ? max(cpuPercent, 0) : 0
        return v < 10 ? String(format: "%.1f", v) : "\(Int(v.rounded()))"
    }

    nonisolated static func barFraction(_ cpuPercent: Double, maxCPU: Double) -> Double {
        min(max(cpuPercent / max(maxCPU, .ulpOfOne), 0), 1)
    }

    nonisolated static func compositionPercents(user: Double, system: Double) -> (user: Int, system: Int, idle: Int) {
        let u = Int((min(max(user, 0), 1) * 100).rounded())
        let s = Int((min(max(system, 0), 1) * 100).rounded())
        let idle = max(0, 100 - u - s)
        return (u, s, idle)
    }

    nonisolated static func topCPUProcesses(_ processes: [MonitorProcessSample]?, limit: Int) -> [MonitorProcessSample]? {
        guard let processes, !processes.isEmpty else { return nil }
        let sorted = processes.enumerated().sorted { lhs, rhs in
            lhs.element.cpuPercent != rhs.element.cpuPercent
                ? lhs.element.cpuPercent > rhs.element.cpuPercent
                : lhs.offset < rhs.offset
        }.map(\.element)
        return Array(sorted.prefix(max(0, limit)))
    }

    // MARK: Core heat strip geometry

    /// Cell spacing in the M strip and in the L strip. Both feed
    /// `coreStripBandHeight` and the width each cell ends up with, so the two
    /// numbers live next to the caps they were chosen against.
    nonisolated static let compactCoreCellGap: CGFloat = 2
    nonisolated static let tallCoreCellGap: CGFloat = 3

    /// Widest row the M strip allows. A 2-cluster M tile gives each cluster
    /// ~102 pt (356 pt tile − 32 pt inset − 104 pt gauge column − 7 pt − 9 pt,
    /// halved), so 8 cells with 2 pt gaps are 11.5 pt wide. Equal to the cap the
    /// strip already enforced as `count > 8 ? 2 : 1` rows, so every cluster of
    /// 16 or fewer cores lays out exactly as it did.
    nonisolated static let compactCoreCellsPerRow = 8

    /// Widest row the L strip allows. Its cluster column is ~157 pt (356 − 32 −
    /// 9, halved with the process column), so 12 cells at 3 pt gaps are 10.4 pt
    /// wide — the width the 12-core cluster on an 18-core Mac already draws at.
    /// Before this cap the L strip put a whole cluster in one row: a 24-core
    /// cluster came out 3.7 pt wide, and `HeatCell`'s 1 pt inset border eats
    /// 2 pt of that.
    nonisolated static let tallCoreCellsPerRow = 12

    /// Rows a cluster of `coreCount` cells wraps into so no row exceeds `cap`.
    nonisolated static func coreStripRows(coreCount: Int, cap: Int) -> Int {
        guard coreCount > 0, cap > 0 else { return 1 }
        return (coreCount + cap - 1) / cap
    }

    /// Cells in each row once a cluster is split evenly over `rows`: 18 cores in
    /// 3 rows are 6 + 6 + 6, not 8 + 8 + 2.
    nonisolated static func coreStripCellsPerRow(coreCount: Int, rows: Int) -> Int {
        let rowCount = max(rows, 1)
        return max(1, (max(coreCount, 0) + rowCount - 1) / rowCount)
    }

    /// Height the M strip's shared band needs for `rows`. One and two rows keep
    /// the band the tile was drawn for; past that each extra row adds its own
    /// height instead of subdividing the band into slivers.
    nonisolated static func coreStripBandHeight(base: CGFloat, rows: Int, gap: CGFloat) -> CGFloat {
        let rowCount = CGFloat(max(rows, 1))
        let rowHeight = (base - gap) / 2
        return max(base, rowHeight * rowCount + gap * (rowCount - 1))
    }

    nonisolated static func coreCountText(_ groups: [CoreGroupLoads]) -> String {
        "\(groups.reduce(0) { $0 + $1.loads.count })"
    }

    nonisolated static func identityLine(_ info: MonitorCPUInfo?) -> CPUIdentity? {
        guard let info else { return nil }
        let device = info.deviceName.flatMap { $0.isEmpty ? nil : $0 }

        var summary: String?
        let groups = (info.coreGroups ?? []).filter { $0.physicalCount > 0 }
        let total = info.coreCount ?? (groups.isEmpty ? nil : groups.reduce(0) { $0 + $1.physicalCount })
        if let total, total > 0 {
            let noun = total == 1 ? "core" : "cores"
            if groups.isEmpty {
                summary = "\(total) \(noun)"
            } else {
                let composed = groups.map { "\($0.physicalCount) \($0.name)" }.joined(separator: " + ")
                summary = "\(total) \(noun) (\(composed))"
            }
        } else if !groups.isEmpty {
            summary = groups.map { "\($0.physicalCount) \($0.name)" }.joined(separator: " + ")
        }

        if device == nil && summary == nil { return nil }
        return CPUIdentity(deviceName: device, coreSummary: summary)
    }

    nonisolated static func coreGroupLoads(perCore: [Double]?, cpuInfo: MonitorCPUInfo?) -> [CoreGroupLoads]? {
        guard let perCore, !perCore.isEmpty else { return nil }
        let groups = (cpuInfo?.coreGroups ?? []).filter { $0.physicalCount > 0 }
        guard !groups.isEmpty else {
            return [CoreGroupLoads(name: "CPU", loads: perCore)]
        }

        var result: [CoreGroupLoads] = []
        var offset = 0
        for group in groups {
            guard offset < perCore.count else { break }
            let end = min(offset + group.physicalCount, perCore.count)
            result.append(CoreGroupLoads(name: group.name, loads: Array(perCore[offset..<end])))
            offset = end
        }
        if offset < perCore.count {
            result.append(CoreGroupLoads(name: "CPU", loads: Array(perCore[offset...])))
        }
        return result
    }
}

// MARK: - Previews

#if DEBUG
private extension MonitorWidgetContext {
    static let ultraTopology: (device: String, groups: [(name: String, count: Int)]) =
        ("Apple M5 Ultra", [("Efficiency", 12), ("Performance", 24)])

    static func cpuSample(
        size: MonitorWidgetSize,
        withSensors: Bool,
        showTrend: Bool = true,
        topology: (device: String, groups: [(name: String, count: Int)]) =
            ("Apple M5 Pro", [("Super", 6), ("Performance", 12)])
    ) -> MonitorWidgetContext {
        // Deterministic per-core loads so a synthetic 36-core machine reads the
        // same way on every run; the 18-core case keeps its hand-picked curve.
        let ramp: [Double] = [0.71, 0.58, 0.66, 0.34, 0.52, 0.19,
                              0.44, 0.29, 0.51, 0.12, 0.38, 0.22,
                              0.47, 0.09, 0.33, 0.18, 0.41, 0.15]
        var sys = MonitorSystemSnapshot()
        sys.cpuTotal = 0.37
        sys.cpuUser = 0.26
        sys.cpuSystem = 0.11
        let totalCores = topology.groups.reduce(0) { $0 + $1.count }
        sys.perCore = (0 ..< totalCores).map { ramp[$0 % ramp.count] }
        sys.loadAverage1 = 3.42
        sys.cpuLoadAvg = [3.42, 2.88, 2.41]
        sys.thermalState = "fair"
        sys.cpuInfo = MonitorCPUInfo(
            deviceName: topology.device,
            coreCount: totalCores,
            coreGroups: topology.groups.map { MonitorCPUCoreGroup(name: $0.name, physicalCount: $0.count) }
        )
        sys.topProcesses = [
            MonitorProcessSample(name: "Xcode", cpuPercent: 52, memBytes: UInt64(3.4 * 1_073_741_824)),
            MonitorProcessSample(name: "kernel_task", cpuPercent: 31, memBytes: UInt64(1.2 * 1_073_741_824)),
            MonitorProcessSample(name: "WindowServer", cpuPercent: 23, memBytes: 640 * 1_048_576),
            MonitorProcessSample(name: "claude (Helper)", cpuPercent: 3.2, memBytes: UInt64(1.4 * 1_073_741_824))
        ]
        if withSensors {
            sys.sensors = MonitorSensorReadings(cpuTempC: 42, fanRPM: [1_450, 1_560])
        }

        let curve: [Double] = [
            0.28, 0.31, 0.35, 0.30, 0.42, 0.55, 0.48, 0.39, 0.33, 0.36,
            0.44, 0.52, 0.61, 0.47, 0.38, 0.34, 0.29, 0.33, 0.41, 0.50,
            0.58, 0.63, 0.52, 0.44, 0.37, 0.31, 0.28, 0.35, 0.43, 0.49,
            0.57, 0.51, 0.42, 0.36, 0.32, 0.30, 0.34, 0.40, 0.47, 0.53,
            0.59, 0.50, 0.41, 0.35, 0.33, 0.29, 0.32, 0.38, 0.45, 0.52,
            0.48, 0.40, 0.36, 0.34, 0.31, 0.35, 0.39, 0.44, 0.38, 0.37
        ]
        let now = Date()
        var history = MonitorHistorySnapshot()
        history.sampleTimes = curve.indices.map {
            now.timeIntervalSince1970 - Double(curve.count - 1 - $0)
        }
        history.cpuTotal = curve
        history.cpuUser = curve.map { $0 * 0.7 }
        history.cpuSystem = curve.map { $0 * 0.3 }
        history.cpuPeak = 0.63

        var snapshot = MonitorSnapshot()
        snapshot.system = sys

        var placement = MonitorWidgetPlacement(kind: .cpu, size: size)
        if !showTrend { placement.options[MonitorCPUDraft.showTrendKey] = .bool(false) }

        return MonitorWidgetContext(
            snapshot: snapshot,
            history: history,
            placement: placement,
            isEditing: false,
            reduceMotion: false,
            now: now
        )
    }
}

#Preview("CPU · S") {
    HStack(spacing: 20) {
        CPUWidgetView(context: .cpuSample(size: .small, withSensors: false))
            .frame(width: 170, height: 170)
        CPUWidgetView(context: .cpuSample(size: .small, withSensors: true))
            .frame(width: 170, height: 170)
        CPUWidgetView(context: .cpuSample(size: .small, withSensors: true, showTrend: false))
            .frame(width: 170, height: 170)
    }
    .padding(32)
    .background(Design.boardWash)
}

#Preview("CPU · M") {
    VStack(spacing: 20) {
        CPUWidgetView(context: .cpuSample(size: .medium, withSensors: false))
            .frame(width: 364, height: 170)
        CPUWidgetView(context: .cpuSample(size: .medium, withSensors: true))
            .frame(width: 364, height: 170)
    }
    .padding(32)
    .background(Design.boardWash)
}

#Preview("CPU · L") {
    HStack(spacing: 20) {
        CPUWidgetView(context: .cpuSample(size: .large, withSensors: false))
            .frame(width: 364, height: 376)
        CPUWidgetView(context: .cpuSample(size: .large, withSensors: true))
            .frame(width: 364, height: 376)
    }
    .padding(32)
    .background(Design.boardWash)
}

// A machine nobody here owns: 36 cores is where the core strip used to squeeze
// a cluster below its own cell border.
#Preview("CPU · 36 cores") {
    let topology = MonitorWidgetContext.ultraTopology
    HStack(spacing: 20) {
        CPUWidgetView(context: .cpuSample(size: .medium, withSensors: true, topology: topology))
            .frame(width: 356, height: 170)
        CPUWidgetView(context: .cpuSample(size: .large, withSensors: true, topology: topology))
            .frame(width: 356, height: 356)
    }
    .padding(32)
    .background(Design.boardWash)
}
#endif
