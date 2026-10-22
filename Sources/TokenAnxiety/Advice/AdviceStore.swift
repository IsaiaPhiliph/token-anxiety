import Foundation
import Observation
import Security
import TokenAnxietyCore

/// The user's own Anthropic API key, in a Keychain item of the app's own (never Claude
/// Code's session).
enum APIKeyStore {
    private static let service = "Token Anxiety API key"
    private static let account = "anthropic"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var exists: Bool {
        var search = query
        search[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(search as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Prepares the advice request for the user to read, sends it only when asked, and keeps
/// the tips (with the user's ratings) on this Mac.
@MainActor @Observable
final class AdviceStore {
    enum State: Equatable {
        case idle
        case sending
        case failed(String)
    }

    private(set) var preview: Data?
    private(set) var tips: [Advice.Tip] = []
    private(set) var tipsDate: Date?
    private(set) var state = State.idle
    private(set) var hasKey = APIKeyStore.exists

    @ObservationIgnored private let demo: Bool
    /// `TA_ADVICE_URL` points the request elsewhere, for trying the flow against a local fake.
    @ObservationIgnored private let endpoint: URL

    init(demo: Bool) {
        self.demo = demo
        endpoint = ProcessInfo.processInfo.environment["TA_ADVICE_URL"].flatMap(URL.init(string:)) ?? Advice.endpoint
        if demo && endpoint != Advice.endpoint { hasKey = true }
        load()
        if demo { (tips, tipsDate) = (Self.demoTips, Date().addingTimeInterval(-3 * 3600)) }
    }

    var endpointDescription: String { endpoint.absoluteString }

    func prepare(ledger: UsageLedger, includeProjects: Bool, plans: [ProviderID: String], weeklyUsed: [ProviderID: Double]) {
        let summary = Advice.summary(ledger: ledger, calendar: Fmt.calendar, includeProjects: includeProjects,
                                     plans: plans, weeklyUsed: weeklyUsed)
        let language = Fmt.locale.language.languageCode?.identifier == "es" ? "Spanish" : "English"
        preview = Advice.body(summary: summary, language: language)
        state = .idle
    }

    func discardPreview() {
        preview = nil
    }

    func send() async {
        guard let body = preview else { return }
        let key = demo && endpoint != Advice.endpoint ? "demo" : APIKeyStore.read()
        guard let key, !key.isEmpty else {
            state = .failed(String(localized: "Add your Anthropic API key in Settings › Statistics first."))
            return
        }
        state = .sending
        do {
            tips = try await Advice.send(body: body, apiKey: key, endpoint: endpoint)
            tipsDate = Date()
            preview = nil
            state = .idle
            save()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Returns true the first time a tip is rated.
    @discardableResult
    func rate(_ tip: Advice.Tip, helpful: Bool) -> Bool {
        guard let index = tips.firstIndex(where: { $0.id == tip.id }) else { return false }
        let first = tips[index].helpful == nil
        tips[index].helpful = helpful
        save()
        return first
    }

    func saveKey(_ key: String) {
        hasKey = APIKeyStore.save(key)
    }

    func removeKey() {
        APIKeyStore.remove()
        hasKey = false
    }

    /// What an answer looks like, for `--demo`.
    private static var demoTips: [Advice.Tip] {
        if Fmt.locale.language.languageCode?.identifier == "es" {
            return [
                Advice.Tip(title: "Recorta la salida de Bash", evidence: "Los resultados de Bash son el 38 % de lo que entra en el contexto, más que tus prompts y las respuestas juntos.",
                           action: "Pasa los comandos largos (tests, builds, logs) por tail o grep antes de que lleguen a Claude.", helpful: true),
                Advice.Tip(title: "Deja Opus para lo difícil", evidence: "Opus 5.5 hace el 58 % de las peticiones pero el 81 % del coste; Sonnet 5.5 resuelve tus sesiones cortas con la mitad de tokens.",
                           action: "Empieza las tareas pequeñas con Sonnet y cambia a Opus solo si se atasca."),
                Advice.Tip(title: "Sesiones más cortas", evidence: "La sesión mediana llega a 412 mil tokens de contexto, y cada petición vuelve a leerlo entero desde la caché.",
                           action: "Usa /clear al cambiar de tarea en vez de seguir en la misma conversación."),
            ]
        }
        return [
            Advice.Tip(title: "Trim Bash output", evidence: "Bash results are 38% of what goes into the context, more than your prompts and the replies together.",
                       action: "Pipe long commands (tests, builds, logs) through tail or grep before Claude sees them.", helpful: true),
            Advice.Tip(title: "Keep Opus for the hard parts", evidence: "Opus 5.5 makes 58% of the requests but 81% of the cost; Sonnet 5.5 handles your short sessions with half the tokens.",
                       action: "Start small tasks on Sonnet and switch to Opus only when it gets stuck."),
            Advice.Tip(title: "Shorter sessions", evidence: "The median session reaches 412K tokens of context, and every request reads all of it again from the cache.",
                       action: "Use /clear when you switch tasks instead of carrying on in the same conversation."),
        ]
    }

    // MARK: Saving

    private struct Saved: Codable {
        var tips: [Advice.Tip]
        var date: Date?
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenAnxiety/advice.json")
    }

    private func load() {
        guard !demo, let data = try? Data(contentsOf: Self.url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        tips = saved.tips
        tipsDate = saved.date
    }

    private func save() {
        guard !demo, let data = try? JSONEncoder().encode(Saved(tips: tips, date: tipsDate)) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
