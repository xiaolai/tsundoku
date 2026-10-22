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
        queue.async {
            guard !self.running else { return }
            self.running = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1.5)
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async {
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
            guard page.text != lastText else { return }
            lastText = page.text
            _ = try archive.recordPage(
                asin: asin, page: page.pageNumber, text: page.text)
        } catch {
            // A repaint can make one read fail; the next tick retries.
        }
    }
}
