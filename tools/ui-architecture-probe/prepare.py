from pathlib import Path
import hashlib,json,os
root=Path(__file__).resolve().parents[2]; base=Path(os.environ.get('UI_PROBE_OUT', root/'.notes/evidence/ui/2026-09-15-appkit-experiment')); out=base/'generated'; out.mkdir(parents=True,exist_ok=True)
manifest=[]
def source(p):
 data=(root/p).read_bytes();manifest.append({'path':p,'sha256':hashlib.sha256(data).hexdigest()});return data.decode()
def block(text,marker):
 start=text.index(marker);brace=text.index('{',start);depth=1;i=brace+1
 while depth:
  if text[i]=='{':depth+=1
  if text[i]=='}':depth-=1
  i+=1
 return text[start:i]
parts=['import AppKit\nimport ImageIO\nimport SwiftUI\nimport LiveWallpaperCore\nimport os']
for p,m in [('LiveWallpaper/Infrastructure/Workshop/WorkshopQueryService.swift','struct WorkshopQueryItem:'),('LiveWallpaper/Infrastructure/Workshop/SteamWorkshopMetadata.swift','struct SteamWorkshopMetadata:'),('LiveWallpaper/Views/Workshop/PasteRowCard.swift','enum WorkshopCountFormatter'),('LiveWallpaper/Infrastructure/Services/LocalImageCacheReclaimer.swift','final class LocalImageCacheRegistry:')]:parts.append(block(source(p),m))
t=source('LiveWallpaper/Views/Workshop/BrowseViewModel.swift');parts += [block(t,m) for m in ['enum WorkshopContentTypeFilter:','enum WorkshopResolutionFilter:','extension WorkshopQueryItem']]
parts += ['private struct InspectorContentIsVisibleKey: EnvironmentKey { static let defaultValue = true }\nextension EnvironmentValues { var inspectorContentIsVisible: Bool { get { self[InspectorContentIsVisibleKey.self] } set { self[InspectorContentIsVisibleKey.self] = newValue } } }','enum MatureContentSettings { @MainActor static var isConfirmed = false; @MainActor static func confirm() { isConfirmed = true } }']
(out/'Extracted.swift').write_text('\n\n'.join(parts))
p='LiveWallpaper/Infrastructure/Workshop/WorkshopPreviewImageLoader.swift'
t=source(p).replace('static let shared = WorkshopPreviewImageLoader()','static let shared = makeProbeLoader()')
(out/'WorkshopPreviewImageLoader.swift').write_text(t)
(base/'extraction-manifest.json').write_text(json.dumps(manifest,indent=2))
print(out)
p=out/'Extracted.swift';p.write_text(p.read_text()+'\n'+block(source('LiveWallpaper/Infrastructure/Workshop/WorkshopQueryService.swift'),'enum WorkshopRating:'))
t=source('LiveWallpaper/Infrastructure/Diagnostics/WPEImageCacheMeter.swift');t=t[:t.index('enum WPEImageCacheMeter {')]+'''enum WPEImageCacheMeter {
 static let shared = WPEImageCacheAccountant()
 static func attach<K: AnyObject,V: AnyObject>(_ cache: NSCache<K,V>, as kind: WPEImageCacheKind) { shared.attach(cache, as: kind) }
 static func recordInsert(_ object: AnyObject,cost: Int,in kind: WPEImageCacheKind) { shared.recordInsert(object,cost:cost,in:kind) }
}''';(out/'WPEImageCacheMeter.swift').write_text(t)
(base/'extraction-manifest.json').write_text(json.dumps(manifest,indent=2))


p=out/'HistoryRow.swift';p.write_text(source('LiveWallpaper/Views/ScreenDetail/HistoryRow.swift').replace('import LiveWallpaperProWPE',''))
p=out/'Extracted.swift';p.write_text(p.read_text()+'\n@MainActor struct Screen: Identifiable { let id: UInt32; let name: String }\n')
(base/'extraction-manifest.json').write_text(json.dumps(manifest,indent=2))
