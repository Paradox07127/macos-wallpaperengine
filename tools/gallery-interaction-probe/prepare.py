from pathlib import Path
import os,json,hashlib
root=Path(__file__).resolve().parents[2]
out=Path(os.environ['GALLERY_PROBE_OUT']);out.mkdir(parents=True,exist_ok=True)
manifest=[]
def src(p):
 s=(root/p).read_text();manifest.append({'path':p,'sha256':hashlib.sha256(s.encode()).hexdigest()});return s
def block(s,m):
 start=s.index(m);i=s.index('{',start)+1;depth=1
 while depth:
  if s[i]=='{':depth+=1
  elif s[i]=='}':depth-=1
  i+=1
 return s[start:i]
parts=['import AppKit\nimport SwiftUI\nimport LiveWallpaperCore\nimport ImageIO\nimport WebKit']
for path,marker in [('Views/Bookmarks/LibraryView.swift','private struct BookmarkTile:'),('Views/Schemes/SchemeLibraryView.swift','private struct SchemeTile:'),('Infrastructure/Platform/AppleAerialsLibrary.swift','struct AerialAsset:'),('Views/SystemWallpaper/SystemWallpaperLibraryView.swift','struct SystemWallpaperTile:'),('Views/SystemWallpaper/SystemWallpaperLibraryView.swift','enum SystemWallpaperThumbnails'),('Views/ScreenDetail/HTMLPreviewSection.swift','enum HTMLPreviewKey'),('Infrastructure/Services/LocalImageCacheReclaimer.swift','final class LocalImageCacheRegistry:')]:
 parts.append(block(src('LiveWallpaper/'+path),marker).replace('private struct BookmarkTile:','struct BookmarkTile:').replace('private struct SchemeTile:','struct SchemeTile:').replace('struct SystemWallpaperTile:','struct SystemWallpaperTile:'))
for marker in ['struct HTMLWallpaperCompatibilityResult', 'enum HTMLWallpaperCompatibilityPolicy', 'private enum WPEPathSafety']:
 parts.append(block(src('LiveWallpaper/Runtime/Session/AmbientWallpaperSessionBuilder.swift'),marker))
# Exclude publication/list construction, preserve the actual candidate thumbnail method and tile.
s=src('LiveWallpaper/Views/SystemWallpaper/SystemWallpaperCandidate.swift')
parts.append('struct SystemWallpaperCandidate: Identifiable { enum Source { case bookmark(WallpaperBookmark) }; let id: String; let title: String; let source: Source; @MainActor '+block(s,'func thumbnail()')+' }')
parts.append(block(s,'struct SystemWallpaperCandidateTile:'))
s=src('LiveWallpaper/Infrastructure/Diagnostics/WPEImageCacheMeter.swift');parts.append(s[:s.index('enum WPEImageCacheMeter {')]+'''enum WPEImageCacheMeter {
 static let shared = WPEImageCacheAccountant()
 static func attach<K: AnyObject,V: AnyObject>(_ cache: NSCache<K,V>, as kind: WPEImageCacheKind) { shared.attach(cache,as:kind) }
 static func recordInsert(_ object:AnyObject,cost:Int,in kind:WPEImageCacheKind) { shared.recordInsert(object,cost:cost,in:kind) }
}''')
(out/'Extracted.swift').write_text('\n'.join(parts))
(out/'source-manifest.json').write_text(json.dumps(manifest,indent=2))
