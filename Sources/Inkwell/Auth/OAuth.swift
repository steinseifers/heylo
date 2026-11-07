import Foundation
import CryptoKit

/// OAuth 2.0 (authorization code + PKCE, public client, no secret) for Microsoft 365 IMAP/SMTP.
/// The client ID is configuration, not code: `INKWELL_OAUTH_CLIENT_ID` or the user default
/// `oauthClientID`. Refresh tokens live in the Keychain of each Mac (own sign-in per Mac).
enum OAuth {
    static let redirectScheme = "de.steinseifers.steinsmail"
    static var redirectURI: String { redirectScheme + "://oauth" }
    static let scopes = ["https://outlook.office.com/IMAP.AccessAsUser.All", "https://outlook.office.com/SMTP.Send",
                         "offline_access", "openid", "email", "profile"]
    /// Tokens are renewed this long before they expire.
    static var refreshMargin: TimeInterval = 60

    static var baseURL: String { ProcessInfo.processInfo.environment["INKWELL_OAUTH_BASE"] ?? "https://login.microsoftonline.com" }
    static var clientID: String? {
        let id = ProcessInfo.processInfo.environment["INKWELL_OAUTH_CLIENT_ID"] ?? UserDefaults.standard.string(forKey: "oauthClientID")
        return (id?.isEmpty ?? true) ? nil : id
    }

    enum OAuthError: LocalizedError {
        case noClientID, badResponse(String), denied(String)
        var errorDescription: String? {
            switch self {
            case .noClientID: return "No Microsoft 365 client ID configured (Settings or INKWELL_OAUTH_CLIENT_ID)."
            case .badResponse(let s): return "Unexpected sign-in response: \(s)"
            case .denied(let s): return "Microsoft sign-in failed: \(s)"
            }
        }
    }

    struct Tokens {
        var access: String
        var refresh: String?
        var expires: Date
        var idToken: String?
    }

    // MARK: PKCE and URLs

    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func pkcePair() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URL(Data(bytes))
        return (verifier, base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
    }

    static func authorizeURL(clientID: String, tenant: String, challenge: String, state: String, loginHint: String?) -> URL {
        var c = URLComponents(string: "\(baseURL)/\(tenant)/oauth2/v2.0/authorize")!
        var q = [("client_id", clientID), ("response_type", "code"), ("redirect_uri", redirectURI), ("response_mode", "query"),
                 ("scope", scopes.joined(separator: " ")), ("code_challenge", challenge), ("code_challenge_method", "S256"),
                 ("state", state), ("prompt", "select_account")]
        if let h = loginHint, !h.isEmpty { q.append(("login_hint", h)) }
        c.queryItems = q.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!
    }

    // MARK: token endpoint

    private static func tokenRequest(tenant: String, form: [(String, String)]) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "\(baseURL)/\(tenant)/oauth2/v2.0/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let err = json["error"] as? String { throw OAuthError.denied((json["error_description"] as? String) ?? err) }
        guard let access = json["access_token"] as? String else { throw OAuthError.badResponse("no access_token") }
        let life = (json["expires_in"] as? Double) ?? (json["expires_in"] as? String).flatMap(Double.init) ?? 3600
        return Tokens(access: access, refresh: json["refresh_token"] as? String, expires: Date().addingTimeInterval(life), idToken: json["id_token"] as? String)
    }

    static func exchange(code: String, verifier: String, tenant: String) async throws -> Tokens {
        guard let id = clientID else { throw OAuthError.noClientID }
        return try await tokenRequest(tenant: tenant, form: [("client_id", id), ("grant_type", "authorization_code"), ("code", code),
                                                             ("redirect_uri", redirectURI), ("code_verifier", verifier), ("scope", scopes.joined(separator: " "))])
    }

    static func refresh(_ refreshToken: String, tenant: String) async throws -> Tokens {
        guard let id = clientID else { throw OAuthError.noClientID }
        return try await tokenRequest(tenant: tenant, form: [("client_id", id), ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
                                                             ("scope", scopes.joined(separator: " "))])
    }

    /// Claims of an ID token (payload only; used to learn the user's address and tenant, not for trust decisions).
    static func claims(_ jwt: String?) -> [String: Any] {
        guard let p = jwt?.split(separator: ".").dropFirst().first else { return [:] }
        var s = String(p).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return (Data(base64Encoded: s)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    // MARK: per-account tokens

    static func refreshKey(_ account: Account) -> String { "oauth-refresh-\(account.id.uuidString)" }

    /// Keeps the refresh token in the Keychain and the short-lived access token in memory.
    static func store(_ t: Tokens, for account: Account) {
        if let r = t.refresh { _ = Keychain.set(r, for: refreshKey(account)) }
        Task { await cache.put(account.id, t) }
    }

    private actor Cache {
        var tokens: [UUID: Tokens] = [:]
        var inflight: [UUID: Task<Tokens, Error>] = [:]
        func put(_ id: UUID, _ t: Tokens) { tokens[id] = t }
        func clear() { tokens = [:] }

        func token(for account: Account) async throws -> String {
            if let t = tokens[account.id], t.expires.timeIntervalSinceNow > OAuth.refreshMargin { return t.access }
            // One refresh at a time per account: refresh tokens rotate, parallel use would invalidate each other.
            if let running = inflight[account.id] { return try await running.value.access }
            guard let refresh = Keychain.get(OAuth.refreshKey(account)) else { throw OAuthError.denied("Not signed in on this Mac. Sign in again in Settings.") }
            let task = Task { try await OAuth.refresh(refresh, tenant: account.oauthTenant ?? "organizations") }
            inflight[account.id] = task
            defer { inflight[account.id] = nil }
            let t = try await task.value
            if let r = t.refresh { _ = Keychain.set(r, for: OAuth.refreshKey(account)) }
            tokens[account.id] = t
            return t.access
        }
    }
    private static let cache = Cache()
    /// Tests only.
    static func dropCache() async { await cache.clear() }

    static func accessToken(for account: Account) async throws -> String { try await cache.token(for: account) }

    /// For the connection queues (never call on the main thread).
    static func accessTokenBlocking(for account: Account) throws -> String {
        final class Box: @unchecked Sendable { var result: Result<String, Error> = .failure(OAuthError.badResponse("no result")) }
        let box = Box(), sem = DispatchSemaphore(value: 0)
        Task { box.result = await Result { try await accessToken(for: account) }; sem.signal() }
        sem.wait()
        return try box.result.get()
    }
}

extension Data {
    var sha256Bytes: [UInt8] { Array(SHA256.hash(data: self)) }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
