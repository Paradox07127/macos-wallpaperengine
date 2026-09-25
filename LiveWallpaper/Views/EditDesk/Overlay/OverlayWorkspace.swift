import LiveWallpaperCore
import SwiftUI

/// The layer list floats above the canvas; expanding it never resizes the artwork.
struct OverlayWorkspace: View {
    let session: OverlayEditorSession
    let cover: CGImage?
    let screen: Screen
    let size: CGSize
    @Binding var layersVisible: Bool
    @Binding var inspectorVisible: Bool
    @Binding var inspectorWidth: Double
    @Binding var liveInspectorWidth: Double?
    var topInset: CGFloat = 0
    let recapture: () -> Void
    let back: () -> Void

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var interaction: InteractionModel
    @State private var addExpanded = true
    @AppStorage(MonitorBoardPreviewMode.defaultsKey) private var previewMode: MonitorBoardPreviewMode = .snapshot

    init(session: OverlayEditorSession, cover: CGImage?, screen: Screen, size: CGSize,
         layersVisible: Binding<Bool>, inspectorVisible: Binding<Bool>,
         inspectorWidth: Binding<Double>, liveInspectorWidth: Binding<Double?>,
         topInset: CGFloat = 0, recapture: @escaping () -> Void, back: @escaping () -> Void) {
        self.session = session
        self.cover = cover
        self.screen = screen
        self.size = size
        _layersVisible = layersVisible
        _inspectorVisible = inspectorVisible
        _inspectorWidth = inspectorWidth
        _liveInspectorWidth = liveInspectorWidth
        self.topInset = topInset
        self.recapture = recapture
        self.back = back
        interaction = session.interaction
    }

    private var drawerHeight: CGFloat {
        addExpanded ? 160 : 38
    }

    private var editorHeight: CGFloat {
        max(1, size.height - drawerHeight - topInset)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            InspectorSplit(
                isMounted: true, isVisible: inspectorVisible,
                animationTrigger: inspectorVisible, reduceMotion: reduceMotion,
                storedWidth: $inspectorWidth, liveWidth: $liveInspectorWidth,
                minWidth: 300, maxWidth: 440, mainFloor: 320,
                onClose: { inspectorVisible = false },
                main: { canvas }, inspector: { width in
                    ObjectInspector(session: session, screen: screen, screenManager: screenManager,
                                    placements: interaction.placements,
                                    height: editorHeight, width: width)
                        .overlay(alignment: .leading) { Divider() }
                }
            )
            .frame(height: editorHeight)
            AddOverlayDrawer(session: session, isExpanded: $addExpanded, height: drawerHeight)
                .overlay(alignment: .top) { Divider() }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: layersVisible)
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: addExpanded)
        .onChange(of: session.selection) { _, selection in
            inspectorVisible = selection != nil
        }
        .onChange(of: screen.id, initial: true) { _, _ in
            inspectorVisible = session.selection != nil
        }
        .onChange(of: previewMode) { _, _ in session.capturePreview() }
    }

    private var rows: [OverlayLayerRow] {
        OverlayLayerList.rows(placements: interaction.placements,
                              boardEnabled: session.boardEnabled,
                              clockEnabled: session.overlay.clock.enabled,
                              musicEnabled: session.overlay.music.enabled,
                              effectVisible: session.effectVisible)
            .filter { row in
                // Disabled singleton layers are available in the add strip, rather than empty rows.
                // The widget group has no add-strip entry, so it always stays.
                if row.kind != .board, case let .toggle(isOn) = row.action {
                    return isOn || row.selection == session.selection
                }
                return true
            }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let box = OverlayGeometry.aspectFit(logicalSize: session.logicalSize,
                                                in: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 20, dy: 20))
            OverlayCanvas(session: session, cover: cover, size: box.size)
                .frame(width: box.width, height: box.height)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: DetailPreviewFrameKey.self,
                                               value: [screen.id: geometry.frame(in: .named(DetailPreviewSpace.name))])
                    }
                }
                .overlay(alignment: .topTrailing) {
                    GlassIconButton("arrow.clockwise", action: recapture)
                        .help(Text("Recapture preview"))
                        .accessibilityLabel(Text("Recapture preview"))
                        .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DetailBackSwipe(enabled: true, action: back))
                .overlay(alignment: .topLeading) {
                    floatingLayers(availableHeight: proxy.size.height)
                        .padding(12)
                }
                .id(screen.id)
                .transition(.opacity)
                .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: screen.id)
        }
    }

    private func floatingLayers(availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button { layersVisible.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.3.layers.3d")
                    Text("Layers")
                    Text(verbatim: "\(OverlayLayerList.layerCount(rows))").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(layersVisible ? 180 : 0))
                }
                .font(DesignTokens.EditDesk.Typography.body)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Layers"))
            .accessibilityValue(Text(layersVisible ? "Expanded" : "Collapsed"))
            if layersVisible {
                Divider().padding(.horizontal, 12)
                LayerNavigator(session: session, rows: rows,
                               height: min(CGFloat(rows.count) * OverlayColumnLayout.rowHeight,
                                           max(30, min(300, availableHeight - 76))))
                    .padding(.vertical, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: 220)
        .clipped()
        .adaptiveGlassSurface(.roundedRectangle(14))
    }
}
