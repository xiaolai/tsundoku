import Foundation
import Testing
@testable import TsundokuCore

struct FullDiskAccessListingRequestTests {
    @Test func retainedSystemBlockOutlivesTheCFunctionCall() async {
        let system: FullDiskAccessListingRequest.RequestFunction = { _, _, callback in
            let retained = RetainedBlock(callback)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { retained.callback(false) }
        }
        #expect(await FullDiskAccessListingRequest.request(timeout: 1, invoke: { done in
            system("fixture-service" as CFString, nil) { _ in done() }
            return true
        }) == .responded)
    }

    @Test func unavailableDoesNotWaitForTimeout() async {
        #expect(await FullDiskAccessListingRequest.request(timeout: 1, invoke: { _ in false }) == .unavailable)
    }
    @Test func missingCallbackIsBounded() async {
        #expect(await FullDiskAccessListingRequest.request(timeout: 0.01, invoke: { _ in true }) == .submittedWithoutResponse)
    }
    @Test func repeatedCallbackResumesOnlyOnce() async {
        #expect(await FullDiskAccessListingRequest.request(timeout: 1, invoke: { done in
            done(); done(); return true
        }) == .responded)
    }
    @Test func lateCallbackAfterTimeoutIsIgnored() async {
        let callback = Callback()
        #expect(await FullDiskAccessListingRequest.request(timeout: 0.01, invoke: { done in
            callback.store(done)
            return true
        }) == .submittedWithoutResponse)
        callback.fire()
        callback.fire()
    }

    private final class Callback: @unchecked Sendable {
        let lock = NSLock()
        var value: (@Sendable () -> Void)?
        func store(_ value: @escaping @Sendable () -> Void) { lock.withLock { self.value = value } }
        func fire() { lock.withLock { value }?() }
    }

    private struct RetainedBlock: @unchecked Sendable {
        let callback: @convention(block) (Bool) -> Void
        init(_ callback: @escaping @convention(block) (Bool) -> Void) { self.callback = callback }
    }
}
