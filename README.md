# Tsundoku

A local macOS reader for the Kindle and Apple Books libraries you own. It reads
the catalog, annotations and reading state both apps keep on this Mac, exports
the combined archive, captures a Kindle book as a searchable PDF, and sends the
page, chapter, or book text you choose to an AI provider.

- Swift 6, SwiftUI, macOS 15 or later.
- No sandbox. Accessibility and Screen Recording are needed for the live page,
  capture and AI panel; the library and archive need neither.
- No telemetry. Only the passage you choose leaves the Mac — the page, a
  captured chapter or book excerpt, or a selection with its surrounding page
  context — and only on an explicit action. The update checker asks GitHub for
  the latest release at most once a day unless disabled; that request carries
  no library or reading data.

## Install

Requires an Apple silicon Mac on macOS 15 (Sequoia) or later.

```sh
brew install --cask xiaolai/tap/tsundoku
```

The app is signed with a Developer ID and notarized, so it opens without a
Gatekeeper prompt. To upgrade:

```sh
brew upgrade --cask tsundoku
```

To uninstall:

```sh
brew uninstall --cask tsundoku
```

Uninstalling keeps your data. The archive, caches and AI history stay in
`~/Library/Application Support/Tsundoku`, and exports and captures stay in
`~/Documents/Tsundoku` unless you chose another export folder in Settings.

Each release, with its notes, is at
[github.com/xiaolai/tsundoku/releases](https://github.com/xiaolai/tsundoku/releases).

