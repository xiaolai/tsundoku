import Foundation
import TsundokuCore

/// Runs one library import and reports everything the model publishes.
///
/// The coordinator owns reading, validating and writing each store; the model
/// keeps only the presentation state and the wording of the finished result.
/// Both sources go through the same path, so a change to totals, health or
/// failure collection cannot reach one branch and miss the other.
@MainActor
struct LibraryImportCoordinator {
    struct Source {
        let source: BookSource
        /// Health text when the store is absent. Absence is not a failure.
        let missingMessage: String
        let read: @Sendable () throws
            -> (books: [Book], annotations: [Annotation])?
    }

    struct Outcome {
        var books = 0
        var annotations = 0
        var user = 0
        var lastImportDate: Date?
        var importedSources: [String] = []
        var committedSources = Set<BookSource>()
        var failures: [LibraryImportFailure] = []
        var health: [BookSource: String] = [:]
        var lastImportBySource: [BookSource: Date] = [:]
    }

    private struct Imported {
        let books: Int
        let annotations: Int
        let user: Int
        let importedAt: Date
    }

    static func run(
        _ sources: [Source], archive: Archive
    ) async -> Outcome {
        var outcome = Outcome()
        for source in sources {
            do {
                let result = try await importOne(source, archive: archive)
                outcome.health[source.source] = result.health
                guard let imported = result.imported else { continue }
                outcome.books += imported.books
                outcome.annotations += imported.annotations
                outcome.user += imported.user
                outcome.lastImportDate = max(
                    outcome.lastImportDate ?? imported.importedAt,
                    imported.importedAt)
                outcome.importedSources.append(source.source.displayName)
                outcome.committedSources.insert(source.source)
                outcome.lastImportBySource[source.source] =
                    imported.importedAt
            } catch {
                outcome.failures.append(
                    LibraryImportFailure(
                        source: source.source, error: error))
                outcome.health[source.source] = "Import failed: \(error)"
            }
        }
        return outcome
    }

    /// Owns the import task, re-entry guard and queued follow-up. The model
    /// supplies sources and publishes the outcome; it no longer coordinates
    /// the workflow these flags used to encode.
    @MainActor
    final class Session {
        struct Run {
            let sources: [Source]
            let archive: Archive
            let announce: Bool
            let accessGeneration: Int?
        }

        private var task: Task<Void, Never>?
        private var makeRun: (@MainActor () -> Run?)?
        private var onOutcome:
            (@MainActor (LibraryImportCoordinator.Outcome, Run) -> Void)?
        private var onFinish: (@MainActor () -> Void)?
        private var requestedAgain = false

        var isRunning: Bool { task != nil }

        func request(
            makeRun: @escaping @MainActor () -> Run?,
            onOutcome: @escaping @MainActor (
                LibraryImportCoordinator.Outcome, Run
            ) -> Void,
            onFinish: @escaping @MainActor () -> Void
        ) {
            self.makeRun = makeRun
            self.onOutcome = onOutcome
            self.onFinish = onFinish
            if task != nil {
                requestedAgain = true
                return
            }
            start()
        }

        /// Awaits the active run and every run queued behind it.
        func waitForCompletion() async {
            while let task { await task.value }
        }

        private func start() {
            guard task == nil, let makeRun, let run = makeRun() else {
                return
            }
            task = Task { [weak self] in
                let outcome = await LibraryImportCoordinator.run(
                    run.sources, archive: run.archive)
                guard let self else { return }
                self.onOutcome?(outcome, run)
                self.task = nil
                let again = self.requestedAgain
                self.requestedAgain = false
                self.onFinish?()
                if again { self.start() }
            }
        }
    }

    private static func importOne(
        _ source: Source, archive: Archive
    ) async throws -> (imported: Imported?, health: String) {
        guard let data = try await Task.detached(
            operation: source.read).value
        else {
            return (nil, source.missingMessage)
        }
        let imported = try await Task.detached {
            try archive.importAll(
                books: data.books, annotations: data.annotations)
        }.value
        // The meta key is presentation-independent bookkeeping; keeping it
        // here means both sources record it the same way.
        try? archive.setMeta(
            "last_import_source_\(source.source.displayName)",
            ISO8601DateFormatter().string(from: imported.importedAt))
        let health =
            "Imported \(imported.books.formatted()) books · "
            + TsundokuFormat.relative(imported.importedAt)
        return (
            Imported(
                books: imported.books, annotations: imported.annotations,
                user: imported.userAnnotations,
                importedAt: imported.importedAt),
            health)
    }
}
