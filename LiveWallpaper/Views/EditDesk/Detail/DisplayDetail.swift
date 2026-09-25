import CoreGraphics
import LiveWallpaperCore
import SwiftUI

enum DetailPreviewSpace {
    static let name = "display-detail-window"
}

struct DetailPreviewFrameKey: PreferenceKey {
    static let defaultValue: [CGDirectDisplayID: CGRect] = [:]
    static func reduce(value: inout [CGDirectDisplayID: CGRect], nextValue: () -> [CGDirectDisplayID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// The top bar's segment selects the wallpaper preview or overlay editing surface.
enum DetailSection: Hashable {
    case wallpaper
    case overlay
}

/// Everything the detail shell hands back out; the host owns the side effects.
struct DetailActions {
    var back: () -> Void
    var selectDisplay: (CGDirectDisplayID) -> Void
    var saveAsScheme: () -> Void
    var applyToAll: () -> Void
    var clearWallpaper: () -> Void
    /// The transport drives the desktop session, not the still hero.
    var playback: (StagePlaybackAction) -> Void
    var recapture: () -> Void
    var copyOverlays: () -> Void
    var snapEnabled: Binding<Bool>
    var openAutomation: (() -> Void)?
    var resumeSchedule: (() -> Void)?
    var applyScheme: (ScreenScheme) -> Void = { _ in }
    var manageSchemes: () -> Void = {}
    /// nil while the wallpaper library is empty.
    var chooseFromLibrary: (() -> Void)?
    var importFile: () -> Void = {}
    var enterWebAddress: () -> Void = {}
    /// Present only while this display keeps a saved video (web page) it is not showing.
    var switchBackToVideo: (() -> Void)?
    var switchBackToWebPage: (() -> Void)?
    var applyWebSource: (HTMLSource) -> Void = { _ in }
    var reload: () -> Void = {}
    var swipe: (DetailSwipeStep) -> Void = { _ in }
}

/// One toolbar and one background shared by the wallpaper and overlay workspaces.
@MainActor
struct DisplayDetail<HUD: View, Inspector: View, Overlay: View, Status: View>: View {
    let displayName: String
    let tags: [DetailDisplayTag]
    let hero: DetailHeroStatus
    let heroImage: CGImage?
    let windowSize: CGSize
    @Binding var section: DetailSection
    let heroVisible: Bool
    var returning = false
    let actions: DetailActions
    @ViewBuilder let hud: () -> HUD
    @ViewBuilder let inspector: (CGFloat) -> Inspector
    @ViewBuilder let overlayCanvas: (CGSize) -> Overlay
    var isEmpty = false
    var preview: DetailPreviewState = .hero
    /// The attempt's page while `preview` shows one, otherwise the notices above the setup or hero.
    @ViewBuilder let wallpaperStatus: () -> Status
    var emptyScreen: Screen?
    var webTransform: DetailWebTransform?
    var schedulePausedUntil: Date?
    /// The side the shown display's preview slides in from when another display is switched to.
    var switchEdge: HorizontalEdge = .trailing
    @Binding var inspectorVisible: Bool
    @Binding var inspectorWidth: Double
    @Binding var liveInspectorWidth: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chromeVisible = false

    var body: some View {
        VStack(spacing: 0) {
            DetailTopBar(tags: tags, section: $section, actions: actions,
                         inspectorVisible: $inspectorVisible,
                         hasWallpaper: !isEmpty, schedulePausedUntil: schedulePausedUntil,
                         attemptShown: section == .wallpaper && preview.showsAttempt)
                .opacity(chromeVisible ? 1 : 0)
                .offset(y: chromeVisible || reduceMotion ? 0 : -8)
                .allowsHitTesting(heroVisible && chromeVisible)
                // Above the workspace, whose content can reach up into this strip and take its clicks.
                .zIndex(1)
            workspace
                // Scroll views draw up into the top bar's strip, which has no fill to hide them.
                .clipped()
                .allowsHitTesting(heroVisible)
        }
        // No fill, so the window's canvas shows; the clear shape still takes the clicks that would
        // otherwise fall through to the hidden overview under the page.
        .background { Color.clear.contentShape(Rectangle()).allowsHitTesting(heroVisible) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: section)
        .onAppear { setChromeVisible(!returning) }
        .onChange(of: returning) { _, returning in setChromeVisible(!returning) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: displayName))
    }

    @ViewBuilder
    private var workspace: some View {
        if section == .overlay {
            overlayCanvas(CGSize(width: windowSize.width, height: max(1, windowSize.height - DetailGeometry.topBarHeight)))
                .opacity(heroVisible ? 1 : 0)
        } else {
            InspectorSplit(
                isMounted: !isEmpty, isVisible: inspectorVisible && !isEmpty,
                animationTrigger: inspectorVisible, reduceMotion: reduceMotion,
                storedWidth: $inspectorWidth, liveWidth: $liveInspectorWidth,
                minWidth: 300, maxWidth: 520, mainFloor: 460,
                onClose: { inspectorVisible = false },
                main: { wallpaperPreview }, inspector: { width in
                    inspector(width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .overlay(alignment: .leading) { Divider() }
                        .contentColumnBackground()
                        .opacity(chromeVisible ? 1 : 0)
                        .offset(x: chromeVisible || reduceMotion ? 0 : 16)
                }
            )
        }
    }

    private var wallpaperPreview: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Group {
                    if preview.showsAttempt {
                        wallpaperStatus()
                            .background(previewMeasurement)
                    } else {
                        VStack(spacing: 0) {
                            wallpaperStatus()
                            if isEmpty {
                                if let emptyScreen {
                                    EmptyDisplaySetup(screen: emptyScreen, chooseFile: actions.importFile,
                                                      applyWebSource: actions.applyWebSource,
                                                      chooseFromLibrary: actions.chooseFromLibrary)
                                        .background(previewMeasurement)
                                }
                            } else {
                                // Measured below the notices, so a banner shrinks the hero instead of covering it.
                                GeometryReader { proxy in
                                    let box = OverlayGeometry.aspectFit(
                                        logicalSize: CGSize(width: 16, height: 9),
                                        in: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 24, dy: 24)
                                    )
                                    DetailHero(status: hero, image: heroImage, size: box.size, hud: hud,
                                               playback: actions.playback, webTransform: webTransform)
                                        .background(previewMeasurement)
                                        .overlay(alignment: .topTrailing) {
                                            GlassIconButton("arrow.clockwise", action: actions.recapture)
                                                .help(Text("Recapture preview"))
                                                .accessibilityLabel(Text("Recapture preview"))
                                                .padding(12)
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                    }
                }
                .opacity(heroVisible ? 1 : 0)
                .id(currentDisplayID)
                .transition(.detailSwitch(from: switchEdge, reduceMotion: reduceMotion))
            }
            .animation(.detailSwitch(reduceMotion: reduceMotion), value: currentDisplayID)
        }
        // Outside the per-display identity: rebuilt mid-swipe, it would count the rest of the gesture as a second step.
        .background(DetailSwipeNavigator(enabled: heroVisible, navigate: actions.swipe))
    }

    private var currentDisplayID: CGDirectDisplayID? {
        tags.first(where: \.isCurrent)?.id
    }

    private var previewMeasurement: some View {
        GeometryReader { proxy in
            if let id = tags.first(where: \.isCurrent)?.id {
                Color.clear.preference(key: DetailPreviewFrameKey.self,
                                       value: [id: proxy.frame(in: .named(DetailPreviewSpace.name))])
            }
        }
    }

    private func setChromeVisible(_ visible: Bool) {
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.24)) { chromeVisible = visible }
    }
}

extension AnyTransition {
    /// The arriving display slides in from `edge` over the leaving one.
    static func detailSwitch(from edge: HorizontalEdge, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let offset = edge == .trailing ? DesignTokens.Spacing.xl : -DesignTokens.Spacing.xl
        // The leaving view keeps the transition it was built with, the previous edge, so it only fades.
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: offset)), removal: .opacity)
    }
}

extension Animation {
    static func detailSwitch(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.25)
    }
}
