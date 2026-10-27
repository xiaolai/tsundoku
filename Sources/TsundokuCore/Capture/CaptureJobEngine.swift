import CoreGraphics
import Foundation

/// Drives one capture session and owns the files it produces. The engine knows
/// nothing about Kindle, Accessibility or ScreenCaptureKit.
public struct CaptureJobEngine: Sendable {
    private let archive: Archive

    public init(archive: Archive) {
        self.archive = archive
    }

    public func run(
        session: any ReaderCaptureSession,
        subject: CaptureSubject,
        pageLimit: Int?,
        output: URL,
        progress: @Sendable (CaptureProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool,
        lifecycle: CaptureLifecycle = CaptureLifecycle(),
        publisher: any CapturePublisher = PDFPublisher(),
        cleanPage: CleanPageRequest? = nil,
        bundle: CaptureBundleRequest? = nil,
        outputPageSize: CGSize? = nil,
        cropTop: Int = 0,
        cropBottom: Int = 0,
        cropAutomatic: Bool = false,
        cropRect: CGRect? = nil,
        resume: Bool = false
    ) throws -> CaptureResult {
        var cropManifest: [String: Any] = [
            "top": cropTop,
            "bottom": cropBottom,
            "automatic": cropAutomatic,
        ]
        if let cropRect {
            cropManifest["source"] = "manual"
            cropManifest["windowLocal"] = [
                "x": cropRect.minX, "y": cropRect.minY,
                "width": cropRect.width, "height": cropRect.height,
            ]
        }
        try lifecycle.checkReady()
        let activity = lifecycle.begin()
        defer { lifecycle.end(activity) }
        // A chrome-hidden reader exposes no title, so an unknown identity is
        // not evidence of a wrong book. Compare only against a title Kindle
        // actually reported.
        if let book = subject.book, !book.title.isEmpty,
            let observed = Self.observedTitle(session.identity),
            !Self.sameTitle(book.title, observed)
        {
            throw ReaderCaptureError.wrongBook(
                expected: book.title, observed: observed)
        }
        if case .exact(let observed) = session.identity.confidence,
            let selected = subject.book?.asin, !selected.isEmpty,
            BookIdentity.normalize(selected)
                != BookIdentity.normalize(observed)
        {
            throw ReaderCaptureError.captureFailed(
                subject.kind,
                reason: "the selected book is \(selected), but the reader "
                    + "reports \(observed)")
        }

        // A whole-book capture starts at the book's first page, never at
        // whatever page happened to be open. A reader that cannot return
        // reports it and the capture says so in its manifest. A manual
        // Kindle session is forward-only: "all pages" means every page from
        // the previewed page to the end, so there is nothing to rewind.
        var rewind: RewindReport?
        if pageLimit == nil, !session.isManualCapture {
            do {
                rewind = try session.rewindToStart()
            } catch {
                throw Self.attach(
                    restore: nil, clean: nil, to: error, kind: subject.kind)
            }
            if rewind?.attempted == true, rewind?.reachedStart == false {
                throw ReaderCaptureError.captureFailed(
                    subject.kind,
                    reason: "could not return to the first page: "
                        + (rewind?.reason
                            ?? "the reader did not stop moving"))
            }
        }

        // The clean-page toggle runs before any page is written, so a refused
        // control aborts before `pages/` exists.
        var cleanGuard: CleanPageGuard?
        var cleanBegin: CleanPageOutcome?
        var cleanRestore: CleanPageOutcome?
        let cleanPolicy = cleanPage?.policy
        if let cleanPage, cleanPage.policy.hidesPopularHighlights {
            let pageGuard = CleanPageGuard(
                panel: cleanPage.panel, journal: cleanPage.journal)
            do {
                cleanBegin = try pageGuard.begin()
                cleanGuard = pageGuard
            } catch {
                throw ReaderCaptureError.captureFailed(
                    subject.kind,
                    reason: "clean page: \(error)")
            }
        }
        func restoreCleanPage() {
            guard let cleanGuard, cleanRestore == nil else { return }
            cleanRestore = cleanGuard.restore()
        }
        let personalMarks: Any = Self.personalMarks(
            archive: archive, asin: subject.book?.asin)
        func addCleanPage(_ manifest: inout [String: Any]) {
            Self.addCleanPage(
                &manifest, policy: cleanPolicy, begin: cleanBegin,
                restore: cleanRestore, personalMarks: personalMarks)
        }

        let store: CaptureArtifactStore
        do {
            store = try CaptureArtifactStore(
                output: output, resuming: resume)
        } catch {
            // The guard may already have turned Popular Highlights off; an
            // unwritable output must not leave it that way.
            restoreCleanPage()
            throw Self.attach(
                restore: nil, clean: cleanRestore, to: error,
                kind: subject.kind, manual: session.isManualCapture)
        }
        var pageTexts: [String] = []
        var firstPixelSize: CGSize?
        var termination: Termination = .failed("the run did not start")
        // A previous restore, an alert that just closed, or Kindle finishing
        // a page animation can leave the first read moving. It is safe to
        // retry: no page has been committed yet.
        var snapshot: PageSnapshot?
        var snapshotError: Error?
        for attempt in 0..<3 {
            if isCancelled() {
                snapshotError = ReaderCaptureError.cancelled
                break
            }
            do {
                snapshot = try session.snapshot()
                break
            } catch {
                snapshotError = error
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.4) }
            }
        }
        guard let snapshot else {
            // The reader must leave any terminal sheet first; the display
            // setting cannot be read from a non-reading surface.
            let report = session.restore()
            restoreCleanPage()
            let failureReason = snapshotError.map { "\($0)" } ?? "unknown"
            var failure = Self.manifestBase(session: session, subject: subject, crop: cropManifest)
            addCleanPage(&failure)
            failure["state"] = "incomplete"
            failure["termination"] = "failed:initial snapshot: "
                + failureReason
            failure["error"] = failureReason
            failure["complete"] = [
                "requestedRange": false, "structural": false,
                "wholeBook": false,
            ]
            failure["startPage"] = NSNull()
            failure["restore"] = Self.restore(report)
            try? store.writeManifest(failure)
            throw Self.attach(
                restore: report, clean: cleanRestore,
                to: snapshotError ?? ReaderCaptureError.cancelled,
                kind: subject.kind, manual: session.isManualCapture)
        }
        var current = snapshot
        // A resumed run starts on the last page already stored. The session
        // verified that page against the stored mark before the engine saw
        // it, so the page is not written again.
        var skipCurrent = resume
        if resume {
            pageTexts = store.entries.compactMap { $0["text"] as? String }
        }
        let firstPageNumber = snapshot.pageNumber
        let displayScale: Double =
            snapshot.cropRect.width > 0
            ? Double(snapshot.pixelSize.width / snapshot.cropRect.width)
            : 1
        var restored: RestoreReport?
        let pageClock = PageClock()
        var totalPages =
            pageLimit
            ?? Self.remainingPages(
                pageCount: snapshot.pageCount,
                pageNumber: snapshot.pageNumber)

