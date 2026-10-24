# Tsundoku

A local macOS reader for the Kindle and Apple Books libraries you own. It reads
the catalog, annotations and reading state both apps keep on this Mac, exports
the combined archive, captures a Kindle book as a searchable PDF, and sends the
current page to an AI provider you choose.

- Swift 6, SwiftUI, macOS 15 or later.
- No sandbox. Accessibility and Screen Recording are needed for the live page,
  capture and AI panel; the library and archive need neither.
- No telemetry. Only the current page leaves the Mac, and only on an explicit
  action.

## Reading companion

Tsundoku is a menu-bar agent (`LSUIElement`): no Dock icon, no window at login.
Open a book in Kindle or Apple Books and a glasses button appears at the reader
edge; click it or press ⌥⌘K to open a panel beside the reader. The panel follows
the reader's move and resize, hides when the reader is minimized or another app
is frontmost, and never takes focus from the reader. The library, annotations,
history and exports share one window; Settings is a separate window.

Kindle's local stores keep a highlight's position and colour, not its words.
Tsundoku reports those rows as position-only rather than inventing text; Apple
Books keeps the selected text for every highlight.

## Build

The AX driver is a private submodule. Source builds need access to
`xiaolai/kindle-toolkit`; binary installations do not.

```sh
git submodule update --init --recursive
./scripts/build-app.sh      # not a raw swift build: it records the real SDK
open build/Tsundoku.app
swift test
```

The app starts hidden; use the menu-bar menu. The command-line tool is
`.build/debug/tsundoku-cli` (`inspect`, `applebooks`, `page`, `ask`, `capture`,
`export`, `history`, `track`; `--help` lists them).

## Release and evidence

`./scripts/release.sh plan` shows the phases; the pipeline uses an existing
`notarytool` Keychain profile and never loads credentials from files. GUI and
end-to-end runs happen on a separate test Mac; the runbook and measurements
live in the project's documentation repository.
