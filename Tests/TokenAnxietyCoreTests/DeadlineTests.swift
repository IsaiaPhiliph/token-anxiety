import Foundation
import Testing
@testable import TokenAnxietyCore

@Suite struct DeadlineTests {
    @Test func answersInTime() async {
        let value = await withDeadline(5, onTimeout: { "late" }) { "done" }
        #expect(value == "done")
    }

    @Test func givesUpOnWorkThatNeverEnds() async {
        let start = Date()
        // A continuation nobody resumes: cancelling it does nothing, like a stuck provider.
        let value = await withDeadline(0.2, onTimeout: { "late" }) {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return "done"
        }
        #expect(value == "late")
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func processTimeoutDoesNotWaitForAToolThatIgnoresIt() async {
        let start = Date()
        // The shell ignores SIGTERM and its child keeps the pipes open.
        await #expect(throws: ProviderError.self) {
            try await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; sleep 4"], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
