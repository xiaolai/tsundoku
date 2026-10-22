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
        switch command {
        case "inspect":
            inspect()
        case "page":
            page()
        case "ask":
            await ask(Array(arguments.dropFirst()))
        case "capture":
            capture(Array(arguments.dropFirst()))
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
            let snapshot = try KindleSnapshot.capture(paths)
            let books = try KindleReader.readBooks(snapshot)
            let states = try KindleReader.readReadStates(snapshot)
            let storage = try KindleReader.readAnnotationStorage(
                snapshot, books: books)
            let ksdk = try KindleReader.readKSDK(snapshot, books: books)
            snapshot.cleanup()
            let annotations = storage + ksdk
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

    private static func ask(_ arguments: [String]) async {
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
            if let provider = value("--provider", in: arguments) {
                switch provider {
                case "codex": settings.provider = .codexCLI
                case "http": settings.provider = .http
                case "apple": settings.provider = .appleOnDevice
                case "claude": settings.provider = .claudeCLI
                default: break
                }
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
            let request = AIRequest(
                action: action, pageText: live.text,
                bookTitle: live.title, question: question,
                language: settings.language)
            let answer = try await AIService.answer(
                for: request, settings: settings)
            print("provider=\(answer.provider)")
            print(answer.text)
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func capture(_ arguments: [String]) {
        do {
            let archive = try Archive.standard()
            let book: Book? = nil
            let pages = Int(value("--pages", in: arguments) ?? "5") ?? 5
            let outputPath =
                value("--out", in: arguments)
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("TsundokuExports").path
            let output = URL(fileURLWithPath: outputPath)
                .appendingPathComponent(
                    "capture-\(Int(Date().timeIntervalSince1970))")
            let engine = CaptureEngine(archive: archive)
            let result = try engine.capture(
                book: book, pageLimit: pages, output: output,
                progress: { progress in
                    print(
                        "page \(progress.page)"
                            + (progress.pageLimit.map {
                                "/\($0)"
                            } ?? "")
                            + " · \(progress.message)")
                },
                isCancelled: { false })
            print("pdf=\(result.pdf.path)")
            print("pages=\(result.pages)")
            print("title=\(result.title)")
            print("directory=\(result.directory.path)")
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func export(_ arguments: [String]) {
        do {
            let archive = try Archive.standard()
            let format =
                AnnotationExportFormat(
                    rawValue: value("--format", in: arguments) ?? "json")
                ?? .json
            let path =
                value("--out", in: arguments)
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "tsundoku-annotations.\(format.fileExtension)").path
            let provenance: AnnotationProvenance?
            switch value("--provenance", in: arguments) {
            case "mine": provenance = .user
            case "popular": provenance = .amazon
            case "system": provenance = .system
            default: provenance = nil
            }
            let source: BookSource?
            switch value("--source", in: arguments)?.lowercased() {
            case "kindle": source = .kindle
            case "applebooks", "apple-books", "apple", "books":
                source = .appleBooks
            default: source = nil
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
            let asin = value("--asin", in: arguments) ?? ""
            let seconds =
                Double(value("--seconds", in: arguments) ?? "6") ?? 6
            let logger = SessionLogger(archive: archive)
            logger.setBook(asin.isEmpty ? nil : asin)
            logger.start()
            Thread.sleep(forTimeInterval: seconds)
            logger.stop()
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
            let paths: BooksPaths
            if let container = value("--container", in: arguments) {
                paths = BooksPaths(
                    container: URL(fileURLWithPath: container))
            } else {
                paths = BooksPaths.standard()
            }
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

    private static func value(_ flag: String, in arguments: [String])
        -> String?
    {
        guard let index = arguments.firstIndex(of: flag),
            arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private static func usage() {
        print(
            """
            usage: tsundoku-cli <inspect|page|ask|capture|export|history|track|import|applebooks> [options]
              ask --action explain|translate|summarize|ask|define
                  --question "…" --provider claude|codex|http|apple
              capture --pages 5 --out ~/TsundokuExports
              export --format json|markdown|csv --provenance mine|popular|system
                     --source kindle|applebooks
              track --asin B0HH6TM91Q --seconds 6
              import --container ~/TsundokuImports/air
              applebooks [--container PATH] [--read-only]
            """)
    }
}
