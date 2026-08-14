import SwiftUI
import LiveWallpaperCore

struct NetworkWidgetView: View {
    let context: MonitorWidgetContext

    private static let rxColor = Design.signalAmber
    private static let txColor = Design.signalSteel

    private static let smallChartWindowSamples = 30
    private static let mediumChartWindowSamples = 60
    private static let largeChartWindowSamples = 120

    private var snapshot: MonitorSnapshot { context.snapshot }
    private var system: MonitorSystemSnapshot? { snapshot.system }
    private var history: MonitorHistorySnapshot { context.history }

    var body: some View {
        GeometryReader { geo in
            let rowSpan: CGFloat = context.placement.size == .large ? 2 : 1
            let cellHeight = geo.size.height / (2 * rowSpan)
            WidgetContainer(
                label: "Network",
                systemImage: headerSymbol,
                cellHeight: cellHeight,
                status: { headerStatus(cellHeight: cellHeight) },
                content: {
                    switch context.placement.size {
                    case .small: smallBody(cellHeight: cellHeight)
                    case .medium: mediumBody(cellHeight: cellHeight)
                    case .large: largeBody(cellHeight: cellHeight)
                    }
                }
            )
        }
    }

    // MARK: - Header

    /// Active-interface type drives the glyph; falls back to a generic network dot.
    private var headerSymbol: String {
        switch activeInterfaceType {
        case "wifi": return "wifi"
        case "wiredEthernet", "wired": return "cable.connector"
        case "cellular": return "antenna.radiowaves.left.and.right"
        default: return "network"
        }
    }

    @ViewBuilder
    private func headerStatus(cellHeight: CGFloat) -> some View {
        let scale = Design.TypeScale(cellHeight: cellHeight)
        HStack(spacing: 5) {
            if let name = headerInterfaceLabel {
                Text(verbatim: name)
                    .font(Design.subFont(size: scale.label))
                    .foregroundStyle(Design.inkMuted)
            }
            connectivityDot
        }
    }

    /// S shows the short interface label ("Wi-Fi"); M shows "en0 · Wi-Fi".
    private var headerInterfaceLabel: String? {
        switch context.placement.size {
        case .small:
            let typeLabel = Format.interfaceTypeLabel(activeInterfaceType)
            if !typeLabel.isEmpty { return typeLabel }
            return activeInterface?.name
        case .medium, .large:
            guard let iface = activeInterface else {
                let typeLabel = Format.interfaceTypeLabel(activeInterfaceType)
                return typeLabel.isEmpty ? nil : typeLabel
            }
            let typeLabel = Format.interfaceTypeLabel(activeInterfaceType)
            return typeLabel.isEmpty ? iface.name : "\(iface.name) · \(typeLabel)"
        }
    }

    private var connectivityDot: some View {
        Circle()
            .fill(isOnline ? Design.signalSage : Design.signalCoral)
            .frame(width: 6, height: 6)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
            .shadow(color: (isOnline ? Design.signalSage : Design.signalCoral)
                .opacity(0.6), radius: 3)
    }

    // MARK: - Small (2×2)

