import Foundation

/// Server-side "send later". The finished message waits in the Drafts folder, its send time is an
/// IMAP keyword (`$InkwellSendAt_<UTC>`). Before sending, an instance must win an atomic claim:
/// `UID STORE … (UNCHANGEDSINCE <modseq>) +FLAGS ($InkwellClaim_<instance>_<time>)` succeeds for
/// exactly one client, because the first store changes the message's mod-sequence. Only the winner
/// sends. See docs/p5-p6-senden-lokalisierung.md and docs/multi-mac.md.
///
/// Absolute rule: never send twice. After a claim, nothing is retried automatically unless the
/// sender proves nothing was sent (`NotSent`). A claim that stays unfinished is reported as
/// `.stuck` and left for the user to decide.
enum ScheduledSend {
    static let sendAtPrefix = "$InkwellSendAt_"
    static let claimPrefix = "$InkwellClaim_"
    static let sentKeyword = "$InkwellSent"
    /// A claim older than this without a result is treated as stuck.
    static var claimTimeout: TimeInterval = 600

    /// Thrown by the send closure when it is certain that nothing was handed to the mail server
    /// (e.g. connection or login failed). The claim is released and the next cycle retries.
    struct NotSent: Error { var underlying: Error? }
    enum SchedulingError: LocalizedError {
        case unsupported
        var errorDescription: String? { "This server can't hold a scheduled message safely (needs custom keywords and CONDSTORE), so the message stays on this Mac." }
    }

    struct Entry: Equatable {
        var uid: UInt32
        var modseq: UInt64
        var sendAt: Date?
        var claimedBy: String?
        var claimedAt: Date?
        var claimKeyword: String?
        var sent: Bool
    }

    enum Outcome: Equatable {
        case sent(uid: UInt32)
        /// Another instance claimed it first, or it isn't due.
        case skipped(uid: UInt32)
        /// Not sent, claim released; will be retried.
        case retryLater(uid: UInt32)
        /// A claim without result for too long. Not sent again automatically; ask the user.
        case stuck(uid: UInt32, claimedAt: Date)
    }

    // MARK: keywords

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    static func keyword(sendAt: Date) -> String { sendAtPrefix + formatter.string(from: sendAt) }

    static func parse(uid: UInt32, modseq: UInt64, flags: [String]) -> Entry {
        var e = Entry(uid: uid, modseq: modseq, sendAt: nil, claimedBy: nil, claimedAt: nil, claimKeyword: nil, sent: false)
        for f in flags {
            if f.hasPrefix(sendAtPrefix) { e.sendAt = formatter.date(from: String(f.dropFirst(sendAtPrefix.count))) }
            else if f.hasPrefix(claimPrefix) {
                let parts = f.dropFirst(claimPrefix.count).split(separator: "_")
                if parts.count == 2, let t = TimeInterval(parts[1]) { e.claimedBy = String(parts[0]); e.claimedAt = Date(timeIntervalSince1970: t); e.claimKeyword = f }
            } else if f == sentKeyword { e.sent = true }
        }
        return e
    }

    // MARK: server operations (account connection queue)

