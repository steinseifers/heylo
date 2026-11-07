import Foundation

/// `Inkwell --probe`: reports what each configured IMAP server supports (read-only).
/// `INKWELL_PROBE_WRITE=<email> Inkwell --probe` additionally runs a write test for that one
/// account in a throwaway folder (APPEND, keyword, MOVE, check the keyword survived, clean up).
/// Output goes to stdout; keep it out of the public repo (it contains host names).
enum Probe {
    static func run() -> Never {
        let writeFor = ProcessInfo.processInfo.environment["INKWELL_PROBE_WRITE"]?.lowercased()
        let accounts = SettingsStore.load().accounts.filter(\.enabled)
        if accounts.isEmpty { print("No enabled accounts."); exit(1) }
        for a in accounts {
            print("== \(a.email) (\(a.imapHost):\(a.imapPort))")
            do {
                let c = try IMAPClient(host: a.imapHost, port: a.imapPort)
                if let pw = ProcessInfo.processInfo.environment["INKWELL_PROBE_PASSWORD"] { try c.login(user: a.username, password: pw) }
                else { try c.login(account: a) }  // password from the Keychain, or OAuth
                let caps = c.capabilities.sorted()
                print("CAPABILITY: \(caps.joined(separator: " "))")
                let interesting = ["MOVE", "UIDPLUS", "CONDSTORE", "QRESYNC", "SNOOZE", "IDLE", "SPECIAL-USE", "LITERAL+"]
                print("  " + interesting.map { "\($0)=\(c.capabilities.contains($0) ? "yes" : "no")" }.joined(separator: " "))
                let lines = try c.command("EXAMINE \"INBOX\"")
                let perm = lines.map { String(decoding: $0, as: UTF8.self) }.first { $0.contains("PERMANENTFLAGS") } ?? "(none announced)"
                print("INBOX \(perm.trimmingCharacters(in: .whitespacesAndNewlines))")
                print("  custom keywords: \(perm.contains("\\*") ? "allowed (\\*)" : "NOT allowed")")
                if writeFor == a.email.lowercased() { try writeTest(c) }
                else if writeFor == nil { print("  write test: skipped (set INKWELL_PROBE_WRITE=<email> to allow for one account)") }
                c.close()
            } catch { print("  error: \(error)") }
        }
        exit(0)
    }

    private static func writeTest(_ c: IMAPClient) throws {
        let id = String(UUID().uuidString.prefix(8))
        let src = "Inkwell-Probe-\(id)-A", dst = "Inkwell-Probe-\(id)-B"
        let kw = "$InkwellProbe"
        var cleanup: [String] = []
        defer { for f in cleanup { _ = try? c.command("DELETE \(IMAPClient.quote(f))") } }
        try c.create(src); cleanup.append(src)
        try c.create(dst); cleanup.append(dst)
        let msg = Data("From: probe@example.invalid\r\nTo: probe@example.invalid\r\nSubject: probe \(id)\r\nMessage-ID: <probe-\(id)@example.invalid>\r\n\r\nprobe\r\n".utf8)
        try c.append(src, flags: "", message: msg)
        _ = try c.select(src)
        let uids = try c.uidSearch("ALL")
        guard let uid = uids.first else { print("  write test: APPEND produced no message"); return }
        try c.store("\(uid)", flags: kw, add: true)
        let before = try c.command("UID FETCH \(uid) (FLAGS)").map { String(decoding: $0, as: UTF8.self) }.joined()
        print("  keyword set: \(before.contains(kw) ? "ok" : "REJECTED")")
        try c.move("\(uid)", to: dst)
        _ = try c.select(dst)
        let u2 = try c.uidSearch("ALL")
        guard let nu = u2.first else { print("  write test: moved message not found"); return }
        let after = try c.command("UID FETCH \(nu) (FLAGS)").map { String(decoding: $0, as: UTF8.self) }.joined()
        print("  keyword survives MOVE: \(after.contains(kw) ? "YES" : "NO")")
        _ = try? c.command("UNSELECT")
    }
}
