import AppKit
import AuthenticationServices

/// Interactive Microsoft sign-in in the system web authentication sheet (shares Safari's sign-ins).
extension OAuth {
    struct SignInResult {
        var tokens: Tokens
        var email: String
        var name: String
        var tenant: String
    }

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
    @MainActor private static var anchor = Anchor()
    @MainActor private static var current: ASWebAuthenticationSession?

    /// One interactive round in the web authentication sheet; returns the authorization code and its PKCE verifier.
    @MainActor
    private static func authorize(tenant: String, scopes: [String], prompt: String, loginHint: String?) async throws -> (code: String, verifier: String) {
        guard let id = clientID else { throw OAuthError.noClientID }
        let pkce = pkcePair()
        let state = base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let url = authorizeURL(clientID: id, tenant: tenant, challenge: pkce.challenge, state: state, loginHint: loginHint, scopes: scopes, prompt: prompt)
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: redirectScheme) { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: OAuthError.denied(error?.localizedDescription ?? "cancelled")) }
            }
            session.presentationContextProvider = anchor
            current = session
            if !session.start() { cont.resume(throwing: OAuthError.denied("couldn't open the sign-in window")) }
        }
        current = nil
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let e = item("error") { throw OAuthError.denied(item("error_description") ?? e) }
        guard item("state") == state, let code = item("code") else { throw OAuthError.badResponse("state mismatch") }
        return (code, pkce.verifier)
    }

    private static func needsConsent(_ e: Error) -> Bool {
        let m = "\(e)"
        return m.contains("AADSTS65001") || m.contains("consent_required") || m.contains("interaction_required") || m.contains("AADSTS50076")
    }

    @MainActor
    static func signIn(loginHint: String?) async throws -> SignInResult {
        // Work and school accounts of any tenant; the real tenant ID is read from the ID token.
        let first = try await authorize(tenant: "organizations", scopes: scopes, prompt: "select_account", loginHint: loginHint)
        var tokens = try await exchange(code: first.code, verifier: first.verifier, tenant: "organizations")
        let c = claims(tokens.idToken)
        let email = (c["preferred_username"] as? String) ?? (c["email"] as? String) ?? loginHint ?? ""
        let tenant = (c["tid"] as? String) ?? "organizations"
        // Sending needs a token for Microsoft Graph. Consent for a second resource is not always granted in the first round
        // (and customer tenants may differ): if it is missing, ask for it explicitly, then keep the newest refresh token.
        if let refresh = tokens.refresh {
            do {
                let g = try await OAuth.refresh(refresh, tenant: tenant, resource: .graph)
                if let r = g.refresh { tokens.refresh = r }
            } catch where needsConsent(error) {
                let second = try await authorize(tenant: tenant, scopes: scopes(for: .graph), prompt: "consent", loginHint: email.isEmpty ? loginHint : email)
                let g = try await exchange(code: second.code, verifier: second.verifier, tenant: tenant, resource: .graph)
                if let r = g.refresh { tokens.refresh = r }
            }
        }
        return SignInResult(tokens: tokens, email: email, name: (c["name"] as? String) ?? "", tenant: tenant)
    }
}
