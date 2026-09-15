# Workshop workflow experiment

Optimized, independent macOS component harness. It does not change the shipping
grid, app preferences, bookmarks, wallpapers, or Steam files. It reads the local
Workshop corpus and writes only experiment outputs and its own byte caches.

## Candidates

- `lazy`: fixed geometry `LazyVGrid`, stable IDs, per-card observable state.
- `windowed`: flat eager SwiftUI `Layout`, fixed-square placement without child
  measurement, stable IDs across column changes, and explicit visible-range
  materialization with one extra row on either side. Range changes update only
  entering/leaving card IDs. The complete cheap grid geometry exists up front;
  expensive card subtrees do not.
- `collection`: `NSCollectionViewFlowLayout` + diffable source + `NSHostingView`.
  Selection updates the old/new card states without replacing hosting roots.
  Structure changes use differences with animation duration zero. Reuse removes
  the previous card subtree, cancelling its view-owned tasks.
- `eager`: flat eager layout without visibility windowing; retained as an
  optional control after its hundred-card smoke showed much larger memory use.

All candidates use the same real BrowseCard / HistoryRow, the same Core design
tokens, the same fixed tile-size algorithm, and the current product preview
decoders and playback gates. The shared optional lookahead prepares the next two
rows in existing bounded image caches. It does not decode whole GIFs. `--preheat
off` disables it for an ablation experiment. Local preheating exposes the exact
product decoder in the generated file; it does not alter production visibility.

The model holds immutable card inputs and an ID dictionary. It intentionally
does not run the full InstalledLibrary filtering, bookmark store, screen manager,
or download service. These are shared upstream concerns, not container-specific
work. Selection, filter structure changes, view lifecycle, and responsive sizing
are exercised. The inspector phase changes available width, not actual detail
content or a wallpaper session.

## Reproduce

```sh
UI_PROBE_OUT="$PWD/.notes/evidence/ui/NEW-RUN/probe" \
  bash tools/workshop-workflow-probe/build.sh
python3 tools/workshop-workflow-probe/run.py \
  --out "$PWD/.notes/evidence/ui/NEW-RUN"
python3 tools/workshop-workflow-probe/summarize.py \
  .notes/evidence/ui/NEW-RUN/matrix
```

The runner refuses existing results and concurrent probe / xcodebuild / xctrace
processes, including `profile_scenes.py` between recordings. Runs are serial, rotate candidate order, and reverse page order on
alternate repetitions. Every run starts in Nominal thermal state; a thermal
change aborts the batch and retains the affected raw output. Each process gets a
new online byte-cache directory. There is a five-second gap between processes.

The corpus has 67 real previews in the verified September 15 inventory. A
100-card run cycles those resources with distinct card IDs: it is not a sample
of 100 distinct GIFs. Online fetch is an actor reading those same local bytes,
not a live Steam network request. The process byte cache is cold; the operating
system filesystem cache is uncontrolled. Warm return reconstructs the window
in the same process without purging the shared image caches.

## Workflow and validation

1. Cold window creation and first 12 preview assignments (first viewport).
2. 96 fixed-distance scroll steps, down then back, capped at 1000 points.
3. Three real CGEvent hover and click sequences through the product handlers.
   Each click must select the expected ID. Hover retains the product debounce.
4. Filter to even IDs and restore; ensure all IDs survive.
5. Change width from 900 to 620 to 900; check the expected 4/2/4 columns.
6. Close/reopen with warm caches; require the first viewport's previews again.
7. Close, stop animations, purge caches; verify no further frame assignments.

The runner exercises only its own disposable window and restores pointer
position. Do not use the pointer during an automated run. Inspection runs and
Instruments runs are separate from the uninstrumented comparison. The optional
`--inspect-file PATH` pauses before close until that file exists; `--wait-file
PATH` pauses before opening the window so Instruments can attach first.

## Measurements and boundaries

- `viewportReadyMs`: window construction through successful preview assignments;
  it is not first physical presentation. Images are also visually inspected in
  the real composited window. NSView bitmap snapshots can omit CALayer images.
- `submissionMs`: synchronous scrolling + layout + display submission + flush;
  not presented-frame duration. Real hitches require the separate Instruments
  Animation Hitches recording.
- Hover latency ends at the actual settled-hover callback. Click latency starts
  at posting mouse-up and ends at the actual card action. Neither is a complete
  input-to-photon measurement. Filter timing includes its explicit settle wait.
- CPU is `getrusage` user+system core-seconds over the bounded workflow; it is
  separate from elapsed time and from a percentage of all machine cores.
- RSS is sampled process residency. Image-cache accounting tracks inserted
  estimated costs and evictions, with duplicate/unattributed warnings preserved.
  Sampled maxima are not guaranteed instantaneous peaks. Disk cache bytes are
  separately measured. Original installed preview files are input, not new cache.
- No wallpaperrenderer, actual download, network latency, trackpad momentum,
  persistent app state, or full inspector content is included. Do not present
  these component results as whole-app acceptance or as a production migration.

`prepare.py` asserts every source instrumentation anchor and records input
hashes. `build.sh` records an optimized binary hash and UUID. Retain those
manifests, logs, individual JSONs, and failed/thermal-invalid runs with reports.

## Separate display-timing drivers

`WORKFLOW_TIMER_DRIVER=1` builds a RunLoop-timer continuation variant. It was an
exploratory driver, not part of the 72-run component matrix.

`WORKFLOW_EVENTLOOP_DRIVER=1` builds `EventLoopDriver.swift`: each AppKit timer
callback performs a short operation. Online encoded bytes are primed before the
READY marker, and decoded caches are purged between cases. Each process runs
both pages and all three candidates; `--rotation 0|1|2` changes their order and
`--page online|installed` narrows it. These cache conditions differ from the
fresh-process matrix and must not be pooled with it.

`--real-wheel true` sends continuous pixel scroll events from a background
producer at 60 Hz, with the pointer over a card. The main thread cannot slow
the producer. It records actual clip positions and verifies travel/return.
Without it, the driver coalesces programmatic scroll positions on its main-thread
timer. Record these protocols separately. Start recording only after READY and
allow the recorder to start before creating the `--wait-file` marker. Verify
that every phase is present in the trace before interpreting the results.

`--scroll-only true` limits each case to cold open, wheel scroll and close. Use
three independent recordings with rotations 0, 1, 2. Each capture must contain
all 18 complete phase intervals. Wait for the requested recording duration to
elapse before calling `stop_recording`; stopping early truncates later cases.
The input journal records all 121 actual event-posting times; verify its span,
spacing, travel and return before comparing hitches. Synthetic continuous wheel
events exercise the real event path but do not reproduce trackpad momentum.

After native Instruments schema discovery and queries, preserve `start.json`,
`stop.json`, `queries.json` and `trace.json` (PID, discovered signpost position,
and completeness decision) in each trace's directory. `export_cached_trace.py`
reads raw nanosecond timestamps from the MCP's already-ingested SQLite cache
in read-only mode and cross-checks every row against the native query output.
`summarize_wheel.py` keeps incomplete captures out of the comparison and retains
potential-hang counts as a separate diagnostic. A UI hang label is not evidence
that the recorder itself failed, and sparse CPU samples do not disprove it.
