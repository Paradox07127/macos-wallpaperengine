import AppKit
import LiveWallpaperCore
import SwiftUI

/// Tracks whether a library tile is mid-drag.
///
/// SwiftUI's `onDrag` reports no completion, so a drag released anywhere that is
/// not a drop target would leave the bar on screen forever. The end has to come
/// from AppKit event monitors.
@MainActor
@Observable
final class LibraryDragSession {
    struct MonitorHooks {
        let installLocal: (@escaping @MainActor () -> Void) -> Any?
        let installGlobal: (@escaping @MainActor () -> Void) -> Any?
        let remove: (Any) -> Void

        @MainActor static let appKit = MonitorHooks(
            installLocal: { onEnd in
                NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { event in
                    // 53 is Escape: a drag abandoned with the keyboard still ends.
                    if event.type == .leftMouseUp || (event.type == .keyDown && event.keyCode == 53) {
                        Task { @MainActor in onEnd() }
                    }
                    return event
                }
            },
            installGlobal: { onEnd in
                NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
                    Task { @MainActor in onEnd() }
                }
            },
            remove: { NSEvent.removeMonitor($0) }
        )
    }

    private(set) var isDragging = false

    /// `nonisolated(unsafe)`: mutated only from MainActor code, but `deinit` runs
    /// on an arbitrary queue and must still take the monitors down.
    private nonisolated(unsafe) let hooks: MonitorHooks
    private nonisolated(unsafe) var localMonitor: Any?
    private nonisolated(unsafe) var globalMonitor: Any?

    init(hooks: MonitorHooks = .appKit) {
        self.hooks = hooks
    }

    deinit {
        removeMonitorsFromAnyIsolation()
    }

    #if DEBUG
    /// Test-only introspection; no production reader.
    var activeMonitorCount: Int {
        (localMonitor == nil ? 0 : 1) + (globalMonitor == nil ? 0 : 1)
    }
    #endif

    /// Returns the drag payload so call sites read as `NSItemProvider(object: session.begin(id) as NSString)`.
    @discardableResult
    func begin(payload: String) -> String {
        removeMonitorsFromAnyIsolation()
        isDragging = true
        localMonitor = hooks.installLocal { [weak self] in self?.end() }
        globalMonitor = hooks.installGlobal { [weak self] in self?.end() }
        return payload
    }

    func end() {
        isDragging = false
        removeMonitorsFromAnyIsolation()
    }

    private nonisolated func removeMonitorsFromAnyIsolation() {
        if let localMonitor {
            hooks.remove(localMonitor)
        }
        if let globalMonitor {
            hooks.remove(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
    }
}

/// The strip of display drop targets that floats over a library grid while a
/// tile is being dragged. Shared by Workshop Installed, Bookmarks and Schemes so
/// the three pages cannot drift into three slightly different drag-to-apply
/// gestures.
struct LibraryDragApplyBar: View {
    let screens: [Screen]
    let onCancel: () -> Void
    /// Two-phase on purpose. Phase one runs synchronously when the drop lands, so
    /// a page can snapshot a validity ticket *before* the item provider's
    /// asynchronous read; phase two consumes the payload once it arrives
    /// (`identifier` nil or `loadFailed` true when the provider gave nothing).
    let makeDropHandler: (Screen) -> @MainActor (_ identifier: String?, _ loadFailed: Bool) -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text("Drop onto a display to apply")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)

            // Laid out in the system's own arrangement so the target you aim at
            // is the panel in that physical position.
            DisplayArrangementMap(
                items: screens.map { DisplayArrangementItem(id: $0.id, frame: $0.frame) },
                height: 110
            ) { item, size in
                if let screen = screens.first(where: { $0.id == item.id }) {
                    dropTarget(screen, size: size)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        // Floats over the grid for the length of a drag — the one moment these
        // pages have live content under a control strip.
        .adaptiveGlassSurface(.roundedRectangle(0), stroked: false)
        .overlay(alignment: .topTrailing) {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(DesignTokens.Spacing.sm)
            .help(Text("Cancel"))
            .accessibilityLabel(Text("Cancel"))
        }
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func dropTarget(_ screen: Screen, size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [5]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous))
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "display")
                        .font(.system(size: size.height >= 60 ? 24 : 16))
                        .foregroundStyle(Color.accentColor)
                    // A short panel has no room for both glyph and name.
                    if size.height >= 46 {
                        Text(verbatim: screen.name)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                }
            }
            .contentShape(Rectangle())
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                handleDrop(providers, to: screen)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Apply to \(screen.name)"))
    }

    private func handleDrop(_ providers: [NSItemProvider], to screen: Screen) -> Bool {
        let handler = makeDropHandler(screen)
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            handler(nil, true)
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { value, error in
            // Extract Sendable values (String / Bool) before crossing to the main
            // actor — NSString and Error are not Sendable under Swift 6.
            let identifier = value as? String
            let loadFailed = error != nil
            Task { @MainActor in handler(identifier, loadFailed) }
        }
        return true
    }
}

/// Small icon shown under the cursor while dragging — deliberately NOT the
/// tile's artwork, so it doesn't obscure which display you're hovering.
struct LibraryDragPreview: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.onAccentFill)
            .frame(width: 54, height: 54)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous))
    }
}
