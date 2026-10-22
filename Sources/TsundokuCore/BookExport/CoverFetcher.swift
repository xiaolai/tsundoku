import Foundation

public enum CoverFetchError: Error, CustomStringConvertible, Sendable {
    case status(Int)
    case tooLarge(Int)
    case timedOut
    case empty
    case transport(String)

    public var description: String {
        switch self {
        case .status(let code):
            "the cover server answered HTTP \(code)"
        case .tooLarge(let bytes):
            "the cover is \(bytes) bytes, over the configured limit"
        case .timedOut:
            "the cover request timed out"
        case .empty:
            "the cover response was empty"
        case .transport(let message):
            "the cover request failed: \(message)"
        }
    }
}

/// A synchronous cover fetch. Injectable so tests never touch the network.
public protocol CoverDataFetching: Sendable {
    func fetch(_ url: URL, timeout: TimeInterval, byteLimit: Int) throws
        -> Data
}

public struct URLSessionCoverFetcher: CoverDataFetching {
    private let configuration: @Sendable () -> URLSessionConfiguration

    public init(
        configuration: @escaping @Sendable () -> URLSessionConfiguration = {
            URLSessionConfiguration.ephemeral
        }
    ) {
        self.configuration = configuration
    }

    public func fetch(
        _ url: URL, timeout: TimeInterval, byteLimit: Int
    ) throws -> Data {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            // The absolute deadline is the semaphore below; the request
            // timeout is slightly later so the deadline, not URLSession's
            // idle timer, is what a slow server hits.
            timeoutInterval: timeout + 1)
        request.httpMethod = "GET"
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let semaphore = DispatchSemaphore(value: 0)
        let accumulator = CoverFetchAccumulator(
            byteLimit: byteLimit, semaphore: semaphore)
        let session = URLSession(
            configuration: configuration(), delegate: accumulator,
            delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            throw CoverFetchError.timedOut
        }
        session.finishTasksAndInvalidate()
        guard let result = accumulator.resultValue else {
            throw CoverFetchError.transport("the request did not finish")
        }
        return try result.get()
    }
}

/// Counts bytes as they arrive and cancels the task at the limit, so an
/// oversized or trickling response never becomes a large in-memory buffer.
private final class CoverFetchAccumulator: NSObject, URLSessionDataDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let byteLimit: Int
    private let semaphore: DispatchSemaphore
    private var data = Data()
    private var result: Result<Data, Error>?
    private var signalled = false

    init(byteLimit: Int, semaphore: DispatchSemaphore) {
        self.byteLimit = byteLimit
        self.semaphore = semaphore
        super.init()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse,
            !(200..<300).contains(http.statusCode)
        {
            finish(.failure(CoverFetchError.status(http.statusCode)))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(byteLimit) {
            finish(
                .failure(
                    CoverFetchError.tooLarge(
                        Int(response.expectedContentLength))))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        if result != nil {
            lock.unlock()
            return
        }
        self.data.append(data)
        let over = self.data.count > byteLimit
        if over {
            result = .failure(CoverFetchError.tooLarge(self.data.count))
        }
        lock.unlock()
        if over { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        if result == nil {
            if let error {
                result = .failure(
                    CoverFetchError.transport(error.localizedDescription))
            } else if data.isEmpty {
                result = .failure(CoverFetchError.empty)
            } else {
                result = .success(data)
            }
        }
        let shouldSignal = !signalled
        signalled = true
        lock.unlock()
        if shouldSignal { semaphore.signal() }
    }

    var resultValue: Result<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private func finish(_ value: Result<Data, Error>) {
        lock.lock()
        if result == nil { result = value }
        lock.unlock()
    }
}
