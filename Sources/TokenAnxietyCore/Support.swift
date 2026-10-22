import Foundation

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
                           timeout: TimeInterval = 10) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let box = Box(process: process)
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProviderError.badResponse("No se pudo ejecutar \(path): \(error.localizedDescription)"))
                return
            }
            if let input {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if box.process.isRunning {
                    box.timedOut.withLock { $0 = true }
                    box.process.terminate()
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
                if box.timedOut.withLock({ $0 }) {
                    continuation.resume(throwing: ProviderError.network("\((path as NSString).lastPathComponent) ha tardado demasiado en responder."))
                } else {
                    continuation.resume(returning: Output(status: box.process.terminationStatus,
                                                          stdout: out.withLock { $0 },
                                                          stderr: err.withLock { $0 }))
                }
            }
        }
    }

    private final class Box: @unchecked Sendable {
        let process: Process
        let timedOut = Locked(false)
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

public enum HTTP {
    /// Sends the request and parses a JSON body; any non-2xx status throws `ProviderError.http`.
    public static func json(_ request: URLRequest, session: URLSession = .shared) async throws -> JSONValue {
        let (data, status) = try await send(request, session: session)
        guard (200..<300).contains(status) else { throw ProviderError.http(status) }
        do {
            return try JSONValue.parse(data)
        } catch {
            throw ProviderError.badResponse("La respuesta del servicio no se entiende.")
        }
    }

    public static func send(_ request: URLRequest, session: URLSession = .shared) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Log.debug("\(request.httpMethod ?? "GET") \(request.url?.host() ?? "?")\(request.url?.path() ?? "") → \(status), \(data.count) bytes")
            return (data, status)
        } catch let error as URLError {
            Log.debug("\(request.url?.host() ?? "?")\(request.url?.path() ?? "") → URLError \(error.code.rawValue)")
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw ProviderError.network("Sin conexión a internet.")
            case .timedOut:
                throw ProviderError.network("El servicio ha tardado demasiado en responder.")
            case .cannotConnectToHost, .cannotFindHost:
                throw ProviderError.network("No se puede conectar con el servicio.")
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

    public static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("  · \(message())\n".utf8))
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
