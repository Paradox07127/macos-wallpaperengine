import AppKit
import LiveWallpaperCore
import SwiftUI

/// Edits global shortcut bindings and their master switch.
struct ShortcutsView: View {
    @State private var bindings: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?] = [:]
    @State private var rejectionMessage: String?
    @State private var globalShortcutsEnabled: Bool
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    init(pendingSearchAnchor: Binding<SettingsSearchAnchor?> = .constant(nil)) {
        let settings = SettingsManager.shared.loadGlobalSettings()
        _bindings = State(initialValue: settings.globalShortcuts)
        _globalShortcutsEnabled = State(initialValue: settings.globalShortcutsEnabled)
        _pendingSearchAnchor = pendingSearchAnchor
    }

    var body: some View {
        Form {
            masterEnableSection

            Section {
                ForEach(GlobalShortcutAction.allCases) { action in
                    ShortcutRow(
                        action: action,
                        binding: bindingFor(action),
                        isEnabled: globalShortcutsEnabled,
                        onCapture: { newBinding in updateBinding(newBinding, for: action) },
                        onClear: { updateBinding(nil, for: action) },
                        onReset: { resetToDefault(action) }
                    )
                }
                if let rejectionMessage {
                    Text(verbatim: rejectionMessage)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
                        .accessibilityLabel(Text("Shortcut rejected: \(rejectionMessage)"))
                }
            } header: {
                SettingsSearchSectionHeader("Global Shortcuts", anchor: .shortcutsGlobal)
            }
            .disabled(!globalShortcutsEnabled)
        }
        .settingsFormChrome(minWidth: 500, minHeight: 400)
        .settingsSearchAnchorScroller(
            pendingSearchAnchor: $pendingSearchAnchor,
            anchors: [
                .shortcutsMaster,
                .shortcutsGlobal
            ]
        )
        .onReceive(NotificationCenter.default.publisher(for: .globalShortcutsDidChange)) { _ in
            // Refresh after external reset or import to avoid saving stale bindings.
            let latest = SettingsManager.shared.loadGlobalSettings()
            var didResync = false
            if globalShortcutsEnabled != latest.globalShortcutsEnabled {
                globalShortcutsEnabled = latest.globalShortcutsEnabled
                didResync = true
            }
            if bindings != latest.globalShortcuts {
                bindings = latest.globalShortcuts
                didResync = true
            }
            if didResync { rejectionMessage = nil }
        }
    }

    private var masterEnableSection: some View {
        Section {
            SettingRow(
                icon: "command",
                iconColor: .blue,
                title: "Enable Global Shortcuts",
                info: "Bindings are kept while off. Shortcuts require a modifier key and must not conflict with other shortcuts."
            ) {
                Toggle("", isOn: masterEnableBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Enable Global Shortcuts"))
                    .accessibilityHint(Text("Master switch for every global shortcut. Bindings are preserved while off."))
            }
        } header: {
            SettingsSearchSectionHeader("Shortcuts", anchor: .shortcutsMaster)
        }
    }

    /// Persist only when the master switch changes.
    private var masterEnableBinding: Binding<Bool> {
        Binding(
            get: { globalShortcutsEnabled },
            set: { newValue in
                guard globalShortcutsEnabled != newValue else { return }
                globalShortcutsEnabled = newValue
                rejectionMessage = nil
                persistSettings()
            }
        )
    }

    private func bindingFor(_ action: GlobalShortcutAction) -> GlobalShortcutBinding? {
        if bindings.keys.contains(action.rawAction) {
            return bindings[action.rawAction] ?? nil
        }
        return GlobalShortcutAction.defaultBinding(for: action)
    }

    private func updateBinding(_ newBinding: GlobalShortcutBinding?, for action: GlobalShortcutAction) {
        guard globalShortcutsEnabled else { return }
        if let newBinding {
            switch validate(newBinding, for: action) {
            case .valid:
                rejectionMessage = nil
            case .missingModifier:
                rejectionMessage = String(
                    localized: "Include a modifier key (⌃ ⌥ ⇧ ⌘).",
                    bundle: .appLanguage
                )
                NSSound.beep()
                return
            case .duplicate(let other):
                rejectionMessage = String(
                    localized: "\(newBinding.displayString) is already used by \(other.displayName).",
                    bundle: .appLanguage
                )
                NSSound.beep()
                return
            }
        } else {
            rejectionMessage = nil
        }
        bindings[action.rawAction] = newBinding
        persistSettings()
    }

    private func resetToDefault(_ action: GlobalShortcutAction) {
        rejectionMessage = nil
        bindings.removeValue(forKey: action.rawAction)
        persistSettings()
    }

    /// Save bindings and the master switch together.
    private func persistSettings() {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.globalShortcuts = bindings
        settings.globalShortcutsEnabled = globalShortcutsEnabled
        SettingsManager.shared.saveGlobalSettings(settings)
        Task { @MainActor in
            NotificationCenter.default.post(name: .globalShortcutsDidChange, object: nil)
        }
    }

    private func validate(_ binding: GlobalShortcutBinding, for action: GlobalShortcutAction) -> ValidationResult {
        guard !binding.modifiers.isEmpty else { return .missingModifier }
        for other in GlobalShortcutAction.allCases where other != action {
            if bindingFor(other) == binding { return .duplicate(other) }
        }
        return .valid
    }

    private enum ValidationResult {
        case valid
        case missingModifier
        case duplicate(GlobalShortcutAction)
    }
}

