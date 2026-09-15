# Workshop browse-page fixtures

## Identities are synthetic

Every third-party Steam identity in these files was replaced after capture, so
no URL, id or name here resolves to a real account:

- **SteamID64** — 26 of them, swapped for same-length `7656119000000000N`. The
  length is what matters: the SSR payload is a triple-escaped JS string literal,
  and a same-length swap leaves its byte shape untouched.
- **`persona_name`** (and the matching `>By …</a>` in the grid) — 27 of them,
  replaced keeping the ASCII / non-ASCII split, so the parser still sees both.
- **`avatar`** byte arrays and the creator page's avatar hash.
- **`short_description`** — only the 7 that carried someone's handle (bilibili,
  抖音, artist credits). Remapped character by character within the same
  character class, so length, escaping and the CJK/ASCII/emoji mix all survive;
  the text is deliberately meaningless. The other 23 are untouched.

Assertions in `WorkshopPublicSearchSSRTests.swift` were moved to the synthetic
values in the same pass. The capture URLs quoted below are the scrubbed form —
they are provenance, not something to re-fetch.

Source: one live GET of
`https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&days=7&p=1&excludedtags[]=Application&excludedtags[]=Asset&excludedtags[]=Preset`
captured 2026-09-07T03 (746 KB, 30 results, `total_count` 2747905). The
capture itself lives outside the repository; these files are derived from it.

## Trimming rules (`browse_trend7_p1.html`, 320 KB)

- The result grid container (`<div class="JnRpQcV2qgY- Panel">`, the element
  right after "Show incompatible items") is kept up to the "Per page" control,
  so all 60 `filedetails/?id=` anchors (2 per result) survive in page order.
  The fragment is cut, not balanced markup.
- The `<script nonce=…>` that carries `window.SSR` is reduced to
  `window.SSR={};` followed by the `window.SSR.renderContext=JSON.parse("…");`
  statement **verbatim** (same bytes as served, including the JS-string
  escaping of the double-encoded `queryData`). `window.SSR.loaderData` and
  `window.SSR.renderConfig` (306 KB of site navigation and tag definitions)
  are dropped.
- Everything else (head, header, footer, module script tags) is dropped.

## Derived pages

Built at test run time from `browse_trend7_p1.html` by
`LiveWallpaperTests/Support/WorkshopBrowseFixture.swift` (string replacement
on the escaped SSR literal; each replacement must hit exactly once):

- `withoutSSRScript()` — same grid, no `window.SSR` script at all.
- `keyPage2()` — SSR `queryKey[1].page` changed 1 → 2.
- `pages3()` — SSR `total_pages` changed 1000 → 3.
- `tainted()` — result 1 `preview_url` moved to `https://evil.example/…`,
  result 2 gains `"banned": true`, result 3 gains `"visibility": 2`. The live
  payload carries neither `banned` nor `visibility` on any result; the fields
  are added here to pin the drop rules.

## Creator page (`creator_empty_page.html`, 44 KB)

Source: one live GET of
`https://steamcommunity.com/profiles/76561190000000024/myworkshopfiles/?appid=431960&numperpage=30&p=999`
captured 2026-09-07 (73 KB, HTTP 200, 0 `filedetails/?id=` anchors — the
creator's items fit on page 1, so p=999 is past the end). The profile workshop
page is the legacy server-rendered template, not the React browse page: it has
no `window.SSR` and reports an empty page through the
`<div class="view_inventory_page inventory_msg_ctn" id="no_items">` container
("No matching files were found for …").

Trimming: every `<script>`, `<style>` and `<link>` is dropped, as are the site
header and menus above `#responsive_page_template_content`; the content block
is kept verbatim from there up to the `#workshop_item_hover` template, wrapped
in a minimal head/body.

## Hand-written

- `challenge_page.html` — a same-host 200 with neither the SSR script nor any
  `filedetails/?id=` anchor (login/challenge shape).

Expected values in the tests (id order, `total_count`, `total_pages`, the first
three titles / persona names / preview URLs / tags) were computed from the
trimmed file with Python, not typed by hand.
