from pathlib import Path
import hashlib,json,subprocess,os
root=Path.cwd();out=Path(os.environ['UI_PROBE_OUT'])
paths=list((root/'tools/workshop-workflow-probe').glob('*'))+list((out/'generated').glob('*.swift'))+list((out/'driver').glob('*.swift'))
for folder in ['Packages/LiveWallpaperCore/Sources','LiveWallpaper/Infrastructure/Workshop','LiveWallpaper/Infrastructure/Services','LiveWallpaper/Infrastructure/Diagnostics','LiveWallpaper/Infrastructure/Assets','LiveWallpaper/Views/ScreenDetail','LiveWallpaper/Views/Workshop','Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/Schema','Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/PathSafety']:
 paths.extend((root/folder).rglob('*.swift'))
manifest={'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'optimization':'swiftc -O; SwiftPM release','sources':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()},'binarySHA256':hashlib.sha256((out/'WorkflowProbe').read_bytes()).hexdigest()}
(out/'source-build-manifest.json').write_text(json.dumps(manifest,indent=2))