        do {
            var index = store.pageURLs.count
            let safetyLimit = index + (pageLimit ?? 5_000)
            let targetCount = pageLimit.map { index + $0 }
            while index < safetyLimit {
                try lifecycle.checkReady()
                if isCancelled() {
                    termination = .cancelled
                    throw ReaderCaptureError.cancelled
                }
                if let firstPixelSize, firstPixelSize != current.pixelSize {
                    throw ReaderCaptureError.captureFailed(
                        subject.kind,
                        reason: "page \(index + 1) has size "
                            + "\(Int(current.pixelSize.width))×"
                            + "\(Int(current.pixelSize.height)); the first "
                            + "page was \(Int(firstPixelSize.width))×"
                            + "\(Int(firstPixelSize.height))")
                }
                firstPixelSize = current.pixelSize

                if skipCurrent {
                    skipCurrent = false
                } else {
                    let text = current.text ?? ""
                    _ = try store.commitPage(
                        image: current.image, text: text,
                        source: current.textSource?.rawValue ?? "none")
                    pageTexts.append(text)
                    var running = Self.manifestBase(session: session, subject: subject, crop: cropManifest)
                    running["state"] = "running"
                    running["termination"] = "running"
                    running["complete"] = [
                        "requestedRange": false,
                        "structural": false,
                        "wholeBook": false,
                    ]
                    try store.writeManifest(running)
                    index += 1
                    if totalPages == nil,
                        let remaining = Self.remainingPages(
                            pageCount: current.pageCount,
                            pageNumber: current.pageNumber)
                    {
                        // The run already captured `index - 1` frames before
                        // this page number became known.
                        totalPages =
                            current.pageNumber == nil
                            ? remaining : index - 1 + remaining
                    }
                    let elapsed = pageClock.elapsed()
                    let average = elapsed / Double(index)
                    let remaining = totalPages.map {
                        max(0, Double($0 - index) * average)
                    }
                    progress(
                        CaptureProgress(
                            page: index, pageLimit: pageLimit,
                            totalPages: totalPages,
                            estimatedRemaining: remaining,
                            message: "Captured page \(index)"
                                + (totalPages.map { " of \($0)" } ?? "")
                                + (current.isEndOfBook
                                    ? " · end of book" : "")))
                }

                if current.isEndOfBook {
                    termination = .endOfBook
                    break
                }
                if let targetCount, index >= targetCount {
                    termination = .pageLimit
                    break
                }
                if pageLimit == nil, index >= safetyLimit {
                    termination = .safetyCap
                    break
                }

                switch try session.advance(after: current.mark) {
                case .turned(let next, _):
                    current = next
                case .endOfBook:
                    termination = .endOfBook
                case .noTurn(_, let reason):
                    throw ReaderCaptureError.pageDidNotTurn(
                        subject.kind, reason: reason)
                }
                if termination == .endOfBook { break }
            }
            if pageLimit == nil, store.pageURLs.count >= safetyLimit,
                termination != .endOfBook
            {
                termination = .safetyCap
            }
            if isCancelled() {
                termination = .cancelled
                throw ReaderCaptureError.cancelled
            }
        } catch {
            restored = session.restore()
            restoreCleanPage()
            if termination != .cancelled {
                termination = .failed("\(error)")
            }
            var failure = Self.manifestBase(session: session, subject: subject, crop: cropManifest)
            addCleanPage(&failure)
            failure["state"] = Self.state(termination)
            failure["termination"] = Self.termination(termination)
            failure["error"] = "\(error)"
            failure["complete"] = [
                "requestedRange": false,
                "structural": false,
                "wholeBook": false,
            ]
            failure["startPage"] = firstPageNumber ?? NSNull()
            if let restored {
                failure["restore"] = Self.restore(restored)
            }
            try? store.writeManifest(failure)
            throw Self.attach(
                restore: restored, clean: cleanRestore, to: error,
                kind: subject.kind, manual: session.isManualCapture)
        }
        restored = session.restore()
        restoreCleanPage()
        if isCancelled() {
            var failure = Self.manifestBase(session: session, subject: subject, crop: cropManifest)
            addCleanPage(&failure)
            failure["state"] = "cancelled"
            failure["termination"] = "cancelled"
            failure["complete"] = [
                "requestedRange": false, "structural": false,
                "wholeBook": false,
            ]
            failure["startPage"] = firstPageNumber ?? NSNull()
            if let restored {
                failure["restore"] = Self.restore(restored)
            }
            try? store.writeManifest(failure)
            if let cleanRestore, !cleanRestore.restored {
                throw ReaderCaptureError.cancelledWithWarning(
                    "Popular Highlights was not restored: "
                        + (cleanRestore.reason ?? "unknown reason"))
            }
            throw ReaderCaptureError.cancelled
        }

