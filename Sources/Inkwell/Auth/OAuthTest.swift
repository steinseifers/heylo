import Foundation

/// `Inkwell --oauthtest <port> <long|short>` against scripts/fake_oauth.py (see scripts/test_oauth.py).
/// "long": tokens live an hour (cache must be used); "short": tokens expire at once (every call refreshes, refresh tokens rotate).
enum OAuthTest {
    static func run(args: [String]) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let i = args.firstIndex(of: "--oauthtest"), args.indices.contains(i + 2) else { print("usage: --oauthtest <port> <long|short>"); exit(2) }
        let short = args[i + 2] == "short"
        Task {
            var failures = 0
            func check(_ ok: Bool, _ what: String) { print(ok ? "✓ \(what)" : "✗ \(what)"); if !ok { failures += 1 } }
            let p = OAuth.pkcePair()
            check(p.verifier.count >= 43 && p.challenge == OAuth.base64URL(Data(SHA256Helper.hash(p.verifier))), "PKCE challenge is the S256 of the verifier")
            let url = OAuth.authorizeURL(clientID: "cid", tenant: "organizations", challenge: p.challenge, state: "s", loginHint: "me@example.invalid")
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
            check(v("code_challenge_method") == "S256" && v("response_type") == "code" && v("login_hint") == "me@example.invalid"
                  && (v("scope") ?? "").contains("IMAP.AccessAsUser.All") && (v("scope") ?? "").contains("graph.microsoft.com/Mail.Send") && (v("scope") ?? "").contains("offline_access"), "authorize URL carries PKCE, scopes and login hint")
            var acct = Account(label: "T", displayName: "Me", email: "me@example.invalid", username: "me@example.invalid", imapHost: "127.0.0.1", smtpHost: "127.0.0.1")
            acct.oauth = true
            defer { Keychain.delete(OAuth.refreshKey(acct)) }
            do {
                let t = try await OAuth.exchange(code: "good-code", verifier: p.verifier, tenant: "organizations")
                let claims = OAuth.claims(t.idToken)
                check(claims["preferred_username"] as? String == "me@example.invalid" && claims["tid"] as? String == "tenant-123", "ID token yields address and tenant")
                acct.oauthTenant = claims["tid"] as? String
                OAuth.store(t, for: acct)
                try? await Task.sleep(nanoseconds: 100_000_000)
                let a1 = try await OAuth.accessToken(for: acct)
                let a2 = try await OAuth.accessToken(for: acct)
                if short { check(a1 != "access-1" && a2 != a1, "expired tokens are refreshed on use") }
                else { check(a1 == "access-1" && a2 == "access-1", "valid token is served from cache without a request") }
                // Graph: its own token (other resource) from the same refresh token; sending uses it.
                let g1 = try await OAuth.accessToken(for: acct, resource: .graph)
                check(g1.hasPrefix("graph-") && g1 != a1, "Graph access token is a separate token for the Graph resource")
                let mime = Data("From: me@example.invalid\r\nTo: you@example.invalid\r\nSubject: hi\r\n\r\nbody\r\n".utf8)
                do { try await GraphMail.send(account: acct, mime: GraphMail.withBcc(mime, bcc: "hidden@example.invalid")); check(true, "Graph sendMail accepts the MIME message (202)") }
                catch { check(false, "Graph sendMail failed: \(error)") }
                do { try await GraphMail.send(account: acct, mime: Data("Subject: FAIL400\r\n\r\nx".utf8)); check(false, "client error must throw") }
                catch GraphMail.SendError.rejected(let code, _) { check(code == 403, "client error (403) means certainly not sent") }
                catch { check(false, "wrong error \(error)") }
                do { try await GraphMail.send(account: acct, mime: Data("Subject: FAIL500\r\n\r\nx".utf8)); check(false, "server error must throw") }
                catch GraphMail.SendError.unknown { check(true, "server error (500) is treated as possibly sent") }
                catch { check(false, "wrong error \(error)") }
                // Parallel callers share a single refresh (refresh tokens rotate; two refreshes would break each other).
                OAuth.refreshMargin = 100_000
                let tokens = try await withThrowingTaskGroup(of: String.self) { g in
                    for _ in 0..<8 { g.addTask { try await OAuth.accessToken(for: acct) } }
                    var out: [String] = []; for try await t in g { out.append(t) }; return out
                }
                check(Set(tokens).count == 1, "8 parallel callers got the same token (one refresh)")
                check(Keychain.get(OAuth.refreshKey(acct)) != nil, "rotated refresh token is stored in the Keychain")
                // Refresh token revoked: a clear error, no crash.
                _ = Keychain.set("bad", for: OAuth.refreshKey(acct))
                var broken = acct; broken.id = acct.id
                OAuth.refreshMargin = 1_000_000
                await OAuth.dropCache()
                do { _ = try await OAuth.accessToken(for: broken); check(false, "revoked refresh token must fail") }
                catch { check("\(error)".contains("refresh token invalid") || (error as? OAuth.OAuthError) != nil, "revoked refresh token gives a sign-in error") }
            } catch { check(false, "unexpected error: \(error)") }
            print(failures == 0 ? "All OAuth checks passed" : "OAuth FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}

enum SHA256Helper {
    static func hash(_ s: String) -> [UInt8] { Array(Data(s.utf8).sha256Bytes) }
}
