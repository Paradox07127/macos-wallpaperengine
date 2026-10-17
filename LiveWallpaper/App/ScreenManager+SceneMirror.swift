#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

/// One display's claim to a scene, as far as sharing its runtime with another display is concerned.
struct SceneMirrorCandidate: Equatable, Sendable {
    var screenID: CGDirectDisplayID
    var descriptor: SceneDescriptor
    var fitMode: VideoFitMode
    var mouseInteraction: Bool
    var clickCapture: Bool
    /// nil = no Metal device drives the display.
    var deviceRegistryID: UInt64?
    var frame: CGRect
    var density: CGFloat
    /// The span route presents SDR only, so a display that would get HDR output never mirrors.
    var wantsHDR: Bool

    func canMirror(_ other: Self) -> Bool {
        guard let deviceRegistryID, deviceRegistryID == other.deviceRegistryID, !wantsHDR, !other.wantsHDR,
              descriptor == other.descriptor, fitMode == other.fitMode,
              mouseInteraction == other.mouseInteraction, clickCapture == other.clickCapture,
              frame.width > 0, frame.height > 0, other.frame.width > 0, other.frame.height > 0 else { return false }
        // Presenters scale the shared frame; a shape gap over 1% would show as a visibly different crop.
        let ratio = (frame.width / frame.height) / (other.frame.width / other.frame.height)
        return abs(ratio - 1) <= 0.01
    }
}

enum SceneMirrorPlan: Equatable {
    case independent
    case join(UUID)
    case create(peers: [CGDirectDisplayID])
}

struct SceneMirrorEntry {
    /// The display whose restore created the group; joiners must match it.
    let lead: SceneMirrorCandidate
    let group: SceneSpanWallpaperGroup
}

extension ScreenManager {
    static func sceneMirrorPlan(for candidate: SceneMirrorCandidate, peers: [SceneMirrorCandidate],
                                groups: [(id: UUID, lead: SceneMirrorCandidate, density: CGFloat)],
                                enabled: Bool) -> SceneMirrorPlan {
        guard enabled else { return .independent }
        let matching = peers.filter { $0.screenID != candidate.screenID && candidate.canMirror($0) }
        guard !matching.isEmpty else { return .independent }
        // A group rendered for a lower density would upscale this display; rebuild with every peer instead.
        if let group = groups.first(where: { $0.lead.canMirror(candidate) && $0.density >= candidate.density }) {
            return .join(group.id)
        }
        return .create(peers: matching.map(\.screenID))
    }

    func sceneMirrorCandidate(for screen: Screen, configuration: ScreenConfiguration) -> SceneMirrorCandidate? {
        guard configuration.sceneSpanGroupID == nil, case let .scene(descriptor) = configuration.activeWallpaper else { return nil }
        let edr = screen.nsScreen.maximumPotentialExtendedDynamicRangeColorComponentValue
        let hdr = WPEDisplayHDROutput.shouldRequestHDROutput(settingEnabled: WPEDisplayHDROutput.isEnabled, targetMaximumPotentialEDR: edr)
        return SceneMirrorCandidate(
            screenID: screen.id, descriptor: descriptor, fitMode: configuration.fitMode,
            mouseInteraction: configuration.sceneMouseInteractionEnabled, clickCapture: configuration.sceneClickCaptureEnabled,
            deviceRegistryID: CGDirectDisplayCopyCurrentMetalDevice(screen.id)?.registryID,
            frame: screen.frame, density: screen.nsScreen.backingScaleFactor, wantsHDR: hdr
        )
    }

