import SwiftUI
import AppKit
import LiveWallpaperCore

/// Chrome for `HTMLSourceSection`: glass when it floats over the live web preview,
/// a flat card when it sits in page flow with nothing behind it to refract.
private struct HTMLSourceChrome: ViewModifier {
    let floating: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if floating {
            // Capsule, matching the scene preview's info bar — same role, same shape.
            content.adaptiveGlassSurface(.capsule)
        } else {
            // Field-for-field the flat look of `ContainerGroupBoxStyle` (same
            // `Corner.panel` / `Card.strokeWidth` source); kept hand-built only
            // because this chrome needs the glass/flat dual state above.
            content
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.panel, style: .continuous)
                        .fill(DesignTokens.Colors.surfaceRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.panel, style: .continuous)
                        .strokeBorder(
                            DesignTokens.Colors.separator.opacity(0.55),
                            lineWidth: DesignTokens.Card.strokeWidth
                        )
                )
        }
    }
}

/// Picker and options for URL- or locally-backed HTML wallpapers.
struct HTMLSourceSection: View {
    var screen: Screen
    @Binding var source: HTMLSource?
    @Binding var config: HTMLConfig
    /// `true` when the picker floats over the web preview instead of sitting in
    /// page flow — the one case where glass has live content to refract.
    var floating: Bool = false

    @Environment(ScreenManager.self) private var screenManager
    @State private var trustStore = TrustedHostStore.shared

    @State private var selectedSegment: SourceSegment = .url
    @State private var urlInput: String = ""

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            sourceSegmentPicker
                .frame(width: 108)

