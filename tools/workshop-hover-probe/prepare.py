from pathlib import Path
import os,json,hashlib
out=Path(os.environ['HOVER_PROBE_OUT']); gen=out/'generated';manifest={}
def read(p):
 s=Path(p).read_text();manifest[p]=hashlib.sha256(s.encode()).hexdigest();return s
for name,p,field in [('BrowseCard','LiveWallpaper/Views/Workshop/BrowseCard.swift','isHovered'),('HistoryRow','LiveWallpaper/Views/ScreenDetail/HistoryRow.swift','isHovering')]:
 s=read(p).replace('import LiveWallpaperProWPE','')
 needle='    @State private var '+field+' = false';assert needle in s
 s=s.replace(needle,'    @Environment(\\.probeHovered) private var probeHovered\n'+needle)
 needle='.settledHover { '+field+' = $0 }';assert needle in s
 s=s.replace(needle,'.onChange(of: probeHovered, initial: true) { _, value in\n            if '+field+' != value { AnimationMetrics.hoverTransitions += 1 }; '+field+' = value\n        }')
 if os.environ.get('HOVER_VARIANT')=='chrome-fixed':
  s=s.replace('.galleryTileChrome(isHovering: '+field, '.galleryTileChrome(isHovering: false')
  s=s.replace('                isHovering: '+field+',','                isHovering: false,')
 s=s.replace('    var body: some View {','    var body: some View {\n        let _ = AnimationMetrics.cardBodies += 1',1)
 (gen/(name+'.swift')).write_text(s)
for name,p in [('AnimatedGIFThumbnail','LiveWallpaper/Views/Workshop/AnimatedGIFThumbnail.swift'),('ScenePreview','LiveWallpaper/Views/ScreenDetail/ScenePreview.swift')]:
 s=read(p);needle='if let frame { self.displayedFrame = frame }' if name=='AnimatedGIFThumbnail' else 'if let frame { self.layer?.contents = frame }'
 assert needle in s;s=s.replace(needle,needle.replace('if let frame {','if let frame { AnimationMetrics.frames += 1;'))
 (gen/(name+'.swift')).write_text(s)
s=read('Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/ThumbnailTitleBand.swift')
s=s.replace('import SwiftUI','import SwiftUI\nimport LiveWallpaperCore')
if os.environ.get('HOVER_VARIANT')=='title-fixed':s=s.replace('isHovering ? lineHeight * 2 : lineHeight','lineHeight')
(gen/'ThumbnailTitleBand.swift').write_text(s)
(out/'hover-source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
