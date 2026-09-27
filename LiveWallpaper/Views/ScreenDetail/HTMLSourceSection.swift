import SwiftUI
import AppKit
import LiveWallpaperCore

@MainActor
enum HTMLLocalSourcePicker {
    /// A file pick bookmarks that file alone; a folder pick infers its index file.
    /// No `allowedContentTypes`: an HTML-only list disables Choose for every directory.
    static func pick(_ completion: (HTMLSource) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else { return }

        if isDirectory.boolValue {
            guard let bookmark = ResourceUtilities.createBookmark(for: url) else { return }
            completion(.folder(bookmarkData: bookmark, indexFileName: inferIndexFileName(in: url)))
            return
        }

        guard let source = ResourceUtilities.htmlSourceFromPickedFile(url) else { return }
        completion(source)
    }

    private static func inferIndexFileName(in folder: URL) -> String {
        let didStart = folder.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return ResourceUtilities.inferHTMLIndexFileName(from: entries)
    }
}

struct HTMLTransformControls: View {
    var screen: Screen
    @Binding var config: HTMLConfig
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

    private var dragRow: some View {
        SettingRow(
            icon: "hand.draw",
            iconColor: .teal,
            title: "Adjust on the Preview",
            info: "Drag to move; pinch to scale; twist to rotate."
        ) {
            Toggle("", isOn: $isDragEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Adjust on the preview"))
        }
    }

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
            title: "Scale"
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

    private var translateRow: some View {
        SettingRow(
            icon: "arrow.up.and.down.and.arrow.left.and.right",
            iconColor: .purple,
            title: "Translate",
            info: "Offsets are measured in CSS pixels."
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

    private var rotationRow: some View {
        SettingRow(
            icon: "rotate.right",
            iconColor: .pink,
            title: "Rotation"
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
