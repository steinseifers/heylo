import Foundation

/// Sends mail through Microsoft Graph (`POST /me/sendMail`, MIME body) for Microsoft 365 accounts that sign in with OAuth.
/// Exchange Online disables SMTP AUTH for many tenants ("SmtpClientAuthenticationDisabled"); Graph does not depend on it.
/// The MIME message is sent as it is, so S/MIME signed or encrypted messages work too. Graph files the message in Sent Items.
enum GraphMail {
    static var baseURL: String { ProcessInfo.processInfo.environment["INKWELL_GRAPH_BASE"] ?? "https://graph.microsoft.com/v1.0" }

    /// OAuth accounts at Exchange Online send through Graph (tests point INKWELL_GRAPH_BASE at a fake server).
    static func uses(_ account: Account) -> Bool {
        account.oauth && (account.imapHost.contains("office365") || ProcessInfo.processInfo.environment["INKWELL_GRAPH_BASE"] != nil)
    }

    enum SendError: LocalizedError {
        /// The service answered with a client error: certainly nothing was sent.
        case rejected(Int, String)
        /// Timeout, connection loss or server error after the request left: the message may have been sent.
        case unknown(String)
        var errorDescription: String? {
            switch self {
            case .rejected(let code, let detail): return "Microsoft refused to send (\(code)): \(detail)"
            case .unknown(let detail): return "Sending was interrupted (\(detail)). The message may or may not have been sent; check Sent before trying again."
            }
        }
    }

    /// Bcc recipients must be in the MIME headers for Graph (it removes the header before delivery).
    static func withBcc(_ mime: Data, bcc: String) -> Data {
        bcc.trimmingCharacters(in: .whitespaces).isEmpty ? mime : Data("Bcc: \(bcc)\r\n".utf8) + mime
    }

    static func send(account: Account, mime: Data) async throws {
        let token = try await OAuth.accessToken(for: account, resource: .graph)
        var req = URLRequest(url: URL(string: "\(baseURL)/me/sendMail")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.httpBody = mime.base64EncodedData()
        req.timeoutInterval = 120
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw SendError.unknown(error.localizedDescription) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200...299: return
        case 400..<500 where code != 408: throw SendError.rejected(code, detail(data))
        default: throw SendError.unknown("HTTP \(code) \(detail(data))")
        }
    }

    /// For the connection queues (send-later), never on the main thread. A failure before the request was made
    /// (no token) or a client error is reported as `NotSent`; anything else may have been delivered.
    static func sendBlocking(account: Account, mime: Data) throws {
        final class Box: @unchecked Sendable { var error: Error? }
        let box = Box(), sem = DispatchSemaphore(value: 0)
        Task { do { try await send(account: account, mime: mime) } catch { box.error = error }; sem.signal() }
        sem.wait()
        if let e = box.error {
            if case SendError.unknown = e { throw e }
            throw ScheduledSend.NotSent(underlying: e)
        }
    }

    private static func detail(_ data: Data) -> String {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = j["error"] as? [String: Any] else {
            return String(decoding: data.prefix(160), as: UTF8.self)
        }
        let code = e["code"] as? String ?? "", msg = e["message"] as? String ?? ""
        let hint = (code.contains("Authorization") || code == "ErrorAccessDenied" || code == "InvalidAuthenticationToken")
            ? " (Check that the app has the Microsoft Graph permission Mail.Send and that you signed in again after adding it.)" : ""
        return "\(code) \(msg)\(hint)"
    }
}
