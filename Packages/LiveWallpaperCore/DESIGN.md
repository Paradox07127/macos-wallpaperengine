# LiveWallpaper — Design System Contract

The visual contract for every SwiftUI view in the app (Pro + Lite SKUs). All
tokens live in `DesignTokens` (`LiveWallpaperCore/UI/Tokens`). New views
**must** use tokens — no inline magic numbers, fonts, or colors.

## Visual language (locked 2026-06-05; content-card rule revised 2026-08-22)

- **Content cards** (wallpaper / library tiles) → `GalleryTileChrome`, which backs the whole card — thumbnail *and* footer — with an **opaque** raised surface (`Colors.surfaceRaised`). A card without a surface has a transparent footer, and `shadow` then traces only the opaque thumbnail, so the card reads as an image with loose text under it. Not glass: a card-sized `glassEffect` resamples the scrolling grid behind every tile each frame, and the thumbnail hides it anyway — the badges floating over the artwork are where glass earns its cost.
- **Floating chrome** (toolbars, filter ribbon, inspector, sheets, toasts, menu-bar dropdown) → glass (`AdaptiveGlass`).
- **Small accents** (type pills, badges, selection, segmented controls) → liquid-glass (`TypeBadge`, `thumbnailBadgeGlass`).
- Apple-HIG aligned, modern, restrained. Default SF font design (no `.rounded`) to sit cleanly next to native chrome.

## Typography — `DesignTokens.Typography`

24 ad-hoc sizes collapse into 7 roles (+3 emphasized variants). Dynamic-Type
styles auto-scale with accessibility; `badge` is the only fixed size.

| Token | Font | ≈pt | Use | Absorbs |
| --- | --- | --- | --- | --- |
| `badge` | `.caption2.semibold` | 10 | type pills, corner/thumbnail badges, status chips | 6, 8, 9, 10 |
| `caption` | `.caption` | 10 | metadata, helper text | 11 |
| `captionEmphasized` | `.caption.semibold` | 10 | emphasized metadata | — |
| `body` | `.body` | 13 | body copy, form labels | 12, 13 |
| `bodyEmphasized` | `.body.semibold` | 13 | card / list-row titles | 13 (semibold) |
| `sectionTitle` | `.title3.semibold` | 15 | group & inspector headers | 14, 15, 16 |
| `pageTitle` | `.title2` | 17 | page / nav / sheet titles | 17, 18, 20, 22 |
| `hero` | `.largeTitle` | 26 | empty-state / onboarding | 24–56 |
| `metric` | `.caption.monospacedDigit()` | 10 | inline numeric readouts: slider %, fps, gauges | numeric readouts |
| `metricEmphasized` | `.callout.monospaced.semibold.monospacedDigit()` | 12 | compact headline metrics in menu/status chrome | 12 (semibold monospaced) |
| `code` | `.body.monospaced` | 13 | paths, commands, IDs, technical text | monospaced text |
| `codeCaption` | `.caption.monospaced` | 10 | dense technical text: log lines, paths, IDs | caption-sized monospaced |

> ≈pt = measured macOS text-style metrics at default size (caption1/caption2 = 10, subheadline = 11, callout = 12, body = 13). Lint tooling and exact-equivalence judgments must use these measured values.

## Color — `DesignTokens.Colors`

System `NSColor`-backed → automatic light/dark + Increase Contrast.

| Token | Source | Use |
| --- | --- | --- |
| `pageBackground` | `.windowBackgroundColor` | window canvas |
| `surfaceRaised` | page base blended 4–6% toward contrast (was `.controlBackgroundColor`, which resolves identical to the page) | cards, fields, raised controls |
| `surfaceSunken` | `.underPageBackgroundColor` | sidebars, wells |
| `textPrimary` | `.labelColor` | titles, primary content |
| `textSecondary` | `.secondaryLabelColor` | captions, metadata |
| `textTertiary` | `.tertiaryLabelColor` | placeholders, disabled — never body copy (low contrast) |
| `separator` | `.separatorColor` | dividers, hairlines |
| `accent` | `.controlAccentColor` | selection, highlights |
| `Status.active` | `.systemGreen` | "in use" / running |
| `Status.warning` | `.systemOrange` | "won't run" blockers |
| `Status.caution` | `.systemYellow` | "needs deps" / pending |
| `Status.danger` | `.systemRed` | errors, destructive |
| `Gauge.low/medium/high` | muted green/amber/red | ring-gauge dashboards (calmer than Status) |

