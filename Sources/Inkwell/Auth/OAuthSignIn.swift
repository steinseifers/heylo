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

    @MainActor
    static func signIn(loginHint: String?) async throws -> SignInResult {
        guard let id = clientID else { throw OAuthError.noClientID }
        let pkce = pkcePair()
        let state = base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        // Work and school accounts of any tenant; the real tenant ID is read from the ID token.
        let url = authorizeURL(clientID: id, tenant: "organizations", challenge: pkce.challenge, state: state, loginHint: loginHint)
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
        let tokens = try await exchange(code: code, verifier: pkce.verifier, tenant: "organizations")
        let c = claims(tokens.idToken)
        let email = (c["preferred_username"] as? String) ?? (c["email"] as? String) ?? loginHint ?? ""
        return SignInResult(tokens: tokens, email: email, name: (c["name"] as? String) ?? "", tenant: (c["tid"] as? String) ?? "organizations")
    }
}
