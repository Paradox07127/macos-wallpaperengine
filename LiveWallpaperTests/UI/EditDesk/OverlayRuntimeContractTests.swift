import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Overlay editor runtime boundaries")
struct OverlayRuntimeContractTests {
    @Test("Desktop edits still skip reconcile and capture still forces painted panels")
    func desktopWriteAndCaptureContracts() throws {
        let manager = try RepositoryRoot.source("LiveWallpaper/App/ScreenManager+Monitor.swift")
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