    /// nil = this display runs its own runtime.
    func makeSceneMirrorSession(
        descriptor: SceneDescriptor, origin: WPEOrigin?, screen: Screen,
        configuration: ScreenConfiguration, dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL?, onOriginBookmarkRefresh: @escaping AmbientWallpaperSessionBuilder.WPEOriginRefreshHandler
    ) -> (any SceneWallpaperRuntime)? {
        let enabled = WPEParityResourceSaverFlags.resolve().sceneMirrorRendering
        guard enabled, var candidate = sceneMirrorCandidate(for: screen, configuration: configuration) else { return nil }
        candidate.descriptor = descriptor
        let peers = screens.compactMap { peer in
            getConfiguration(for: peer).flatMap { sceneMirrorCandidate(for: peer, configuration: $0) }
        }
        let groups = sceneMirrorGroups.map { (id: $0.key, lead: $0.value.lead, density: $0.value.group.density) }
        let group: SceneSpanWallpaperGroup
        switch Self.sceneMirrorPlan(for: candidate, peers: peers, groups: groups, enabled: enabled) {
        case .independent:
            return nil
        case let .join(id):
            guard let existing = sceneMirrorGroups[id]?.group else { return nil }
            group = existing
        case let .create(peerIDs):
            let members = [candidate] + peers.filter { peerIDs.contains($0.screenID) }
            guard let created = makeSceneMirrorGroup(lead: candidate, members: members, origin: origin,
                                                     dependencyMounts: dependencyMounts, engineAssetsRootURL: engineAssetsRootURL,
                                                     onOriginBookmarkRefresh: onOriginBookmarkRefresh) else { return nil }
            group = created
        }
        do {
            return try group.makeMember(for: screen, configuration: configuration)
        } catch {
            group.discardUnattachedMember(for: screen.id)
            Logger.warning("Scene mirror presenter could not be created: \(error.localizedDescription)", category: .screenManager)
            return nil
        }
    }

    private func makeSceneMirrorGroup(
        lead: SceneMirrorCandidate, members: [SceneMirrorCandidate], origin: WPEOrigin?, dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL?, onOriginBookmarkRefresh: @escaping AmbientWallpaperSessionBuilder.WPEOriginRefreshHandler
    ) -> SceneSpanWallpaperGroup? {
        let layouts = Dictionary(members.map { ($0.screenID, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let density = members.map(\.density).max() ?? 1
        let frames = WPESceneSpanFrames()
        guard let owner = ambientSessionBuilder.makeSceneSession(
            descriptor: lead.descriptor, origin: origin, frame: SceneSpanWallpaperGroup.mirrorCanvas(layouts), fitMode: lead.fitMode,
            spanFrames: frames, spanDensity: density, spanMemberCount: members.count,
            dependencyMounts: dependencyMounts, engineAssetsRootURL: engineAssetsRootURL,
            onOriginBookmarkRefresh: onOriginBookmarkRefresh
        ) else { return nil }
        let id = UUID()
        let group = SceneSpanWallpaperGroup(id: id, descriptor: lead.descriptor, owner: owner, frames: frames,
                                            density: density, displayFrames: layouts, layout: .mirror)
        // A superseded group keeps presenting until its members are restored into this one.
        sceneMirrorGroups = sceneMirrorGroups.filter { !$0.value.lead.canMirror(lead) }
        sceneMirrorGroups[id] = SceneMirrorEntry(lead: lead, group: group)
        group.onEmpty = { [weak self, weak group] in
            if self?.sceneMirrorGroups[id]?.group === group {
                self?.sceneMirrorGroups[id] = nil
            }
        }
        group.onMemberDiverged = { [weak self] screenID in
            guard let self, let screen = screens.first(where: { $0.id == screenID }) else { return }
            loadConfigurationForScreen(screen)
        }
        let joiners = members.map(\.screenID).filter { $0 != lead.screenID }
        // Deferred: restoring a peer inside this display's own activation would re-enter it.
        Task { @MainActor [weak self, weak group] in
            guard let self, let group, sceneMirrorGroups[id]?.group === group else { return }
            for peer in screens where joiners.contains(peer.id) && !group.hasMember(peer.id) {
                guard let stored = getConfiguration(for: peer), let current = sceneMirrorCandidate(for: peer, configuration: stored),
                      lead.canMirror(current) else { continue }
                loadConfigurationForScreen(peer)
            }
        }
        return group
    }
}
#endif
