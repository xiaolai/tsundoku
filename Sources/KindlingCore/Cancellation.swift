import Foundation

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        value = false
        lock.unlock()
    }

    public var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
