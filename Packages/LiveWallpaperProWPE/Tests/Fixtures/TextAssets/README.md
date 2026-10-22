# Test-only text inputs

These assets are never bundled into the app. `fonts/SOURCE.json` and
`fonts/Twemoji-SOURCE.json` and `fonts/RobotoMono-SOURCE.json` pin unmodified upstream font bytes and their licenses.
They retain the existing metrics, glyph IDs, fallback and color-font assertions
without requiring Wallpaper Engine or a developer's Steam library.

The material and shader probes in tests are hand-authored inputs. Original WPE
shader/Workshop/oracle parity remains under the separate `ExternalCorpus` source group.

`fonts/TestCJK-SOURCE.json` pins two small OFL subsets of Noto Sans CJK: one
contains Chinese and full-width glyphs, and an earlier Symbols fallback contains
those same full-width glyphs. Their actual outlines exercise the unchanged
fallback order and exclusion rule without optional macOS language fonts.

`fonts/TestFontCollection-SOURCE.json` pins a two-face collection made from the
existing Noto Sans and Roboto Mono inputs. It exercises CoreText file descriptors
and FreeType selection of the second PostScript face without copying Apple fonts
or registering substitute system-family names. Test fallback bindings supply
these explicit descriptors; they never supply glyph IDs, layouts or mesh output.
