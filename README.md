# Tsundoku

A local macOS reader for Kindle and Apple Books libraries you own. It reads the
catalog, annotations and reading state both apps keep on this Mac, and exports
the combined archive. The Kindle lane can also capture a book as a searchable
PDF by capturing the reader and send the current page to an AI provider you
choose. Apple Books highlights, bookmarks and reading progress are also imported, and
both reader apps have page-capture adapters.

- SwiftUI, Swift 6.3 or later, macOS 15 or later. The UI uses standard SwiftUI controls, so
  macOS 26+ gets Liquid Glass from the system and macOS 15 keeps the same
  structure without it.
- `KindleAX` is pinned under `vendor/kindle-toolkit/packages/ax-driver`.
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
- The library, annotations, history and exports share one Library window.
  Settings is one separate native window; Access contains setup and recovery.
  Open them from the menu bar or reopen the app to browse the Library.
  Login does not import the library or poll Kindle.

The panel reads the current Kindle page through `KindleLive` and the Apple Books
page through its `AXStaticText` nodes, with a Vision OCR fallback that is
labelled in the panel. Apple Books selection is not supported. Only the current
page is sent, and only when an action is chosen; no whole book is uploaded.

## Build

The driver is a private submodule. Source builds require authorized access to
`xiaolai/kindle-toolkit`; public binary installations do not. No private driver
source or development documentation is copied into this repository.

```sh
git submodule update --init --recursive
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
| `Sources/TsundokuUI/Companion` | trigger, panel, companion settings |
| `Sources/TsundokuApp` | `@main`, menu-bar shell, tracker, hot key, login item |
| `Sources/TsundokuCLI` | headless e2e and inspection |
| `Tests/TsundokuTests` | identity, dates, archive, Books reader, geometry, state, cancellation |

## Evidence and e2e

All GUI and end-to-end runs happen on a separate test Mac, never on the
development Mac. The test-host runbook and the recorded measurements live in
the project's documentation repository.

## Release

The pipeline uses an existing `notarytool` Keychain profile. It never loads an
environment file or provisions credentials as part of a release. Set up a
profile interactively with Apple's `xcrun notarytool store-credentials` once.

```sh
# Show the phases and exact public asset names without changing anything.
./scripts/release.sh plan

# Scan all local refs, Git messages/tags, current source and private filenames.
python3 scripts/privacy_audit.py --report build/privacy-report.json

# Build from a clean committed tree, run tests, sign, notarize and staple.
./scripts/release.sh build --profile "$NOTARY_PROFILE"

# Verify the exact DMG and its mounted app on the dedicated test Mac.
# The alias is private local configuration. This command does not launch an app.
./scripts/release.sh verify --host "$TSUNDOKU_TEST_HOST"

# Publish audited source separately, with the intended branch named explicitly.
git push origin HEAD:refs/heads/main

# Upload only the DMG, public provenance and checksums into a private draft.
./scripts/release.sh draft --notes /path/to/reviewed-release-notes.md

# Re-download and verify every asset, recheck source/privacy, then publish.
./scripts/release.sh publish

# Independently verify the public assets before updating the tap.
./scripts/release.sh cask --tap "$TSUNDOKU_TAP_DIR"
```

All phases use `--build 1` by default; use the same explicit build number across
phases if it differs. Build output is isolated by version, build and source
commit under `build/release`. Internal reports, notarization IDs and verification
receipts remain there and are never uploaded. The public manifest identifies
the source commit/tree, pinned driver commit, version/build and DMG checksum.
No glob selects release assets.

Each app is stapled before the DMG is assembled. The DMG is then signed,
notarized, stapled and checked independently. Remote verification checks the
mounted app's signature, ticket, version and embedded source provenance. A
known notarization ID resumes waiting; an upload with an unknown outcome stops
for reconciliation instead of submitting again. Published releases and their
assets are never overwritten.

A draft requires the exact audited source commit on `origin/main`. Existing
historical privacy findings block the build and publication stages until they
are removed. Jev reviews public inputs before upload/publication. Public CI
runs the repository audit without checking out the private driver, writing
credentials or uploading private reports. Functional GUI/E2E checks remain
on demand on the dedicated test Mac.

The privacy policy stores hashes of reviewed, intentionally public contributor
contact addresses. New unreviewed addresses are flagged without printing them;
GitHub noreply identities and synthetic example contacts are recognized. These
checks complement the credential scanner; neither a clean report nor a history
rewrite can remove copies that other people already downloaded.
