# Gallery interaction probe

Optimized standalone macOS probe for actual BookmarkTile, SchemeTile, Aerial ThumbnailCard, SystemWallpaperCandidateTile and SystemWallpaperTile. Mixed mode combines saved cover reads, AVFoundation posters and local WKWebView snapshots. The gallery host supplies the real wide grid tokens but is not the application's full navigation hierarchy.

Build (outside other UI measurement runs):

```sh
GALLERY_PROBE_OUT="$PWD/.notes/evidence/ui/2026-09-15-gallery-completion/candidate" bash tools/gallery-interaction-probe/build.sh
python3 tools/gallery-interaction-probe/run_matrix.py baseline --fixtures /private/tmp/lw-gallery-fixtures-v2 --tag=-v2
python3 tools/gallery-interaction-probe/run_matrix.py final --fixtures /private/tmp/lw-gallery-fixtures-v2 --tag=-v2
python3 tools/gallery-interaction-probe/summarize.py --v2
python3 tools/gallery-interaction-probe/resources.py
```

Requires `/private/tmp/lw-gallery-fixtures/inventory.json` (67 real Workshop titles/previews in the recorded experiment), a short H.264 `fixture.mp4`, local `fixture.html`, and `Covers/`. The initial exploratory corpus copied raw previews (including GIF) into the cover and system-poster paths. It is not the final performance basis. `fixtures.swift` converts those same real artwork sources to PNG covers and first-frame JPEG posters for the v2 matrix, matching the product formats. These remain controlled artwork fixtures, not captures of the user’s real desktop. Video and HTML are controlled fixtures reused under unique card IDs. Expanded counts test concurrency, not unique media throughput.

Boundaries are explicit in `Boundaries.swift`: no display apply, publication, user configuration or persistent trust changes. Only known local HTML fixture content is loaded. Its navigation stub permits navigation and its tracker-list stub is empty, so this harness does not verify HTML security policies; app tests cover those. Original cover/video/HTML load services are compiled, not mocked. Generated private card types change only declaration visibility. System candidate list/publish is excluded, while its real thumbnail method and view body are retained. Cache accounting omits the periodic logger.

The matrix has nine ordered phases: cold, scroll, filter, filtered-scroll, restore, leave/return, warm-scroll, selection, resize. Selection is meaningful only for candidate/system states; other modes keep the same state update as a control. Click-based rename/popover testing uses a separate input build, not the programmatic performance matrix.

`submissionMs` measures synchronous layout/display submission. `mainActorGapMs` includes the requested 16 ms sleep plus scheduling and preceding work; it is **not** frame duration, latency from physical input, or hitch duration. Three fresh processes per mode; in-process cache is cold at startup and warm on return, filesystem cache is uncontrolled. Inspect thermal fields and binary identity. This stress scroll jumps across 120 entries and is not a human-speed scroll benchmark.

Onscreen compositing requires ScreenCaptureKit or the app screenshot tool: `cacheDisplay` PNGs omit some layer-backed content and cannot establish image completeness. An input build (`GALLERY_EXTRA_FLAGS=-D\ GALLERY_INPUT_CHECKS`) posts native mouse-down/up events to its own window, checks filter/leave/return/rename/selection state, and opens real card popovers. The test coordinates were checked against ScreenCaptureKit captures. Earlier accessibility-action attempts were unsuccessful and retained as failed probe checks. This adds no product accessibility behavior. Physical-pointer hover remains separate from these posted click events.

Keep baseline, candidate and any refinement outputs separate. Capture exact compiler/source/binary provenance, failed/partial runs and unavailable instrumentation, and do not report an incomplete matrix or truncated trace as a clean comparison.

To verify a live probe window, compile `CaptureWindow.swift` separately with `xcrun swiftc` and pass an absolute PNG output path. Keep the input probe alive with `--input-hold 90`. A System card popover can remain within the composed window without increasing the normal window count; its input result therefore requires visual verification instead of treating that count as pass/fail.
