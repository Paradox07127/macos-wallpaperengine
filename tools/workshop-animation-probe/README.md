# Workshop animation lifecycle comparison

Build a standalone optimized macOS window with the actual online and installed preview components:

```sh
ANIMATION_PROBE_OUT="$PWD/.notes/evidence/ui/workshop-animation-probe" bash tools/workshop-animation-probe/build.sh
.../AnimationProbe.app/Contents/MacOS/AnimationProbe --mode installed --count 8 --gif /absolute/path/preview.gif --output /private/tmp/installed.json
```

Requires an existing Release Core build at `/private/tmp/lw-ui-settings-core`. Set it up using `swift build --package-path Packages/LiveWallpaperCore -c release --scratch-path /private/tmp/lw-ui-settings-core`. The build links actual preview loaders, views and decode code. Generated copies only count preview body evaluations and frame assignments; HTTP fetching is replaced with a local actor reading the specified GIF. App configuration and wallpaper sessions are untouched.

Run serially on the interactive desktop after builds and other probes finish. Each fresh process warms for two seconds, then measures static, playing, retained-but-hidden host, and resumed states. The hidden state changes the real `inspectorContentIsVisible` environment contract, while retaining the view. Eight concurrent autoplay previews are deliberate stress, not eight simultaneous real pointer hovers. Default duration is three seconds per phase; `--seconds` changes it. Both components use their tile size (800 longest-edge pixels).

CPU is per-process user plus system CPU time. `frameTimes` records per-controller/view image assignment timestamps and is reset for each phase. `frames` counts image assignments, not presented frames. Body evaluations count the component body only. Main-actor gaps include a requested 16 ms sleep and are not hitch or physical input latency measurements. This probe does not scroll the production page or contact Steam. Use full-app input and Instruments separately to assess those paths. Preserve three repetitions, thermal states, generated sources and binary hashes. A single run is diagnostic evidence only.

The original baseline and visibility-fix binaries and their probe-source snapshots are preserved under `.notes/evidence/ui/2026-09-15-workshop-cards/`. Later rebuilds should use a new output directory.