    @ViewBuilder
    private func smallBody(cellHeight: CGFloat) -> some View {
        let scale = Design.TypeScale(cellHeight: cellHeight)
        VStack(alignment: .leading, spacing: scale.label * 0.5) {
            dualRate(scale: scale)
            mirroredScope(scale: scale, windowSamples: Self.smallChartWindowSamples)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Medium (4×2) / Large (4×4)

    @ViewBuilder
    private func mediumBody(cellHeight: CGFloat) -> some View {
        scopeBody(cellHeight: cellHeight, isLarge: false)
    }

    @ViewBuilder
    private func largeBody(cellHeight: CGFloat) -> some View {
        scopeBody(cellHeight: cellHeight, isLarge: true)
    }

    /// Preserves a 30-point chart floor while allowing it to absorb font-metric changes.
    @ViewBuilder
    private func scopeBody(cellHeight: CGFloat, isLarge: Bool) -> some View {
        let scale = Design.TypeScale(cellHeight: cellHeight)
        let rowSpacing = scale.label * (isLarge ? 0.8 : 0.6)
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                currentPairLabel(scale: scale)
                Spacer(minLength: 6)
                Text(verbatim: "\(Format.rate(rxRate)) · \(Format.rate(txRate))")
                    .font(Design.subFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(Design.inkPrimary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            mirroredScope(scale: scale, windowSamples:
                isLarge ? Self.largeChartWindowSamples : Self.mediumChartWindowSamples)
                .overlay(alignment: .topTrailing) { peakTag(scale: scale) }

            if activeInterface != nil {
                interfaceDetail(scale: scale)
            }

            HStack(alignment: .firstTextBaseline) {
                if let errN = errorCount {
                    healthCorner(errorCount: errN, scale: scale)
                }
                Spacer(minLength: 6)
                sessionTotalTag(scale: scale)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func mirroredScope(scale: Design.TypeScale, windowSamples: Int) -> some View {
        MirroredAreaChart(
            up: Self.tail(history.netRx, count: windowSamples),
            down: Self.tail(history.netTx, count: windowSamples),
            upColor: Self.rxColor,
            downColor: Self.txColor
        )
        .frame(minHeight: scale.caption * 3)
        .frame(maxHeight: .infinity)
    }

    private func currentPairLabel(scale: Design.TypeScale) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: "↓").foregroundStyle(Self.rxColor)
            Text(verbatim: " RX  ").foregroundStyle(Design.inkFaint)
            Text(verbatim: "↑").foregroundStyle(Self.txColor)
            Text(verbatim: " TX").foregroundStyle(Design.inkFaint)
        }
        .font(Design.labelFont(size: scale.label))
        .tracking(Design.labelTracking(size: scale.label))
    }

    private func peakTag(scale: Design.TypeScale) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Design.oklch(0.72, 0.09, 60).opacity(0.85))
                .frame(width: 5, height: 5)
            Text(verbatim: "↓ PEAK")
                .tracking(Design.labelTracking(size: scale.label))
                .foregroundStyle(Design.inkFaint)
            Text(verbatim: Format.rate(history.netRxPeak))
                .monospacedDigit()
                .foregroundStyle(Design.inkMuted)
        }
        .font(Design.labelFont(size: scale.label))
        .monitorChip(scale)
        .padding(scale.label * 0.3)
    }

    /// Session-total Σ, chip-wrapped like every other small board annotation.
    private func sessionTotalTag(scale: Design.TypeScale) -> some View {
        Text(verbatim: "Σ \(Format.bytes(sessionTotalBytes))")
            .font(Design.captionFont(size: scale.label))
            .foregroundStyle(Design.inkFaint)
            .monitorChip(scale)
    }

