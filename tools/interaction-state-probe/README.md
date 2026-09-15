# Remaining interaction checks

Standalone macOS input probe. Product code stays in SwiftUI; the AppKit candidate is linked only into this executable.

```sh
INTERACTION_PROBE_OUT="$PWD/.notes/evidence/ui/2026-09-15-remaining-interactions/probe" bash tools/interaction-state-probe/build.sh
python3 tools/interaction-state-probe/run.py
```

The build expects the existing release Core build in `/private/tmp/lw-ui-settings-core`; create it with `swift build --package-path Packages/LiveWallpaperCore -c release --scratch-path /private/tmp/lw-ui-settings-core` if absent. Run after other builds, tests and probes finish, with an interactive desktop. The executable requires its own window to be active. Run serially; do not run a held visual probe alongside another input run.

The matrix uses two real Workshop project schemas, three fresh processes for each input variant and schema, and 40 posted native mouse samples per drag. Both variants share the real `InspectorSplit` layout and handle visuals. The native candidate changes only mouse tracking to an NSView overlay; it is not an NSSplitView rewrite. Its generated callback follows the original handle's preview/commit/close logic. Property content comes from the existing `SceneProbeView`, using the repository's schema parser, presentation, rows and QuantizedSlider. It is not the full production inspector or runtime patch path.

Each run checks no write before release, exactly one width commit, correct endpoint, and drag-to-close. States are initial, changed boolean option if present, collapsed groups, reopened, and close. A schema without groups has a no-op collapsed-groups control. `submissionMs` measures explicit layout/display submission after the event pump; AppKit may already have laid out during that pump. `mainActorGapMs` includes the requested 16 ms sleep. Neither is presented frame time or physical input latency. Preserve full values, thermal states and source/binary hashes; do not infer universal framework superiority from this experiment.

Other modes, with the same executable:

```sh
.../InteractionProbe --mode timeline --output /private/tmp/timeline.json
.../InteractionProbe --mode web --output /private/tmp/web.json
```

Timeline uses the actual TimelineEditor and SchedulePolicy with three controlled slots. Checks move, leading/trailing edge edits and release-only commits. Coordinates were calibrated against the composed window; the first failed run landed in the tick area, not the track.

Web uses the actual WebTransformCanvas, with two read-only state observations added to the generated copy. `WebBoundary.swift` replaces only the display and wallpaper commit receiver: writes are recorded, never applied to a desktop. Checks first prove a live drag, then disarm, switch display during a second drag, send more events before release, and start a third valid drag. The 400×300 intrinsic canvas shrinks its window; the pointer starts at the actual content center. An unmatched initial drag invalidates all downstream checks. No physical pinch/rotation, remote webpage, or real wallpaper rendering is measured.

The original inspector comparison binary lives in `probe/`; later HTML experiments use separate `web-*` output folders to preserve the earlier measurements. Raw unmatched runs and the successful negative/positive comparison remain in the evidence folder.
