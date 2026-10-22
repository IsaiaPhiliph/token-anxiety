import Foundation

/// Reading the services' JSONL logs: whole lines from a byte offset, cheap byte
/// searches before any JSON is parsed, and the few values that need to be fast.
enum LogLines {
    /// Calls `body` with each complete line from `offset` on, and returns the offset just
    /// past the last newline: a line still being written is left for the next read.
    static func read(_ url: URL, from offset: UInt64, chunkSize: Int = 4 << 20,
                     body: (UnsafeRawBufferPointer) throws -> Void) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var consumed = offset
        var pending = Data()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            pending.append(chunk)
            let used = try pending.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var start = 0
                while start < raw.count,
                      let newline = memchr(base + start, 0x0A, raw.count - start) {
                    let end = base.distance(to: newline)
                    if end > start { try body(UnsafeRawBufferPointer(rebasing: raw[start..<end])) }
                    start = end + 1
                }
                return start
            }
            consumed += UInt64(used)
            pending.removeSubrange(0..<used)
        }
        return consumed
    }

    static func contains(_ line: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = line.baseAddress else { return false }
        return memmem(base, line.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    /// "2026-10-22T14:05:31.123Z" without a date formatter; anything else goes to `DateParsing`.
    static func date(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,
              bytes[13] == 0x3A, bytes[16] == 0x3A, bytes.last == 0x5A else { return DateParsing.iso8601(text) }
        func number(_ from: Int, _ count: Int) -> Int? {
            var value = 0
            for byte in bytes[from..<from + count] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day) else { return DateParsing.iso8601(text) }
        var fraction = 0.0
        if bytes.count > 21, bytes[19] == 0x2E {
            let digits = bytes[20..<(bytes.count - 1)]
            guard digits.count <= 9, let value = number(20, digits.count) else { return DateParsing.iso8601(text) }
            fraction = Double(value) / pow(10, Double(digits.count))
        } else if bytes.count != 20 {
            return DateParsing.iso8601(text)
        }
        // Days from the civil date (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: seconds)
    }
}

/// FNV-1a: a hash that stays the same between launches, for the keys saved to disk.
enum StableHash {
    static func of(_ parts: String...) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for (index, part) in parts.enumerated() {
            if index > 0 { hash = (hash ^ 0x1F) &* 0x100_0000_01b3 }
            for byte in part.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        }
        return hash
    }
}

/// Decodes a field leniently: a value of the wrong type reads as nil instead of
/// failing the whole line (logs have had a number where a string was expected).
extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    func lenientInt(_ key: Key) -> Int? {
        if let value = lenient(Int.self, key) { return value }
        return lenient(Double.self, key).flatMap { $0.isFinite ? Int($0) : nil }
    }
}