        try store.writeText()
        let title = Self.captureTitle(session: session, subject: subject)
        let identifier: String?
        if case .exact(let observed) = session.identity.confidence {
            identifier = observed
        } else {
            identifier = nil
        }
        let capturedPages = store.pageURLs.count
        let bookSource: BookSource =
            subject.kind == .kindle ? .kindle : .appleBooks
        let bundlePlan: ExportBundlePlan?
        if let bundle {
            bundlePlan = ExportBundle.prepare(
                directory: output, book: subject.book,
                capturedTitle: title, identifier: identifier,
                source: bookSource, capturedPages: capturedPages,
                options: bundle.options, services: bundle.services,
                now: bundle.now())
        } else {
            bundlePlan = nil
        }
        let published: PublishedCapture
        do {
            published = try publisher.publish(
                CaptureArtifact(
                    directory: output, pageURLs: store.pageURLs,
                    texts: pageTexts,
                    metadata: CaptureMetadata(
                        title: title, author: subject.book?.author,
                        identifier: identifier,
                        source: subject.kind.displayName,
                        displayScale: displayScale),
                    termination: termination,
                    cancellation: ClosureCancellation(isCancelled),
                    coverPage: bundlePlan?.coverPage,
                    pageSize: outputPageSize))
        } catch {
            var failure = Self.manifestBase(session: session, subject: subject, crop: cropManifest)
            addCleanPage(&failure)
            failure["state"] = "incomplete"
            failure["termination"] = Self.termination(termination)
            failure["error"] = "\(error)"
            failure["complete"] = [
                "requestedRange": false, "structural": false,
                "wholeBook": false,
            ]
            failure["startPage"] = firstPageNumber ?? NSNull()
            if let restored {
                failure["restore"] = Self.restore(restored)
            }
            try? store.writeManifest(failure)
            throw error
        }
        let pdfURL = published.url
        let pdfPages = published.pageCount
        let expectedPDFPages =
            capturedPages + (bundlePlan?.coverPage == nil ? 0 : 1)
        guard pdfPages == expectedPDFPages else {
            throw ReaderCaptureError.captureFailed(
                subject.kind,
                reason: "the publisher returned \(pdfPages) pages; "
                    + "\(expectedPDFPages) were expected")
        }

