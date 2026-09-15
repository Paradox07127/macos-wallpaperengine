# Loomscreen UI architecture probe

Independent macOS executable and XCTest bundle. No Xcode project, dependency, entitlement or app setting changes. Build and run on the Mac with Xcode 27.0 and the local Workshop corpus. Output lives under `.notes/evidence/ui/2026-09-15-appkit-experiment/` in this worktree.

```sh
bash tools/ui-architecture-probe/build.sh
bash tools/ui-architecture-probe/test.sh
python3 tools/ui-architecture-probe/run_matrix.py --suite scene
python3 tools/ui-architecture-probe/run_matrix.py --suite grid
python3 tools/ui-architecture-probe/run_matrix.py --suite installed
python3 tools/ui-architecture-probe/run_matrix.py --suite interactions --steps 120
python3 tools/ui-architecture-probe/run_matrix.py --suite state-sequence --steps 100 --repeats 3
python3 tools/ui-architecture-probe/summarize_states.py
python3 tools/ui-architecture-probe/summarize.py
```

Run suites **serially**, with no other build/recording or UI performance task active. Stop only the probe you launched if an interruption requires it; do not stop other apps. A fresh `--cache` directory is a cold harness byte cache; macOS filesystem caching remains uncontrolled. Reuse the same directory for warm runs. The runner reverses case order on alternate repeats and records command, exit status and binary hash. It does not enforce system exclusivity or thermal equality; inspect the saved metadata.

Single run:

```sh
.notes/evidence/ui/2026-09-15-appkit-experiment/UIArchitectureProbe.app/Contents/MacOS/UIArchitectureProbe \
  --mode scene --scene 3351072238 --variant native --steps 300 \
  --output /private/tmp/native-scene.json --screenshot /private/tmp/native-scene.png
```

Modes: `scene`, `grid` (online BrowseCard component), `installed` (HistoryRow component). Scene variants: `current`, `100`, `200`, `500`, `1000`, `continuous`, `native`. Grid variants: `current`, `collection`. Operations: `scroll`, `select`, `filter`, `resize`, `edit`, `collapse`, `state-sequence`, `idle`; only use operations appropriate to the mode. `--count 0` is the full local inventory. Expanded counts cycle real records with unique identities but reuse preview URLs. No live network search/download/apply/delete runs in this harness.

`--language en|zh-Hans|zh-Hant|ja|es` selects project localization and an in-process volatile app-language preference; generated app resources come from the current xcstrings catalog. It does not persist the user's language. Accessibility Reduce Motion/Transparency are read from NSWorkspace; CLI labels do not override these system flags. Pointer events are ignored during programmatic measurements to avoid accidental hover differences. Full hover/keyboard/VoiceOver interaction is a separate UI session.

Measurements are synchronous layout/display submission, process CPU, sampled resident memory and process high-water RSS. They are not display-frame duration, first presented frame, actual hitch count or GPU time. Instrumented runs are separate from uninstrumented runs. A render session and configuration writes are deliberately outside this executable.

The generated files identify exact imported types and two offline boundaries: HTTP fetch reads local bytes; Screen is a name/id-only type because screen actions are not invoked. HistoryRow and ScenePreview bodies are source-identical (the unused ProWPE module import is removed and its actual path helpers are directly compiled). Cache accounting is always enabled without its periodic logger. See the evidence protocol and source manifests for fidelity and coverage limits.

All prototype code stays here. Returning to the app's existing UI requires no preference reset or rollback action. Do not merge a candidate until the report's integration gates pass.

## Production slider follow-up

The `quantized` scene variant hosts the actual Core `QuantizedSlider` used by the app. It retains the system control behavior; it has no custom key or accessibility actions. Use a separate output directory to retain the original experiment artifacts:

```sh
UI_PROBE_OUT="$PWD/.notes/evidence/ui/2026-09-15-settings-implementation/probe" \
UI_CORE_BUILD=/private/tmp/lw-ui-settings-core bash tools/ui-architecture-probe/build.sh
python3 tools/ui-architecture-probe/run_settings_implementation.py
python3 tools/ui-architecture-probe/summarize_settings_implementation.py
```

Run the matrix after builds/tests finish. The two scenes use the same state-sequence protocol as before; commits and render sessions remain excluded.
