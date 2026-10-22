import Foundation
import Testing

@testable import TsundokuCore

private final class FakePanel: PopularHighlightsPanel, @unchecked Sendable {
    var value: Bool
    var failSet = false
    var failStateOnceAfterSet = false
    private var failStateOnce = false
    private var armedOnce = false
    var setCalls = 0
    var stateCalls = 0

    init(_ value: Bool) { self.value = value }

    func state() throws -> Bool {
        stateCalls += 1
        if failStateOnce {
            failStateOnce = false
            throw CleanPageError.stateUnreadable
        }
        return value
    }

    func set(_ on: Bool) throws {
        setCalls += 1
        if failSet { throw CleanPageError.toggleFailed(expected: on, actual: value) }
        value = on
        if failStateOnceAfterSet, !armedOnce {
            armedOnce = true
            failStateOnce = true
        }
    }
}

@Suite("Clean page guard")
struct CleanPageTests {
    private func journal() -> CleanPageJournal {
        CleanPageJournal(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "tsundoku-clean-\(UUID().uuidString).json"))
    }

    @Test("an on state is turned off and restored")
    func offAndRestore() throws {
        let panel = FakePanel(true)
        let journal = journal()
        defer { journal.clear() }
        let pageGuard = CleanPageGuard(panel: panel, journal: journal)
        let begin = try pageGuard.begin()
        #expect(begin.changed)
        #expect(panel.value == false)
        #expect(journal.load() == true)
        let restore = pageGuard.restore()
        #expect(restore.restored)
        #expect(panel.value == true)
        #expect(journal.load() == nil)
    }

    @Test("an already-off state is a no-op")
    func alreadyOff() throws {
        let panel = FakePanel(false)
        let journal = journal()
        let pageGuard = CleanPageGuard(panel: panel, journal: journal)
        let begin = try pageGuard.begin()
        #expect(!begin.changed)
        #expect(panel.setCalls == 0)
        #expect(journal.load() == nil)
        let restore = pageGuard.restore()
        #expect(restore.restored)
        #expect(panel.value == false)
    }

    @Test("a user turning it back on during the run is left alone")
    func userChange() throws {
        let panel = FakePanel(true)
        let journal = journal()
        defer { journal.clear() }
        let pageGuard = CleanPageGuard(panel: panel, journal: journal)
        _ = try pageGuard.begin()
        panel.value = true // the user turned it back on
        let restore = pageGuard.restore()
        #expect(restore.restored)
        #expect(restore.reason == "already restored")
        #expect(panel.value == true)
        #expect(journal.load() == nil)
    }

    @Test("a failed set restores the original state")
    func failedSet() throws {
        let panel = FakePanel(true)
        panel.failSet = true
        let journal = journal()
        defer { journal.clear() }
        let pageGuard = CleanPageGuard(panel: panel, journal: journal)
        #expect(throws: CleanPageError.self) {
            _ = try pageGuard.begin()
        }
        #expect(panel.value == true)
        #expect(journal.load() == nil)
    }

    @Test("a toggle that lands but fails verification is put back")
    func toggleLandedThenVerificationFailed() throws {
        let panel = FakePanel(true)
        panel.failStateOnceAfterSet = true
        let journal = journal()
        defer { journal.clear() }
        let pageGuard = CleanPageGuard(panel: panel, journal: journal)
        #expect(throws: CleanPageError.self) {
            _ = try pageGuard.begin()
        }
        // set(false) landed, then the verifying read failed; the guard must
        // have turned it back on and cleared the journal.
        #expect(panel.value == true)
        #expect(journal.load() == nil)
    }

    @Test("a journal left by a crash restores on launch")
    func crashRecovery() throws {
        let panel = FakePanel(false)
        let journal = journal()
        defer { journal.clear() }
        try journal.save(original: true)
        let outcome = CleanPageGuard.recoverIfNeeded(
            panel: panel, journal: journal)
        #expect(outcome?.restored == true)
        #expect(panel.value == true)
        #expect(journal.load() == nil)
    }

    @Test("an unobserved final state is not invented")
    func summaryFinalUnknown() {
        let begin = CleanPageOutcome(
            original: true, final: false, changed: true, restored: false,
            reason: nil)
        let restore = CleanPageOutcome(
            original: true, final: nil, changed: true, restored: false,
            reason: "the state could not be read")
        let summary = CleanPageSummary(
            policy: .hidePopularHighlights, begin: begin, restore: restore)
        #expect(summary.final == nil)
    }

    @Test("a failed restore keeps the journal")
    func failedRestore() throws {
        let panel = FakePanel(true)
        let journal = journal()
        defer { journal.clear() }
        let pageGuard = CleanPageGuard(panel: panel, journal: journal)
        _ = try pageGuard.begin()
        panel.failSet = true
        let outcome = pageGuard.restore()
        #expect(!outcome.restored)
        #expect(journal.load() == true)
    }
}