        let completeRequested =
            termination == .endOfBook || termination == .pageLimit
        var manifest = Self.manifestBase(session: session, subject: subject, crop: cropManifest)
        if let identifier { manifest["asin"] = identifier }
        manifest["state"] = Self.state(termination)
        manifest["pageCount"] = capturedPages
        manifest["pdfPages"] = pdfPages
        manifest["pdf"] = pdfURL.lastPathComponent
        manifest["termination"] = Self.termination(termination)
        manifest["startPage"] = firstPageNumber ?? NSNull()
        manifest["complete"] = [
            "requestedRange": completeRequested,
            "structural": pdfPages == expectedPDFPages,
            "wholeBook": termination == .endOfBook && firstPageNumber == 1,
        ]
        if let firstPixelSize {
            manifest["pageWidth"] = Int(firstPixelSize.width)
            manifest["pageHeight"] = Int(firstPixelSize.height)
        }
        if let calibration = snapshot.calibration {
            manifest["layout"] = [
                "status": calibration.status.rawValue,
                "insets": calibration.insets.named,
                "window": [
                    snapshot.cropRect.minX - calibration.insets.left,
                    snapshot.cropRect.minY - calibration.insets.top,
                    snapshot.cropRect.width
                        + calibration.insets.left
                        + calibration.insets.right,
                    snapshot.cropRect.height
                        + calibration.insets.top
                        + calibration.insets.bottom,
                ],
                "pageRect": [
                    snapshot.cropRect.minX, snapshot.cropRect.minY,
                    snapshot.cropRect.width, snapshot.cropRect.height,
                ],
                "pixelSize": [
                    snapshot.pixelSize.width, snapshot.pixelSize.height,
                ],
                "characters": snapshot.text?.count ?? 0,
                "signature": Self.signature(
                    snapshot: snapshot, pageTexts: pageTexts),
                "spread": snapshot.spread,
            ]
        }
        if let restored {
            manifest["restore"] = Self.restore(restored)
        }
        addCleanPage(&manifest)
        var bundleWarnings = bundlePlan?.warnings ?? []
        // A page whose text did not fit the PDF layer is a capture warning,
        // not a failed capture: the images and the other pages are intact.
        bundleWarnings.append(contentsOf: published.warnings)
        if let bundlePlan {
            do {
                bundleWarnings.append(
                    contentsOf: try ExportBundle.finish(
                        bundlePlan, manifest: &manifest, directory: output,
                        isCancelled: isCancelled))
            } catch is CancellationError {
                try store.writeManifest(
                    Self.cancelledFinalization(
                        manifest,
                        warnings: session.captureWarnings + bundleWarnings))
                throw ReaderCaptureError.cancelled
            }
            // The copy checks cancellation while it streams, but a stop
            // arriving after the last chunk must still not report success.
            if isCancelled() {
                try store.writeManifest(
                    Self.cancelledFinalization(
                        manifest,
                        warnings: session.captureWarnings + bundleWarnings))
                throw ReaderCaptureError.cancelled
            }
        }
        manifest["warnings"] = session.captureWarnings + bundleWarnings
        try store.writeManifest(manifest)

