import Foundation
import TsundokuCore

@main
struct TsundokuCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            usage()
            exit(2)
        }
        if command == "--help" || command == "-h" {
            usage()
            exit(0)
        }
        switch command {
        case "inspect":
            inspect()
        case "page":
            page()
        case "selection":
            selection()
        case "cards":
            cards()
        case "ask":
            await ask(Array(arguments.dropFirst()))
        case "capture":
            capture(Array(arguments.dropFirst()))
        case "clean-page":
            cleanPage(Array(arguments.dropFirst()))
        case "page-setup":
            pageSetup(Array(arguments.dropFirst()))
        case "export":
            export(Array(arguments.dropFirst()))
        case "history":
            history()
        case "track":
            track(Array(arguments.dropFirst()))
        case "import":
            importContainer(Array(arguments.dropFirst()))
        case "applebooks":
            appleBooks(Array(arguments.dropFirst()))
        case "books-asset":
            booksAsset(Array(arguments.dropFirst()))
        case "cover":
            cover(Array(arguments.dropFirst()))
        case "original":
            original(Array(arguments.dropFirst()))
        case "books-probe":
            BooksProbe.run(Array(arguments.dropFirst()))
        case "context-index":
            contextIndex(Array(arguments.dropFirst()))
        default:
            usage()
            exit(2)
        }
    }

    private static func inspect() {
        do {
            let paths = KindlePaths.standard()
            guard paths.exists else {
                print("Kindle data not found at \(paths.container.path)")
                exit(1)
            }
            // Read through the reconciled path: importing the raw BookData
            // states here overwrote correct Whispersync read statuses.
            let data = try KindleReader.readAllWithStates(paths)
            let books = data.books
            let states = data.states
            let annotations = data.annotations
            let user = annotations.filter { $0.provenance == .user }
            let archive = try Archive.standard()
            let imported = try archive.importAll(
                books: books, annotations: annotations)
            let counts = try archive.counts()
            print(
                "read books=\(books.count) states=\(states.count) "
                    + "annotations=\(annotations.count) user=\(user.count)")
            print(
                "imported books=\(imported.books) "
                    + "annotations=\(imported.annotations) "
                    + "user=\(imported.userAnnotations)")
            print(
                "archive books=\(counts.books) "
                    + "annotations=\(counts.annotations) "
                    + "user=\(counts.userAnnotations) "
                    + "sessions=\(counts.sessions)")
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func page() {
        do {
            let live = try KindleLive.currentPage()
            print("state=\(live.state)")
            print("characters=\(live.characters)")
            print("title=\(live.title)")
            print("book_id=\(live.bookID ?? "nil")")
            print("end_of_book=\(live.endOfBook)")
            print("page=\(live.pageNumber.map(String.init) ?? "?")")
            print("pages=\(live.pageCount.map(String.init) ?? "?")")
            if let frame = live.windowFrame {
                print(
                    "window=\(Int(frame.x)),\(Int(frame.y)) "
                        + "\(Int(frame.width))x\(Int(frame.height))")
            }
            if let frame = live.pageTextFrame {
                print(
                    "text_rect=\(Int(frame.x)),\(Int(frame.y)) "
                        + "\(Int(frame.width))x\(Int(frame.height))")
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    /// Reads Kindle's current selection through its Copy button. Prints the
    /// length only: the words are book data and stay out of terminal logs.
    private static func selection() {
        switch KindleLive.copySelection() {
        case .copied(let text):
            print("characters=\(text.count)")
        case .copiedButClipboardNotRestored(let text):
            print("characters=\(text.count)")
            FileHandle.standardError.write(
                Data(
                    "warning: the clipboard could not be restored\n".utf8))
        case .noSelection:
            print("selection=none")
        case .failed(let reason):
            print("error: \(reason)")
            exit(1)
        }
    }

    private static func cards() {
        do {
            let archive = try Archive.standard()
            let total = try archive.aiCardCount()
            let cards = try archive.aiCards(limit: 5)
            print("cards=\(total)")
            for card in cards {
                print(
                    "id=\(card.id) turn=\(card.turnID) "
                        + "conversation=\(card.conversationID) "
                        + "key=\(card.bookKey) chars=\(card.answer.count)")
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func ask(_ arguments: [String]) async {
        // Argument validation comes before any work: an unreadable Kindle must
        // not mask a usage error.
        if let service = value("--service", in: arguments),
            !AIService.knownServiceIDs.contains(service)
        {
            print(
                "error: unknown service '\(service)'. Known: \(AIService.knownServiceIDs.joined(separator: ", "))"
            )
            exit(2)
        }
        if let action = value("--action", in: arguments),
            AIAction(rawValue: action) == nil
        {
            print(
                "error: unknown action '\(action)'. Known: "
                    + AIAction.allCases.map(\.rawValue).joined(
                        separator: ", "))
            exit(2)
        }
        if let provider = value("--provider", in: arguments),
            AIProviderOption(rawValue: provider) == nil
        {
            print(
                "error: unknown provider '\(provider)'. Known: "
                    + AIProviderOption.allCases.map(\.rawValue).joined(
                        separator: ", "))
            exit(2)
        }
        do {
            let live = try KindleLive.currentPage()
            guard !live.text.isEmpty else {
                print("error: the current page exposes no text")
                exit(1)
            }
            let action =
                AIAction(rawValue: value("--action", in: arguments) ?? "")
                ?? .explain
            let question = value("--question", in: arguments) ?? ""
            var settings = AISettings.defaults
            if let raw = value("--provider", in: arguments),
                let provider = AIProviderOption(rawValue: raw)
            {
                settings.provider = provider.settingsValue
            }
            if let model = value("--model", in: arguments) {
                settings.model = model
            }
            if let language = value("--language", in: arguments) {
                settings.language = language
            }
            if let endpoint = value("--endpoint", in: arguments) {
                settings.endpoint = endpoint
            }
            if let service = value("--service", in: arguments) {
                settings.httpProfileID = service
            }
            let request = AIRequest(
                action: action, pageText: live.text,
                bookTitle: live.title, question: question,
                language: settings.language)
            do {
                let answer = try await AIService.answer(
                    for: request, settings: settings)
                print("provider=\(answer.provider)")
                print(answer.text)
            } catch {
                print(
                    "error: \(AIProviderFailure.message(for: error, provider: settings.provider))"
                )
                exit(1)
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    /// Everything a capture needs, validated before the archive is opened or
    /// the reader is touched.
    private struct CaptureOptions {
        let pages: Int
        let asin: String?
        let source: BookSource
        let output: URL
        let pageSize: CapturePageSize
        let setup: PageSetupRequest
        let bundleOptions: CaptureBundleOptions
        let cleanPage: CleanPagePolicy
    }

    private static func captureOptions(_ arguments: [String])
        -> CaptureOptions
    {
        let pages: Int
        if let raw = value("--pages", in: arguments) {
            guard let parsed = Int(raw), parsed > 0 else {
                print("error: --pages needs a positive integer")
                exit(2)
            }
            pages = parsed
        } else {
            pages = 5
        }
        let pageSize: CapturePageSize
        switch value("--page-size", in: arguments)?.lowercased() {
        case nil, "asdisplayed", "as-displayed":
            pageSize = .asDisplayed
        case "a4":
            pageSize = .a4
        case let other?:
            print(
                "error: unknown --page-size '\(other)'. Use asdisplayed or "
                    + "a4.")
            exit(2)
        }
        let outputPath =
            value("--out", in: arguments)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("TsundokuExports").path
        let output = URL(fileURLWithPath: outputPath)
            .appendingPathComponent(
                "capture-\(Int(Date().timeIntervalSince1970))")
        let setup = PageSetupRequest(
            pageSize: pageSize,
            font: optionalInteger("--font-size", arguments),
            booksFontSteps: optionalInteger("--text-size", arguments) ?? 0,
            cropTop: cropValue("--crop-top", arguments) ?? 0,
            cropBottom: cropValue("--crop-bottom", arguments))
        let bundleOptions = CaptureBundleOptions(
            includeCoverPage: !arguments.contains("--no-cover"),
            writeSidecars: !arguments.contains("--no-sidecars"),
            copyOriginal: arguments.contains("--copy-original"),
            pageSize: pageSize.points)
        return CaptureOptions(
            pages: pages, asin: value("--asin", in: arguments),
            source: sourceValue(arguments), output: output,
            pageSize: pageSize, setup: setup, bundleOptions: bundleOptions,
            cleanPage: arguments.contains("--clean-page")
                ? .hidePopularHighlights : .asDisplayed)
    }

    private static func resolveCaptureBook(
        _ options: CaptureOptions, archive: Archive
    ) throws -> Book? {
        guard let asin = options.asin else { return nil }
        // An identifier the archive does not know cannot verify what the
        // reader is showing; resolving its cover or original would attach
        // another book's metadata to this capture.
        guard
            let matched = BookLookup.book(
                asin: asin, source: options.source,
                in: try archive.books())
        else {
            print(
                "error: no \(options.source.displayName) book with ASIN "
                    + "\(asin) in the archive; import it first or capture "
                    + "without --asin")
            exit(1)
        }
        return matched
    }

    private static func capture(_ arguments: [String]) {
        let options = captureOptions(arguments)
        let kind: ReaderKind =
            options.source == .appleBooks ? .appleBooks : .kindle
        do {
            let archive = try Archive.standard()
            let book = try resolveCaptureBook(options, archive: archive)
            // Ctrl-C must cancel cooperatively, or the engine never restores
            // the reading position or the Popular Highlights setting.
            let flag = CancellationFlag()
            let cancelSignals = installCancellationHandlers(flag: flag)
            defer { cancelSignals() }
            let engine = CaptureEngine(archive: archive)
            let result = try engine.capture(
                book: book, kind: kind, pageLimit: options.pages,
                output: options.output,
                progress: { progress in
                    print(
                        "page \(progress.page)"
                            + (progress.pageLimit.map {
                                "/\($0)"
                            } ?? "")
                            + " · \(progress.message)")
                },
                isCancelled: { flag.isSet },
                cleanPage: options.cleanPage,
                pageSetup: options.setup,
                bundle: CaptureBundleRequest(options: options.bundleOptions))
            print("pdf=\(result.pdf.path)")
            print("pages=\(result.pages)")
            print("title=\(result.title)")
            print("directory=\(result.directory.path)")
            if let clean = result.cleanPage {
                print("cleanPage=\(clean.changed ? "changed" : "unchanged")"
                    + " restored=\(clean.restored)")
            }
            printBundleSummary(at: options.output)
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    /// An optional integer option. A present but malformed value is a usage
    /// error; silently ignoring it would run a different capture.
    private static func optionalInteger(
        _ flag: String, _ arguments: [String]
    ) -> Int? {
        guard let raw = value(flag, in: arguments) else { return nil }
        guard let parsed = Int(raw) else {
            print("error: \(flag) needs an integer")
            exit(2)
        }
        return parsed
    }

    /// Route Ctrl-C and SIGTERM into a cooperative cancellation flag so the
    /// capture engine can restore the reader before exiting. The returned
    /// closure removes the signal sources.
    private static func installCancellationHandlers(
        flag: CancellationFlag
    ) -> () -> Void {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(
                signal: number, queue: .global())
            source.setEventHandler { flag.set() }
            source.resume()
            return source
        }
        return { sources.forEach { $0.cancel() } }
    }

    /// Report the bundle objects the manifest recorded, without any book text.
    private static func printBundleSummary(at directory: URL) {
        guard
            let data = try? Data(
                contentsOf: directory.appendingPathComponent("manifest.json")),
            let manifest = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            print("bundle=none")
            return
        }
        let cover = (manifest["cover"] as? [String: Any])?["source"]
            as? String ?? "none"
        print("cover=\(cover)")
        print("coverPage=\(manifest["coverPage"] as? Bool ?? false)")
        print("textSidecars=\(manifest["text"] != nil)")
        if let original = manifest["original"] as? [String: Any] {
            print(
                "original="
                    + ((original["available"] as? Bool ?? false)
                        ? "available" : "unavailable"))
        }
        if let warnings = manifest["warnings"] as? [String],
            !warnings.isEmpty
        {
            for warning in warnings {
                print("warning: \(warning)")
            }
        }
    }

    /// Manual control and crash-recovery harness for the Popular Highlights
    /// guard. `begin` leaves the journal behind, exactly as a crash between
    /// the toggle and its restore would; `recover` puts the setting back.
    private static func cleanPage(_ arguments: [String]) {
        let panel = KindlePopularHighlights()
        do {
            switch arguments.first ?? "status" {
            case "status":
                let on = try panel.state()
                let journal = CleanPageJournal().load()
                print("popularHighlights=\(on ? "on" : "off")")
                print(
                    "journal="
                        + (journal.map { $0 ? "original-on" : "original-off" }
                            ?? "none"))
            case "begin":
                let outcome = try CleanPageGuard(panel: panel).begin()
                print("changed=\(outcome.changed)")
                print("journal=\(CleanPageJournal().load() == nil ? "none" : "written")")
            case "recover":
                guard
                    let outcome = CleanPageGuard.recoverIfNeeded(panel: panel)
                else {
                    print("journal=none")
                    return
                }
                print("restored=\(outcome.restored)")
                print("reason=\(outcome.reason ?? "none")")
                if !outcome.restored { exit(1) }
            default:
                print("usage: tsundoku-cli clean-page status|begin|recover")
                exit(2)
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    /// Inspect or restore a page setup left behind by an interrupted
    /// capture. `status` prints the saved window and font, never any secret.
    private static func pageSetup(_ arguments: [String]) {
        switch arguments.first ?? "status" {
        case "status":
            guard let saved = PageSetupJournal().load() else {
                print("journal=none")
                return
            }
            print("journal=present")
            if let font = saved.font { print("font=\(font)") }
            if let window = saved.window {
                print(
                    "window=\(Int(window.minX)),\(Int(window.minY)) "
                        + "\(Int(window.width))x\(Int(window.height))")
            }
        case "recover":
            guard let outcome = KindlePageSetup.recoverIfNeeded() else {
                print("journal=none")
                return
            }
            print("restored=\(outcome.restored)")
            print("reason=\(outcome.reason ?? "none")")
            if !outcome.restored { exit(1) }
        default:
            print("usage: tsundoku-cli page-setup status|recover")
            exit(2)
        }
    }

    private static func export(_ arguments: [String]) {
        do {
            let archive = try Archive.standard()
            let format: AnnotationExportFormat
            if let raw = value("--format", in: arguments)?.lowercased() {
                guard let parsed = AnnotationExportFormat(rawValue: raw) else {
                    print(
                        "error: unknown --format '\(raw)'. Known: "
                            + AnnotationExportFormat.allCases.map(\.rawValue)
                                .joined(separator: ", "))
                    exit(2)
                }
                format = parsed
            } else {
                format = .json
            }
            let path =
                value("--out", in: arguments)
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "tsundoku-annotations.\(format.fileExtension)").path
            // An absent filter exports everything; a present but unknown
            // value must not silently become "no filter" and export more
            // than the caller asked for.
            let provenance: AnnotationProvenance?
            if let raw = value("--provenance", in: arguments)?.lowercased() {
                switch raw {
                case "mine": provenance = .user
                case "popular": provenance = .amazon
                case "system": provenance = .system
                default:
                    print(
                        "error: unknown --provenance '\(raw)'. Use mine, "
                            + "popular or system.")
                    exit(2)
                }
            } else {
                provenance = nil
            }
            let source: BookSource?
            if let raw = value("--source", in: arguments)?.lowercased() {
                switch raw {
                case "kindle": source = .kindle
                case "applebooks", "apple-books", "apple", "books":
                    source = .appleBooks
                default:
                    print(
                        "error: unknown --source '\(raw)'. Use kindle or "
                            + "applebooks.")
                    exit(2)
                }
            } else {
                source = nil
            }
            let url = URL(fileURLWithPath: path)
            try archive.exportAnnotations(
                to: url, format: format, provenance: provenance,
                source: source)
            print("exported=\(url.path)")
            print("bytes=\(try Data(contentsOf: url).count)")
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func history() {
        do {
            let archive = try Archive.standard()
            let counts = try archive.counts()
            let sessions = try archive.sessions()
            print(
                "books=\(counts.books) annotations=\(counts.annotations) "
                    + "sessions=\(counts.sessions)")
            for session in sessions.prefix(20) {
                let title = session.bookTitle.isEmpty
                    ? session.asin : session.bookTitle
                print(
                    "\(title) · \(session.pageCount) pages · "
                        + "\(max(1, Int(session.duration / 60))) min · "
                        + ISO8601DateFormatter().string(
                            from: session.startedAt))
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func track(_ arguments: [String]) {
        do {
            let archive = try Archive.standard()
            let asin: String
            if let raw = value("--asin", in: arguments), !raw.isEmpty {
                asin = raw
            } else if let current = KindleLive.lastOpenedBookID() {
                asin = current
                print("asin=\(asin) (current book)")
            } else {
                print(
                    "error: track needs --asin; Kindle reports no open book")
                exit(2)
            }
            let seconds =
                Double(value("--seconds", in: arguments) ?? "6") ?? 6
            let logger = SessionLogger(archive: archive)
            logger.setBook(asin)
            logger.start()
            Thread.sleep(forTimeInterval: seconds)
            // No logger can be ticking with a book when this returns, so the
            // session query below sees the writes the tracking produced.
            logger.stopAndDrain()
            let sessions = try archive.sessions()
            print("sessions=\(sessions.count)")
            for session in sessions.prefix(5) {
                print(
                    "\(session.bookTitle.isEmpty ? session.asin : session.bookTitle)"
                        + " · \(session.pageCount) pages")
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func importContainer(_ arguments: [String]) {
        guard let container = value("--container", in: arguments) else {
            usage()
            exit(2)
        }
        do {
            let paths = KindlePaths(
                container: URL(fileURLWithPath: container))
            guard paths.exists else {
                print("No BookData.sqlite under \(container)")
                exit(1)
            }
            let archive = try Archive.standard()
            let data = try KindleReader.readAll(paths)
            let result = try archive.importAll(
                books: data.books, annotations: data.annotations)
            print(
                "imported books=\(result.books) "
                    + "annotations=\(result.annotations) "
                    + "user=\(result.userAnnotations)")
            let counts = try archive.counts()
            print(
                "archive books=\(counts.books) "
                    + "annotations=\(counts.annotations) "
                    + "user=\(counts.userAnnotations)")
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func appleBooks(_ arguments: [String]) {
        do {
            let paths = booksPaths(arguments)
            guard paths.exists else {
                print(
                    "Apple Books stores not found at \(paths.container.path)")
                exit(1)
            }
            let data = try BooksReader.readAll(paths)
            let highlights = data.annotations.filter { $0.kind == .highlight }
            let bookmarks = data.annotations.filter { $0.kind == .bookmark }
            let positions = data.annotations.filter { $0.kind == .position }
            let withText = data.annotations.filter(\.isResolved)
            print(
                "read books=\(data.books.count) "
                    + "annotations=\(data.annotations.count) "
                    + "highlights=\(highlights.count) "
                    + "bookmarks=\(bookmarks.count) "
                    + "positions=\(positions.count) "
                    + "with_text=\(withText.count)")
            if arguments.contains("--read-only") {
                return
            }
            let archive = try Archive.standard()
            let imported = try archive.importAll(
                books: data.books, annotations: data.annotations)
            print(
                "imported books=\(imported.books) "
                    + "annotations=\(imported.annotations) "
                    + "user=\(imported.userAnnotations)")
            let sourceBooks = try archive.books().filter {
                $0.source == .appleBooks
            }
            let sourceAnnotations = try archive.annotations(
                source: .appleBooks)
            print(
                "archive applebooks_books=\(sourceBooks.count) "
                    + "applebooks_annotations=\(sourceAnnotations.count)")
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func booksAsset(_ arguments: [String]) {
        do {
            let asset: BooksAsset
            if let path = value("--path", in: arguments) {
                let url = URL(fileURLWithPath: path)
                asset = BooksAsset.load(
                    assetID: url.lastPathComponent, path: url,
                    contentType: contentType(for: url))
            } else if let asin = value("--asin", in: arguments) {
                let reader = BooksAssetReader(paths: booksPaths(arguments))
                guard let found = try reader.asset(for: asin) else {
                    print("asset=none")
                    exit(1)
                }
                asset = found
            } else {
                usage()
                exit(2)
            }
            printAsset(asset)
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func cover(_ arguments: [String]) {
        do {
            let source = sourceValue(arguments)
            guard
                let identifier = value("--asin", in: arguments)
                    ?? value("--identifier", in: arguments),
                !identifier.isEmpty
            else {
                usage()
                exit(2)
            }
            let archive = try Archive.standard()
            let book = try resolveBook(
                asin: identifier, source: source, archive: archive)
            let title = value("--title", in: arguments) ?? book?.title ?? ""
            let output = URL(fileURLWithPath: value(
                "--out", in: arguments) ?? checkDirectory("cover"))
            let services = CaptureBundleServices.standard()
            var metadata = services.metadataResolver.resolve(
                book: book, capturedTitle: title, identifier: identifier,
                source: source)
            if let explicitTitle = value("--title", in: arguments),
                !explicitTitle.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
            {
                metadata.setTitle(explicitTitle, from: .observed)
            }
            let result = services.coverService.resolve(
                for: metadata, into: output)
            print("cover=\(result.cover?.source.rawValue ?? "none")")
            if let cover = result.cover {
                print("file=\(cover.fileURL.path)")
                print("bytes=\(cover.byteCount)")
                print("mediaType=\(cover.mediaType)")
            }
            print("title=\(metadata.title ?? "")")
            if let original = metadata.original {
                print(originalLine(original))
            } else {
                print("original=unknown")
            }
            for warning in metadata.warnings + result.warnings {
                print("warning: \(warning)")
            }
            if result.cover == nil { exit(1) }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func original(_ arguments: [String]) {
        do {
            let availability: OriginalAvailability
            if let path = value("--path", in: arguments) {
                let url = URL(fileURLWithPath: path)
                let asset = BooksAsset.load(
                    assetID: url.lastPathComponent, path: url,
                    contentType: contentType(for: url))
                availability = OriginalDetector.books(asset: asset)
            } else if let asin = value("--asin", in: arguments) {
                switch sourceValue(arguments) {
                case .kindle:
                    availability = OriginalDetector.kindle(
                        asin: asin, paths: KindlePaths.standard())
                case .appleBooks:
                    let asset = try BooksAssetReader(
                        paths: booksPaths(arguments)
                    ).asset(for: asin)
                    availability = OriginalDetector.books(asset: asset)
                }
            } else {
                usage()
                exit(2)
            }
            print(originalLine(availability))
            if arguments.contains("--copy") {
                guard availability.isAvailable else { exit(1) }
                guard let kind = availability.kind else { exit(1) }
                let output = URL(fileURLWithPath: value(
                    "--out", in: arguments) ?? checkDirectory("original"))
                let copied = try OriginalService.copy(
                    availability, into: output,
                    destinationName: OriginalService.destinationName(
                        for: kind, in: output))
                print("copied=\(copied.url.path)")
                print("bytes=\(copied.bytes)")
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func printAsset(_ asset: BooksAsset) {
        print("asset=\(asset.assetID)")
        print("contentType=\(asset.contentType.rawValue)")
        print("pathKind=\(asset.pathKind.rawValue)")
        print("path=\(asset.path?.path ?? "")")
        switch asset.drm {
        case .clear:
            print("drm=clear")
        case .protected(let reason):
            print("drm=protected")
            print("drmReason=\(reason)")
        case .unknown(let reason):
            print("drm=unknown")
            print("drmReason=\(reason)")
        }
        print("dataless=\(asset.isDataless)")
        if let package = asset.package {
            print("title=\(package.title ?? "")")
            print("author=\(package.creators.joined(separator: ", "))")
            print("publisher=\(package.publisher ?? "")")
            print("language=\(package.language ?? "")")
            print("publishedDate=\(package.publishedDate ?? "")")
            print("identifier=\(package.identifier ?? "")")
            print("cover=\(package.coverImageURL?.path ?? "none")")
        }
        print(originalLine(OriginalDetector.books(asset: asset)))
        for warning in asset.warnings {
            print("warning: \(warning)")
        }
    }

    private static func originalLine(
        _ availability: OriginalAvailability
    ) -> String {
        switch availability {
        case .available(let kind, let url):
            return "original=available kind=\(kind.rawValue) path=\(url.path)"
        case .protected(let reason):
            return "original=protected reason=\(reason)"
        case .missing:
            return "original=missing"
        }
    }

    private static func contentType(for url: URL) -> BooksAssetContentType {
        switch url.pathExtension.lowercased() {
        case "epub": .epub
        case "pdf": .pdf
        default: .unknown
        }
    }

    /// The CLI's short provider names, mapped to the settings' cases.
    private enum AIProviderOption: String, CaseIterable {
        case claude
        case codex
        case http
        case apple

        var settingsValue: AIProviderKind {
            switch self {
            case .claude: .claudeCLI
            case .codex: .codexCLI
            case .http: .http
            case .apple: .appleOnDevice
            }
        }
    }

    /// Kindle only when `--source` is absent. An unknown value is a typo, not
    /// a request to capture the other reader.
    private static func sourceValue(_ arguments: [String]) -> BookSource {
        guard let raw = value("--source", in: arguments)?.lowercased() else {
            return .kindle
        }
        switch raw {
        case "kindle":
            return .kindle
        case "books", "applebooks", "apple-books", "apple":
            return .appleBooks
        default:
            print(
                "error: unknown --source '\(raw)'. Use kindle or applebooks.")
            exit(2)
        }
    }

    private static func booksPaths(_ arguments: [String]) -> BooksPaths {
        if let container = value("--container", in: arguments) {
            return BooksPaths(container: URL(fileURLWithPath: container))
        }
        return .standard()
    }

    private static func resolveBook(
        asin: String?, source: BookSource, archive: Archive
    ) throws -> Book? {
        guard let asin else { return nil }
        if let found = BookLookup.book(
            asin: asin, source: source, in: try archive.books())
        {
            return found
        }
        return Book(
            asin: asin, title: "", author: "", bookType: 10,
            readState: 0, source: source)
    }

    private static func checkDirectory(_ name: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "TsundokuExports/\(name)-check").path
    }

    private static func cropValue(
        _ flag: String, _ arguments: [String]
    ) -> Int? {
        let indices = arguments.indices.filter { arguments[$0] == flag }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1, indices[0] + 1 < arguments.count,
            let value = Int(arguments[indices[0] + 1]),
            (0...PageCrop.maximumPoints).contains(value)
        else {
            print(
                "error: \(flag) needs one integer from 0 to "
                    + "\(PageCrop.maximumPoints)")
            exit(1)
        }
        return value
    }

    /// One flag, exactly one value. A repeated flag is ambiguous and a value
    /// that looks like another option means the value was forgotten; both are
    /// usage errors rather than a silent default.
    private static func value(_ flag: String, in arguments: [String])
        -> String?
    {
        let indices = arguments.indices.filter { arguments[$0] == flag }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1, indices[0] + 1 < arguments.count,
            !arguments[indices[0] + 1].hasPrefix("--")
        else {
            print(
                "error: \(flag) needs exactly one value and may appear once")
            exit(2)
        }
        return arguments[indices[0] + 1]
    }

    /// Prints the local text index the companion uses: a capture's chapters
    /// and page match, or a non-DRM EPUB's navigation.
    private static func contextIndex(_ arguments: [String]) {
        let liveText: String?
        if let textPath = value("--text", in: arguments) {
            do {
                liveText = try String(
                    contentsOfFile: textPath, encoding: .utf8)
            } catch {
                print("error: cannot read --text file: \(error)")
                exit(1)
            }
        } else {
            liveText = nil
        }
        do {
            if let epub = value("--epub", in: arguments) {
                let index = try EPUBBookIndex(
                    epubDirectory: URL(fileURLWithPath: epub))
                print("epub chapters=\(index.chapters.count)")
                for chapter in index.chapters.prefix(40) {
                    print("  \(chapter.title) [\(chapter.text.count) chars]")
                }
                if let liveText {
                    print(
                        "match chapter="
                            + (index.chapter(containing: liveText) ?? "none"))
                }
                return
            }
            // Skip each option and its value; the first bare argument is the
            // capture directory, never the file named after --text.
            var positional: [String] = []
            var cursor = 0
            while cursor < arguments.count {
                let argument = arguments[cursor]
                if argument == "--text" || argument == "--epub" {
                    cursor += 2
                    continue
                }
                if argument.hasPrefix("--") {
                    cursor += 1
                    continue
                }
                positional.append(argument)
                cursor += 1
            }
            guard let directory = positional.first else {
                print("context-index needs a capture directory or --epub")
                exit(2)
            }
            let index = try BookTextIndex.load(
                directory: URL(fileURLWithPath: directory))
            print(
                "capture pages=\(index.pages.count) "
                    + "chapters=\(index.chapters.count) "
                    + "fingerprint=\(index.fingerprint)")
            for mark in index.chapters.prefix(60) {
                print("  page \(mark.page): \(mark.title)")
            }
            if let liveText {
                if let match = index.match(pageText: liveText) {
                    print(
                        "match page=\(match.page) "
                            + "chapter=\(match.chapter ?? "none")")
                } else {
                    print("match none")
                }
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func usage() {
        print(
            """
            usage: tsundoku-cli <inspect|page|selection|cards|ask|capture|export|history|track|import|applebooks|clean-page|books-asset|cover|original> [options]
              selection
                  reads Kindle's current selection through its Copy action;
                  prints the character count only, exits 1 on a failed read
              cards
                  prints the card count and up to five card summaries
              ask --action explain|translate|summarize|ask|define
                  --question "…" --provider claude|codex|http|apple
                  [--model M] [--service deepseek|openai|ollama|…]
                  [--endpoint URL] (custom services only)
              capture --pages 5 --out ~/TsundokuExports [--clean-page]
                      [--page-size a4|display] [--font-size 5..9]
                      [--text-size -2..2]
                      [--crop-top PT] [--crop-bottom PT]
                      [--asin ASIN] [--no-cover] [--no-sidecars]
                      [--copy-original]
              clean-page status|begin|recover
              page-setup status|recover
              export --format json|markdown|csv --provenance mine|popular|system
                     --source kindle|applebooks
              track --asin B0HH6TM91Q --seconds 6
              import --container ~/TsundokuImports/air
              applebooks [--container PATH] [--read-only]
              books-asset --asin ID | --path PATH [--container PATH]
              cover --asin ID [--source kindle|books] [--title TITLE]
                    [--out DIR]
              original --asin ID [--source kindle|books] [--out DIR] [--copy]
                       | --path PATH
              context-index CAPTURE_DIR [--text FILE]
                       | --epub EPUB_DIR [--text FILE]
            """)
    }
}
