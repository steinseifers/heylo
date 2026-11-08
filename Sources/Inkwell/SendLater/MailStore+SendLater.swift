import Foundation
import CryptoKit

/// Glue for server-side send-later: scheduling, the per-account send cycle, and the "Scheduled" list.
/// Messages that the server can't hold (no keywords/CONDSTORE) keep using the local scheduler (single Mac).
extension MailStore {
    /// Identifies this Mac/process in claim keywords.
    static let sendInstanceID = String(UUID().uuidString.prefix(8)).lowercased()

    struct BuiltMessage {
        var acct: Account
        var to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress]
        var from: EmailAddress
        var data: Data
        var mid: String
    }

    /// Builds the final message for a draft. With `includeBcc` the Bcc header is kept (stored copies need the envelope).
    func buildOutgoing(_ d: OutgoingDraft, includeBcc: Bool = false) throws -> BuiltMessage {
        guard let (acct, alias) = identity(for: d.accountId, fromEmail: d.fromEmail) else { throw MailError.protocolError("No account to send from") }
        let to = MIME.parseAddressList(d.to), cc = MIME.parseAddressList(d.cc), bcc = MIME.parseAddressList(d.bcc)
        guard !(to + cc + bcc).isEmpty else { throw MailError.protocolError("Add at least one recipient") }
        let from = EmailAddress(name: alias?.name.isEmpty == false ? alias!.name : acct.displayName, email: alias?.email ?? acct.email)
        var atts: [MIME.OutgoingAttachment] = []
        for u in d.attachments {
            guard let data = try? Data(contentsOf: u) else { continue }
            atts.append(.init(filename: u.lastPathComponent, mimeType: MIME.mimeType(for: u), data: data))
        }
        var extra: [(String, String)] = []
        if d.requestReadReceipt { extra.append(("Disposition-Notification-To", from.email)) }
        if includeBcc, !bcc.isEmpty { extra.append(("Bcc", d.bcc)) }
        if includeBcc {  // scheduled: the Mac that sends applies S/MIME with its own keychain
            let plan = SMIMESending.plan(for: d, from: (alias?.email ?? acct.email), recipients: (to + cc + bcc).map(\.email))
            if let m = SMIMESending.marker(sign: plan.sign, encrypt: plan.encrypt) { extra.append((SMIMESending.headerName, m)) }
        }
        let html = "<html><body>\(d.html.isEmpty ? HTMLText.fromPlain(d.plain) : d.html)\(d.quotedHTML.isEmpty ? "" : "<br>" + d.quotedHTML)</body></html>"
        let text = d.plain + (d.quotedPlain.isEmpty ? "" : "\n\n" + d.quotedPlain)
        let (data, mid) = MIME.build(from: from, to: to, cc: cc, replyTo: alias?.replyTo, subject: d.subject, text: text, html: html,
                                     inReplyTo: d.inReplyTo.isEmpty ? nil : d.inReplyTo,
                                     references: d.references.split(separator: " ").map(String.init), attachments: atts, extraHeaders: extra)
        return BuiltMessage(acct: acct, to: to, cc: cc, bcc: bcc, from: from, data: data, mid: mid)
    }

    private func scheduledToast(_ at: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
        return "Scheduled for \(f.string(from: at))"
    }

    // MARK: scheduling

    /// Single-Mac fallback (the previous behaviour): the draft waits in the local database.
    func scheduleLocally(_ d: OutgoingDraft, at: Date) {
        if let json = try? JSONEncoder().encode(d) {
            db.exec("INSERT OR REPLACE INTO scheduled(id, json, send_at) VALUES(?,?,?)", [d.id.uuidString, json, at])
        }
        showToast(scheduledToast(at)) { [weak self] in
            self?.db.exec("DELETE FROM scheduled WHERE id=?", [d.id.uuidString])
            self?.drafts[d.id] = d
            self?.openCompose?(d.id)
        }
    }

    /// Stores the finished message in the account's Drafts folder with its send time. False if the server can't hold it.
    func scheduleOnServer(_ d: OutgoingDraft, at: Date) async -> Bool {
        guard let b = try? buildOutgoing(d, includeBcc: true), let folder = b.acct.draftsFolder, let conn = connections[b.acct.id] else { return false }
        let mid = "<\(b.mid)>"
        do { try await conn.run { c in try ScheduledSend.schedule(c, folder: folder, message: b.data, messageID: mid, sendAt: at) } }
        catch { return false }
        showToast(scheduledToast(at)) { [weak self] in
            guard let self else { return }
            Task {
                await self.deleteServerDraft(account: b.acct, messageId: b.mid)
                self.drafts[d.id] = d
                self.openCompose?(d.id)
                await self.sendLaterCycle(b.acct.id, force: true)
            }
        }
        Task { await sendLaterCycle(b.acct.id, force: true) }
        return true
    }

    // MARK: cycle

    func sendLaterTick() {
        let now = Date()
        for a in settings.accounts where a.enabled && connections[a.id] != nil && a.draftsFolder != nil {
            if now.timeIntervalSince(sendLaterLast[a.id] ?? .distantPast) >= 60 { Task { await sendLaterCycle(a.id) } }
        }
    }

    /// Sends what is due (after winning the server-side claim) and refreshes the list of scheduled messages.
    func sendLaterCycle(_ id: UUID, force: Bool = false) async {
        guard let conn = connections[id], let acct = account(id), let folder = acct.draftsFolder, !sendLaterBusy.contains(id) else { return }
        sendLaterBusy.insert(id)
        defer { sendLaterBusy.remove(id); sendLaterLast[id] = Date() }
        let autoFiles = acct.isGmail || acct.smtpHost.contains("office365") || acct.smtpHost.contains("outlook")
        do {
            let (outcomes, infos) = try await conn.run { c -> ([ScheduledSend.Outcome], [ScheduledSend.Info]) in
                let outcomes = try ScheduledSend.processDue(c, folder: folder, instance: MailStore.sendInstanceID, send: { raw in
                    let env = ScheduledSend.envelope(raw)
                    guard !env.recipients.isEmpty else { throw ScheduledSend.NotSent(underlying: nil) }
                    let final: Data
                    do { final = try SMIMESending.applyMarker(to: env.message, from: env.from, recipients: env.recipients) }
                    catch { throw ScheduledSend.NotSent(underlying: error) }  // e.g. no certificate on this Mac: another Mac may send it
                    if GraphMail.uses(acct) {
                        // Microsoft 365 via Graph: a client error or missing token proves nothing was sent (NotSent);
                        // a timeout or server error may have delivered the message (stays claimed, never retried).
                        try GraphMail.sendBlocking(account: acct, mime: GraphMail.withBcc(final, bcc: MIME.parse(raw).header("Bcc")))
                        return
                    }
                    let smtp: SMTPClient
                    do { smtp = try SMTPClient(host: acct.smtpHost, port: acct.smtpPort, security: acct.smtpSecurity); try smtp.login(account: acct) }
                    catch { throw ScheduledSend.NotSent(underlying: error) }
                    try smtp.sendMail(from: env.from, recipients: env.recipients, data: final)
                    smtp.quit()
                }, afterSend: { _, raw in
                    // Gmail and Microsoft file sent mail themselves.
                    if !autoFiles, let sent = acct.sentFolder { try? c.append(sent, flags: "\\Seen", message: ScheduledSend.stripBcc(ScheduledSend.stripHeader(raw, SMIMESending.headerName))) }
                })
                return (outcomes, try ScheduledSend.infos(c, folder: folder))
            }
            serverScheduled[id] = infos
            for o in outcomes {
                switch o {
                case .sent: sync(accountId: id)
                case .stuck(let uid, _):
                    if stuckNotified.insert("\(id)-\(uid)").inserted {
                        showToast("A scheduled message was claimed but never finished. It may or may not have been sent. Check Sent; the message is still in Drafts.", isError: true)
                    }
                default: break
                }
            }
        } catch {
            // Offline or transient: the next tick tries again. Nothing was sent without a won claim.
        }
    }

    // MARK: list, cancel, send now

    /// Server-side scheduled messages, shaped like drafts for the existing list.
    func serverScheduledDrafts() -> [OutgoingDraft] {
        serverScheduled.flatMap { (acct, infos) in
            infos.map { i -> OutgoingDraft in
                var d = OutgoingDraft()
                let h = Array(SHA256.hash(data: Data(i.messageID.utf8)).prefix(16))
                d.id = UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
                d.accountId = acct
                d.to = i.to; d.subject = i.subject; d.sendAt = i.sendAt
                d.serverDraftMessageId = i.messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                d.plain = i.stuck ? "Claimed but not finished: check Sent before sending again." : (i.claimed ? "Sending…" : "")
                return d
            }
        }
    }

    func scheduledDrafts() -> [OutgoingDraft] {
        (legacyScheduledDrafts() + serverScheduledDrafts()).sorted { ($0.sendAt ?? .distantFuture) < ($1.sendAt ?? .distantFuture) }
    }

    func cancelScheduled(_ d: OutgoingDraft) {
        guard let mid = d.serverDraftMessageId, let acctId = d.accountId, let acct = account(acctId), let folder = acct.draftsFolder, let conn = connections[acctId] else {
            cancelScheduledLocally(d); return
        }
        Task {
            // Take the message back (only if nobody claimed it), turn it into an editable draft, remove it from the server.
            let raw: Data? = try? await conn.run { c in
                _ = try c.select(folder)
                guard let uid = try c.uidSearch("HEADER Message-ID \(IMAPClient.quote("<\(mid)>"))").last,
                      let e = try ScheduledSend.entries(c, folder: folder).first(where: { $0.uid == uid }), e.claimedAt == nil else { return nil }
                let data = try c.fetch("\(uid)", items: "BODY.PEEK[]").first?.body
                if data != nil { try c.expunge("\(uid)") }
                return data
            }
            guard let raw else { showToast("This message is already being sent.", isError: true); await sendLaterCycle(acctId, force: true); return }
            let p = MIME.parse(raw)
            var draft = OutgoingDraft()
            draft.accountId = acctId; draft.fromEmail = p.from.email
            draft.to = p.header("To"); draft.cc = p.header("Cc"); draft.bcc = p.header("Bcc"); draft.subject = p.subject
            draft.plain = p.text; draft.html = p.html; draft.inReplyTo = p.header("In-Reply-To"); draft.references = p.header("References")
            drafts[draft.id] = draft
            openCompose?(draft.id)
            await sendLaterCycle(acctId, force: true)
        }
    }

    /// "Send Now" for a scheduled message: moves its send time to now; the cycle sends it (once).
    func sendScheduledNow(_ d: OutgoingDraft) {
        guard let mid = d.serverDraftMessageId, let acctId = d.accountId, let acct = account(acctId), let folder = acct.draftsFolder, let conn = connections[acctId] else {
            db.exec("DELETE FROM scheduled WHERE id=?", [d.id.uuidString])
            var c = d; c.sendAt = nil; queueSend(c); return
        }
        Task {
            _ = try? await conn.run { c in try ScheduledSend.reschedule(c, folder: folder, messageID: "<\(mid)>", to: Date().addingTimeInterval(-1)) }
            await sendLaterCycle(acctId, force: true)
        }
    }
}