            sourcePane
                .frame(maxWidth: .infinity)
                .animation(.snappy(duration: 0.18), value: selectedSegment)
        }
        .padding(.horizontal, floating ? 16 : 20)
        .padding(.vertical, floating ? 6 : 16)
        .modifier(HTMLSourceChrome(floating: floating))
        .onAppear { scheduleBindingSync() }
        .onChange(of: source) { _, _ in
            scheduleBindingSync()
        }
    }

    // MARK: - Segment Picker

    private enum SourceSegment: String, CaseIterable, Identifiable {
        case url, local, inline
        var id: String { rawValue }

        /// `.inline` is display-only for legacy sources, never pickable.
        static let pickable: [SourceSegment] = [.url, .local]

        var labelKey: LocalizedStringKey {
            switch self {
            case .url: return "URL"
            case .local: return "Local"
            case .inline: return "Inline HTML content"
            }
        }
    }

    private var sourceSegmentPicker: some View {
        GlassSegmentedPicker(
            selection: $selectedSegment,
            values: SourceSegment.pickable,
            shell: .flat,
            title: { $0.labelKey }
        )
    }

    // MARK: - Source Pane

    @ViewBuilder
    private var sourcePane: some View {
        switch selectedSegment {
        case .url: urlField
        case .local: localPickerRow
        case .inline: inlinePane
        }
    }

    /// Legacy `.inline` only — never expose raw markup in the URL field.
    private var inlinePane: some View {
        HStack(spacing: 8) {
            summaryLine(icon: "chevron.left.forwardslash.chevron.right", text: Text("Inline HTML content"))

            sourceChipsRow

            Spacer(minLength: 0)

            Text("Pick URL or Local to replace")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var urlField: some View {
        HStack(spacing: 8) {
            TextField("https://example.com or example.com", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitURL() }

            Button(action: pasteFromClipboard) {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(Text("Paste URL from clipboard"))
            .accessibilityLabel(Text("Paste URL from clipboard"))

            Button("Use") { commitURL() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            urlChipsRow
        }
    }

    /// Commits immediately when the pasted value already parses as a valid
    /// `HTMLSource.url`; otherwise just populates the field for the user to edit.
    private func pasteFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        urlInput = trimmed
        if case .url = HTMLSource(userInput: trimmed) {
            commitURL()
        }
    }

    private var localPickerRow: some View {
        HStack(spacing: 8) {
            summaryLine(
                icon: localIconName,
                text: localSummary.map { Text(verbatim: $0) } ?? Text("No file or folder chosen")
            )

            sourceChipsRow

            Spacer(minLength: 0)

            Button("Choose") { pickLocal() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var localIconName: String {
        switch source {
        case .file: return "doc.richtext"
        case .folder: return "folder"
        default: return "doc.richtext"
        }
    }

    private var localSummary: String? {
        switch source {
        case .file, .folder: return source?.displayName
        default: return nil
        }
    }

    @ViewBuilder
    private func summaryLine(icon: String, text: Text) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            text
                .font(DesignTokens.Typography.code)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Chips

    @ViewBuilder
    private var urlChipsRow: some View {
        if let source {
            HStack(spacing: 6) {
                if source.isInsecureURL {
                    insecureChip
                }
                trustStatusChip(for: source)
                multiInstanceChip(for: source)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var sourceChipsRow: some View {
        if let source {
            HStack(spacing: 6) {
                multiInstanceChip(for: source)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var insecureChip: some View {
        chip(
            symbol: "exclamationmark.shield",
            label: Text("HTTP"),
            color: DesignTokens.Colors.Status.warning,
            help: Text("Insecure HTTP — content cannot be verified.")
        )
    }

    @ViewBuilder
    private func trustStatusChip(for source: HTMLSource) -> some View {
        let trust = HTMLTrust.evaluate(source: source, trustedOrigins: trustStore.originSet)
        switch trust {
        case .localContent:
            EmptyView()
        case .trustedRemote(let origin) where origin.isLoopback:
            chip(
                symbol: "laptopcomputer",
                label: Text("Local"),
                color: DesignTokens.Colors.Status.active,
                help: Text("Local development server — JavaScript allowed.")
            )
        case .trustedRemote:
            chip(
                symbol: "checkmark.shield.fill",
                label: Text("Trusted"),
                color: DesignTokens.Colors.Status.active,
                help: Text("JavaScript allowed for this origin.")
            )
        case .untrustedRemote:
            chip(
                symbol: "exclamationmark.shield",
                label: Text("Untrusted"),
                color: DesignTokens.Colors.Status.warning,
                help: Text("Scripts disabled. Manage in Content Security panel.")
            )
        }
    }

    @ViewBuilder
    private func multiInstanceChip(for source: HTMLSource) -> some View {
        let others = screenManager.htmlCoordinator.screensRunningSameSource(as: source, excluding: screen.id)
        if !others.isEmpty {
            let names = others.map(\.name).joined(separator: ", ")
            let total = others.count + 1
            chip(
                symbol: "rectangle.on.rectangle.angled",
                label: Text("\(total)× Active", comment: "URL chip showing the number of screens running the same web wallpaper."),
                color: .indigo,
                help: Text("Also active on: \(names)")
            )
        }
    }

    @ViewBuilder
    private func chip(
        symbol: String,
        label: Text,
        color: Color,
        help: Text
    ) -> some View {
        StatusChip(text: label, tint: color, systemImage: symbol)
            .help(help)
    }

    // MARK: - Actions

    private func scheduleBindingSync() {
        DispatchQueue.main.async {
            Task { @MainActor in
                syncFromBinding()
            }
        }
    }

    private func commitURL() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = HTMLSource(userInput: trimmed) else { return }
        screenManager.setHTMLWallpaper(source: parsed, config: config, for: screen)
    }

    /// File pick promotes bookmark to parent folder (sibling asset access); folders use index inference.
    private func pickLocal() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedHTMLContentTypes
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else { return }

        if isDirectory.boolValue {
            guard let bookmark = ResourceUtilities.createBookmark(for: url) else { return }
            let indexFileName = inferIndexFileName(in: url)
            screenManager.setHTMLWallpaper(
                source: .folder(bookmarkData: bookmark, indexFileName: indexFileName),
                config: config,
                for: screen
            )
            return
        }

        guard let source = ResourceUtilities.htmlSourceFromPickedFile(url) else { return }
        screenManager.setHTMLWallpaper(source: source, config: config, for: screen)
    }

    // MARK: - Helpers

    private func syncFromBinding() {
        guard let source else {
            if selectedSegment != .url { selectedSegment = .url }
            if !urlInput.isEmpty { urlInput = "" }
            return
        }
        switch source {
        case .url(let url):
            if selectedSegment != .url { selectedSegment = .url }
            if urlInput != url.absoluteString { urlInput = url.absoluteString }
        case .file, .folder:
            if selectedSegment != .local { selectedSegment = .local }
        case .inline:
            if selectedSegment != .inline { selectedSegment = .inline }
            if !urlInput.isEmpty { urlInput = "" }
        }
    }

    private func inferIndexFileName(in folder: URL) -> String {
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return ResourceUtilities.inferHTMLIndexFileName(from: entries)
    }
}

/// HTML layout transforms, as the content of the web preview bar's viewport
/// control: scale, translate and rotation are viewport geometry, the role the
/// other two types fill with a fit-mode picker. A popover for the same reason
/// speed and volume are: three sliders will not fit inline on a bar.
struct HTMLTransformControls: View {
    var screen: Screen
    @Binding var config: HTMLConfig
    /// Whether dragging on the preview itself moves the page.
    @Binding var isDragEnabled: Bool

    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        VStack(spacing: 8) {
            dragRow
            Divider()
            scaleRow
            Divider()
            translateRow
            Divider()
            rotationRow
            if config.hasActiveTransform {
                Divider()
                resetRow
            }
        }
        .frame(width: 300)
        .padding(DesignTokens.Spacing.md)
    }

    /// Opt-in, and first in the list. The sliders are safe to leave available;
    /// dragging is not — the preview fills most of the page, and without a switch
    /// the first accidental drag across it throws the wallpaper off-centre.
    private var dragRow: some View {
        SettingRow(
            icon: "hand.draw",
            iconColor: .teal,
            title: "Adjust on the Preview",
            info: "Drag to move, pinch to scale, and twist to rotate directly on the preview. Off by default so a stray drag can't move the page."
        ) {
            Toggle("", isOn: $isDragEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Adjust on the preview"))
        }
    }

    /// A footer row: a popover has no section header to hang an accessory on.
    private var resetRow: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: resetTransform) {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .tint(DesignTokens.Colors.Status.danger)
            .help(Text("Reset scale, translate, and rotation"))
            .accessibilityLabel(Text("Reset transform"))
        }
    }

    private var scaleRow: some View {
        SettingRow(
            icon: "arrow.up.left.and.arrow.down.right",
            iconColor: .teal,
            title: "Scale",
            info: "Scales the rendered page around its center."
        ) {
            // Coalesced: `applyConfigChange` persists the config and pushes it to
            // the live `WKWebView` session on every write.
            CoalescedSlider(
                value: config.transformScale,
                in: HTMLConfig.minTransformScale...HTMLConfig.maxTransformScale,
                owner: transformOwner,
                accessibilityLabel: Text("Scale"),
                accessibilityValue: { Text(verbatim: String(format: "%.0f%%", $0 * 100)) },
                write: { configDoubleBinding(
                    \.transformScale,
                    epsilon: 0.001,
                    clamp: HTMLConfig.clampedTransformScale
                ).wrappedValue = $0 },
                readout: { live in
                    Text(verbatim: String(format: "%.0f%%", live * 100))
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
                }
            )
        }
    }

    /// Slider uses an epsilon-guarded binding (drags emit many near-duplicate values); the text field bypasses the epsilon so typing `100` over a current `99.6` commits cleanly instead of snapping back.
    private var translateRow: some View {
        SettingRow(
            icon: "arrow.up.and.down.and.arrow.left.and.right",
            iconColor: .purple,
            title: "Translate",
            info: "Offsets the rendered page horizontally (X) and vertically (Y) in CSS pixels."
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                translateAxisSlider(
                    axisLabel: "X",
                    sliderValue: configDoubleBinding(
                        \.transformTranslateX,
                        epsilon: 0.5,
                        clamp: HTMLConfig.clampedTransformTranslate
                    ),
                    fieldValue: configExactDoubleBinding(
                        \.transformTranslateX,
                        clamp: HTMLConfig.clampedTransformTranslate
                    ),
                    accessibilityLabel: "Translate X"
                )
                translateAxisSlider(
                    axisLabel: "Y",
                    sliderValue: configDoubleBinding(
                        \.transformTranslateY,
                        epsilon: 0.5,
                        clamp: HTMLConfig.clampedTransformTranslate
                    ),
                    fieldValue: configExactDoubleBinding(
                        \.transformTranslateY,
                        clamp: HTMLConfig.clampedTransformTranslate
                    ),
                    accessibilityLabel: "Translate Y"
                )
            }
        }
    }

    @ViewBuilder
    private func translateAxisSlider(
        axisLabel: String,
        sliderValue: Binding<Double>,
        fieldValue: Binding<Double>,
        accessibilityLabel: LocalizedStringKey
    ) -> some View {
        HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
            Text(verbatim: axisLabel)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)

            // The field is the readout here, so it follows the drag from the
            // slider's own state; typing into it still writes straight through.
            CoalescedSlider(
                value: sliderValue.wrappedValue,
                in: -HTMLConfig.maxTransformTranslate...HTMLConfig.maxTransformTranslate,
                owner: transformOwner,
                accessibilityLabel: Text(accessibilityLabel),
                accessibilityValue: { Text(verbatim: String(format: "%.0f", $0)) },
                write: { sliderValue.wrappedValue = $0 },
                readout: { live in
                    TextField(
                        "",
                        value: Binding(get: { live }, set: { fieldValue.wrappedValue = $0 }),
                        format: .number.precision(.fractionLength(0))
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 56)
                    .accessibilityLabel(Text(accessibilityLabel))
                    .accessibilityHint(Text("Type a value in CSS pixels."))
                }
            )
        }
    }

    /// `±180` covers everything; slider stays continuous (not stepped) so
    /// "tilt the canvas" use cases feel responsive.
    private var rotationRow: some View {
        SettingRow(
            icon: "rotate.right",
            iconColor: .pink,
            title: "Rotation",
            info: "Rotates the rendered page around its center."
        ) {
            CoalescedSlider(
                value: config.transformRotationDegrees,
                in: -180...180,
                owner: transformOwner,
                accessibilityLabel: Text("Rotation"),
                accessibilityValue: { Text(verbatim: String(format: "%.0f°", $0)) },
                write: { configDoubleBinding(
                    \.transformRotationDegrees,
                    epsilon: 0.1,
                    clamp: HTMLConfig.clampedTransformRotation
                ).wrappedValue = $0 },
                readout: { live in
                    Text(verbatim: String(format: "%.0f°", live))
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
                }
            )
        }
    }

    private func resetTransform() {
        guard config.hasActiveTransform else { return }
        var next = config
        next.transformScale = 1.0
        next.transformTranslateX = 0
        next.transformTranslateY = 0
        next.transformRotationDegrees = 0
        config = next
        screenManager.updateHTMLConfig(next, for: screen)
    }

    /// A pending transform commit belongs to one display's config; the section
    /// is reused when the inspector moves.
    private var transformOwner: String { "\(screen.id)" }

    // MARK: - Bindings

    private func configDoubleBinding(
        _ keyPath: WritableKeyPath<HTMLConfig, Double>,
        epsilon: Double,
        clamp: @escaping (Double) -> Double
    ) -> Binding<Double> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { rawValue in
                let newValue = clamp(rawValue)
                guard abs(config[keyPath: keyPath] - newValue) > epsilon else { return }
                applyConfigChange(keyPath, value: newValue)
            }
        )
    }

    /// Identity-guarded but epsilon-free — text-field entries near the current
    /// rounded display value must commit instead of being filtered out.
    private func configExactDoubleBinding(
        _ keyPath: WritableKeyPath<HTMLConfig, Double>,
        clamp: @escaping (Double) -> Double
    ) -> Binding<Double> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { rawValue in
                let newValue = clamp(rawValue)
                guard config[keyPath: keyPath] != newValue else { return }
                applyConfigChange(keyPath, value: newValue)
            }
        )
    }

    private func applyConfigChange<Value: Equatable>(
        _ keyPath: WritableKeyPath<HTMLConfig, Value>,
        value: Value
    ) {
        var next = config
        next[keyPath: keyPath] = value
        config = next
        screenManager.updateHTMLConfig(next, for: screen)
    }
}
