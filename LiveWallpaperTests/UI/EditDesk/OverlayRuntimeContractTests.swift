import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Overlay editor runtime boundaries")
struct OverlayRuntimeContractTests {
    @Test("Desktop edits still skip reconcile and capture still forces painted panels")
    func desktopWriteAndCaptureContracts() throws {
        let manager = try RepositoryRoot.source("LiveWallpaper/App/ScreenManager+Overlays.swift")
        let start = try #require(manager.range(of: "private func persistMonitorOverlayBoard("))
        let end = try #require(manager.range(of: "func monitorOverlay(for", range: start.upperBound ..< manager.endIndex))
        #expect(manager[start.lowerBound ..< end.lowerBound].contains("reconcile: false"))
        let controller = try RepositoryRoot.source("LiveWallpaper/Monitor/Overlay/OverlayController.swift")
        #expect(controller.contains("board.setForcesOpaquePanels(true)"))
        #expect(controller.contains("board.setForcesOpaquePanels(false)"))
    }

    @Test("The shared SwiftUI subtree owns the scale; the editor does not nest a host")
    func swiftUIScalingContract() throws {
        let root = try RepositoryRoot.source("LiveWallpaper/Monitor/Board/MonitorBoardRootContainer.swift")
        let host = try RepositoryRoot.source("LiveWallpaper/Monitor/Board/HostView.swift")
        let canvas = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayCanvas.swift")
        #expect(root.components(separatedBy: ".scaleEffect(").count - 1 == 1)
        #expect(root.contains("overlayContent"))
        #expect(root.contains(".environment(\\.monitorRenderScale, scale)"))
        #expect(!host.contains("struct MonitorBoardRootContainer"))
        #expect(!canvas.contains("NSHostingView"))
        #expect(!canvas.contains("NSViewRepresentable"))
        #expect(canvas.contains("suspended: true, preview: session.preview"))
    }

    @Test("Editor keyboard commands share the session and canvas placement uses layout")
    func editorRoutingContract() throws {
        let root = try RepositoryRoot.source("LiveWallpaper/Monitor/Board/RootView.swift")
        #expect(root.contains("monitorBoardChrome: MonitorBoardChrome = .desktop"))
        #expect(root.contains("editor.deleteSelection()"))
        #expect(root.contains("editor.moveSelection(.left)"))
        #expect(root.contains("if model.isEditing, editor == nil"))
        let canvas = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayWorkspace.swift")
        #expect(canvas.contains("OverlayGeometry.aspectFit"))
        #expect(canvas.contains(".frame(width: box.width, height: box.height)"))
        #expect(!canvas.contains(".offset("))
    }

    @Test("Canvas objects' remove button and VoiceOver Remove share one session call, the one the Layers panel makes")
    func objectRemoveButtonContract() throws {
        let canvas = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayCanvas.swift")
        let chromeStart = try #require(canvas.range(of: "struct OverlayObjectChrome: ViewModifier"))
        let chrome = canvas[chromeStart.lowerBound...]
        #expect(chrome.contains("var onRemove: (() -> Void)?"))
        #expect(chrome.contains("GlassIconButton(\"xmark\""))
        let objectStart = try #require(canvas.range(of: "private func object(_ selection: OverlaySelection"))
        let objectEnd = try #require(canvas.range(of: "private func isBeingMovedByDrop", range: objectStart.upperBound ..< canvas.endIndex))
        let object = canvas[objectStart.upperBound ..< objectEnd.lowerBound]
        #expect(object.contains("let remove = { session.removeSingleton(selection) }"))
        #expect(object.contains("onRemove: remove"))
        // The element hides its children, the button among them, so the action has to sit on the element itself.
        let element = try #require(object.range(of: ".accessibilityElement(children: .ignore)"))
        let action = try #require(object.range(of: #".accessibilityAction(named: Text("Remove"), remove)"#),
                                  "the Clock and Music layers carry no VoiceOver Remove")
        #expect(element.upperBound <= action.lowerBound)

        let session = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayEditorSession.swift")
        let removalStart = try #require(session.range(of: "func removeSingleton(_ selection: OverlaySelection) {"))
        let removalEnd = try #require(session.range(of: "\n    }\n", range: removalStart.upperBound ..< session.endIndex))
        let removal = session[removalStart.upperBound ..< removalEnd.lowerBound]
        #expect(removal.contains("guard isActive else { return }"))
        let layers = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/LayerNavigator.swift")
        #expect(layers.contains("case .clock: session.setClockEnabled(isOn)"))
        #expect(removal.contains("case .clock: setClockEnabled(false)"))
        #expect(layers.contains("case .music: session.setMusicEnabled(isOn)"))
        #expect(removal.contains("case .music: setMusicEnabled(false)"))
        #expect(layers.contains("session.removeWidget(id: id)"))

        let root = try RepositoryRoot.source("LiveWallpaper/Monitor/Board/RootView.swift")
        #expect(root.contains("editor.removeWidget(id: placement.id)"))
        #expect(root.contains("OverlayObjectChrome(selected: isSelected, dragging: isDragging, renderScale: renderScale, onRemove: onRemove)"))
        let board = try RepositoryRoot.source("LiveWallpaper/Monitor/Board/EditChrome.swift")
        let modifier = try #require(board.range(of: "struct MonitorPlacementAccessibilityActions: ViewModifier"))
        let actions = board[modifier.upperBound...]
        #expect(actions.contains(#"@Environment(\.monitorBoardChrome) private var chrome"#))
        #expect(actions.contains("if let editor = chrome.editor {\n                        editor.removeWidget(id: placementID)"),
                "the widget's VoiceOver Remove bypasses the session its remove button goes through")
    }

    @Test("Editor writes use public setters and applied configuration")
    func publicWriterContract() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayEditorSession.swift")
        #expect(source.contains("manager.setMonitorOverlayBoard(board, for: screen)"))
        #expect(source.contains("manager.setMusicOverlay(music, for: screen)"))
        #expect(source.contains("manager.setClockOverlay(clock, for: screen)"))
        #expect(source.contains("manager.updateParticleEffect(effect, for: screen)"))
        #expect(source.contains("manager.getConfiguration(for: screen)"))
        #expect(!source.contains("inspectedWallpaperAttempt"))
        #expect(!source.contains("LayoutEngine.land("))
        #expect(!source.contains("LayoutEngine.resolve("))
    }
}