        let verification = try CaptureVerifier.verify(directory: output)
        var warnings = session.captureWarnings
        warnings.append(contentsOf: verification.faults)
        warnings.append(contentsOf: bundleWarnings)
        if !session.isManualCapture, restored?.exact == false {
            warnings.append("restore not exact")
        }
        if let cleanRestore, !cleanRestore.restored {
            warnings.append(
                "Popular Highlights was not restored"
                    + (cleanRestore.reason.map { ": \($0)" } ?? ""))
        }
        if rewind?.attempted == false {
            warnings.append(
                "This reader cannot return to the first page; the capture "
                    + "started at the current page.")
        }
        manifest["complete"] = [
            "requestedRange": verification.structural && completeRequested,
            "structural": verification.structural,
            "wholeBook": verification.wholeBook,
        ]
        manifest["warnings"] = warnings
        try store.writeManifest(manifest)

        // Verification can run after the last check; a stop arriving now
        // must still not be recorded as a successful capture.
        if isCancelled() {
            try store.writeManifest(
                Self.cancelledFinalization(manifest, warnings: warnings))
            throw ReaderCaptureError.cancelled
        }

        let captureState =
            verification.structural ? Self.state(termination) : "incomplete"
        try archive.recordCapture(
            asin: identifier, title: title, directory: output.path,
            pageCount: pdfPages, pdfPath: pdfURL.path, state: captureState,
            source: subject.kind.captureSource,
            identityConfidence: Self.confidence(session.identity.confidence),
            termination: Self.termination(termination),
            warnings: warnings)
        let cleanSummary: CleanPageSummary?
        if let cleanPolicy {
            if let cleanBegin {
                cleanSummary = CleanPageSummary(
                    policy: cleanPolicy, begin: cleanBegin,
                    restore: cleanRestore)
            } else {
                cleanSummary = CleanPageSummary(
                    policy: cleanPolicy, original: nil, final: nil,
                    changed: false, restored: true, reason: nil)
            }
        } else {
            cleanSummary = nil
        }
        return CaptureResult(
            directory: output, pdf: pdfURL, pages: pdfPages, title: title,
            cleanPage: cleanSummary, pageSetup: session.pageSetupOutcome)
    }

    private struct PageClock {
        let start = Date()
        func elapsed() -> TimeInterval { Date().timeIntervalSince(start) }
    }

    private static func signature(
        snapshot: PageSnapshot, pageTexts: [String]
    ) -> [String: Any] {
        let counts = pageTexts.map(\.count).sorted()
        var object: [String: Any] = [
            "pageCount": snapshot.location?.pageCount ?? NSNull(),
            "textWidth": snapshot.textFrame.map {
                Double($0.width) as Any
            } ?? NSNull(),
            "textHeight": snapshot.textFrame.map {
                Double($0.height) as Any
            } ?? NSNull(),
            "characters": [
                "min": counts.first ?? 0,
                "median": counts.isEmpty ? 0 : counts[counts.count / 2],
                "max": counts.last ?? 0,
            ],
            // The AX tree exposes no font family, size, margin or line-spacing
            // attribute; the page count and text column stand in for them.
            "font": NSNull(),
        ]
        if let pageNumber = snapshot.location?.pageNumber {
            object["openingPage"] = pageNumber
        }
        return object
    }

    private static func personalMarks(
        archive: Archive, asin: String?
    ) -> Any {
        guard let asin else { return NSNull() }
        let marks =
            (try? archive.annotations(asin: asin, provenance: .user)) ?? []
        return marks.count
    }

    private static func addCleanPage(
        _ manifest: inout [String: Any], policy: CleanPagePolicy?,
        begin: CleanPageOutcome?, restore: CleanPageOutcome?,
        personalMarks: Any
    ) {
        guard let policy else { return }
        let summary: CleanPageSummary
        if let begin {
            summary = CleanPageSummary(
                policy: policy, begin: begin, restore: restore)
        } else {
            summary = CleanPageSummary(
                policy: policy, original: nil, final: nil, changed: false,
                restored: true, reason: nil)
        }
        var object = summary.manifest
        // Reported, never removed: the marks stay in the page images.
        object["personalMarks"] = personalMarks
        manifest["cleanPage"] = object
    }

    private static func attach(
        restore: RestoreReport?, clean: CleanPageOutcome?,
        to error: Error, kind: ReaderKind, manual: Bool = false
    ) -> Error {
        var reasons: [String] = []
        if !manual, let restore, !restore.exact {
            reasons.append(
                "restore was not exact: "
                    + (restore.reason ?? "unknown reason"))
        }
        if let clean, !clean.restored {
            reasons.append(
                "Popular Highlights was not restored: "
                    + (clean.reason ?? "unknown reason"))
        }
        guard !reasons.isEmpty else { return error }
        return ReaderCaptureError.captureFailed(
            kind, reason: "\(error); " + reasons.joined(separator: "; "))
    }

    private static func manifestBase(
        session: any ReaderCaptureSession, subject: CaptureSubject,
        crop: [String: Any] = [:]
    ) -> [String: Any] {
        var manifest: [String: Any] = [
            "version": 2,
            "source": subject.kind.captureSource,
            "identity": [
                "title": session.identity.title,
                "confidence": confidence(session.identity.confidence),
            ],
            "title": captureTitle(session: session, subject: subject),
            "warnings": session.captureWarnings,
        ]
        if session.isManualCapture {
            manifest["manual"] = true
            manifest["restored"] = false
        }
        if !crop.isEmpty { manifest["crop"] = crop }
        if let rewind = session.rewindOutcome {
            manifest["rewind"] = rewind.manifest
        }
        if let pageSetup = session.pageSetupOutcome {
            manifest["pageSetup"] = pageSetup.manifest
        }
        if let book = subject.book {
            manifest["author"] = book.author
        }
        return manifest
    }

    /// A cancellation observed after the PDF was published: the files that
    /// exist are kept, but the manifest never claims a complete capture.
    private static func cancelledFinalization(
        _ manifest: [String: Any], warnings: [String]
    ) -> [String: Any] {
        var cancelled = manifest
        cancelled["state"] = "cancelled"
        cancelled["termination"] = "cancelled"
        cancelled["warnings"] = warnings + ["Finalization was cancelled."]
        cancelled["complete"] = [
            "requestedRange": false,
            "structural": false,
            "wholeBook": false,
        ]
        return cancelled
    }

    private static func state(_ termination: Termination) -> String {
        switch termination {
        case .endOfBook: "finished"
        case .pageLimit: "partial"
        case .cancelled: "cancelled"
        case .safetyCap, .failed(_): "incomplete"
        }
    }

    /// The title Kindle actually reported, or nil when it reported none.
    private static func observedTitle(_ identity: ObservedIdentity) -> String? {
        switch identity.confidence {
        case .exact:
            identity.title.isEmpty ? nil : identity.title
        case .titleOnly(let title):
            title.isEmpty ? nil : title
        case .unknown:
            nil
        }
    }

    /// The title to publish when Kindle cannot name the book itself.
    private static func captureTitle(
        session: any ReaderCaptureSession, subject: CaptureSubject
    ) -> String {
        guard observedTitle(session.identity) == nil else {
            return session.identity.displayTitle
        }
        if let book = subject.book, !book.title.isEmpty {
            return book.title
        }
        return "\(subject.kind.displayName) book"
    }

    private static func sameTitle(_ left: String, _ right: String) -> Bool {
        left.compare(
            right, options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    /// The pages left from the current one, for a run without a page limit.
    /// The engine counts captured frames, so a run that starts mid-book has
    /// fewer pages to report than the book's total.
    private static func remainingPages(
        pageCount: Int?, pageNumber: Int?
    ) -> Int? {
        guard let count = pageCount else { return nil }
        guard let number = pageNumber else { return count }
        return max(1, count - number + 1)
    }

    private static func confidence(_ value: IdentityConfidence) -> String {
        switch value {
        case .exact(let identifier): "exact:\(identifier)"
        case .titleOnly(let title): "titleOnly:\(title)"
        case .unknown: "unknown"
        }
    }

    private static func termination(_ value: Termination) -> String {
        switch value {
        case .endOfBook: "endOfBook"
        case .pageLimit: "pageLimit"
        case .cancelled: "cancelled"
        case .safetyCap: "safetyCap"
        case .failed(let reason): "failed:\(reason)"
        }
    }

    private static func restore(_ report: RestoreReport) -> [String: Any] {
        [
            "exact": report.exact,
            "attempted": report.attempted,
            "posted": report.posted,
            "observed": report.observed,
            "terminal": report.terminal,
            "unresolved": report.unresolved,
            "openingPage": report.opening?.pageNumber ?? NSNull(),
            "finalPage": report.final?.pageNumber ?? NSNull(),
            "reason": report.reason ?? NSNull(),
        ]
    }
}
