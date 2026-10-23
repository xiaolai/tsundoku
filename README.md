# Tsundoku

A local macOS reader for Kindle and Apple Books libraries you own. It reads the
catalog, annotations and reading state both apps keep on this Mac, and exports
the combined archive. The Kindle lane can also capture a book as a searchable
PDF by capturing the reader and send the current page to an AI provider you
choose. Apple Books is a data lane today: its highlights, bookmarks and reading
progress are imported; live page capture is not implemented.

- SwiftUI, Swift 6, macOS 15 or later. The UI uses standard SwiftUI controls, so
  macOS 26+ gets Liquid Glass from the system and macOS 15 keeps the same
  structure without it.
- `KindleAX` from `../kindle-toolkit/packages/ax-driver`.
- No sandbox. Accessibility and Screen Recording are needed for the live page,
  capture and AI panel; the library and archive need neither.
- No telemetry. Only the current page leaves the Mac, on an explicit action.

## Reading companion

Tsundoku runs as a menu-bar agent: `LSUIElement`, activation policy
`.accessory`, no Dock icon and no window at login. Open a book in Kindle or
Apple Books and a glasses button appears at the reader edge.

- Click the button, or press the configurable shortcut (⌥⌘K by default), to
  open the panel. Opening it does not take focus from the reader.
- The panel follows the reader's move and resize. A side drawer matches the
  reader's height, a bottom drawer its width, and a reader with no room outside
  gets an overlay inside its edge.
- It hides when the reader is minimized or loses its window focus, and when
  another app is frontmost. Restoring a minimized reader restores the panel.
- Clicking the ask field activates Tsundoku, because the spike measured Apple
  Books taking the first keystroke from a nonactivating panel. Quick actions do
  not activate the app.
- Escape, the inside close control, or a click outside closes the panel. Closing
  cancels in-flight AI work and writes nothing.
- The library, annotations, history, exports and settings stay in one window.
  Open it from the menu bar (`Library…`, `Settings…`) or by reopening the app.
  It is created on demand; login does not import the library or poll Kindle.

The panel reads the current Kindle page through `KindleLive` and the Apple Books
page through its `AXStaticText` nodes, with a Vision OCR fallback that is
labelled in the panel. Apple Books selection is not supported. Only the current
page is sent, and only when an action is chosen; no whole book is uploaded.

## Build

```sh
swift build
swift test
./scripts/build-app.sh
open build/Tsundoku.app
```

The app starts hidden; use its menu-bar glasses menu to open the library or the
companion. The app bundle is `build/Tsundoku.app`; the command-line tool is
`.build/debug/tsundoku-cli`.

Use `./scripts/build-app.sh` for the app bundle, not a raw `swift build`. The
script records the real macOS SDK version in `LC_BUILD_VERSION` while keeping the
deployment target at macOS 15; without it, macOS runs the app in legacy
appearance (square window corners, no Liquid Glass).

Ordinary builds use the sole available Developer ID Application signing identity.
Set `CODESIGN_IDENTITY` explicitly if more than one is available, or use
`CODESIGN_IDENTITY=-` for an isolated ad-hoc test build. Without a Developer ID
identity, the script warns and falls back to ad-hoc signing. macOS permission
grants apply to a signing identity: a differently signed rebuild can show
“Needed” even while the earlier copy remains enabled in System Settings.
Re-check reports access for the running copy; quit and reopen after granting access.

The icon is rendered from `Resources/IconSources` by
`./scripts/build-icons.sh` into `Resources/AppIcon.icns` and
`Resources/Assets.car`. Those two artifacts are committed; an ordinary build
copies them and fails loudly if they are missing.

## Data caveat

Kindle's local stores keep a highlight's position and colour, not its words.
Notes do carry their text. Tsundoku reports position-only highlights as such
and never fabricates the missing text; the Annotations view leads with the rows
that have text.

Apple Books is different: `AEAnnotation` stores the selected text for every
highlight, so those rows are readable without OCR. Apple Books bookmarks have a
location but no words. Both sources go into one archive, and every book and
annotation records which app it came from; the Library and Annotations views
can filter by source and exports carry a `book_source` field.

## Command line

```sh
tsundoku-cli inspect              # import Kindle's stores into the archive
tsundoku-cli applebooks           # import Apple Books' library and annotations
tsundoku-cli page                 # current live page: state and character count
tsundoku-cli ask --provider codex --action explain
tsundoku-cli capture --pages 5    # page images, text.jsonl, searchable PDF
tsundoku-cli export --format json # add --source kindle|applebooks
tsundoku-cli history
tsundoku-cli track --asin <ASIN> --seconds 6
```

`applebooks --read-only` reports what the local stores contain without writing
the archive. `--container <path>` points at a copied Books container instead of
the standard one.

## Layout

| Path | Purpose |
|---|---|
| `Sources/TsundokuCore` | data, archive, live AX, AI providers, capture, PDF |
| `Sources/TsundokuCore/Companion` | settings, geometry, state machine, diagnostics |
| `Sources/TsundokuCore/Reader` | Kindle and Apple Books page contexts, OCR fallback |
| `Sources/TsundokuUI` | SwiftUI views, app model, AI panel |
| `Sources/TsundokuUI/Companion` | trigger, glass panel, onboarding, settings |
| `Sources/TsundokuApp` | `@main`, menu-bar shell, tracker, hot key, login item |
| `Sources/TsundokuCLI` | headless e2e and inspection |
| `Tests/TsundokuTests` | identity, dates, archive, Books reader, geometry, state, cancellation |

## Evidence and e2e

All GUI and end-to-end runs happen on a separate test Mac, never on the
development Mac. The test-host runbook and the recorded measurements live in
the project's documentation repository.

## Release

```sh
# Real release: read the notary credentials from the workspace .env, store the
# keychain profile, then build, notarize, staple and verify.
./scripts/release.sh

# Check the credentials and the profile only; nothing is built:
./scripts/release.sh --profile-only

# Local ad-hoc DMG, no notarization:
./scripts/release.sh --adhoc
```

`scripts/release.sh` reads `APPLE_ID`, `APP_SPECIFIC_PASSWORD` (or
`APPLE_PASSWORD`) and `TEAM_ID` from the workspace `.env`, prints names and
never values, and stores the profile as `tsundoku-notary` unless `--profile`
names another. The owner is `REPO_OWNER`/`GITHUB_OWNER` from `.env`, else
`xiaolai`. `scripts/release-build.sh` is the raw pipeline behind it and writes
`build/release/tsundoku.rb` from `scripts/distribution/tsundoku.rb.in`.

A release is three steps:

1. `./scripts/release.sh` — build, sign, notarize, staple, write the cask.
2. `gh release create v$(cat VERSION) build/release/Tsundoku-$(cat VERSION).dmg`
   with a title and notes.
3. `./scripts/publish-cask.sh` — verify the asset URL and sha256, then commit
   and push `Casks/tsundoku.rb` to `xiaolai/homebrew-tap`; install with
   `brew install --cask xiaolai/tap/tsundoku`.

The pipeline publishes nothing itself: the disk image path and its sha256 are
printed.
