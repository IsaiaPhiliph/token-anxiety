import Foundation

/// Keeps the `UsageLedger` up to date with the services' local logs.
///
/// Each file is read once: a checkpoint remembers how far it was read (size, modification
/// date, inode, offset), so a refresh only reads what was appended. The first pass over a
/// long history takes a few seconds and reports its progress. Work runs on a serial queue
/// of its own, never on the caller's thread.
///
/// Saved in one file, `usage.json` in `directory` (nil keeps everything in memory, as
/// `--print --stats` does), so the ledger and the checkpoints never disagree. Besides them
/// it holds the keys of every response counted, so a line copied into another file is not
/// counted twice, and the last few hours of responses, whose counts can still grow.
public final class LedgerIndexer: @unchecked Sendable {
    public struct Progress: Sendable, Equatable {
        public var bytesRead: Int64
        public var bytesTotal: Int64

        public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesRead) / Double(bytesTotal)) : 1 }
    }

    struct Checkpoint: Codable, Equatable {
        var size: UInt64
        var modified: Double
        var inode: UInt64
        var offset: UInt64
        var codex: CodexLogReader.FileState?
        /// How far the content was measured (Claude Code only; nil: not yet).
        var contentOffset: UInt64?
    }

    private let directory: URL?
    private let claudeRoots: [URL]
    private let codexHome: URL?
    private let names: ProjectNames
    private let queue = DispatchQueue(label: "TokenAnxiety.ledger", qos: .utility)

    // Touched only on `queue`.
    private var loaded = false
    private var ledger = UsageLedger()
    private var files: [String: Checkpoint] = [:]
    private var seen = Set<UInt64>()
    private var recent: [UInt64: UsageEvent] = [:]
    private var messageKeys: [String: UInt64] = [:]
    /// Tool call ids → tool names, to file the results that answer them.
    private var toolNames: [String: String] = [:]
    private var measuresContent = true
    private var skippedCompressed = 0

    /// Responses this recent may still be logged again with more output (Claude Code writes
    /// the final line seconds later; the margin covers a Mac that slept in between).
    static let growthWindow: TimeInterval = 6 * 3600

    public init(directory: URL?, claudeRoots: [URL] = ClaudeLogReader.roots(),
                codexHome: URL? = CodexLogReader.codexHome(), names: ProjectNames = ProjectNames()) {
        self.directory = directory
        self.claudeRoots = claudeRoots
        self.codexHome = codexHome
        self.names = names
    }

    /// Where the app keeps it: `~/Library/Application Support/TokenAnxiety/usage`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenAnxiety/usage", isDirectory: true)
    }

    /// Reads whatever the logs added since the last call and returns the ledger.
    public func update(now: Date = Date(), progress: (@Sendable (Progress) -> Void)? = nil) async -> UsageLedger {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.updateNow(now: now, progress: progress))
            }
        }
    }

    /// The ledger as saved, without reading the logs.
    public func current() async -> UsageLedger {
        await withCheckedContinuation { continuation in
            queue.async {
                self.loadIfNeeded()
                continuation.resume(returning: self.ledger)
            }
        }
    }

    /// Whether to measure the conversations' content too (`ContentReader`).
    public func setMeasuresContent(_ value: Bool) {
        queue.async { self.measuresContent = value }
    }

    /// `.jsonl.zst` files (compressed Codex history) seen but not read: macOS has no zstd.
    public var compressedFilesSkipped: Int { queue.sync { skippedCompressed } }

    // MARK: Reading the logs

    private struct Pending {
        var key: String
        var url: URL
        var provider: ProviderID
        var start: UInt64
        var contentStart: UInt64?
        var checkpoint: Checkpoint

        var bytes: Int64 {
            let size = checkpoint.size
            return Int64(size - start) + Int64(contentStart.map { size - $0 } ?? 0)
        }
    }

    private func updateNow(now: Date, progress: (@Sendable (Progress) -> Void)?) -> UsageLedger {
        loadIfNeeded()
        let started = Date()
        var pending: [Pending] = []
        var present = Set<String>()
        skippedCompressed = 0

        for root in claudeRoots {
            for url in Self.logFiles(in: root, compressed: &skippedCompressed) {
                plan(url, key: url.path, provider: .claude, into: &pending, present: &present)
            }
        }
        if let codexHome {
            for root in CodexLogReader.roots(codexHome: codexHome) {
                for url in Self.logFiles(in: root, compressed: &skippedCompressed) {
                    // Keyed by name: archiving moves the file, it does not make a new one.
                    plan(url, key: "codex/" + url.lastPathComponent, provider: .codex, into: &pending, present: &present)
                }
            }
        }

        let total = pending.reduce(Int64(0)) { $0 + $1.bytes }
        var done: Int64 = 0
        var reported: Int64 = 0
        progress?(Progress(bytesRead: 0, bytesTotal: total))
        var changed = files.keys.contains { !present.contains($0) }
        files = files.filter { present.contains($0.key) }

        for item in pending {
            var checkpoint = item.checkpoint
            do {
                switch item.provider {
                case .claude:
                    if item.start < checkpoint.size {
                        checkpoint.offset = try readClaude(item.url, from: item.start, now: now)
                    }
                    if let contentStart = item.contentStart, contentStart < checkpoint.size {
                        checkpoint.contentOffset = try readClaudeContent(item.url, from: contentStart)
                    }
                default:
                    var state = item.start == 0 ? CodexLogReader.FileState() : (checkpoint.codex ?? .init())
                    checkpoint.offset = try readCodex(item.url, from: item.start, state: &state, now: now)
                    checkpoint.codex = state
                }
                files[item.key] = checkpoint
                changed = true
            } catch {
                Log.debug("usage: could not read \(item.url.lastPathComponent): \(error.localizedDescription)")
            }
            done += item.bytes
            if done - reported > 16 << 20 {
                reported = done
                progress?(Progress(bytesRead: done, bytesTotal: total))
            }
        }
        if changed, let codexHome { readCodexTitles(codexHome) }
        progress?(Progress(bytesRead: total, bytesTotal: total))

        let cutoff = now.addingTimeInterval(-Self.growthWindow)
        let before = recent.count
        recent = recent.filter { $0.value.date >= cutoff }
        messageKeys = [:]
        if changed || recent.count != before { save() }
        Log.debug("usage: \(pending.count) files, \(total >> 10) KB read in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        return ledger
    }

    private func plan(_ url: URL, key: String, provider: ProviderID, into pending: inout [Pending], present: inout Set<String>) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return }
        present.insert(key)
        let size = UInt64(max(0, info.st_size))
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        let inode = UInt64(info.st_ino)
        let measured = provider == .claude && measuresContent
        var start: UInt64 = 0
        var contentStart: UInt64? = measured ? 0 : nil
        var codex: CodexLogReader.FileState?
        var contentOffset: UInt64?
        // A file that shrank or was replaced is read again from the start: the keys
        // already counted keep its old lines from counting twice.
        if let old = files[key], old.inode == inode, size >= old.offset {
            start = old.offset
            codex = old.codex
            contentOffset = old.contentOffset
            if measured { contentStart = min(old.contentOffset ?? 0, size) }
        }
        let tokensDone = start >= size
        let contentDone = contentStart.map { $0 >= size } ?? true
        guard !tokensDone || !contentDone else {
            files[key] = Checkpoint(size: size, modified: modified, inode: inode, offset: start, codex: codex,
                                    contentOffset: contentOffset)
            return
        }
        pending.append(Pending(key: key, url: url, provider: provider, start: start,
                               contentStart: contentDone ? nil : contentStart,
                               checkpoint: Checkpoint(size: size, modified: modified, inode: inode, offset: start,
                                                      codex: codex, contentOffset: contentOffset)))
    }

    static func logFiles(in root: URL, compressed: inout Int) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsPackageDescendants]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in walker {
            if url.pathExtension == "jsonl" {
                urls.append(url)
            } else if url.lastPathComponent.hasSuffix(".jsonl.zst") {
                compressed += 1
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func readClaude(_ url: URL, from offset: UInt64, now: Date) throws -> UInt64 {
        // `<session>.jsonl`, or `<session>/subagents/agent-x.jsonl` for a subagent.
        let parts = url.pathComponents
        let fileSession: String
        if parts.count >= 3, parts[parts.count - 2] == "subagents" {
            fileSession = parts[parts.count - 3]
        } else {
            fileSession = url.deletingPathExtension().lastPathComponent
        }
        return try LogLines.read(url, from: offset) { line in
            guard ClaudeLogReader.isCandidate(line), let parsed = ClaudeLogReader.parse(Data(line)) else { return }
            switch parsed {
            case .title(let session, let title, let custom):
                ledger.setTitle(title, provider: .claude, session: session, custom: custom)
            case .usage(let usage):
                var key = usage.dedupKey
                if let message = usage.messageID {
                    // A line without its requestId belongs to the one other line of that message.
                    if usage.requestID == nil, let known = messageKeys[message] {
                        key = known
                    } else if let key {
                        messageKeys[message] = key
                    }
                }
                let event = UsageEvent(provider: .claude, date: usage.date, session: usage.session ?? fileSession,
                                       project: names.name(for: usage.directory), branch: usage.branch,
                                       model: usage.model,
                                       tier: Pricing.tier(model: usage.model, inputSide: usage.counts.inputSide, fast: usage.fast),
                                       effort: usage.effort, agent: usage.agent, entrypoint: usage.entrypoint,
                                       counts: usage.counts)
                ingest(event, key: key, now: now)
            }
        }
    }

    private func readCodex(_ url: URL, from offset: UInt64, state: inout CodexLogReader.FileState, now: Date) throws -> UInt64 {
        let fileSession = Self.codexSession(fromFileName: url.lastPathComponent)
        var current = state
        let end = try LogLines.read(url, from: offset) { line in
            guard CodexLogReader.isCandidate(line),
                  let request = CodexLogReader.read(Data(line), state: &current) else { return }
            let thread = current.session ?? fileSession
            let model = current.model ?? "unknown"
            let event = UsageEvent(provider: .codex, date: request.date, session: current.parent ?? thread,
                                   project: names.name(for: current.directory), model: model,
                                   tier: Pricing.tier(model: model, inputSide: request.promptTokens, fast: false),
                                   effort: current.effort, agent: current.parent == nil ? nil : thread,
                                   entrypoint: nil, counts: request.counts)
            ingest(event, key: request.dedupKey, now: now)
        }
        state = current
        return end
    }

    /// "rollout-2026-05-27T12-50-46-019e690e-….jsonl" → "019e690e-…".
    static func codexSession(fromFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let parts = base.split(separator: "-")
        return parts.count > 7 ? parts.suffix(5).joined(separator: "-") : base
    }

    private func ingest(_ event: UsageEvent, key: UInt64?, now: Date) {
        guard let key else {
            ledger.add(event)
            return
        }
        if seen.contains(key) {
            // The same response again: count only what it grew by since.
            if let counted = recent[key], event.counts.total > counted.counts.total {
                var growth = counted
                growth.counts = counted.counts.growth(to: event.counts)
                growth.date = counted.date
                ledger.add(growth)
                recent[key]?.counts = event.counts
            }
            return
        }
        seen.insert(key)
        // Kept for the whole read (a first pass reads old responses with their later lines),
        // then only the last few hours.
        recent[key] = event
        ledger.add(event)
    }

    /// Content sizes, read apart from the tokens so a history read before can be measured later.
    private func readClaudeContent(_ url: URL, from offset: UInt64) throws -> UInt64 {
        try LogLines.read(url, from: offset) { line in
            guard ContentReader.isCandidate(line), let parsed = ContentReader.read(Data(line)) else { return }
            // Forked sessions copy lines with their uuid: measure each once.
            if let uuid = parsed.uuid, !seen.insert(StableHash.of("content", uuid)).inserted { return }
            if toolNames.count > 20_000 { toolNames = [:] } // calls whose results never came
            for (id, name) in parsed.toolCalls { toolNames[id] = name }
            var counts = parsed.counts
            for (id, characters) in parsed.results {
                counts.toolResults[ContentReader.toolName(toolNames.removeValue(forKey: id)), default: 0] += characters
            }
            ledger.addContent(counts, date: parsed.date)
        }
    }

    /// Thread names from `session_index.jsonl` (one `{"id", "thread_name"}` per line).
    private func readCodexTitles(_ codexHome: URL) {
        let url = codexHome.appendingPathComponent("session_index.jsonl")
        _ = try? LogLines.read(url, from: 0) { line in
            guard let json = try? JSONValue.parse(Data(line)), let id = json["id"]?.string,
                  let name = json["thread_name"]?.string?.trimmed, !name.isEmpty else { return }
            ledger.setTitle(name, provider: .codex, session: id, custom: true)
        }
    }

    // MARK: Saving

    private struct Store: Codable {
        var ledger: UsageLedger
        var files: [String: Checkpoint]
        var recent: [String: UsageEvent]
        /// `seen`, as little-endian 64-bit keys.
        var seen: Data
    }

    private var storeURL: URL? { directory?.appendingPathComponent("usage.json") }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = storeURL, let data = try? Data(contentsOf: url) else { return }
        do {
            let store = try JSONDecoder().decode(Store.self, from: data)
            ledger = store.ledger
            files = store.files
            recent = Dictionary(uniqueKeysWithValues: store.recent.compactMap { key, event in UInt64(key).map { ($0, event) } })
            seen = Set(Self.keys(from: store.seen))
        } catch {
            // Never lose history silently: keep the unreadable file aside and start over.
            Log.notice("usage: unreadable ledger (\(error.localizedDescription)), starting a new one")
            let aside = url.deletingLastPathComponent().appendingPathComponent("usage-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
        }
    }

    private func save() {
        guard let url = storeURL else { return }
        let store = Store(ledger: ledger, files: files,
                          recent: Dictionary(uniqueKeysWithValues: recent.map { (String($0.key), $0.value) }),
                          seen: Self.keyData(seen))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(store).write(to: url, options: .atomic)
        } catch {
            Log.notice("usage: could not save the ledger: \(error.localizedDescription)")
        }
    }

    static func keyData(_ keys: Set<UInt64>) -> Data {
        var data = Data(capacity: keys.count * 8)
        for key in keys.sorted() {
            withUnsafeBytes(of: key.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func keys(from data: Data) -> [UInt64] {
        stride(from: 0, to: data.count - data.count % 8, by: 8).map { offset in
            data[data.startIndex + offset ..< data.startIndex + offset + 8].withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
            }
        }
    }
}
