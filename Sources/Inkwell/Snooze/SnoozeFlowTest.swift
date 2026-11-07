import Foundation

/// `Inkwell --snoozeflow <port>` (isolated INKWELL_HOME + INKWELL_INSECURE_LOCAL=1, see scripts/test_snooze.py):
/// drives the real MailStore as "Mac A" against fake_imap_multi.py, while a bare IMAP client plays "Mac B".
enum SnoozeFlowTest {
    static func start(args: [String]) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let i = args.firstIndex(of: "--snoozeflow"), args.indices.contains(i + 1), let port = Int(args[i + 1]) else { print("usage: --snoozeflow <port>"); exit(2) }
        Task { @MainActor in
            let ok = await run(port: port)
            print(ok ? "All snooze flow checks passed" : "snooze flow FAILED")
            exit(ok ? 0 : 1)
        }
        dispatchMain()
    }

    @MainActor static func run(port: Int) async -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "✓ \(what)" : "✗ \(what)"); if !ok { failures += 1 } }
        func wait(_ what: String, _ cond: @MainActor () -> Bool) async {
            for _ in 0..<100 { if cond() { return }; try? await Task.sleep(nanoseconds: 100_000_000) }
            print("… timed out waiting for \(what)")
        }
        do {
            let b = try SnoozeTest.client(port)
            for n in 1...3 { try SnoozeTest.put(b, n) }
            let store = MailStore.shared
            var acct = Account(label: "Test", displayName: "Me", email: "me@example.invalid", username: "u", imapHost: "127.0.0.1", smtpHost: "127.0.0.1")
            acct.imapPort = port
            store.settings.accounts = [acct]
            store.startAccount(acct)
            let aid = acct.id.uuidString
            func count(_ folder: String) -> Int { store.db.query("SELECT COUNT(*) FROM messages WHERE account=? AND folder=?", [aid, folder]) { $0.int(0) }.first ?? 0 }
            func inboxThreads() -> [String] { store.mailbox = .allInboxes; store.reloadNow(); return store.threads.map(\.latest.subject).sorted() }
            func thread(_ subject: String) -> ThreadSummary? { store.mailbox = .allInboxes; store.reloadNow(); return store.threads.first { $0.latest.subject == subject } }
            await wait("initial sync") { count("INBOX") == 3 }
            if count("INBOX") != 3 { print("account error:", store.accountErrors[acct.id] ?? "none") }
            check(count("INBOX") == 3, "Mac A synced 3 mails")

            // Mac A snoozes m1 via the app.
            guard let t1 = thread("m1") else { print("✗ thread m1 missing"); return false }
            await store.snoozeOnServer([t1], until: Date().addingTimeInterval(3600))
            var d = try SnoozeTest.dump(b)
            check(SnoozeTest.ids(d, ServerSnooze.defaultFolder) == ["<m1@example.invalid>"], "server: m1 is in the Wiedervorlage folder")
            check(!inboxThreads().contains("m1"), "m1 hidden from the inbox list")
            let rows = store.db.query("SELECT server FROM snoozes WHERE account=?", [aid]) { $0.int(0) }
            check(rows == [1], "cache row marked server=1")
            store.mailbox = .snoozed; store.reloadNow()
            check(store.threads.map(\.latest.subject) == ["m1"], "Snoozed view shows m1")

            // Mac B snoozes m2 (due in an hour); Mac A learns about it at its next cycle.
            _ = try b.select("INBOX")
            let u2 = Array(try b.uidSearch("ALL").sorted().prefix(1))  // m1 is gone, so this is m2
            try ServerSnooze.snooze(b, uids: u2, until: Date().addingTimeInterval(3600), folder: ServerSnooze.defaultFolder)
            await store.snoozeCycle(acct.id)
            let rows2 = store.db.query("SELECT COUNT(*) FROM snoozes WHERE account=? AND server=1", [aid]) { $0.int(0) }.first ?? 0
            check(rows2 == 2, "Mac A picked up Mac B's snooze (2 cached)")

            // Mac B makes m1 due (swaps the keyword for a past one); Mac A wakes it.
            let entries = try ServerSnooze.entries(b, folder: ServerSnooze.defaultFolder)
            if let e1 = entries.first(where: { $0.until != nil }) {
                _ = try b.select(ServerSnooze.defaultFolder)
                // pick the m1 message: the first uid in the folder
                let first = try b.uidSearch("ALL").min() ?? e1.uid
                try b.store("\(first)", flags: e1.keywords.joined(separator: " "), add: false)
                try b.store("\(first)", flags: ServerSnooze.keyword(for: Date().addingTimeInterval(-300)), add: true)
            }
            await store.snoozeCycle(acct.id)
            d = try SnoozeTest.dump(b)
            check(SnoozeTest.ids(d, "INBOX").filter { $0 == "<m1@example.invalid>" }.count == 1, "due snooze woke: m1 in INBOX exactly once")
            let bump = store.db.query("SELECT COUNT(*) FROM bumps WHERE account=?", [aid]) { $0.int(0) }.first ?? 0
            check(bump >= 1, "woken thread is bumped to the top")
            check((SnoozeTest.ids(d, ServerSnooze.defaultFolder)) == ["<m2@example.invalid>"], "m2 still snoozed")

            // Unsnooze m2 from Mac A.
            store.mailbox = .snoozed; store.reloadNow()
            if let t2 = store.threads.first(where: { $0.latest.subject == "m2" }) {
                store.unsnooze([t2])
                await wait("unsnooze") { (try? SnoozeTest.ids(SnoozeTest.dump(b), ServerSnooze.defaultFolder).isEmpty) ?? false }
            }
            d = try SnoozeTest.dump(b)
            check(SnoozeTest.ids(d, ServerSnooze.defaultFolder).isEmpty && SnoozeTest.ids(d, "INBOX").count == 3, "unsnooze: all three mails back in INBOX")
            check((store.db.query("SELECT COUNT(*) FROM snoozes WHERE account=?", [aid]) { $0.int(0) }.first ?? 9) == 0, "cache empty")

            // A reply from someone else arrives in a snoozed thread: the thread wakes by itself.
            if let t3 = thread("m3") {
                await store.snoozeOnServer([t3], until: Date().addingTimeInterval(3600))
                check(SnoozeTest.ids(try SnoozeTest.dump(b), ServerSnooze.defaultFolder) == ["<m3@example.invalid>"], "m3 snoozed")
                let reply = "From: other@example.invalid\r\nTo: me@example.invalid\r\nSubject: Re: m3\r\nMessage-ID: <r3@example.invalid>\r\nIn-Reply-To: <m3@example.invalid>\r\nReferences: <m3@example.invalid>\r\n\r\nreply\r\n"
                try b.append("INBOX", flags: "", message: Data(reply.utf8))
                store.sync(accountId: acct.id)
                await wait("reply wake") { ((try? SnoozeTest.ids(SnoozeTest.dump(b), ServerSnooze.defaultFolder).isEmpty) ?? false) }
                d = try SnoozeTest.dump(b)
                check(SnoozeTest.ids(d, ServerSnooze.defaultFolder).isEmpty && SnoozeTest.ids(d, "INBOX").contains("<m3@example.invalid>"), "reply woke the snoozed thread")
            } else { check(false, "thread m3 missing") }
        } catch {
            print("✗ unexpected error: \(error)")
            failures += 1
        }
        return failures == 0
    }
}
