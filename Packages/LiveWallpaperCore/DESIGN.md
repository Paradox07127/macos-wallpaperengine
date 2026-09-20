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

## Edit Desk (`DesignTokens.EditDesk`)

Fixed-dark tokens for the Edit Desk rebuild (`.notes/design_handoff_loomscreen_redesign`). Values are literal design px/hex, not the adaptive scale above — the window forces dark and never runs Dynamic Type. Three color tokens carry an Increase Contrast branch (see GAP_ANALYSIS.md §6); everything else is a fixed value.

| Token | Value | Source |
| --- | --- | --- |
| `Colors.background` | `#121215` | README Tokens #1 |
| `Colors.panel` | `rgba(28,28,34,.95)` | README Tokens #1 |
| `Colors.console` | `rgba(18,18,22,.92)` | README Tokens #1 |
| `Colors.textPrimary` | `#e8e8ec` | README Tokens #2 |
| `Colors.textSecondary` | `#9a9aa3`; Increase Contrast → `#c8c8cf` | README Tokens #2; GAP_ANALYSIS §6 |
| `Colors.textTertiary` | `#8a8a93` | README Tokens #2 |
| `Colors.textCapsule` | `#c8c8cf` | SCREENS S1 (方案胶囊 / status text) |
| `Colors.success` | `#4ade80` | README Tokens #3 |
| `Colors.warning` | `#f5b544` | README Tokens #3 |
| `Colors.sceneGroupLayers/Effects/Colors` | `#60a5fa` / `#c084fc` / `#f5b544` | S6 scene sections; adaptive light `#2563eb` / `#9333ea` / `#b0760c` |
| `Colors.danger` | `#ff8080` | README Tokens #3 |
| `Colors.link` | `#9ab4ff` | README Tokens #3 |
| `Colors.strokeRegular` | white `.10`; Increase Contrast → `.35` | README Tokens #4; GAP_ANALYSIS §6 |
| `Colors.strokeShell` | white `.32`; Increase Contrast → `.65` | README Tokens #4; GAP_ANALYSIS §6 |
| `Colors.strokePanel` | white `.14` | README Tokens #4 |
| `Colors.strokeBadge` | white `.25` | SCREENS S1 (type badge border) |
| `Colors.strokeSelectedChip` | white `.40` | SCREENS S6 (selected console chip border) |
| `Colors.strokeHotShell` | white `.80` | SCREENS S2 / MOTION (hovered shelf card outline) |
| `Colors.strokeShelfCardRing` | white `.12` | SCREENS S2 (shelf card shadow ring) |
| `Colors.fillShell` | white `.02` | SCREENS S1 (display shell background) |
| `Colors.fillNavPill` | white `.06` | SCREENS S1 (nav pill / import capsule) |
| `Colors.fillSelectedChip` | white `.14` | SCREENS S6 (selected console chip fill) |
| `Colors.fillSelectedNavItem` | white `.16` | SCREENS S1 (selected nav item) |
| `Colors.dropHighlight` | `rgba(74,222,128,.22)` | SCREENS S1/S5 (drop target overlay) |
| `Colors.dropHighlightGlow` | `rgba(74,222,128,.45)` | SCREENS S5 (drop target glow) |
| `Colors.playbackControlFill` | `rgba(0,0,0,.55)` | SCREENS S1 (hover playback controls) |
| `Colors.gradientStageBottom` | black `.7` | SCREENS S1 (screen content bottom gradient) |
| `Colors.gradientCardBottom` | black `.5` | SCREENS S2 (shelf card bottom gradient) |
| `Colors.dotGrid` | `rgba(255,255,255,.06)` | README Tokens; SCREENS S1 (stage dot grid) |
| `Colors.modalScrim` | `rgba(8,8,10,.62)`; light `.32` black | SCREENS S4 (modal scrim) |
| `Colors.modalPanel` | `rgba(22,22,26,.98)` | SCREENS S4 (modal background) |
| `Colors.mediaChipFill` | black `.6` (fixed) | SCREENS S4/S5 (preview chips, ⌘n badges) |
| `Colors.tagChipFill` | `rgba(0,0,0,.55)` (fixed) | SCREENS S4 (tag chips) |
| `Colors.fillSecondaryButton` | white `.10` | SCREENS S4 (secondary apply button) |
| `Colors.fillTertiaryButton` | white `.06` | SCREENS S4 (＋ / … buttons) |
| `Colors.fillFloatButton` | white `.08` | SCREENS S5 (⧉ all displays) |
| `Colors.primaryButtonFill` / `primaryButtonText` | white / black (inverted in light) | SCREENS S4 (primary apply button) |
| `Corner.content` | 3 | README Tokens #5 |
| `Corner.badge` | 3 | SCREENS S1 (type badge) |
| `Corner.shelfCard` | 6 | README Tokens #5 |
| `Corner.playbackControl` | 6 | SCREENS S1 (playback buttons) |
| `Corner.gridCard` | 8 | README Tokens #5 |
| `Corner.shell` | 8 | README Tokens #5 |
| `Corner.shellBuiltinTop` | 9 | SCREENS S1 (MacBook shell top) |
| `Corner.shellBuiltinBottom` | 3 | SCREENS S1 (MacBook shell bottom) |
| `Corner.notch` | 5 | SCREENS S1 (MacBook notch bottom corners) |
| `Corner.panel` | 10 | README Tokens #5 |
| `Corner.panelLarge` | 12 | README Tokens #5 |
| `Corner.statusExpanded` | 14 | SCREENS S1 (status capsule, expanded) |
| `Corner.modal` | 18 | README Tokens #5 |
| `Corner.capsule` | 99 | README Tokens #5 |
| `Corner.floatPanel` | 16 | SCREENS S5 |
| `Corner.button` | 9 | SCREENS S4 (bottom-bar buttons) |
| `Corner.chip` | 5 | SCREENS S4/S5 (preview chips, float thumbnails) |
| `Shadow.shell` | `0 30px 80px rgba(0,0,0,.6)` | README Tokens #6 |
| `Shadow.modal` | `0 60px 140px rgba(0,0,0,.7)` | README Tokens #6 |
| `Shadow.hoverCard` | `0 30px 60px rgba(0,0,0,.7)` | README Tokens #6 |
| `Shadow.shelfCard` | `0 14px 30px rgba(0,0,0,.6)` (+ `strokeShelfCardRing`) | SCREENS S2 |
| `Shadow.floatPanel` | `0 20px 50px rgba(0,0,0,.5)` | SCREENS S5 |
| `Spacing.s8` | 8 | README Tokens #7 |
| `Spacing.s12` | 12 | README Tokens #7 |
| `Spacing.s14` | 14 | README Tokens #7 |
| `Spacing.gutter` | 24 | README Tokens #7 |
| `Spacing.topBar` | 56 | README Tokens #7 |
| `Spacing.gridGap` | 12 | SCREENS S3 (library grid gap) |
| `Spacing.workshopGridGap` | 14 | SCREENS S8 (Workshop grid gap) |
| `Typography.badgeMono` | 9pt monospaced | README Tokens #2/#8 |
| `Typography.metaMono` / `DesignTokens.Typography.microMono` | 10pt monospaced | README Tokens #2/#8 |
| `Typography.chip` | 11pt | README Tokens #8 |
| `Typography.body` | 12pt | README Tokens #8 |
| `Typography.cardTitle` | 11pt semibold | README Tokens #8 |
| `Typography.stageTitle` | 13pt semibold | README Tokens #8 |
| `Typography.modalTitle` | 22pt bold | README Tokens #8 |
| `Typography.navItem` | 12pt | SCREENS S1 (nav pill item) |
| `Typography.libraryModalTitle` | 20pt bold | SCREENS S4 (library modal title) |
| `Typography.button` | 13pt bold | SCREENS S4 (bottom-bar buttons) |
| `Typography.floatName` | 10pt semibold | SCREENS S5 (thumbnail name) |
| `Typography.dropLabel` | 11pt bold | SCREENS S5 (「松手替换」) |

Not tokenized: blur radii (6/30/70/80), glow radii, and one-off component geometry (capsule widths/heights, panel paddings) — these are single-use layout/effect parameters for views this work package does not implement, not reusable design-system steps.

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
12. **One component per role — with one named exemption.** `ShelfCard` (Edit Desk stage/shelf) is a deliberate second card implementation beside `GalleryTileChrome`: the shelf animates 14 tilted cards in a CALayer tree, where SwiftUI views can't hit the frame budget. It must build its colors from `DesignTokens.EditDesk` values converted to `CGColor`, never a fresh literal. No other CALayer card may be added without extending this exemption (GAP_ANALYSIS.md D7).
