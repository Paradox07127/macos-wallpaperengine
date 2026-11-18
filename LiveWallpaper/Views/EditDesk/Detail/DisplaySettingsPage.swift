import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// One entry of the resolution menu: a point size, with a HiDPI size and its low-resolution twin listed apart.
struct DisplayResolution: Hashable {
    let width: Int
    let height: Int
    let isHiDPI: Bool
}

extension DisplayResolution {
    init(_ option: DisplayModeOption) {
        self.init(width: option.key.width, height: option.key.height, isHiDPI: option.isHiDPI)
    }
}

/// The detail's Display section: power, mode, rotation and HDR of the shown display.
struct DisplaySettingsPage: View {
    let screen: Screen
    let reportFailure: (String) -> Void

    @Environment(ScreenManager.self) private var screenManager
    @State private var options: [DisplayModeOption] = []
    /// The deadline of the last confirmation the user answered.
    @State private var answeredDeadline: Date?
    #if !MAS_BUILD
    /// nil = the display reports an angle outside the four quadrants.
    @State private var rotation: DisplayRotation?
    /// nil = this display or OS offers no HDR control.
    @State private var hdr: DisplayHDRState?
    @State private var onlineDisplayCount = 0
    @State private var confirmingTurnOff = false
    #endif

    var body: some View {
        ScrollView {
            GroupBox {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    #if !MAS_BUILD
                    if DisplayPower.isSoftPowerAvailable {
                        powerRow
                        Divider()
                    }
                    #endif
                    resolutionRow
                    Divider()
                    refreshRateRow
                    #if !MAS_BUILD
                    if DisplayRotation.isSettable {
                        Divider()
                        rotationRow
                    }
                    if let hdr, hdr.isSupported {
                        Divider()
                        hdrRow(isOn: hdr.isPreferred)
                    }
                    #endif
                }
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
            .frame(maxWidth: DesignTokens.Settings.maxContentWidth)
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        // A mode, rotation or power change rebuilds every `Screen`, so a new instance means fresh values to read.
        .onChange(of: ObjectIdentifier(screen), initial: true) { reload() }
        .alert(Text("Keep these display settings?"), isPresented: confirmationPresented) {
            Button("Keep") { screenManager.displaySettings.keepPendingChange() }
            Button("Revert", role: .cancel) {
                Task { await screenManager.displaySettings.revertPendingChange() }
            }
        } message: {
            Text("The previous settings come back in 15 seconds unless you keep these.")
        }
        #if !MAS_BUILD
        .alert(Text("Turn off this display?"), isPresented: $confirmingTurnOff) {
            Button("Turn Off") { turnOff() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(screen.name)” will go dark. To turn it back on, click its gray display on the wallpaper shelf.",
                 comment: "Confirmation before switching a display off. Placeholder is the display's name.")
        }
        #endif
    }

    private var resolutionRow: some View {
        let resolutions = Self.resolutions(in: options)
        return SettingRow(icon: "display", iconColor: .blue, title: "Resolution") {
            Picker("Resolution", selection: Binding(
                get: { Self.selection(in: options)?.resolution },
                set: { next in
                    if let next {
                        applyMode(Self.mode(for: next, refreshRate: Self.selection(in: options)?.refreshRate ?? 0, in: options))
                    }
                }
            )) {
                ForEach(resolutions, id: \.self) { resolution in
                    Text(verbatim: Self.resolutionTitle(resolution, among: resolutions)).tag(Optional(resolution))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var refreshRateRow: some View {
        let current = Self.selection(in: options)
        return SettingRow(icon: "waveform.path", iconColor: .teal, title: "Refresh Rate") {
            Picker("Refresh Rate", selection: Binding(
                get: { current?.refreshRate },
                set: { next in
                    if let next, let resolution = current?.resolution {
                        applyMode(Self.mode(for: resolution, refreshRate: next, in: options))
                    }
                }
            )) {
                if let resolution = current?.resolution {
                    ForEach(Self.refreshRates(for: resolution, in: options), id: \.self) { rate in
                        Text(verbatim: Self.refreshRateTitle(rate)).tag(Optional(rate))
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    #if !MAS_BUILD
    private var powerRow: some View {
        SettingRow(
            icon: "power", iconColor: .red, title: "Display Power",
            info: "When the app quits normally, it turns this display back on. If the app crashes or is force quit, the display stays off until the app opens again."
        ) {
            Toggle("", isOn: Binding(get: { true }, set: { on in
                if !on {
                    confirmingTurnOff = true
                }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(onlineDisplayCount < 2)
            .help(onlineDisplayCount < 2 ? Text("The only display that is on can't be turned off.") : Text("Display Power"))
            .accessibilityLabel(Text("Display Power"))
        }
    }

    private var rotationRow: some View {
        SettingRow(icon: "rotate.right", iconColor: .orange, title: "Rotation") {
            Picker("Rotation", selection: Binding(get: { rotation }, set: { next in
                if let next {
                    applyRotation(next)
                }
            })) {
                ForEach(DisplayRotation.allCases, id: \.self) { rotation in
                    Text(verbatim: "\(rotation.rawValue)°").tag(Optional(rotation))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func hdrRow(isOn: Bool) -> some View {
        SettingRow(icon: "sun.max", iconColor: .yellow, title: "High Dynamic Range") {
            Toggle("", isOn: Binding(get: { isOn }, set: { setHDR($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("High Dynamic Range"))
        }
    }

    private func applyRotation(_ next: DisplayRotation) {
        Task {
            do {
                try await screenManager.displaySettings.applyRotation(next, to: screen)
            } catch {
                fail(String(localized: "Couldn't rotate this display.", bundle: .appLanguage,
                            comment: "Toast when rotating a display from the Edit Desk failed."), error)
            }
            reload()
        }
    }

    private func setHDR(_ preferred: Bool) {
        do {
            try DisplayHDR.setPreferred(preferred, for: screen.id)
        } catch {
            fail(String(localized: "Couldn't change HDR on this display.", bundle: .appLanguage,
                        comment: "Toast when switching a display's HDR from the Edit Desk failed."), error)
        }
        reload()
    }

    private func turnOff() {
        Task {
            do {
                try await screenManager.displaySettings.turnOff(screen)
            } catch {
                fail(String(localized: "Couldn't turn off this display.", bundle: .appLanguage,
                            comment: "Toast when switching a display off from the Edit Desk failed."), error)
            }
            reload()
        }
    }
    #endif

    private var confirmationPresented: Binding<Bool> {
        let pending = screenManager.displaySettings.pendingConfirmation
        // Revert clears the pending change only once its task runs; until then the answered deadline keeps the alert down.
        return Binding(get: { pending?.displayID == screen.id && pending?.deadline != answeredDeadline }, set: { presented in
            if !presented {
                answeredDeadline = pending?.deadline
            }
        })
    }

    private func applyMode(_ key: DisplayModeKey?) {
        guard let key else { return }
        Task {
            do {
                try await screenManager.displaySettings.applyMode(key, to: screen)
            } catch {
                fail(String(localized: "Couldn't change this display's mode.", bundle: .appLanguage,
                            comment: "Toast when changing a display's resolution or refresh rate from the Edit Desk failed."), error)
            }
            reload()
        }
    }

    private func fail(_ message: String, _ error: any Error) {
        Logger.error("Display control on \(screen.id) failed: \(error)", category: .screenManager)
        reportFailure(message)
    }

    private func reload() {
        options = DisplayModes.availableOptions(for: screen.id)
        #if !MAS_BUILD
        rotation = DisplayRotation.current(for: screen.id)
        // Throws when the panel framework or this display is missing from it; the row is hidden then.
        hdr = try? DisplayHDR.state(for: screen.id)
        onlineDisplayCount = DisplayPower.onlineDisplayIDs().count
        #endif
    }

    // MARK: Menu contents

    /// Largest first; a HiDPI size before its low-resolution twin.
    static func resolutions(in options: [DisplayModeOption]) -> [DisplayResolution] {
        Set(options.map(DisplayResolution.init)).sorted {
            ($0.width, $0.height, $0.isHiDPI ? 1 : 0) > ($1.width, $1.height, $1.isHiDPI ? 1 : 0)
        }
    }

    /// Fastest first.
    static func refreshRates(for resolution: DisplayResolution, in options: [DisplayModeOption]) -> [Double] {
        Set(options.filter { DisplayResolution($0) == resolution }.map(\.key.refreshRate)).sorted(by: >)
    }

    /// nil = the running mode is not one of `options`.
    static func selection(in options: [DisplayModeOption]) -> (resolution: DisplayResolution, refreshRate: Double)? {
        options.first(where: \.isCurrent).map { (DisplayResolution($0), $0.key.refreshRate) }
    }

    /// The mode at `refreshRate`, or the fastest one when the resolution does not offer that rate.
    static func mode(for resolution: DisplayResolution, refreshRate: Double, in options: [DisplayModeOption]) -> DisplayModeKey? {
        let matching = options.filter { DisplayResolution($0) == resolution }
        return (matching.first { $0.key.refreshRate == refreshRate } ?? matching.max { $0.key.refreshRate < $1.key.refreshRate })?.key
    }

    static func resolutionTitle(_ resolution: DisplayResolution, among resolutions: [DisplayResolution]) -> String {
        let size = "\(resolution.width) × \(resolution.height)"
        let hasHiDPITwin = !resolution.isHiDPI
            && resolutions.contains(DisplayResolution(width: resolution.width, height: resolution.height, isHiDPI: true))
        guard hasHiDPITwin else { return size }
        return String(localized: "\(size) (low resolution)", bundle: .appLanguage,
                      comment: "Resolution menu item for a size that also exists as a sharper HiDPI mode. Placeholder is the size, e.g. 1920 × 1080.")
    }

    static func refreshRateTitle(_ rate: Double) -> String {
        guard rate != 0 else {
            return String(localized: "Default", bundle: .appLanguage,
                          comment: "Refresh rate menu item for a display that reports no rate.")
        }
        let value = rate.formatted(.number.precision(.fractionLength(0 ... 2)))
        return String(localized: "\(value) Hz", bundle: .appLanguage,
                      comment: "Refresh rate menu item. Placeholder is the rate, e.g. 60 or 59.94.")
    }
}
