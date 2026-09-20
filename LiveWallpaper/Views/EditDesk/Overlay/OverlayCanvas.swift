import AppKit
import LiveWallpaperCore
import SwiftUI

struct OverlayCanvas: View {
    let session: OverlayEditorSession
    let cover: CGImage?
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private static let coordinateSpace = "EditDeskOverlayCanvas"

    var body: some View {
        ZStack {
            DesignTokens.Colors.surfaceRaised
            if let cover {
                Image(decorative: cover, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
            MonitorBoardRootContainer(
                model: session.interaction, data: session.data, reduceMotion: reduceMotion,
                suspended: true, preview: session.preview, logicalSize: session.logicalSize
            ) {
                layers
            }
            .environment(\.monitorBoardChrome, .editDesk(session))
            .id(session.gestureGeneration)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .simultaneousGesture(TapGesture().onEnded { focused = true })
        .onDeleteCommand { session.deleteSelection() }
        .onMoveCommand { direction in
            switch direction {
            case .left: session.moveSelection(.left)
            case .right: session.moveSelection(.right)
            case .up: session.moveSelection(.up)
            case .down: session.moveSelection(.down)
            @unknown default: break
            }
        }
        .onAppear {
            updateScale()
            focused = true
        }
        .onChange(of: size) { updateScale() }
        .onChange(of: session.logicalSize) { updateScale() }
    }

    private func updateScale() {
        session.renderScale = MonitorBoardRootContainer.previewScale(available: size, logical: session.logicalSize)
    }

    private var layers: some View {
        ZStack(alignment: .topLeading) {
            grid.allowsHitTesting(false)
            if session.overlay.clock.enabled {
                object(.clock) {
                    NixieClockView(configuration: session.overlay.clock,
                                   now: session.preview.chartReference(fallback: Date()), animatesSeparators: false)
                }
            }
            if session.overlay.music.enabled {
                object(.music) {
                    NowPlayingWidgetView(context: MusicOverlayContext(
                        snapshot: session.preview.snapshot ?? MonitorSnapshot(), size: session.overlay.music.size,
                        options: session.overlay.music.options, isEditing: true, reduceMotion: true,
                        now: session.preview.chartReference(fallback: Date())
                    ))
                }
            }
            guides.allowsHitTesting(false)
        }
        .frame(width: session.logicalSize.width, height: session.logicalSize.height, alignment: .topLeading)
        .coordinateSpace(name: Self.coordinateSpace)
        .environment(\.monitorSuspended, true)
    }

    private var grid: some View {
        Path { path in
            let spacing = OverlayGeometry.gridSpacing(forRenderScale: session.renderScale)
            for x in stride(from: spacing, to: session.logicalSize.width, by: spacing) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: session.logicalSize.height))
            }
            for y in stride(from: spacing, to: session.logicalSize.height, by: spacing) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: session.logicalSize.width, y: y))
            }
        }
        .stroke(DesignTokens.EditDesk.Colors.dotGrid,
                lineWidth: OverlayGeometry.decorationLineWidth(forRenderScale: session.renderScale))
    }

    @ViewBuilder
    private var guides: some View {
        if let drag = session.drag {
            Path { path in
                for guide in [drag.snap.guideX, drag.snap.guideY].compactMap(\.self) {
                    let segment = LayoutEngine.guideSegment(guide, draggedRect: drag.rect, geometry: session.interaction.geometry)
                    path.move(to: segment.start)
                    path.addLine(to: segment.end)
                }
            }
            .stroke(DesignTokens.EditDesk.Colors.success,
                    lineWidth: OverlayGeometry.decorationLineWidth(forRenderScale: session.renderScale))
        }
    }

    private func object(_ selection: OverlaySelection, @ViewBuilder content: () -> some View) -> some View {
        let rect = session.rect(for: selection)
        let generation = session.gestureGeneration
        return content()
            .allowsHitTesting(false)
            .frame(width: rect.width, height: rect.height)
            .overlay { Color.clear.contentShape(Rectangle()) }
            .modifier(OverlayObjectChrome(selected: session.selection == selection,
                                          dragging: session.drag?.selection == selection, renderScale: session.renderScale))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpace))
                .onChanged { value in
                    guard generation == session.gestureGeneration else { return }
                    focused = true
                    session.updateDrag(selection, translation: value.translation, bypassSnap: bypassSnap)
                }
                .onEnded { value in
                    guard generation == session.gestureGeneration else { return }
                    session.updateDrag(selection, translation: value.translation, bypassSnap: bypassSnap)
                    session.endDrag()
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(selection == .music ? Text("Drag to move the Music layer") : Text("Drag to move the Clock layer"))
            .accessibilityAddTraits(session.selection == selection ? .isSelected : [])
            .accessibilityAction { session.select(selection) }
            .position(x: rect.midX, y: rect.midY)
    }

    private var bypassSnap: Bool {
        NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.option)
    }
}

struct OverlayObjectChrome: ViewModifier {
    let selected: Bool
    let dragging: Bool
    let renderScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if selected || dragging {
                    RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.chip)
                        .strokeBorder(DesignTokens.EditDesk.Colors.strokeHotShell,
                                      lineWidth: OverlayGeometry.decorationLineWidth(forRenderScale: renderScale))
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: DesignTokens.EditDesk.Shadow.floatPanel.color.opacity(dragging && !reduceMotion ? 1 : 0),
                    radius: DesignTokens.EditDesk.Shadow.floatPanel.radius,
                    y: reduceMotion ? 0 : DesignTokens.EditDesk.Shadow.floatPanel.y)
            .scaleEffect(dragging && !reduceMotion ? OverlayGeometry.liftScale : 1)
            .opacity(reduceMotion && dragging ? DesignTokens.Opacity.dimmedContent : 1)
            .animation(animation, value: dragging)
    }

    private var animation: Animation {
        if reduceMotion {
            return .linear(duration: OverlayGeometry.reducedMotionDuration)
        }
        return dragging
            ? .spring(response: OverlayGeometry.liftResponse, dampingFraction: OverlayGeometry.liftDamping)
            : .easeOut(duration: OverlayGeometry.dropDuration)
    }
}
