import Foundation
import QuartzCore

/// One live surface: a remote context plus the renderer feeding it.
final class WallpaperSurface {
    let uuid: UUID
    let bridge = RemoteContextBridge()
    let renderer = VideoRenderer()
    var contextId: UInt32 = 0
    var choiceID: String?
    var isPreview = false
    var teardownWorkItem: DispatchWorkItem?
    /// Last system state seen in an update for this surface — kept so a
    /// manifest change (Darwin notification) can recompute the tier without
    /// waiting for the next update callback.
    var lastPresentationMode = "default"
    var lastActivityState = "active"

    init(uuid: UUID) {
        self.uuid = uuid
    }
}

/// Keyed by WallpaperID UUID, not by display: macOS keeps several Spaces'
/// surfaces plus the lock screen alive at once and a context can only be
/// hosted once, so sharing one contextId makes all but one go black
/// (contract §9 坑 2).
final class SurfaceRegistry {
    /// Each surface owns a remote CAContext and a decoder pipeline, and the
    /// appex lives under the system wallpaper process budget — an unbounded
    /// registry turns a retry storm of fresh WallpaperIDs into an OOM kill.
    /// Displays × Spaces × (desktop + lock + preview) stays far below this.
    static let maxSurfaces = 32

    private var surfaces: [UUID: WallpaperSurface] = [:]

    func surface(for uuid: UUID) -> WallpaperSurface? { surfaces[uuid] }

    func makeSurface(for uuid: UUID) -> WallpaperSurface? {
        if let existing = surfaces[uuid] { return existing }
        guard surfaces.count < Self.maxSurfaces else { return nil }
        let surface = WallpaperSurface(uuid: uuid)
        surfaces[uuid] = surface
        return surface
    }

    func remove(_ uuid: UUID) {
        surfaces.removeValue(forKey: uuid)
    }

    var all: [WallpaperSurface] { Array(surfaces.values) }
}
