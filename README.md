# Kindling

A local macOS reader for a Kindle library you own. It reads the catalog,
annotations and reading state Kindle keeps on this Mac; exports a book as a
searchable PDF by capturing the reader; and sends the current page to an AI
provider you choose.

- SwiftUI, Swift 6, macOS 15 or later. The UI uses standard SwiftUI controls, so
  macOS 26+ gets Liquid Glass from the system and macOS 15 keeps the same
  structure without it.
- `KindleAX` from `../kindle-toolkit/packages/ax-driver`.
- No sandbox. Accessibility and Screen Recording are needed for the live page,
  capture and AI panel; the library and archive need neither.
- No telemetry. Only the current page leaves the Mac, on an explicit action.

## Build

```sh
swift build
swift test
./scripts/build-app.sh
open build/Kindling.app
```

The app bundle is `build/Kindling.app`; the command-line tool is
`.build/debug/kindling-cli`.

Use `./scripts/build-app.sh` for the app bundle, not a raw `swift build`. The
script records the real macOS SDK version in `LC_BUILD_VERSION` while keeping the
deployment target at macOS 15; without it, macOS runs the app in legacy
appearance (square window corners, no Liquid Glass).

The icon is rendered from `Resources/IconSources` by
`./scripts/build-icons.sh` into `Resources/AppIcon.icns` and
`Resources/Assets.car`. Those two artifacts are committed; an ordinary build
copies them and fails loudly if they are missing.

## Data caveat

Kindle's local stores keep a highlight's position and colour, not its words.
Notes do carry their text. Kindling reports position-only highlights as such
and never fabricates the missing text; the Annotations view leads with the rows
that have text.

## Command line

```sh
kindling-cli inspect              # import Kindle's stores into the archive
kindling-cli page                 # current live page: state and character count
kindling-cli ask --provider codex --action explain
kindling-cli capture --pages 5    # page images, text.jsonl, searchable PDF
kindling-cli export --format json
kindling-cli history
kindling-cli track --asin <ASIN> --seconds 6
```

## Layout

| Path | Purpose |
|---|---|
| `Sources/KindlingCore` | data, archive, live AX, AI providers, capture, PDF |
| `Sources/KindlingUI` | SwiftUI views, app model, AI panel |
| `Sources/KindlingApp` | `@main`, global hot key, app delegate |
| `Sources/KindlingCLI` | headless e2e and inspection |
| `Tests/KindlingTests` | identity, dates, archive and prompt tests |

## Evidence and e2e

All GUI and end-to-end runs happen on `the test Mac`, never on the development
Mac. See `the project documentation` and
`../dev-docs/measurements/2026-10-21-wi0/`.

## Release

```sh
# Local, ad-hoc, no notarization:
ALLOW_ADHOC_RELEASE=1 CODESIGN_IDENTITY=- ./scripts/release.sh

# Real release (a Developer ID and a notarytool Keychain profile):
CODESIGN_IDENTITY="Developer ID Application: …" \
NOTARY_PROFILE="…" ./scripts/release.sh
```

The cask template is `scripts/distribution/kindling.rb.in`; replace `<owner>`
with the GitHub account that hosts the release before publishing.
