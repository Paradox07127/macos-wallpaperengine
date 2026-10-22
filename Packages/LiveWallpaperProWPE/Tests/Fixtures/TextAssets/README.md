# Test-only text inputs

These assets are never bundled into the app. `fonts/SOURCE.json` and
`fonts/Twemoji-SOURCE.json` and `fonts/RobotoMono-SOURCE.json` pin unmodified upstream font bytes and their licenses.
They retain the existing metrics, glyph IDs, fallback and color-font assertions
without requiring Wallpaper Engine or a developer's Steam library.

The material and shader probes in tests are hand-authored inputs. Original WPE
shader/Workshop/oracle parity remains under the separate `ExternalCorpus` source group.