private struct ShortcutRow: View {
    let action: GlobalShortcutAction
    let binding: GlobalShortcutBinding?
    let isEnabled: Bool
    let onCapture: (GlobalShortcutBinding) -> Void
    let onClear: () -> Void
    let onReset: () -> Void

    @State private var isCapturing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(action.displayNameKey)
                        .font(DesignTokens.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHint(Text(action.displayDescriptionKey))
                    if let scopeInfo {
                        InfoTooltipButton(text: scopeInfo)
                    }
                }

                Spacer()

                ShortcutCaptureField(
                    binding: binding,
                    isCapturing: $isCapturing,
                    onCapture: onCapture
                )
                .frame(width: 140)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabledContent)
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled { isCapturing = false }
                }

                Menu {
                    Button("Clear", role: .destructive) { onClear() }
                    Button("Reset to Default", role: .destructive) { onReset() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabledContent)
                .accessibilityLabel(Text("More options for \(action.displayName)", comment: "Shortcut row menu a11y label. The placeholder is the shortcut action name."))
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private var scopeInfo: String.LocalizationValue? {
        switch action {
        case .nextWallpaper, .previousWallpaper:
            "Targets the playlist on the display under the pointer."
        case .toggleMute:
            "Applies to video and scene wallpapers."
        case .toggleMouseInteraction:
            "Controls cursor tracking in scenes and mouse interaction on web pages."
        default:
            nil
        }
    }
}

private struct ShortcutCaptureField: View {
    let binding: GlobalShortcutBinding?
    @Binding var isCapturing: Bool
    let onCapture: (GlobalShortcutBinding) -> Void

    var body: some View {
        Button(action: { isCapturing.toggle() }) {
            HStack {
                if isCapturing {
                    Text("Press keys…")
                        .foregroundStyle(.secondary)
                        .italic()
                } else if let binding {
                    Text(verbatim: binding.displayString)
                        .font(DesignTokens.Typography.code)
                } else {
                    Text("None")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                    .fill(isCapturing ? Color.accentColor.opacity(0.18) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                    .strokeBorder(
                        isCapturing ? Color.accentColor : Color.primary.opacity(DesignTokens.Opacity.activeFill),
                        lineWidth: isCapturing ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .background(KeyCaptureMonitor(isActive: $isCapturing) { binding in
            onCapture(binding)
        })
        .accessibilityLabel(isCapturing
            ? Text("Press keys to set shortcut")
            : shortcutAccessibilityLabel)
        .accessibilityHint(isCapturing
            ? Text("Listening for the next key combination")
            : Text("Click to record a new keyboard shortcut"))
    }

    private var shortcutAccessibilityLabel: Text {
        if let binding {
            return Text(verbatim: binding.displayString)
        }
        return Text("No shortcut set")
    }
}

/// Hidden NSView that runs a local key-down monitor for the duration of `isActive == true`.
private struct KeyCaptureMonitor: NSViewRepresentable {
    @Binding var isActive: Bool
    let onCapture: (GlobalShortcutBinding) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isActive {
            context.coordinator.startMonitoring(deactivate: { isActive = false })
        } else {
            context.coordinator.stopMonitoring()
        }
    }

    @MainActor
    final class Coordinator {
        let onCapture: (GlobalShortcutBinding) -> Void
        // deinit runs nonisolated even on a @MainActor class, and must remove the monitor synchronously there.
        nonisolated(unsafe) private var localMonitor: Any?

        init(onCapture: @escaping (GlobalShortcutBinding) -> Void) {
            self.onCapture = onCapture
        }

        deinit {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func startMonitoring(deactivate: @escaping () -> Void) {
            stopMonitoring()
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let keyCode = UInt32(event.keyCode)
                let modifiers = self.modifierSet(from: event.modifierFlags)
                let binding = GlobalShortcutBinding(keyCode: keyCode, modifiers: modifiers)
                self.onCapture(binding)
                deactivate()
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
        }

        private func modifierSet(from flags: NSEvent.ModifierFlags) -> GlobalShortcutBinding.ModifierSet {
            var set: GlobalShortcutBinding.ModifierSet = []
            if flags.contains(.command)  { set.insert(.command) }
            if flags.contains(.option)   { set.insert(.option) }
            if flags.contains(.control)  { set.insert(.control) }
            if flags.contains(.shift)    { set.insert(.shift) }
            return set
        }
    }
}
