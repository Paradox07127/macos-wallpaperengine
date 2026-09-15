"""Instrument current product cards; fail on drift. Changes are probe-only."""
from pathlib import Path
import hashlib, json, os

out = Path(os.environ['UI_PROBE_OUT'])
gen = out / 'generated'
manifest = {}

def read(path):
    text = Path(path).read_text()
    manifest[path] = hashlib.sha256(text.encode()).hexdigest()
    return text

def replace(text, old, new):
    assert old in text, old
    return text.replace(old, new)

for name, field in [('BrowseCard', 'isHovered'), ('HistoryRow', 'isHovering')]:
    folder = 'Workshop' if name == 'BrowseCard' else 'ScreenDetail'
    text = read(f'LiveWallpaper/Views/{folder}/{name}.swift').replace('import LiveWallpaperProWPE', '')
    text = replace(text, '    var body: some View {', '    var body: some View {\n        let _ = Metrics.cardBodies += 1')
    text = replace(text, f'.settledHover {{ {field} = $0 }}',
                   f'.settledHover {{ {field} = $0; Metrics.hoverChanged($0) }}')
    (gen / f'{name}.swift').write_text(text)

text = read('LiveWallpaper/Views/Workshop/AnimatedGIFThumbnail.swift')
text = replace(text, 'phase = asset == nil ? .failed : .ready',
               'phase = asset == nil ? .failed : .ready\n        if asset != nil { Metrics.ready.insert(url.lastPathComponent) }')
text = replace(text, 'if let frame { self.displayedFrame = frame }',
               'if let frame { self.displayedFrame = frame; Metrics.frames += 1 }')
(gen / 'AnimatedGIFThumbnail.swift').write_text(text)

text = read('LiveWallpaper/Views/ScreenDetail/ScenePreview.swift')
text = replace(text, 'nsView.apply(cached)', 'nsView.apply(cached); Metrics.ready.insert(url.deletingLastPathComponent().lastPathComponent)')
text = replace(text, 'nsView.apply(decoded)', 'nsView.apply(decoded); Metrics.ready.insert(url.deletingLastPathComponent().lastPathComponent)')
text = replace(text, 'if let frame { self.layer?.contents = frame }',
               'if let frame { self.layer?.contents = frame; Metrics.frames += 1 }')
# Expose the exact product decode operation to the bounded, probe-only preheater.
text = replace(text, '    private static func loadAndDecode(', '    static func loadAndDecode(')
text += '''\n@MainActor func workflowDecode(_ url: URL, bookmark: Data) async -> WPEPreviewDecodedImage? {
    await AspectFillImage.loadAndDecode(url: url, bookmarkData: bookmark, size: .tile)
}\n'''
(gen / 'ScenePreview.swift').write_text(text)
(out / 'workflow-source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

driver = out / 'driver'
driver.mkdir(exist_ok=True)
text = read('tools/workshop-workflow-probe/main.swift')
if os.environ.get('WORKFLOW_EVENTLOOP_DRIVER') == '1':
    text = text[:text.index('@MainActor func run() async throws')]
    text += read('tools/workshop-workflow-probe/EventLoopDriver.swift')
if os.environ.get('WORKFLOW_TIMER_DRIVER') == '1':
    text = text.replace('Task.sleep(for: ', 'runLoopDelay(')
    text = text.replace('"\\(name)"', '"\\(name, privacy: .public)"')
    text += '''
@MainActor func runLoopDelay(_ duration: Duration) async throws {
    let parts = duration.components
    let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let timer = Timer(timeInterval: max(0.0001, seconds), repeats: false) { _ in
            continuation.resume()
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
'''
(driver / 'main.swift').write_text(text)
(out / 'workflow-source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
