import Foundation
import Observation
import TokenAnxietyCore

/// The local usage history (Claude Code's and Codex's logs) for the app: brings the
/// ledger up to date after each refresh and publishes it, with the first pass's progress.
@MainActor @Observable
final class UsageLedgerStore {
    private(set) var ledger = UsageLedger()
    /// While the logs are being read; nil the rest of the time.
    private(set) var progress: LedgerIndexer.Progress?
    private(set) var lastUpdate: Date?

    /// Called with each new ledger.
    @ObservationIgnored var onUpdate: ((UsageLedger) -> Void)?
    @ObservationIgnored private let indexer: LedgerIndexer?
    @ObservationIgnored private var running = false

    /// In demo mode nothing is read or written.
    init(demo: Bool) {
        indexer = demo ? nil : LedgerIndexer(directory: LedgerIndexer.defaultDirectory)
        if demo {
            ledger = Demo.ledger()
            lastUpdate = Date()
        }
    }

    func update() {
        guard let indexer, !running else { return }
        running = true
        Task {
            let ledger = await indexer.update { progress in
                // Only a pass with real work shows its progress.
                guard progress.bytesTotal > 64 << 20 else { return }
                Task { @MainActor in self.progress = progress.fraction < 1 ? progress : nil }
            }
            self.ledger = ledger
            onUpdate?(ledger)
            progress = nil
            lastUpdate = Date()
            running = false
        }
    }
}
