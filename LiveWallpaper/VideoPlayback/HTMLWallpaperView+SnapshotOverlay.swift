import AppKit
import WebKit

extension HTMLWallpaperView {
    // MARK: - Snapshot Overlay

    /// Cap suspend-snapshot width (~50 MB full 5K capture would defeat suspend memory relief).
    private static let maxSuspendSnapshotWidth: CGFloat = 1920

    /// Generation-counted so stale takeSnapshot cannot reappear after resume.
    func captureSuspendSnapshot() {
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.afterScreenUpdates = false
        // Point-width + absolute ceiling; multi-screen must not pin full 5K bitmaps.
        let pointWidth = webView.bounds.width
        if pointWidth > 0 {
            snapshotConfig.snapshotWidth = NSNumber(
                value: Double(min(pointWidth, Self.maxSuspendSnapshotWidth))
            )
        }
        webView.takeSnapshot(with: snapshotConfig) { [weak self] image, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isCleaningUp,
                      self.mediaPlaybackSuspended,
                      self.snapshotGeneration == generation,
                      let image else { return }
                self.applySnapshotOverlay(image: image)
            }
        }
    }

    private func applySnapshotOverlay(image: NSImage) {
        snapshotOverlay.image = image
        snapshotOverlay.frame = bounds
        snapshotOverlay.isHidden = false
        webView.isHidden = true
    }

    func hideSnapshotOverlay() {
        snapshotOverlay.isHidden = true
        snapshotOverlay.image = nil
        webView.isHidden = false
    }
}
