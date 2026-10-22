import Foundation
import os

/// Runs a command-line tool and collects its output, with a timeout.
public enum ProcessRunner {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data

        public var text: String { String(decoding: stdout, as: UTF8.self) }
        public var errorText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// GUI apps start with a bare PATH; tools such as `codex` may need the usual places.
    public static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
        let current = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        environment["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        return environment
    }

    /// `input` is written to the tool's stdin, which keeps secrets out of `ps`.
    public static func run(_ path: String, _ arguments: [String], input: Data? = nil,
                           timeout: TimeInterval = 10, directory: URL? = nil,
                           extraPath: [String] = []) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = environment
        if !extraPath.isEmpty { environment["PATH"] = (extraPath + [environment["PATH"] ?? ""]).joined(separator: ":") }
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let box = Box(process: process)
        return try await withCheckedThrowingContinuation { continuation in
            // Resumed once: by the tool's exit or by the timeout, whichever comes first.
            let finish = Locked<CheckedContinuation<Output, Error>?>(continuation)
            let resume = { @Sendable (result: Result<Output, Error>) in
                finish.withLock { pending in defer { pending = nil }; return pending }?.resume(with: result)
            }
            do {
                try process.run()
            } catch {
                resume(.failure(ProviderError.badResponse(String(localized: "Could not run \(path): \(error.localizedDescription)"))))
                return
            }
            if let input {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard box.process.isRunning else { return }
                box.process.terminate()
                // A tool stuck in the kernel ignores SIGTERM and may never close its pipes:
                // answer now instead of waiting for it.
                resume(.failure(ProviderError.network(String(localized: "\((path as NSString).lastPathComponent) took too long to answer."))))
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global().async {
                // Both pipes are drained in parallel so a chatty stderr cannot block stdout.
                let group = DispatchGroup()
                let out = Locked(Data())
                let err = Locked(Data())
                group.enter()
                DispatchQueue.global().async {
                    out.withLock { $0 = stdout.fileHandleForReading.readDataToEndOfFile() }
                    group.leave()
                }
                err.withLock { $0 = stderr.fileHandleForReading.readDataToEndOfFile() }
                group.wait()
                box.process.waitUntilExit()
                resume(.success(Output(status: box.process.terminationStatus,
                                       stdout: out.withLock { $0 }, stderr: err.withLock { $0 })))
            }
        }
    }

    private final class Box: @unchecked Sendable {
        let process: Process
        init(process: Process) { self.process = process }
    }
}

/// A value behind a lock, for the few places where callbacks arrive on other threads.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) { self.value = value }

    @discardableResult
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Runs `work` but gives up after `seconds`, answering `onTimeout()` instead. Unlike a
/// task group, it does not wait for work that ignores cancellation: that work is
/// cancelled and left to finish on its own, and its late answer is dropped.
public func withDeadline<T: Sendable>(_ seconds: Double, onTimeout: @escaping @Sendable () -> T,
                                      _ work: @escaping @Sendable () async -> T) async -> T {
    let pending = Locked<CheckedContinuation<T, Never>?>(nil)
    let take = { @Sendable in pending.withLock { continuation in defer { continuation = nil }; return continuation } }
    return await withCheckedContinuation { continuation in
        pending.withLock { $0 = continuation }
        let worker = Task {
            let value = await work()
            take()?.resume(returning: value)
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard let continuation = take() else { return }
            worker.cancel()
            continuation.resume(returning: onTimeout())
        }
    }
}

public enum HTTP {
    /// Sends the request and parses a JSON body; a 429 throws `ProviderError.rateLimited`
    /// and any other non-2xx status `ProviderError.http`.
    public static func json(_ request: URLRequest, session: URLSession = .shared) async throws -> JSONValue {
        let (data, response) = try await exchange(request, session: session)
        let status = response?.statusCode ?? 0
        if status == 429 {
            throw ProviderError.rateLimited(retryAfter: retryAfter(response?.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(status) else { throw ProviderError.http(status) }
        do {
            return try JSONValue.parse(data)
        } catch {
            throw ProviderError.badResponse(String(localized: "The service's answer makes no sense."))
        }
    }

    public static func send(_ request: URLRequest, session: URLSession = .shared) async throws -> (Data, Int) {
        let (data, response) = try await exchange(request, session: session)
        return (data, response?.statusCode ?? 0)
    }

    /// Seconds to wait from a `Retry-After` header, which holds either seconds or an HTTP date.
    public static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private static func exchange(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse?) {
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            Log.debug("\(request.httpMethod ?? "GET") \(request.url?.host() ?? "?")\(request.url?.path() ?? "") → \(http?.statusCode ?? 0), \(data.count) bytes")
            return (data, http)
        } catch let error as URLError {
            Log.debug("\(request.url?.host() ?? "?")\(request.url?.path() ?? "") → URLError \(error.code.rawValue)")
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw ProviderError.network(String(localized: "No internet connection."))
            case .timedOut:
                throw ProviderError.network(String(localized: "The service took too long to answer."))
            case .cannotConnectToHost, .cannotFindHost:
                throw ProviderError.network(String(localized: "Cannot connect to the service."))
            default:
                throw ProviderError.network(error.localizedDescription)
            }
        }
    }

    public static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:],
                               body: Data? = nil, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenAnxiety/\(AppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

/// Diagnostics on stderr with `--debug` or TA_DEBUG=1. Never pass secrets here.
public enum Log {
    public static let enabled = CommandLine.arguments.contains("--debug")
        || ProcessInfo.processInfo.environment["TA_DEBUG"] != nil

    private static let system = Logger(subsystem: "com.tokenanxiety.app", category: "providers")

    public static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("  · \(message())\n".utf8))
    }

    /// Rare events worth finding afterwards (a Claude renewal), kept in the system log too:
    /// `log show --predicate 'subsystem == "com.tokenanxiety.app"' --last 1d`.
    public static func notice(_ message: String) {
        system.notice("\(message, privacy: .public)")
        debug(message)
    }
}

public enum AppInfo {
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

public enum JWT {
    /// The claims of a JSON Web Token, without verifying it: only used to read
    /// the account id the service itself put there.
    public static func claims(_ token: String) -> JSONValue? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONValue.parse(data)
    }
}

extension FileManager {
    var home: URL { homeDirectoryForCurrentUser }

    func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    func isExecutable(_ url: URL) -> Bool {
        isFile(url) && isExecutableFile(atPath: url.path)
    }
}
