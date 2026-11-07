import Foundation

/// `Inkwell --snoozetest <port> [nokeywords]` against scripts/fake_imap_multi.py (see scripts/test_snooze.py).
/// Two independent clients play two Macs. Exits non-zero on the first failed check.
enum SnoozeTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "✓ \(what)" : "✗ \(what)")
        if !ok { failures += 1 }
    }

    static func client(_ port: Int) throws -> IMAPClient {
        let c = try IMAPClient(host: "127.0.0.1", port: port)
        try c.login(user: "u", password: "p")
        return c
    }

    static func dump(_ c: IMAPClient) throws -> [String: [String: [String: Any]]] {
        let line = try c.command("X-DUMP").map { String(decoding: $0, as: UTF8.self) }.first { $0.contains("X-DUMP") } ?? ""
        let json = line.drop(while: { $0 != "{" })
        return (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: [String: Any]]]) ?? [:]
    }

    static func ids(_ d: [String: [String: [String: Any]]], _ folder: String) -> [String] {
        (d[folder] ?? [:]).values.compactMap { $0["id"] as? String }.sorted()
    }

    static func put(_ c: IMAPClient, _ n: Int) throws {
        let m = "From: a@example.invalid\r\nTo: me@example.invalid\r\nSubject: m\(n)\r\nMessage-ID: <m\(n)@example.invalid>\r\n\r\nx\r\n"
        try c.append("INBOX", flags: "", message: Data(m.utf8))
    }

    static func run(args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--snoozetest"), args.indices.contains(i + 1), let port = Int(args[i + 1]) else { print("usage: --snoozetest <port> [nokeywords]"); exit(2) }
        let noKeywords = args.contains("nokeywords")
        let folder = ServerSnooze.defaultFolder
        do {
            let a = try client(port), b = try client(port)
            for n in 1...3 { try put(a, n) }
            _ = try a.select("INBOX")
            let all = try a.uidSearch("ALL")

            if noKeywords {
                do { try ServerSnooze.snooze(a, uids: [all[0]], until: Date().addingTimeInterval(3600), folder: folder); check(false, "snooze must refuse without keywords") }
                catch ServerSnooze.SnoozeError.keywordsUnsupported { check(true, "snooze refused: server drops keywords") }
                let d = try dump(b)
                check(ids(d, "INBOX").count == 3 && ids(d, folder).isEmpty, "mail stays in INBOX, nothing moved")
                exit(failures == 0 ? 0 : 1)
            }

            // Snooze #1 for an hour, #2 already due (as if the Mac was asleep).
            try ServerSnooze.snooze(a, uids: [all[0]], until: Date().addingTimeInterval(3600), folder: folder)
            try ServerSnooze.snooze(a, uids: [all[1]], until: Date().addingTimeInterval(-120), folder: folder)
            var d = try dump(b)
            check(ids(d, folder) == ["<m1@example.invalid>", "<m2@example.invalid>"] && ids(d, "INBOX") == ["<m3@example.invalid>"], "snoozed mails moved, third stays")

            let e = try ServerSnooze.entries(b, folder: folder)
            check(e.count == 2 && e.filter(\.isDue).count == 1, "second instance sees 2 snoozed, 1 due")
            check(abs((e.first { !$0.isDue }?.until ?? .distantPast).timeIntervalSinceNow - 3600) < 120, "wake time round-trips via keyword")

            // Both instances wake at the same moment, many times: exactly one copy must arrive.
            let group = DispatchGroup()
            for c in [a, b] {
                group.enter()
                DispatchQueue.global().async { _ = try? ServerSnooze.wakeDue(c, folder: folder); group.leave() }
            }
            group.wait()
            d = try dump(a)
            check(ids(d, "INBOX") == ["<m2@example.invalid>", "<m3@example.invalid>"], "racing wake: due mail in INBOX exactly once")
            check(ids(d, folder) == ["<m1@example.invalid>"], "future snooze untouched")
            let woken = (d["INBOX"] ?? [:]).values.first { ($0["id"] as? String) == "<m2@example.invalid>" }
            check(!((woken?["flags"] as? [String]) ?? []).contains { $0.hasPrefix("$InkwellSnooze_") || $0 == "\\Seen" }, "woken mail is unread without snooze keyword")

            // Crash leftover: a mail in the folder without keyword wakes immediately.
            try a.append(folder, flags: "", message: Data("From: a@example.invalid\r\nSubject: orphan\r\nMessage-ID: <orphan@example.invalid>\r\n\r\nx\r\n".utf8))
            _ = try ServerSnooze.wakeDue(b, folder: folder)
            d = try dump(a)
            check(ids(d, "INBOX").contains("<orphan@example.invalid>") && ids(d, folder) == ["<m1@example.invalid>"], "mail without keyword is woken (fail-safe)")

            // Waking a message another instance already moved is not an error.
            let stale = try ServerSnooze.entries(a, folder: folder)
            _ = try ServerSnooze.wake(b, folder: folder, entries: stale)
            check((try? ServerSnooze.wake(a, folder: folder, entries: stale)) != nil, "waking an already moved mail is harmless")
            d = try dump(a)
            check(ids(d, "INBOX").filter { $0 == "<m1@example.invalid>" }.count == 1, "still exactly one copy")
        } catch {
            print("✗ unexpected error: \(error)")
            failures += 1
        }
        print(failures == 0 ? "All snooze checks passed" : "\(failures) check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
