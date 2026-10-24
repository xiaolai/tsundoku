import Darwin
import Foundation

/// Best-effort self-registration, invoked only by the explicit access action.
/// This is an undocumented SPI: resolve it at runtime and retain the ordinary
/// Settings/manual-add recovery path. A response never means access is granted.
public enum FullDiskAccessListingRequest {
    public enum Outcome: String, Sendable {
        case responded, submittedWithoutResponse, unavailable
    }

    public static func request() async -> Outcome {
        await request(timeout: 2) { completion in
            guard let api else { return false }
            api.call("kTCCServiceSystemPolicyAllFiles" as CFString, nil) { _ in completion() }
            return true
        }
    }

    // The system retains this block after returning. Omitting @escaping causes
    // Swift's non-escaping-block runtime check to trap after the request.
    typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    // Keep the library loaded for the lifetime of any outstanding system block.
    private final class API: @unchecked Sendable {
        let call: RequestFunction
        init?() {
            guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
                  let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
            call = unsafeBitCast(symbol, to: RequestFunction.self)
        }
    }
    private static let api = API()

    static func request(timeout: TimeInterval,
        invoke: @escaping @Sendable (@escaping @Sendable () -> Void) -> Bool) async -> Outcome {
        await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                if !invoke({ completion.finish(.responded) }) { completion.finish(.unavailable) }
            }
            // FDA may record the request without ever invoking its callback.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                completion.finish(.submittedWithoutResponse)
            }
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?
        init(_ continuation: CheckedContinuation<Outcome, Never>) { self.continuation = continuation }
        func finish(_ outcome: Outcome) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: outcome)
        }
    }
}
