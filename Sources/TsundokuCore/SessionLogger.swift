import Foundation

/// Records the pages the reader actually sees.
///
/// It polls only while Kindle is frontmost enough for a live page and only
/// when the reader has chosen a book to track. The text is written to the
/// local archive; it never leaves the Mac through this path.
public final class SessionLogger: @unchecked Sendable {
    private let archive: Archive
    private let queue = DispatchQueue(label: "app.tsundoku.sessions")
    private var timer: DispatchSourceTimer?
    private var asin: String?
    private var lastText: String?
    private var running = false

    public init(archive: Archive) {
        self.archive = archive
    }

    public func setBook(_ asin: String?) {
        queue.async {
            self.asin = asin
            self.lastText = nil
        }
    }

    public func start() {
        queue.async { [weak self] in
            self?.installTimer()
        }
    }

    /// Runs on `queue`. The handler captures weakly so the logger does not
    /// keep itself alive through the timer it owns.
    private func installTimer() {
        guard !running else { return }
        running = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        queue.async {
            self.running = false
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// Stop and wait for the logger's queue to drain, including a tick that
    /// is already reading a page. For callers that query the archive right
    /// after stopping, where `stop()`'s fire-and-forget shutdown would race
    /// the write it is waiting for.
    public func stopAndDrain() {
        queue.sync {
            self.running = false
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func tick() {
        guard running, let asin, KindleLive.isRunning(),
            KindleLive.isTrusted()
        else { return }
        do {
            let page = try KindleLive.currentPage()
            guard page.state == "readingChromeHidden", !page.text.isEmpty
            else { return }
            // File only a page whose reader identity is known and matches the
            // tracked book. An unknown identity (Kindle's last-opened marker
            // unreadable, or unstable across the read) could belong to any
            // book, and a known different one belongs to another; neither may
            // be recorded under the tracked ASIN.
            guard let bookID = page.bookID, !bookID.isEmpty,
                bookID.caseInsensitiveCompare(asin) == .orderedSame
            else {
                lastText = nil
                return
            }
            guard page.text != lastText else { return }
            lastText = page.text
            _ = try archive.recordPage(
                asin: asin, page: page.pageNumber, text: page.text)
        } catch {
            // A repaint can make one read fail; the next tick retries.
        }
    }
}
