# Mac App Store release

**English** · [简体中文](../zh-Hans/app-store.md)

The `LoomscreenAppStore` target is a separate Lite subset. Its identity is
`com.loomscreen.appstore`; do not reuse or rename the DMG identities. The shared
source and the three `Config/*.xcconfig` files define the editions. See the
[edition matrix](lite-vs-pro.md#mac-app-store-edition).

## Maintain the boundary

- App code uses `MAS_BUILD` for Store exclusions and `LITE_BUILD` for Pro exclusions.
  Swift package dependencies receive neither app flag; inject capabilities into shared code.
- The Store target links Core only and has its own Info.plist, entitlement file
  and InfoPlist catalog. Keep Sparkle, external helpers and the system wallpaper
  extension outside its target membership and dependency graph.
- Pro owns automatic extraction of the shared Localizable catalog. Preserve
  manual edition-only keys and all nine languages: de, en, es, fr, ja, ko, pt-BR, zh-Hans, zh-Hant.
  Review catalog changes after Xcode builds; generated symbols are disabled for MAS.
- Pro and Lite use `MARKETING_VERSION` for Sparkle's build version. MAS reads
  `CURRENT_PROJECT_VERSION`: increment it for every upload, including retries.
- Lite and MAS both produce `Loomscreen.app`. Use separate DerivedData/archive
  directories and verify the bundle identifier before testing or packaging.

## Local preflight

Run affected app tests and the shared integration gate after changes. The Store
artifact lane does not run the Pro shader pipeline:

```sh
make verify
DERIVED_DATA="$(mktemp -d -t LoomscreenMAS)" \
  bash scripts/release_candidate_check.sh --appstore
```

The archive is retained under that directory. `ARCHIVE_PATH` may name a fresh
absolute `.xcarchive` outside the checkout. Additional arguments after
`--appstore` are passed to `xcodebuild archive` for the signing machine.
The lane checks source entitlements and localization, archives universal Release,
and inspects the actual signed bundle with `scripts/check_appstore_bundle.py`.
It checks architecture, signature validity, entitlement baseline, known excluded
APIs/endpoints/components, nine compiled localizations and the privacy manifest.
This is a bounded local audit, not a complete private-API detector or Apple approval.

## Distribution and Apple validation

1. Create the macOS app record for `com.loomscreen.appstore` in App Store Connect.
   Configure the team's Mac App Store distribution signing and provisioning.
2. Export this archive using Xcode Organizer's App Store Connect distribution
   flow, or `xcodebuild -exportArchive` with `method=app-store-connect` and
   `destination=export`. Use the team's actual provisioning and certificates.
3. Inspect the exported app again with
   `python3 scripts/check_appstore_bundle.py /path/to/Loomscreen.app --require-distribution`.
   A development-signed or ad-hoc archive is local evidence only.
4. Run Organizer **Validate App** or authenticated `xcrun altool --validate-app`.
   Keep the validation receipt. Local builds cannot certify Apple's server checks.
5. Upload only after version/build, metadata, privacy answers and screenshots
   describe this Store edition. Test the processed build through TestFlight.

## Localized submission text

The versioned source for Store text is [release/app-store/metadata.json](../../release/app-store/metadata.json).
It holds nine locales. App bundles use `de` and `fr`; Connect uses `de-DE` and `fr-FR`.
Brazilian Portuguese is `pt-BR` in both. The shared App catalog and provider catalog
serve all editions; each target retains its own permission catalog and product name.
Permission prompts follow the app language selected by macOS; the in-app language
picker affects app content, not already displayed system prompts.

Run `python3 scripts/check_appstore_metadata.py` before copying the text into Connect.
It checks required locales, text fields, character limits and keyword UTF-8 byte limits.
[Review notes](../../release/app-store/review-notes.txt) remain a draft until device,
TestFlight and contact details are filled in. Screenshots, public URLs and account
fields require separate final submission checks. Nothing in this directory uploads automatically.

## Submission checklist

- Verify first launch, menu-bar reopen/quit, video and local/remote web import,
  apply/pause/clear, saved file grants after relaunch, configuration import/export,
  schedules/playlists, display reconnection, and weather with denied permission
  and a manual city. Check the minimum supported macOS and an Intel Mac separately.
- Use screenshots of the Store build and media you can distribute. Apple currently
  accepts Mac screenshots at 1280×800, 1440×900, 2560×1600 or 2880×1800, without
  transparency. Do not advertise features removed from this edition.
- Publish a working privacy-policy URL in the app and Connect. Cover optional
  weather requests, external web pages and user-submitted support reports.
  Open-Meteo's policy allows request logs containing coordinates for up to 90 days;
  do not claim weather coordinates never leave the device or are never retained.
- Review the actual data flow when answering App Privacy. The manifest's location
  declarations do not automatically fill Connect's answers; no tracking/account
  identifiers are used. Check the weather service licence if monetization changes.
- Answer the age-rating questionnaire for the actual URL-entry capability. User-chosen web wallpapers can load arbitrary sites; assess Unrestricted Web Access rather than assuming a 4+ rating. Apple calculates the rating from the answers.
- Review notes should explain the menu-bar app, public desktop-level windows,
  user-supplied files/URLs, WebKit, optional weather and GitHub support. No login
  is required. Explain that the support repository name is historical; it does
  not enable scene rendering or downloads in this build.

Current Apple references: [Review Guidelines](https://developer.apple.com/app-store/review/guidelines/),
[App Privacy](https://developer.apple.com/app-store/app-privacy-details/),
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).
Weather terms: [Open-Meteo](https://open-meteo.com/en/terms).
