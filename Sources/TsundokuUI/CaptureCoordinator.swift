import Foundation
import TsundokuCore

/// Runs one capture off the main actor.
///
/// The request fixes every input before the engine starts, so a settings
/// change during the capture cannot alter half of it; the model keeps only
/// the phase, progress and result it publishes.
@MainActor
enum CaptureCoordinator {
    struct Request: Sendable {
        let archive: Archive
        let book: Book?
        let kind: ReaderKind
        let pageLimit: Int?
        let output: URL
        let cleanPage: CleanPagePolicy
        let pageSetup: PageSetupRequest
        let booksPageSetup: PageSetupRequest
        let bundleOptions: CaptureBundleOptions
        let cancellation: CancellationFlag
        let manual: ManualCaptureConfiguration?
        let resume: Bool

        func run(
            progress: @escaping @Sendable (CaptureProgress) -> Void
        ) throws -> CaptureResult {
            let engine = CaptureEngine(archive: archive)
            if let manual {
                return try engine.captureManual(
                    book: book, pageLimit: pageLimit, output: output,
                    configuration: manual, progress: progress,
                    isCancelled: { cancellation.isSet },
                    bundle: CaptureBundleRequest(options: bundleOptions),
                    resume: resume)
            }
            return try engine.capture(
                book: book,
                kind: kind,
                pageLimit: pageLimit,
                output: output,
                progress: progress,
                isCancelled: { cancellation.isSet },
                cleanPage: kind == .kindle ? cleanPage : .asDisplayed,
                pageSetup: kind == .kindle ? pageSetup : booksPageSetup,
                bundle: CaptureBundleRequest(options: bundleOptions))
        }
    }

    static func run(
        _ request: Request,
        progress: @escaping @Sendable (CaptureProgress) -> Void
    ) async throws -> CaptureResult {
        try await Task.detached {
            try request.run(progress: progress)
        }.value
    }
}

/// Owns one capture's task and its cancellation flag.
///
/// The model publishes phase, progress and result; it no longer holds the
/// task handle or the flag, so a second start, a cancel and a finish cannot
/// race through separate pieces of state.
@MainActor
final class CaptureSession {
    private var task: Task<Void, Never>?
    private var flag: CancellationFlag?

    var isRunning: Bool { task != nil }

    func start(
        _ request: CaptureCoordinator.Request,
        progress: @escaping @MainActor (CaptureProgress) -> Void,
        completion: @escaping @MainActor (Result<CaptureResult, Error>) -> Void
    ) {
        guard task == nil else { return }
        flag = request.cancellation
        task = Task { [weak self] in
            let result: Result<CaptureResult, Error>
            do {
                let captured = try await CaptureCoordinator.run(request) {
                    value in
                    Task { @MainActor in progress(value) }
                }
                result = .success(captured)
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.task = nil
            self.flag = nil
            completion(result)
        }
    }

    /// Cooperative cancellation: the engine restores the reader before it
    /// returns. The task stays registered until that finish arrives.
    func cancel() {
        flag?.set()
    }
}