    @ViewBuilder
    private func interfaceDetail(scale: Design.TypeScale) -> some View {
        VStack(alignment: .leading, spacing: scale.caption * 0.34) {
            if let ip = privateIPv4 {
                interfaceRow(key: "IPv4", value: ip, scale: scale)
            }
            interfaceRow(
                key: String(localized: "Status", comment: "Network widget: connectivity status row label."),
                value: statusLine, scale: scale, chips: pathChips)
        }
        .padding(.top, scale.caption * 0.35)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Design.hairline.opacity(0.4))
                .frame(height: Design.hairlineWidth)
        }
    }

    @ViewBuilder
    private func interfaceRow(
        key: String, value: String, scale: Design.TypeScale, chips: [String] = []
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: key.uppercased())
                .font(Design.labelFont(size: scale.caption * 0.86))
                .tracking(scale.caption * 0.10)
                .foregroundStyle(Design.inkFaint)
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Text(verbatim: value)
                    .font(Design.subFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(Design.inkPrimary)
                    .truncationMode(.tail)
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    warnChip(chip, scale: scale)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// Semantic (warn-coral) chip — keeps its own color, but the capsule shape
    /// and padding now match the board-wide `monitorChip` proportions.
    private func warnChip(_ text: String, scale: Design.TypeScale) -> some View {
        Text(verbatim: text.uppercased())
            .font(Design.labelFont(size: scale.label * 0.92))
            .tracking(scale.label * 0.10)
            .foregroundStyle(Design.oklch(0.9, 0.03, 44))
            .padding(.horizontal, scale.label * 0.5)
            .padding(.vertical, scale.label * 0.24)
            .background(
                Capsule(style: .continuous).fill(Design.oklch(0.3, 0.05, 44, alpha: 0.28))
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(Design.oklch(0.5, 0.11, 40, alpha: 0.75), lineWidth: 1)
            )
    }

    private func healthCorner(errorCount: Int, scale: Design.TypeScale) -> some View {
        let clean = errorCount == 0
        return HStack(spacing: 5) {
            Circle()
                .fill(clean ? Design.signalSage : Design.signalCoral)
                .frame(width: 5, height: 5)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                .shadow(color: (clean ? Design.signalSage : Design.signalCoral)
                    .opacity(0.6), radius: 2)
            if clean {
                Text("no errors · no drops")
            } else {
                (Text(verbatim: "\(errorCount)").font(Design.subFont(size: scale.label))
                    .foregroundStyle(Design.inkMuted)
                 + Text(verbatim: " ") + Text("errors/drops"))
            }
        }
        .font(Design.labelFont(size: scale.label * 0.98))
        .tracking(scale.label * 0.04)
        .foregroundStyle(clean ? Design.inkFaint : Design.oklch(0.86, 0.06, 40))
        .monitorChip(scale)
    }

    // MARK: - Shared rate readout

    private func dualRate(scale: Design.TypeScale) -> some View {
        let size = scale.sub * 1.12
        return VStack(alignment: .leading, spacing: scale.label * 0.35) {
            rateRow(label: "↓", labelColor: Self.rxColor,
                    text: Format.rate(rxRate),
                    font: Design.subFont(size: size),
                    unitSize: size * 0.62)
            rateRow(label: "↑", labelColor: Self.txColor,
                    text: Format.rate(txRate),
                    font: Design.subFont(size: size),
                    unitSize: size * 0.62)
        }
    }

    private func rateRow(
        label: String, labelColor: Color, text: String, font: Font, unitSize: CGFloat
    ) -> some View {
        let parts = Self.splitRate(text)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: label)
                .font(font)
                .foregroundStyle(labelColor)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: parts.value)
                    .font(font)
                    .monospacedDigit()
                    .foregroundStyle(Design.inkPrimary)
                if !parts.unit.isEmpty {
                    Text(verbatim: parts.unit)
                        .font(Design.microFont(size: unitSize))
                        .foregroundStyle(Design.inkFaint)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    // MARK: - Derived data

    private var rxRate: Double { system?.netRxBytesPerSec ?? 0 }
    private var txRate: Double { system?.netTxBytesPerSec ?? 0 }

    private var isOnline: Bool { (system?.netPath?.status ?? "unknown") == "satisfied" }

    private var sessionTotalBytes: Double {
        history.netRxSessionBytes + history.netTxSessionBytes
    }

    /// Active interface: first `isActive`, else highest rx+tx traffic.
    private var activeInterface: MonitorNetworkInterface? {
        Self.pickActiveInterface(system?.netInterfaces)
    }

    private var activeInterfaceType: String? { system?.netPath?.interfaceType }

    private var privateIPv4: String? {
        activeInterface?.addresses?.first(where: Self.isIPv4)
    }

    /// Connectivity word — localized (rendered verbatim as an already-localized
    /// value, since the same row helper also carries data like the IPv4 address).
    private var statusLine: String {
        isOnline
            ? String(localized: "connected", comment: "Network widget: the active interface has connectivity.")
            : String(localized: "offline", comment: "Network widget: the active interface has no connectivity.")
    }

    /// Path condition chips — localized words (constrained / expensive).
    private var pathChips: [String] {
        guard let path = system?.netPath else { return [] }
        var chips: [String] = []
        if path.isConstrained == true {
            chips.append(String(localized: "constrained", comment: "Network widget: the network path is constrained (Low Data Mode)."))
        }
        if path.isExpensive == true {
            chips.append(String(localized: "expensive", comment: "Network widget: the network path is expensive (cellular/metered)."))
        }
        return chips
    }

    /// Sum of the active interface's cumulative error/drop counters.
    private var errorCount: Int? {
        guard let iface = activeInterface else { return nil }
        let rxErr = iface.rxErrors ?? 0
        let txErr = iface.txErrors ?? 0
        let rxDrop = iface.rxDrops ?? 0
        return Int(min(rxErr + txErr + rxDrop, UInt64(Int.max)))
    }

    // MARK: - Pure helpers (nonisolated for tests)

    nonisolated static func pickActiveInterface(
        _ interfaces: [MonitorNetworkInterface]?
    ) -> MonitorNetworkInterface? {
        guard let interfaces, !interfaces.isEmpty else { return nil }
        if let active = interfaces.first(where: { $0.isActive == true }) { return active }
        return interfaces.max {
            ($0.rxBytesPerSec + $0.txBytesPerSec) < ($1.rxBytesPerSec + $1.txBytesPerSec)
        }
    }

    nonisolated static func isIPv4(_ address: String) -> Bool {
        address.contains(".") && !address.contains(":")
    }

    nonisolated static func splitRate(_ text: String) -> (value: String, unit: String) {
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[text.startIndex..<space]),
                String(text[text.index(after: space)...]))
    }

    /// Last `count` samples of a series (never fewer than the series has).
    nonisolated static func tail(_ series: [Double], count: Int) -> [Double] {
        guard series.count > count else { return series }
        return Array(series.suffix(count))
    }
}

