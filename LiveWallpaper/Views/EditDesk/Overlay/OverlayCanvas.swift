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
            if session.addDrop == .effect {
                effectDropHighlight
            }
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
                object(.clock) { singleton(.clock) }
            }
            if session.overlay.music.enabled {
                object(.music) { singleton(.music) }
            }
            dropPreview.allowsHitTesting(false)
            guides.allowsHitTesting(false)
        }
        .frame(width: session.logicalSize.width, height: session.logicalSize.height, alignment: .topLeading)
        .coordinateSpace(name: Self.coordinateSpace)
        .environment(\.monitorSuspended, true)
    }

    @ViewBuilder
    private func singleton(_ selection: OverlaySelection) -> some View {
        if selection == .clock {
            NixieClockView(configuration: session.overlay.clock,
                           now: session.preview.chartReference(fallback: Date()), animatesSeparators: false)
        } else {
            NowPlayingWidgetView(context: MusicOverlayContext(
                snapshot: session.preview.snapshot ?? MonitorSnapshot(), size: session.overlay.music.size,
                options: session.overlay.music.options, isEditing: true, reduceMotion: true,
                now: session.preview.chartReference(fallback: Date())
            ))
        }
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
        let segments = guideSegments
        if !segments.isEmpty {
            Path { path in
                for segment in segments {
                    path.move(to: segment.start)
                    path.addLine(to: segment.end)
                }
            }
            .stroke(DesignTokens.EditDesk.Colors.success,
                    lineWidth: OverlayGeometry.decorationLineWidth(forRenderScale: session.renderScale))
        }
    }

    /// A canvas drag's guides, else those of the add strip's drop.
    private var guideSegments: [(start: CGPoint, end: CGPoint)] {
        let active: (guides: [MonitorSnapGuide?], rect: CGRect)
        if let drag = session.drag {
            active = ([drag.snap.guideX, drag.snap.guideY], drag.rect)
        } else if case let .widget(_, landing, guideX, guideY)? = session.addDrop {
            active = ([guideX, guideY], landing)
        } else if case let .singleton(_, rect, guideX, guideY)? = session.addDrop {
            active = ([guideX, guideY], rect)
        } else {
            return []
        }
        return active.guides.compactMap(\.self).map {
            LayoutEngine.guideSegment($0, draggedRect: active.rect, geometry: session.interaction.geometry)
        }
    }

    /// Where the add strip's drag would land, drawn on the board.
    @ViewBuilder
    private var dropPreview: some View {
        let geometry = session.interaction.geometry
        switch session.addDrop {
        case let .widget(kind, landing, _, _)?:
            let rect = geometry.renderRect(forRawRect: landing)
            MonitorWidgetNameTile(kind: kind, cellHeight: rect.height, cornerRadius: geometry.cornerRadius)
                .frame(width: rect.width, height: rect.height)
                .opacity(OverlayGeometry.dropPreviewOpacity)
                .modifier(OverlayObjectChrome(selected: true, dragging: true, renderScale: session.renderScale, claimsLanding: false))
                .position(x: rect.midX, y: rect.midY)
        case let .noRoom(_, footprint)?:
            let rect = geometry.renderRect(forRawRect: footprint)
            let shape = RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
            shape.fill(DesignTokens.EditDesk.Colors.danger.opacity(DesignTokens.Opacity.dragFill))
                .overlay(shape.strokeBorder(DesignTokens.EditDesk.Colors.danger,
                                            lineWidth: OverlayGeometry.refusedStrokeWidth(forRenderScale: session.renderScale)))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        case let .singleton(selection, rect, _, _)?:
            singleton(selection)
                .frame(width: rect.width, height: rect.height)
                .opacity(OverlayGeometry.dropPreviewOpacity)
                .modifier(OverlayObjectChrome(selected: true, dragging: true, renderScale: session.renderScale, claimsLanding: false))
                .position(x: rect.midX, y: rect.midY)
        case .effect?, .outside?, nil:
            EmptyView()
        }
    }

    /// Same treatment as the shelf's "Add to Library" drop band.
    private var effectDropHighlight: some View {
        Rectangle()
            .fill(DesignTokens.EditDesk.Colors.dropHighlight)
            .overlay { Rectangle().strokeBorder(DesignTokens.EditDesk.Colors.success, lineWidth: 2) }
            .overlay {
                Text("Release to turn on the effect layer")
                    .font(DesignTokens.EditDesk.Typography.dropLabel)
                    .foregroundStyle(DesignTokens.Colors.overlayForeground)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            }
            .allowsHitTesting(false)
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
            .opacity(isBeingMovedByDrop(selection) ? DesignTokens.Opacity.dimmedContent : 1)
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

    private func isBeingMovedByDrop(_ selection: OverlaySelection) -> Bool {
        if case let .singleton(target, _, _, _)? = session.addDrop {
            return target == selection
        }
        return false
    }

    private var bypassSnap: Bool {
        NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.option)
    }
}

struct OverlayObjectChrome: ViewModifier {
    let selected: Bool
    let dragging: Bool
    let renderScale: CGFloat
    /// False for drop previews, which are never the object that just landed.
    var claimsLanding = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.monitorBoardChrome) private var chrome
    @State private var landings = 0

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
            .keyframeAnimator(initialValue: Landing(), trigger: landings) { view, value in
                view.scaleEffect(value.scale).opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    MoveKeyframe(reduceMotion ? 1 : OverlayGeometry.landingScale)
                    SpringKeyframe(1, duration: OverlayGeometry.landingResponse,
                                   spring: Spring(response: OverlayGeometry.landingResponse, dampingRatio: OverlayGeometry.liftDamping))
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(reduceMotion ? DesignTokens.Opacity.dimmedContent : 1)
                    LinearKeyframe(1, duration: OverlayGeometry.reducedMotionDuration)
                }
            }
            .onAppear(perform: claimLanding)
            .onChange(of: chrome.editor?.landingToken) { claimLanding() }
    }

    /// A new object appears already selected; one that moved stays mounted and sees the token change.
    private func claimLanding() {
        guard claimsLanding, selected, chrome.editor?.claimLanding() == true else { return }
        landings += 1
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

private struct Landing {
    var scale: CGFloat = 1
    var opacity: Double = 1
}
