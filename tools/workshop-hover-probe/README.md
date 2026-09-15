# Workshop hover isolation

Build each diagnostic variant into its own directory:

```sh
HOVER_PROBE_OUT="$PWD/.notes/evidence/ui/2026-09-15-hover-isolation/baseline" HOVER_VARIANT=baseline bash tools/workshop-hover-probe/build.sh
```

Also build `title-fixed` and `chrome-fixed`, then run `python3 tools/workshop-hover-probe/run.py`. The Core Release build is the same prerequisite as `tools/workshop-animation-probe`.

The probe hosts eight real BrowseCard or HistoryRow views with the same local GIF and long title. One card receives 18 controlled settled-hover transitions, separated by 20 samples. This replaces only the card's settled-hover callback with an environment-driven signal in generated copies. It does not simulate a physical pointer, debounce, or scrolling. The runner rejects missing state transitions, missing playing frames, and any frames in the poster-only control.

`baseline --playback false` holds the actual presentation gate closed to isolate visual effects from GIF playback. `title-fixed` retains a one-line title as a diagnostic control. `chrome-fixed` holds gallery scale/shadow hover state false while title and GIF still react. These controls remove visible behavior and are not product changes. The unmeasured layer-offset sketch is retained only in the evidence directory; no title redesign was adopted.

Each fresh process warms for two seconds and collects 360 layout/display/flush samples, sleeping 16 ms between samples. Measurements are explicit submission cost, process CPU, body/assignment counts, and main-actor gaps. They are not presented-frame time, actual hitches, or physical input latency. Compare three serial repeats with matching thermal state. Do not run builds, tests, or other probes during measurement. The standalone window ignores real pointer events and never applies wallpapers or changes app settings.