// MARK: - Previews

#if DEBUG
private func networkPreviewContext(size: MonitorWidgetSize) -> MonitorWidgetContext {
    var system = MonitorSystemSnapshot()
    system.netRxBytesPerSec = 6.2 * 1_048_576
    system.netTxBytesPerSec = 0.74 * 1_048_576
    system.netInterfaces = [
        MonitorNetworkInterface(
            name: "en0",
            rxBytesPerSec: 6.2 * 1_048_576,
            txBytesPerSec: 0.74 * 1_048_576,
            rxErrors: 3, txErrors: 0, rxDrops: 1,
            addresses: ["192.168.1.24", "fe80::14b2:9c3f:8e1a:22d7"],
            isActive: true
        ),
        MonitorNetworkInterface(name: "en1", rxBytesPerSec: 0, txBytesPerSec: 0, isActive: false)
    ]
    system.netPath = MonitorNetworkPath(
        status: "satisfied", interfaceType: "wifi", isConstrained: false, isExpensive: false
    )

    var history = MonitorHistorySnapshot()
    let rx: [Double] = (0..<120).map { (i: Int) -> Double in
        1_048_576.0 * (2.0 + 5.0 * abs(sin(Double(i) / 7.0)))
    }
    let tx: [Double] = (0..<120).map { (i: Int) -> Double in
        1_048_576.0 * (0.2 + 0.7 * abs(cos(Double(i) / 9.0)))
    }
    history.netRx = rx
    history.netTx = tx
    history.netRxPeak = 88 * 1_048_576
    history.netTxPeak = 12 * 1_048_576
    history.netRxSessionBytes = 41.7 * 1_073_741_824
    history.netTxSessionBytes = 6.3 * 1_073_741_824

    return MonitorWidgetContext(
        snapshot: MonitorSnapshot(timestamp: 0, system: system),
        history: history,
        placement: MonitorWidgetPlacement(kind: .network, size: size),
        isEditing: false,
        reduceMotion: false,
        now: Date()
    )
}


#Preview("Network S") {
    NetworkWidgetView(context: networkPreviewContext(size: .small))
        .frame(width: 170, height: 170)
        .padding(32)
        .background(Design.boardWash)
}

#Preview("Network M") {
    NetworkWidgetView(context: networkPreviewContext(size: .medium))
        .frame(width: 364, height: 170)
        .padding(32)
        .background(Design.boardWash)
}

#Preview("Network L") {
    NetworkWidgetView(context: networkPreviewContext(size: .large))
        .frame(width: 364, height: 376)
        .padding(32)
        .background(Design.boardWash)
}
#endif
