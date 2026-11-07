import Foundation

/// `Inkwell --sendtest <imapPort> <smtpPort> [nocondstore]` against fake_imap_multi.py and fake_smtp.py (see scripts/test_sendlater.py).
enum SendLaterTest {
    static func run(args: [String]) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let i = args.firstIndex(of: "--sendtest"), args.indices.contains(i + 2), let imap = Int(args[i + 1]), let smtp = Int(args[i + 2]) else { print("usage"); exit(2) }
        let noCondstore = args.contains("nocondstore")
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "✓ \(what)" : "✗ \(what)"); if !ok { failures += 1 } }
        func message(_ n: Int) -> (Data, String) {
            let id = "<sl\(n)-\(UUID().uuidString.prefix(6))@example.invalid>"
            return (Data("From: me@example.invalid\r\nTo: you@example.invalid\r\nBcc: hidden@example.invalid\r\nSubject: later \(n)\r\nMessage-ID: \(id)\r\n\r\nbody \(n)\r\n".utf8), id)
        }
        func sender(_ raw: Data) throws {
            let s: SMTPClient
            do { s = try SMTPClient(host: "127.0.0.1", port: smtp, security: .ssl); try s.loginXOAUTH2(user: "u", token: "t") }
            catch { throw ScheduledSend.NotSent(underlying: error) }
            try s.sendMail(from: "me@example.invalid", recipients: ["you@example.invalid"], data: raw)
            s.quit()
        }
        func drafts(_ c: IMAPClient) throws -> [String: Any] { (try SnoozeTest.dump(c))["Drafts"] ?? [:] }
        do {
            let a = try SnoozeTest.client(imap), b = try SnoozeTest.client(imap)
            try a.create("Drafts")
            if noCondstore {
                let (m, id) = message(0)
                do { try ScheduledSend.schedule(a, folder: "Drafts", message: m, messageID: id, sendAt: Date().addingTimeInterval(3600)); check(false, "scheduling must be refused without CONDSTORE") }
                catch ScheduledSend.SchedulingError.unsupported { check(true, "server without CONDSTORE: scheduling refused, message stays local") }
                exit(failures == 0 ? 0 : 1)
            }
            // 1. 100 messages, due, two instances racing.
            for n in 1...100 { let (m, id) = message(n); try ScheduledSend.schedule(a, folder: "Drafts", message: m, messageID: id, sendAt: Date().addingTimeInterval(-60)) }
            check(try SnoozeTest.dump(a)["Drafts"]?.count == 100, "100 scheduled messages wait in Drafts")
            let group = DispatchGroup()
            var results: [[ScheduledSend.Outcome]] = [[], []]
            let lock = NSLock()
            for (idx, c) in [a, b].enumerated() {
                group.enter()
                DispatchQueue.global().async {
                    var all: [ScheduledSend.Outcome] = []
                    for _ in 0..<5 { if let o = try? ScheduledSend.processDue(c, folder: "Drafts", instance: "mac\(idx)", send: sender) { all += o } }
                    lock.lock(); results[idx] = all; lock.unlock(); group.leave()
                }
            }
            group.wait()
            let sentCount = results.flatMap { $0 }.filter { if case .sent = $0 { return true } else { return false } }.count
            check(sentCount == 100, "both instances together report exactly 100 sends (got \(sentCount))")
            check(try drafts(a).isEmpty, "Drafts is empty afterwards")

            // 2. Not due yet: untouched.
            let (m2, id2) = message(201)
            try ScheduledSend.schedule(a, folder: "Drafts", message: m2, messageID: id2, sendAt: Date().addingTimeInterval(3600))
            _ = try ScheduledSend.processDue(b, folder: "Drafts", instance: "macB", send: sender)
            check(try drafts(a).count == 1, "a message that is not due yet stays")

            // 3. Certain non-delivery releases the claim, then it is retried.
            let (m3, id3) = message(301)
            try ScheduledSend.schedule(a, folder: "Drafts", message: m3, messageID: id3, sendAt: Date().addingTimeInterval(-10))
            let first = try ScheduledSend.processDue(a, folder: "Drafts", instance: "macA", send: { _ in throw ScheduledSend.NotSent(underlying: nil) })
            check(first.contains { if case .retryLater = $0 { return true } else { return false } }, "NotSent releases the claim")
            let second = try ScheduledSend.processDue(b, folder: "Drafts", instance: "macB", send: sender)
            check(second.contains { if case .sent = $0 { return true } else { return false } }, "released message is sent by the next run")

            // 4. Crash after the claim: never resent automatically, reported as stuck.
            let (m4, id4) = message(401)
            try ScheduledSend.schedule(a, folder: "Drafts", message: m4, messageID: id4, sendAt: Date().addingTimeInterval(-3600))
            let e4 = try ScheduledSend.entries(a, folder: "Drafts").first { $0.claimedAt == nil && ($0.sendAt ?? .distantFuture) < Date() }!
            _ = try ScheduledSend.claim(a, entry: e4, instance: "crashed", now: Date().addingTimeInterval(-3600))  // instance dies right after claiming
            var sentAgain = false
            let out4 = try ScheduledSend.processDue(b, folder: "Drafts", instance: "macB", send: { d in sentAgain = true; try sender(d) })
            check(!sentAgain && out4.contains { if case .stuck = $0 { return true } else { return false } }, "hanging claim is reported as stuck and NOT resent")
            check(try drafts(a).count == 2, "stuck message stays in Drafts for the user to decide")
        } catch { check(false, "unexpected error: \(error.localizedDescription)") }
        print(failures == 0 ? "All send-later checks passed" : "\(failures) check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

/// `Inkwell --sendflow <imapPort> <smtpPort> <smtpLog>`: the real MailStore schedules, sends now and cancels.
enum SendFlowTest {
    static func start(args: [String]) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let i = args.firstIndex(of: "--sendflow"), args.indices.contains(i + 3), let imap = Int(args[i + 1]), let smtp = Int(args[i + 2]) else { print("usage"); exit(2) }
        let log = args[i + 3]
        Task { @MainActor in
            let ok = await run(imap: imap, smtp: smtp, log: log)
            print(ok ? "All send flow checks passed" : "send flow FAILED")
            exit(ok ? 0 : 1)
        }
        dispatchMain()
    }

    @MainActor static func run(imap: Int, smtp: Int, log: String) async -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "✓ \(what)" : "✗ \(what)"); if !ok { failures += 1 } }
        func wait(_ cond: @MainActor () -> Bool) async { for _ in 0..<150 { if cond() { return }; try? await Task.sleep(nanoseconds: 100_000_000) } }
        func deliveries() -> [String] { ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        do {
            let b = try SnoozeTest.client(imap)
            try b.create("Drafts"); try b.create("Sent")
            let store = MailStore.shared
            var acct = Account(label: "T", displayName: "Me", email: "me@example.invalid", username: "u", imapHost: "127.0.0.1", smtpHost: "127.0.0.1")
            acct.imapPort = imap; acct.smtpPort = smtp; acct.draftsFolder = "Drafts"; acct.sentFolder = "Sent"
            store.settings.accounts = [acct]
            store.startAccount(acct)
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            var d = OutgoingDraft()
            d.accountId = acct.id; d.fromEmail = acct.email; d.to = "you@example.invalid"; d.bcc = "hidden@example.invalid"; d.subject = "S1"; d.plain = "hello"
            d.sendAt = Date().addingTimeInterval(3600)
            store.queueSend(d)
            await wait { store.scheduledDrafts().count == 1 }
            check(store.scheduledDrafts().count == 1, "scheduled message shows in the Scheduled list")
            check(((try SnoozeTest.dump(b))["Drafts"]?.count ?? 0) == 1, "the message waits in the server's Drafts folder")
            check(store.db.query("SELECT COUNT(*) FROM scheduled") { $0.int(0) }.first == 0, "nothing sits in the local single-Mac scheduler")
            check(deliveries().isEmpty, "nothing was sent yet")

            store.sendScheduledNow(store.scheduledDrafts()[0])
            await wait { deliveries().count >= 1 }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            check(deliveries().count == 1, "Send Now delivers exactly once (\(deliveries().count))")
            check(deliveries().first?.contains("hidden@example.invalid") == true, "the Bcc recipient is part of the envelope")
            let dump = try SnoozeTest.dump(b)
            check((dump["Drafts"]?.count ?? 0) == 0, "Drafts is empty after sending")
            check((dump["Sent"]?.count ?? 0) == 1, "a copy was filed in Sent")

            // Cancel: the message comes back as an editable draft and leaves the server.
            var d2 = d; d2.id = UUID(); d2.subject = "S2"
            store.queueSend(d2)
            await wait { store.scheduledDrafts().count == 1 }
            let before = store.drafts.count
            store.cancelScheduled(store.scheduledDrafts()[0])
            await wait { store.drafts.count > before }
            check(store.drafts.values.contains { $0.subject == "S2" }, "cancel reopens the message as an editable draft")
            check(((try SnoozeTest.dump(b))["Drafts"]?.count ?? 0) == 0 && deliveries().count == 1, "cancelled message left the server and was never sent")
        } catch { check(false, "unexpected error: \(error.localizedDescription)") }
        return failures == 0
    }
}
