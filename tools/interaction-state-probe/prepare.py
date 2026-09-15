from pathlib import Path
import os,json,hashlib
root=Path.cwd();out=Path(os.environ['INTERACTION_PROBE_OUT']);gen=out/'generated';gen.mkdir(parents=True,exist_ok=True);manifest={}
def read(p):
 s=(root/p).read_text();manifest[p]=hashlib.sha256(s.encode()).hexdigest();return s
handle=read('LiveWallpaper/Views/ScreenDetail/InspectorResizeHandle.swift')
native='import AppKit\nimport SwiftUI\nimport LiveWallpaperCore\n'+handle[handle.index('struct InspectorResizeHandle:'):]
native=native.replace('InspectorResizeHandle','NativeInspectorResizeHandle').replace('.gesture(resizeGesture)', '.overlay(NativeResizeEvents(onDrag: nativeDrag))')
method='''    private func nativeDrag(_ translation: CGFloat, _ ended: Bool) {
        let start = dragStartWidth ?? width
        let candidate = rawCandidate(start: start, translationWidth: translation)
        if ended {
            if armed(for: candidate), let onRequestClose { onRequestClose() }
            else { onCommitWidth(clamped(candidate)) }
            dragStartWidth = nil
            isDragging = false
            isClosingArmed = false
        } else {
            if dragStartWidth == nil { dragStartWidth = start }
            isDragging = true
            setClosingArmed(armed(for: candidate))
            onPreviewWidthChange(clamped(candidate))
        }
    }

'''
native=native.replace('    private var resizeGesture:', method+'    private var resizeGesture:');(gen/'NativeInspectorResizeHandle.swift').write_text(native)
split=read('LiveWallpaper/Views/ScreenDetail/InspectorSplit.swift');split='import SwiftUI\nimport LiveWallpaperCore\n'+split[split.index('struct InspectorSplit<'):];split=split.replace('InspectorSplit<','NativeInspectorSplit<').replace('InspectorResizeHandle','NativeInspectorResizeHandle');(gen/'NativeInspectorSplit.swift').write_text(split)
scene=read('tools/ui-architecture-probe/ProbeViews.swift').split('struct GridProbeView:')[0]
for line in ['    var items: [WorkshopQueryItem] = []\n','    var installed: [UInt64: WPEHistoryEntry] = [:]\n']:scene=scene.replace(line,'')
(gen/'SceneProbe.swift').write_text(scene)
for p in ['LiveWallpaper/Views/Schedule/TimelineEditor.swift','LiveWallpaper/Views/Schedule/Preset.swift','LiveWallpaper/Policies/SchedulePolicy.swift','LiveWallpaper/Views/ScreenDetail/PropertyValueLogic.swift','LiveWallpaper/Views/ScreenDetail/ProjectPresentation.swift','LiveWallpaper/Views/ScreenDetail/ProjectSettingWidgets.swift','LiveWallpaper/Infrastructure/Assets/WallpaperEngineProjectPropertySchema.swift']:
 read(p)
(out/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')

web=read('LiveWallpaper/Views/ScreenDetail/WebTransformCanvas.swift')
web=web.replace('            .gesture(manipulation, isEnabled: isArmed)', '            .gesture(manipulation, isEnabled: isArmed)\n            .onChange(of: dragTranslation) { _, value in TransformTrace.translation = value }\n            .onChange(of: isManipulating) { _, value in TransformTrace.manipulating = value }')
(gen/'WebTransformCanvas.swift').write_text(web)
(out/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')

for p in ['tools/interaction-state-probe/main.swift','tools/interaction-state-probe/NativeResizeEvents.swift','tools/interaction-state-probe/WebBoundary.swift','tools/interaction-state-probe/prepare.py','tools/interaction-state-probe/build.sh','tools/ui-architecture-probe/NativeSlider.swift']:
    read(p)
(out/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