## Spacing & corners (existing)

`Spacing` xxs 2 · xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32
`Corner` sm 6 · md 10 · lg 14 (content cards) · xl 18 (floating chrome)

## State opacity — `DesignTokens.Opacity`

Semantic tiers for state-dependent transparency (W2-B5, 2026-08-31). Fills:
`hoverFill` .05 · `dragFill` .08 · `activeFill` .10 · `selectedFill` .12.
Strokes: `quietStroke` .28 · `strongStroke` .55 · `alertStroke` .75 ·
`emphasisStroke` .85. Content: `dimmedContent` .45 · `disabledContent` .55 ·
`dimmedIcon` .70. New state-dependent opacities use these — never a fresh
literal. Decorative one-off opacities (shadows, gradient stops, scrims) stay
literal by design; see the W2-B5 ledger for the adjudication.

## Hard rules

1. **No inline fonts** for text. Never `.font(.system(size:))` / `.font(.custom())` on `Text`/`Label` — use `DesignTokens.Typography`. (SF Symbol glyph sizing is exempt: a standalone `Image(systemName:)` may use `.font(.system(size:))` for precise sizing, or adopt a Typography token when it sits inline with text so the two scale together.)
2. **No literal colors** for semantic elements. No `.orange` / `.yellow` / `.white` / `Color(red:…)` — use `DesignTokens.Colors`. This still applies to foreground colors layered over user media (video/thumbnail/scene previews) that must contrast the content rather than the theme — use `overlayForeground` / `onAccentFill`, not a raw literal.
3. **Tabular digits** for live-updating numbers — use `Typography.metric` (or `.monospacedDigit()`) so columns don't jitter.
4. **Adaptive surfaces.** Use `AdaptiveGlass` / `GalleryTileChrome`, never hardcoded `.ultraThinMaterial`; it honors Reduce Transparency.
5. **Align to the grid.** Paddings/offsets come from `Spacing.*`, radii from `Corner.*` — no stray numbers.
6. **No color-only status.** A `Status.*` color must always be paired with text or a distinct glyph — never carry meaning by hue alone (WCAG 1.4.1).
7. **Glass contrast.** Don't put light text directly on a raw high-luminance `Status.*` fill; let `thumbnailBadgeGlass` / `AdaptiveGlass` manage the tint so text stays ≥4.5:1.
8. **Button styles follow the decision tree** (`.notes/plan/w1-contracts.md` §1). Short form: custom hit areas (cards/rows/segments) → `.plain` with a visible press state and ≥28x28pt hit region; icon-only actions → `.borderless`, never bare `.plain`; view primary action → `.borderedProminent` (max 1–2 per view, never destructive); secondary → `.bordered` (+ `role: .destructive` for danger); external links → `.link` (never destructive); hero CTAs → `CapsuleButtonStyle`. Row-repeated actions never take prominent.
9. **Expensive sliders coalesce.** A `Slider` whose binding persists config, rebuilds filters/overlays, or touches a render session must be `CoalescedSlider` (or an explicit release-only commit). `step:` detents stay under 1000 (`PropertyValueLogic`). Wide ranges pair the slider with an editable value field.
10. **Pages use a skeleton template** (contracts §3.1): settings form → `Form` + `.settingsFormChrome()`; library/detail column → `DetailPageScaffold`; sheets → shared header + `SheetFooterBar` (hero-type sheets → `HeroScaffold`); popovers → `.settingsPopoverChrome`; empty states → `IllustratedEmptyState`. New pages that fit none: ask before inventing a skeleton.
11. **Glass placement is version-tiered by position** (contracts §4): chrome/badges/toasts go through `AdaptiveGlass`; Form content areas and inspectors never take glass (HIG: no Liquid Glass in the content layer); the appex (deploys at 26.0) writes the 26+ path unconditionally. Enforced by `glass_outside_wrapper` / `material_outside_wrapper` / `appex_tautological_availability` lint rules.
