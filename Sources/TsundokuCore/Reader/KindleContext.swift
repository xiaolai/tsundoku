import Foundation

/// The live Kindle page, adapted to the companion's reader contract.
public struct KindleContext: ReaderContext {
    public let kind: ReaderKind = .kindle

    public init() {}

    /// Kindle's selection is a popover with a Copy button, not
    /// `AXSelectedText`; pressing that button returns the exact words.
    public func selectedText() -> String? {
        selectionReading()?.text
    }

    public func selectionReading() -> KindleLive.SelectionCopy? {
        KindleLive.copySelection()
    }

    public func page() throws -> ReaderPage {
        if Task.isCancelled { throw ReaderContextError.cancelled }
        let live: LivePage
        do {
            // `currentPage()` performs the trust and running checks and
            // reports each through its own error case.
            live = try KindleLive.currentPage()
        } catch let error as KindleLiveError {
            switch error {
            case .notTrusted:
                throw ReaderContextError.notTrusted
            case .notRunning:
                throw ReaderContextError.readerNotRunning(.kindle)
            case .noWindow:
                throw ReaderContextError.noReaderWindow(.kindle)
            case .readFailed(let message):
                throw ReaderContextError.unavailable(
                    .kindle, reason: message)
            }
        } catch {
            throw ReaderContextError.unavailable(
                .kindle, reason: "\(error)")
        }

        // The AX read is synchronous; a cancel that arrived during it must
        // not turn into a successful page.
        if Task.isCancelled { throw ReaderContextError.cancelled }
        guard live.isReading else {
            throw ReaderContextError.unavailable(
                .kindle,
                reason:
                    "Kindle is showing \(live.state), not a live page.")
        }
        guard !live.text.isEmpty else {
            throw ReaderContextError.noPageText(.kindle)
        }
        return ReaderPage(
            text: live.text,
            title: live.title.isEmpty ? "Kindle" : live.title,
            kind: .kindle,
            source: .accessibility,
            pageNumber: live.pageNumber,
            pageCount: live.pageCount,
            identifier: live.bookID)
    }
}
