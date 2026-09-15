from pathlib import Path
import hashlib,json,os
out=Path(os.environ['ANIMATION_PROBE_OUT']);manifest={}
for filename,path in [('AnimatedGIFThumbnail.swift','LiveWallpaper/Views/Workshop/AnimatedGIFThumbnail.swift'),('ScenePreview.swift','LiveWallpaper/Views/ScreenDetail/ScenePreview.swift')]:
 s=Path(path).read_text();manifest[path]=hashlib.sha256(s.encode()).hexdigest()
 s=s.replace('    var body: some View {','    var body: some View {\n        let _ = AnimationMetrics.bodyEvaluations += 1',1)
 if filename=='AnimatedGIFThumbnail.swift':
  needle='if let frame { self.displayedFrame = frame }';assert needle in s;s=s.replace(needle,'if let frame { AnimationMetrics.frames += 1; self.displayedFrame = frame }')
 else:
  needle='if let frame { self.layer?.contents = frame }';assert needle in s;s=s.replace(needle,'if let frame { AnimationMetrics.frames += 1; self.layer?.contents = frame }')
 (out/'generated'/filename).write_text(s)
for p in ['tools/workshop-animation-probe/main.swift','tools/workshop-animation-probe/prepare.py','tools/workshop-animation-probe/build.sh']:manifest[p]=hashlib.sha256(Path(p).read_bytes()).hexdigest()
(out/'animation-source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
