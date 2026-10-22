import ApplicationServices
import Foundation

/// The live Kindle page, adapted to the companion's reader contract.
public struct KindleContext: ReaderContext {
    public let kind: ReaderKind = .kindle

    public init() {}

    public func page() throws -> ReaderPage {
        if Task.isCancelled { throw ReaderContextError.cancelled }
        guard AXIsProcessTrusted() else {
            throw ReaderContextError.notTrusted
        }
        guard KindleLive.isRunning() else {
            throw ReaderContextError.readerNotRunning(.kindle)
        }
        let live: LivePage
        do {
            live = try KindleLive.currentPage()
        } catch let error as KindleLiveError {
            switch error {
            case .notTrusted:
                throw ReaderContextError.notTrusted
            case .notRunning:
                throw ReaderContextError.readerNotRunning(.kindle)
            case .noWindow:
                throw ReaderContextError.noReaderWindow(.kindle)
            case .notReading(let state):
                throw ReaderContextError.unavailable(
                    .kindle,
                    reason:
                        "Kindle is showing \(state), not a live page. "
                        + "Open a book and hide the toolbar.")
            case .readFailed(let message):
                throw ReaderContextError.unavailable(
                    .kindle, reason: message)
            }
        } catch {
            throw ReaderContextError.unavailable(
                .kindle, reason: "\(error)")
        }

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
            pageCount: live.pageCount)
    }
}
