import Foundation

/// `Inkwell --smtptest <port>` against scripts/fake_smtp.py (see scripts/test_smtp.py): XOAUTH2 success and failure.
enum SMTPAuthTest {
    static func run(args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--smtptest"), args.indices.contains(i + 1), let port = Int(args[i + 1]) else { print("usage: --smtptest <port>"); exit(2) }
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "✓ \(what)" : "✗ \(what)"); if !ok { failures += 1 } }
        do {
            let good = try SMTPClient(host: "127.0.0.1", port: port, security: .ssl)
            try good.loginXOAUTH2(user: "me@example.invalid", token: "good-token")
            try good.sendMail(from: "me@example.invalid", recipients: ["you@example.invalid"],
                              data: Data("From: me@example.invalid\r\nTo: you@example.invalid\r\nSubject: t\r\nMessage-ID: <oauth1@example.invalid>\r\n\r\nhi\r\n".utf8))
            good.quit()
            check(true, "XOAUTH2 login and send accepted")
        } catch { check(false, "XOAUTH2 login/send: \(error)") }
        do {
            let bad = try SMTPClient(host: "127.0.0.1", port: port, security: .ssl)
            do { try bad.loginXOAUTH2(user: "me@example.invalid", token: "bad"); check(false, "bad token must fail") }
            catch MailError.auth(let m) { check(m.contains("535"), "bad token rejected with auth error (\(m))") }
            bad.quit()
        } catch { check(false, "connect: \(error)") }
        print(failures == 0 ? "All SMTP auth checks passed" : "SMTP auth FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
