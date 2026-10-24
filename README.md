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
