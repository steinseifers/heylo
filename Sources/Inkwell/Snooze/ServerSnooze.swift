import Foundation

/// Server-side Wiedervorlage (snooze). The wake-up time lives on the message itself as an IMAP
/// keyword (`$InkwellSnooze_20261108T0700Z`, UTC, minute resolution); a snoozed message sits in
/// one folder per account. The server is the single source of truth, so every running instance
/// reaches the same result and concurrent `UID MOVE`s are settled by the server (see docs/multi-mac.md).
///
/// Failure policy: a message in the folder without a valid keyword is woken immediately
/// (better early in the inbox than lost). A MOVE for a UID another instance already moved
/// is not an error.
enum ServerSnooze {
    static let keywordPrefix = "$InkwellSnooze_"
    static let defaultFolder = "Stein's Wiedervorlage"

    enum SnoozeError: LocalizedError {
        case keywordsUnsupported
        var errorDescription: String? {
            "This server doesn't keep custom IMAP keywords, so server-side snooze isn't available for this account yet."
        }
    }

    struct Entry: Equatable {
        var uid: UInt32
        /// nil: no valid wake-up keyword (crash leftover or moved by hand), wake immediately.
        var until: Date?
        var keywords: [String]
        var isDue: Bool { until.map { $0 <= Date() } ?? true }
    }

    // MARK: Keyword coding

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmm'Z'"
        return f
    }()

    /// Minute resolution, rounded up so a snooze never wakes early.
    static func keyword(for date: Date) -> String {
        keywordPrefix + formatter.string(from: Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.up) * 60))
    }

    static func isSnoozeKeyword(_ flag: String) -> Bool { flag.lowercased().hasPrefix(keywordPrefix.lowercased()) }

    static func until(fromFlags flags: [String]) -> Date? {
        for f in flags where isSnoozeKeyword(f) {
            if let d = formatter.date(from: String(f.dropFirst(keywordPrefix.count)).uppercased()) { return d }
        }
        return nil
    }

    // MARK: Server operations (run these on the account's connection)

    /// Moves messages of `source` into the snooze folder with the wake-up keyword. Creates the
    /// folder if missing (only ever called from a user's snooze action). If the server drops the
    /// keyword nothing is moved and `keywordsUnsupported` is thrown.
    static func snooze(_ c: IMAPClient, uids: [UInt32], from source: String = "INBOX", until: Date, folder: String) throws {
        guard !uids.isEmpty else { return }
        if (try? c.select(folder)) == nil {
            try? c.create(folder)
            _ = try? c.command("SUBSCRIBE \(IMAPClient.quote(folder))")
        }
        try c.ensureSelected(source)
        let set = IMAPClient.uidSet(uids)
        let kw = keyword(for: until)
        try c.store(set, flags: kw, add: true)
        let seen = try c.fetch(set, items: "UID FLAGS")
        let kept = Set(seen.filter { $0.flags.contains { $0.caseInsensitiveCompare(kw) == .orderedSame } }.map(\.uid))
        guard !seen.isEmpty, kept.count == seen.count else {
            // Keywords not kept: undo what stuck and leave the mail where it is.
            try? c.store(set, flags: kw, add: false)
            throw SnoozeError.keywordsUnsupported
        }
        try c.move(set, to: folder)
    }

    /// Reads the folder; an absent folder means nothing is snoozed.
    static func entries(_ c: IMAPClient, folder: String) throws -> [Entry] {
        guard (try? c.select(folder)) != nil else { return [] }
        let rows = try c.fetch("1:*", items: "UID FLAGS")
        return rows.filter { $0.uid != 0 }.map { r in
            Entry(uid: r.uid, until: until(fromFlags: r.flags), keywords: r.flags.filter(isSnoozeKeyword))
        }.sorted { ($0.until ?? .distantPast) < ($1.until ?? .distantPast) }
    }

    /// Wakes the given entries (default: everything due): removes the keyword and \Seen, then
    /// moves them to the inbox. Order matters: a crash between the two steps leaves a message
    /// without keyword in the folder, which the next run wakes (fail-safe).
    @discardableResult
    static func wake(_ c: IMAPClient, folder: String, entries: [Entry], inbox: String = "INBOX") throws -> [UInt32] {
        guard !entries.isEmpty else { return [] }
        try c.ensureSelected(folder)
        for e in entries {
            let flags = (e.keywords + ["\\Seen"]).joined(separator: " ")
            try c.store("\(e.uid)", flags: flags, add: false)
        }
        try c.move(IMAPClient.uidSet(entries.map(\.uid)), to: inbox)
        return entries.map(\.uid)
    }

    @discardableResult
    static func wakeDue(_ c: IMAPClient, folder: String, inbox: String = "INBOX") throws -> [UInt32] {
        try wake(c, folder: folder, entries: try entries(c, folder: folder).filter(\.isDue), inbox: inbox)
    }
}