    /// Lists messages in `folder` that carry a send time.
    static func entries(_ c: IMAPClient, folder: String) throws -> [Entry] {
        guard (try? c.select(folder)) != nil else { return [] }
        var out: [Entry] = []
        for line in try c.command("UID FETCH 1:* (UID FLAGS MODSEQ)") {
            let s = String(decoding: line, as: UTF8.self)
            guard let uid = s.firstMatch(#"UID (\d+)"#).flatMap(UInt32.init), let flags = s.firstMatch(#"FLAGS \(([^)]*)\)"#) else { continue }
            let modseq = s.firstMatch(#"MODSEQ \((\d+)\)"#).flatMap(UInt64.init) ?? 0
            let e = parse(uid: uid, modseq: modseq, flags: flags.split(separator: " ").map(String.init))
            if e.sendAt != nil { out.append(e) }
        }
        return out.sorted { ($0.sendAt ?? .distantFuture) < ($1.sendAt ?? .distantFuture) }
    }

    /// Stores a finished message (full RFC 822, `Bcc:` header kept for the envelope) for sending at `sendAt`.
    /// Verifies the server kept the keyword and supports atomic claims; otherwise nothing stays behind.
    static func schedule(_ c: IMAPClient, folder: String, message: Data, messageID: String, sendAt: Date) throws {
        guard c.supportsCondstore else { throw SchedulingError.unsupported }
        let kw = keyword(sendAt: sendAt)
        try c.append(folder, flags: "\\Draft \\Seen \(kw)", message: message)
        _ = try c.select(folder)
        let uids = try c.uidSearch("HEADER Message-ID \(IMAPClient.quote(messageID))")
        guard let uid = uids.last else { throw SchedulingError.unsupported }
        let flags = try c.command("UID FETCH \(uid) (FLAGS)").map { String(decoding: $0, as: UTF8.self) }.joined()
        if !flags.contains(kw) {
            try? c.expunge(IMAPClient.uidSet(uids))
            throw SchedulingError.unsupported
        }
    }

    /// Atomic claim. True only for the instance whose store was applied.
    static func claim(_ c: IMAPClient, entry: Entry, instance: String, now: Date = Date()) throws -> String? {
        let kw = "\(claimPrefix)\(instance)_\(Int(now.timeIntervalSince1970))"
        try c.command("UID STORE \(entry.uid) (UNCHANGEDSINCE \(entry.modseq)) +FLAGS.SILENT (\(kw))")
        let flags = try c.command("UID FETCH \(entry.uid) (FLAGS)").map { String(decoding: $0, as: UTF8.self) }.joined()
        return flags.contains(kw) ? kw : nil
    }

    static func releaseClaim(_ c: IMAPClient, uid: UInt32, keyword: String) { try? c.store("\(uid)", flags: keyword, add: false) }

    /// Sends everything that is due. `send` receives the stored message and must throw `NotSent` if it is
    /// certain that nothing was delivered. Call on the account's connection queue; safe to run on several Macs at once.
    static func processDue(_ c: IMAPClient, folder: String, instance: String, now: Date = Date(),
                           send: (Data) throws -> Void, afterSend: ((UInt32, Data) -> Void)? = nil) throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for e in try entries(c, folder: folder) {
            guard let at = e.sendAt, at <= now else { continue }
            if e.sent { try finish(c, uid: e.uid); continue }   // sent earlier, only the cleanup was missing
            if let claimedAt = e.claimedAt {
                if now.timeIntervalSince(claimedAt) > claimTimeout, e.claimedBy != nil { outcomes.append(.stuck(uid: e.uid, claimedAt: claimedAt)) }
                else { outcomes.append(.skipped(uid: e.uid)) }
                continue
            }
            guard let kw = try claim(c, entry: e, instance: instance, now: now) else { outcomes.append(.skipped(uid: e.uid)); continue }
            guard let raw = try c.fetch("\(e.uid)", items: "BODY.PEEK[]").first?.body else { releaseClaim(c, uid: e.uid, keyword: kw); outcomes.append(.retryLater(uid: e.uid)); continue }
            do { try send(raw) }
            catch is NotSent { releaseClaim(c, uid: e.uid, keyword: kw); outcomes.append(.retryLater(uid: e.uid)); continue }
            // From here on the message may be out: never retry. Mark first, clean up second.
            try? c.store("\(e.uid)", flags: sentKeyword, add: true)
            afterSend?(e.uid, raw)
            try? finish(c, uid: e.uid)
            outcomes.append(.sent(uid: e.uid))
        }
        return outcomes
    }

    /// Moves the send time of a waiting message to `date` (used by "Send Now"); a claimed message is left alone.
    static func reschedule(_ c: IMAPClient, folder: String, messageID: String, to date: Date) throws {
        _ = try c.select(folder)
        for uid in try c.uidSearch("HEADER Message-ID \(IMAPClient.quote(messageID))") {
            let flags = try c.command("UID FETCH \(uid) (FLAGS)").map { String(decoding: $0, as: UTF8.self) }.joined()
            guard let f = flags.firstMatch(#"FLAGS \(([^)]*)\)"#) else { continue }
            let e = parse(uid: uid, modseq: 0, flags: f.split(separator: " ").map(String.init))
            guard e.claimedAt == nil else { continue }
            for old in f.split(separator: " ") where old.hasPrefix(sendAtPrefix) { try c.store("\(uid)", flags: String(old), add: false) }
            try c.store("\(uid)", flags: keyword(sendAt: date), add: true)
        }
    }

    /// Envelope data of a stored message: recipients from To/Cc/Bcc, sender, and the message without its Bcc header.
    static func envelope(_ raw: Data) -> (from: String, recipients: [String], message: Data) {
        let p = MIME.parse(raw)
        let rcpt = (MIME.parseAddressList(p.header("To")) + MIME.parseAddressList(p.header("Cc")) + MIME.parseAddressList(p.header("Bcc"))).map(\.email)
        return (p.from.email, Array(NSOrderedSet(array: rcpt)) as? [String] ?? rcpt, stripBcc(raw))
    }

    static func stripHeader(_ raw: Data, _ name: String) -> Data { stripBcc(raw, header: name) }

    static func stripBcc(_ raw: Data, header: String = "bcc") -> Data {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { return raw }
        let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
        var out: [String] = [], skipping = false
        for line in head.components(separatedBy: "\r\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") { if !skipping { out.append(line) }; continue }
            skipping = line.lowercased().hasPrefix(header.lowercased() + ":")
            if !skipping { out.append(line) }
        }
        return Data(out.joined(separator: "\r\n").utf8) + raw[split.lowerBound...]
    }

    struct Info {
        var uid: UInt32
        var sendAt: Date
        var subject: String
        var to: String
        var messageID: String
        var claimed: Bool
        var stuck: Bool
    }

    /// What the "Scheduled" list shows.
    static func infos(_ c: IMAPClient, folder: String, now: Date = Date()) throws -> [Info] {
        let es = try entries(c, folder: folder).filter { !$0.sent }
        guard !es.isEmpty else { return [] }
        let headers = Dictionary(uniqueKeysWithValues: try c.fetch(IMAPClient.uidSet(es.map(\.uid)), items: "UID BODY.PEEK[HEADER]").map { ($0.uid, $0.header ?? Data()) })
        return es.compactMap { e in
            guard let at = e.sendAt else { return nil }
            let p = MIME.parse((headers[e.uid] ?? Data()) + Data("\r\n".utf8))
            let stuck = e.claimedAt.map { now.timeIntervalSince($0) > claimTimeout } ?? false
            return Info(uid: e.uid, sendAt: at, subject: p.subject, to: p.header("To"), messageID: p.header("Message-ID"), claimed: e.claimedAt != nil, stuck: stuck)
        }
    }

    static func finish(_ c: IMAPClient, uid: UInt32) throws { try c.expunge("\(uid)") }

    /// The user decided to send a stuck message again.
    static func resend(_ c: IMAPClient, uid: UInt32, claimKeyword: String) { releaseClaim(c, uid: uid, keyword: claimKeyword) }
}

private extension String {
    func firstMatch(_ pattern: String) -> String? {
        guard let r = range(of: pattern, options: .regularExpression) else { return nil }
        let m = String(self[r])
        guard let re = try? NSRegularExpression(pattern: pattern), let match = re.firstMatch(in: m, range: NSRange(m.startIndex..., in: m)),
              match.numberOfRanges > 1, let rr = Range(match.range(at: 1), in: m) else { return nil }
        return String(m[rr])
    }
}
