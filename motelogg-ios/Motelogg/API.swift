import Foundation
import Security

/// Supabase-prosjektet som også brukes av gjørelista. Nøkkelen er den offentlige (publishable)
/// nøkkelen – dataene er beskyttet av innlogging og radtilgang (RLS) i databasen.
enum Config {
    static let url = URL(string: "https://oqdjxiokzjepznvhbvkn.supabase.co")!
    static let key = "sb_publishable_PxQBW9-6M1Xm3YKiSWI6ow_1XNsT0YH"
}

struct AuthSession: Codable {
    var access_token: String
    var refresh_token: String
    var expires_at: Double
    var email: String?
}

private struct AuthResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double?
}

struct SessionRow: Decodable {
    let id: String
    let data: RecSession?
    let deleted: Bool
    let updated_at: String

    enum CodingKeys: String, CodingKey { case id, data, deleted, updated_at }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        data = try? c.decode(RecSession.self, forKey: .data)
        deleted = (try? c.decode(Bool.self, forKey: .deleted)) ?? false
        updated_at = (try? c.decode(String.self, forKey: .updated_at)) ?? ""
    }
    var updatedMs: Double {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: updated_at) ?? ISO8601DateFormatter().date(from: updated_at)
        return (d?.timeIntervalSince1970 ?? 0) * 1000
    }
}

struct SettingsRow: Decodable { let gemini_key: String?; let vocab: String? }

enum APIError: LocalizedError {
    case http(Int, String)
    case notLoggedIn
    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "Feil \(code): \(msg.prefix(200))"
        case .notLoggedIn: return "Du er ikke logget inn."
        }
    }
}

/// Snakker med Supabase over vanlig HTTPS (Auth og PostgREST). Ingen eksterne pakker.
final class API: @unchecked Sendable {
    static let shared = API()
    private(set) var session: AuthSession? {
        didSet { if let s = session { Keychain.save(s) } else { Keychain.clear() } }
    }
    init() { session = Keychain.load() }
    var isLoggedIn: Bool { session != nil }

    func signIn(email: String, password: String) async throws {
        let r: AuthResponse = try await auth(grant: "password", body: ["email": email, "password": password])
        session = AuthSession(access_token: r.access_token, refresh_token: r.refresh_token,
                              expires_at: Date().timeIntervalSince1970 + (r.expires_in ?? 3600), email: email)
    }

    func signOut() { session = nil }

    private func refresh() async throws {
        guard let s = session else { throw APIError.notLoggedIn }
        do {
            let r: AuthResponse = try await auth(grant: "refresh_token", body: ["refresh_token": s.refresh_token])
            session = AuthSession(access_token: r.access_token, refresh_token: r.refresh_token,
                                  expires_at: Date().timeIntervalSince1970 + (r.expires_in ?? 3600), email: s.email)
        } catch APIError.http(let code, _) where code == 400 || code == 401 {
            session = nil
            throw APIError.notLoggedIn
        }
    }

    private func auth<T: Decodable>(grant: String, body: [String: String]) async throws -> T {
        var comps = URLComponents(url: Config.url.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(Config.key, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func rest(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      body: Data? = nil, prefer: String? = nil) async throws -> Data {
        guard let s = session else { throw APIError.notLoggedIn }
        if s.expires_at - 60 < Date().timeIntervalSince1970 { try await refresh() }
        for attempt in 0..<2 {
            guard let token = session?.access_token else { throw APIError.notLoggedIn }
            var comps = URLComponents(url: Config.url.appendingPathComponent("rest/v1/" + path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { comps.queryItems = query }
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue(Config.key, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
            req.httpBody = body
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 && attempt == 0 { try await refresh(); continue }
            guard (200..<300).contains(code) else { throw APIError.http(code, String(data: data, encoding: .utf8) ?? "") }
            return data
        }
        throw APIError.notLoggedIn
    }

    // MARK: Referat

    func fetchSessions() async throws -> [SessionRow] {
        let data = try await rest("GET", "referat_sessions", query: [URLQueryItem(name: "select", value: "id,data,deleted,updated_at")])
        return try JSONDecoder().decode([SessionRow].self, from: data)
    }

    func upsertSession(_ s: RecSession, deleted: Bool = false) async throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s))
        let updated = Date(timeIntervalSince1970: (s.updated ?? nowMs()) / 1000)
        let row: [String: Any] = ["id": s.id, "data": json, "deleted": deleted,
                                  "updated_at": ISO8601DateFormatter().string(from: updated)]
        _ = try await rest("POST", "referat_sessions", query: [URLQueryItem(name: "on_conflict", value: "id")],
                           body: try JSONSerialization.data(withJSONObject: [row]),
                           prefer: "resolution=merge-duplicates,return=minimal")
    }

    func fetchSettings() async throws -> SettingsRow? {
        let data = try await rest("GET", "referat_settings", query: [URLQueryItem(name: "select", value: "gemini_key,vocab"),
                                                                     URLQueryItem(name: "id", value: "eq.main")])
        return try JSONDecoder().decode([SettingsRow].self, from: data).first
    }

    func upsertSettings(key: String, vocab: String) async throws {
        let row: [String: Any] = ["id": "main", "gemini_key": key, "vocab": vocab,
                                  "updated_at": ISO8601DateFormatter().string(from: Date())]
        _ = try await rest("POST", "referat_settings", query: [URLQueryItem(name: "on_conflict", value: "id")],
                           body: try JSONSerialization.data(withJSONObject: [row]),
                           prefer: "resolution=merge-duplicates,return=minimal")
    }
}

/// Lagrer innloggingen i nøkkelringen på telefonen.
enum Keychain {
    private static let account = "referat-session"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }
    static func save(_ s: AuthSession) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        clear()
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> AuthSession? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }
    static func clear() { SecItemDelete(base as CFDictionary) }
}
