import Foundation

/// A lenient JSON tree. The usage endpoints are undocumented and change shape
/// now and then, so providers read them through this instead of strict
/// `Decodable` structs: a missing or renamed field degrades to `nil`.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int64(value)) : String(value)
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    public var int: Int? { double.map { Int($0) } }

    public var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let value): ["true", "1", "yes"].contains(value.lowercased())
        default: nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Depth-first search for the first value stored under `key`, for payloads
    /// whose nesting is not stable between versions.
    public func first(key: String) -> JSONValue? {
        switch self {
        case .object(let object):
            if let value = object[key] { return value }
            for value in object.values {
                if let found = value.first(key: key) { return found }
            }
            return nil
        case .array(let array):
            for value in array {
                if let found = value.first(key: key) { return found }
            }
            return nil
        default:
            return nil
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public enum DateParsing {
    /// Parses ISO 8601 dates as the services send them: with or without
    /// fractional seconds (Anthropic sends six digits), `Z` or `+00:00`.
    public static func iso8601(_ string: String?) -> Date? {
        guard let raw = string?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let text = trimFraction(raw)
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        return nil
    }

    /// Unix timestamps in seconds or milliseconds.
    public static func unix(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    /// A date from a JSON value that may be an ISO string or a unix number.
    public static func date(_ value: JSONValue?) -> Date? {
        switch value {
        case .number(let number): unix(number)
        case .string(let string): iso8601(string) ?? unix(Double(string))
        default: nil
        }
    }

    /// Keeps at most three fractional digits, which is what the parser accepts.
    private static func trimFraction(_ text: String) -> String {
        guard let tIndex = text.firstIndex(of: "T"),
              let dot = text[tIndex...].firstIndex(of: ".") else { return text }
        let digitsStart = text.index(after: dot)
        var digitsEnd = digitsStart
        while digitsEnd < text.endIndex, text[digitsEnd].isNumber { digitsEnd = text.index(after: digitsEnd) }
        let digits = text[digitsStart..<digitsEnd]
        guard digits.count > 3 else { return text }
        return String(text[..<digitsStart]) + digits.prefix(3) + String(text[digitsEnd...])
    }
}
