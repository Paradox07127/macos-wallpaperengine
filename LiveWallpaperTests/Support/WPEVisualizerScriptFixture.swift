import Foundation

/// Synthetic fixture reproducing the user's visualizer protocol without copying
/// Workshop artwork. Fixed amplitudes make geometry assertions independent of
/// microphone/system-audio permission and the current music track.
enum WPEVisualizerScriptFixture {
    static let imagePath = "models/workshop/12345/bar.json"
    static let script = """
    // __workshopId = '99999' is a misleading comment, not runtime metadata.
    export let __workshopId = '12345';
    let bars = [], baseOrigin;
    export function init() {
        bars.push(thisLayer);
        let index = thisScene.getLayerIndex(thisLayer);
        for (let i = 1; i < 64; ++i) {
            let bar = thisScene.createLayer('models/bar.json');
            bar.alignment = 'bottom';
            if (!thisScene.sortLayer(bar, index)) throw new Error('sort rejected');
            if (thisScene.getLayerIndex(bar) !== index) throw new Error('stale index');
            bar.parallaxDepth = new Vec2(0, 0);
            bars.push(bar);
        }
        for (let i = 0; i < 64; ++i) bars[i].angles = new Vec3(0, 0, 0);
        baseOrigin = thisLayer.origin.copy();
        shared.initComplete = bars.length === 64;
        shared.currentCount = thisScene.getLayerCount();
        shared.currentOrder = thisScene.enumerateLayers().map(x => x.name).join(',');
        layout();
    }
    function layout() {
        for (let i = 0; i < 64; ++i) {
            let origin = baseOrigin.copy();
            origin.x += (i % 8) * 8;
            origin.y += Math.floor(i / 8) * 8;
            bars[i].alignment = 'bottom';
            bars[i].scale = new Vec3(0.5, 0.25, 0);
            bars[i].origin = origin;
        }
        shared.updateComplete = true;
    }
    export function update() { layout(); }
    """
}
