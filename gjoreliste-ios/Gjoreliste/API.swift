import Foundation
import Security

/// Supabase-prosjektet «gjoreliste». Nøkkelen er den offentlige (publishable) nøkkelen –
/// dataene er beskyttet av innlogging og radtilgang (RLS) i databasen.
enum Config {
    static let url = URL(string: "https://oqdjxiokzjepznvhbvkn.supabase.co")!
    static let key = "sb_publishable_PxQBW9-6M1Xm3YKiSWI6ow_1XNsT0YH"
}

struct Session: Codable {
    var access_token: String
    var refresh_token: String
    var expires_at: Double
    var email: String?
}

private struct AuthResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double?
    let user: AuthUser?
}
private struct AuthUser: Decodable { let email: String? }

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
final class API {
    static let shared = API()
    private(set) var session: Session? {
        didSet { if let s = session { Keychain.save(s) } else { Keychain.clear() } }
    }
    init() { session = Keychain.load() }
    var isLoggedIn: Bool { session != nil }

    func signIn(email: String, password: String) async throws {
        let r: AuthResponse = try await auth(grant: "password", body: ["email": email, "password": password])
        session = Session(access_token: r.access_token, refresh_token: r.refresh_token,
                          expires_at: Date().timeIntervalSince1970 + (r.expires_in ?? 3600),
                          email: r.user?.email ?? email)
    }

    func signOut() { session = nil }

    private func refresh() async throws {
        guard let s = session else { throw APIError.notLoggedIn }
        do {
            let r: AuthResponse = try await auth(grant: "refresh_token", body: ["refresh_token": s.refresh_token])
            session = Session(access_token: r.access_token, refresh_token: r.refresh_token,
                              expires_at: Date().timeIntervalSince1970 + (r.expires_in ?? 3600),
                              email: s.email)
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
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
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
            guard (200..<300).contains(code) else {
                throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        }
        throw APIError.notLoggedIn
    }

    func select<T: Decodable>(_ table: String, _ query: [URLQueryItem] = []) async throws -> [T] {
        let data = try await rest("GET", table, query: [URLQueryItem(name: "select", value: "*")] + query)
        return try JSONDecoder().decode([T].self, from: data)
    }

    func update(_ table: String, id: String, _ fields: [String: Any]) async throws {
        var f = fields
        f["updated_at"] = ISO8601DateFormatter().string(from: Date())
        _ = try await rest("PATCH", table, query: [URLQueryItem(name: "id", value: "eq.\(id)")],
                           body: try JSONSerialization.data(withJSONObject: f), prefer: "return=minimal")
    }

    func delete(_ table: String, id: String) async throws {
        _ = try await rest("DELETE", table, query: [URLQueryItem(name: "id", value: "eq.\(id)")], prefer: "return=minimal")
    }

    func insert(_ table: String, _ fields: [String: Any]) async throws {
        _ = try await rest("POST", table, body: try JSONSerialization.data(withJSONObject: fields), prefer: "return=minimal")
    }
}

/// Lagrer innloggingen i nøkkelringen på telefonen.
enum Keychain {
    private static let account = "gjoreliste-session"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }
    static func save(_ s: Session) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        clear()
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> Session? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }
    static func clear() { SecItemDelete(base as CFDictionary) }
}
