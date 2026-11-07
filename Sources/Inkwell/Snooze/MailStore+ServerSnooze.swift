import Foundation

/// Glue between `ServerSnooze` (IMAP) and the app: snooze/unsnooze/wake on the server, with the
/// local `snoozes` table (rows marked `server=1`) as a pure cache derived from the folder.
/// Rows with `server=0` are the legacy local-only snooze, used when a server drops keywords.
extension MailStore {
    private func snoozeKeys(_ id: UUID) -> String { id.uuidString }

    func snooze(_ threads: [ThreadSummary], until: Date) {
        Task { await snoozeOnServer(threads, until: until) }
    }

    func unsnooze(_ threads: [ThreadSummary]) {
        unsnoozeLocally(threads)  // drops legacy rows; harmless for server snoozes
        Task { await unsnoozeOnServer(threads) }
    }

    // MARK: snooze

    func snoozeOnServer(_ threads: [ThreadSummary], until: Date) async {
        var local: [ThreadSummary] = []
        var failed = false
        var onServer = false
        for (acctId, ts) in Dictionary(grouping: threads, by: \.accountId) {
            guard let conn = connections[acctId], let acct = account(acctId) else { local += ts; continue }
            let uids = ts.flatMap { t in
                db.messages(where: "account=? AND thread_key=? AND folder='INBOX'", [acctId.uuidString, t.threadKey]).map(\.uid)
            }
            if uids.isEmpty { local += ts; continue }
            let db = self.db
            do {
                let entries = try await conn.run { c -> [ServerSnooze.Entry] in
                    try ServerSnooze.snooze(c, uids: uids, until: until, folder: acct.snoozeFolderName)
                    _ = try SyncEngine.syncFolder(c, account: acct, path: "INBOX", db: db)
                    return try Self.syncSnoozeFolder(c, acct: acct, db: db)
                }
                applySnoozeCache(acctId, folder: acct.snoozeFolderName, entries: entries)
                onServer = true
            } catch ServerSnooze.SnoozeError.keywordsUnsupported {
                local += ts
            } catch {
                failed = true
                showToast("Couldn't snooze: \(error.localizedDescription)", isError: true)
                sync(accountId: acctId)
            }
        }
        if !local.isEmpty { snoozeLocally(local, until: until) }
        reload()
        if onServer && !failed {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
            showToast("Snoozed until \(f.string(from: until))") { [weak self] in self?.unsnooze(threads) }
        }
    }

    // MARK: unsnooze

    private func unsnoozeOnServer(_ threads: [ThreadSummary]) async {
        for (acctId, ts) in Dictionary(grouping: threads, by: \.accountId) {
            await wakeThreads(acctId, keys: ts.map(\.threadKey))
        }
        reload()
    }

    /// A new inbox message in a snoozed thread wakes the whole thread; otherwise the reply
    /// would stay hidden until the snooze expires.
    func wakeSnoozedThreads(forNew msgs: [MessageRecord], account: Account) {
        let snoozed = Set(db.query("SELECT thread_key FROM snoozes WHERE account=? AND server=1", [account.id.uuidString]) { $0.string(0) })
        let keys = Set(msgs.filter { !$0.isFromMe && snoozed.contains($0.threadKey) }.map(\.threadKey))
        guard !keys.isEmpty else { return }
        Task {
            await wakeThreads(account.id, keys: Array(keys))
            showToast("A reply woke a snoozed conversation.")
            reload()
        }
    }

    private func wakeThreads(_ acctId: UUID, keys: [String]) async {
        guard let conn = connections[acctId], let acct = account(acctId) else { return }
        let folder = acct.snoozeFolderName
        let uids = Set(keys.flatMap { k in
            db.messages(where: "account=? AND thread_key=? AND folder=?", [acctId.uuidString, k, folder]).map(\.uid)
        })
        if uids.isEmpty { return }
        let db = self.db
        do {
            let entries = try await conn.run { c -> [ServerSnooze.Entry] in
                let mine = try ServerSnooze.entries(c, folder: folder).filter { uids.contains($0.uid) }
                try ServerSnooze.wake(c, folder: folder, entries: mine)
                _ = try SyncEngine.syncFolder(c, account: acct, path: "INBOX", db: db)
                return try Self.syncSnoozeFolder(c, acct: acct, db: db)
            }
            applySnoozeCache(acctId, folder: folder, entries: entries)
        } catch {
            showToast("Couldn't unsnooze: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: wake cycle (called from tick)

    /// Wakes everything due in this account's snooze folder and refreshes the cache. Safe to run
    /// on several Macs at once: the server decides who moves a message, the loser sees nothing to do.
    func snoozeCycle(_ acctId: UUID) async {
        guard let conn = connections[acctId], let acct = account(acctId), acct.enabled, !snoozeBusy.contains(acctId) else { return }
        snoozeBusy.insert(acctId)
        defer { snoozeBusy.remove(acctId); snoozeLast[acctId] = Date() }
        let folder = acct.snoozeFolderName
        let db = self.db
        do {
            let (remaining, woken) = try await conn.run { c -> ([ServerSnooze.Entry], [MessageRecord]) in
                let all = try ServerSnooze.entries(c, folder: folder)
                let due = all.filter(\.isDue)
                var wokenMsgs: [MessageRecord] = []
                if !due.isEmpty {
                    let list = due.map { String($0.uid) }.joined(separator: ",")
                    wokenMsgs = db.messages(where: "account=? AND folder=? AND uid IN (\(list))", [acct.id.uuidString, folder])
                    try ServerSnooze.wake(c, folder: folder, entries: due)
                    _ = try SyncEngine.syncFolder(c, account: acct, path: "INBOX", db: db)
                }
                let left = all.filter { e in !due.contains { $0.uid == e.uid } }
                if !all.isEmpty || db.query("SELECT 1 FROM messages WHERE account=? AND folder=? LIMIT 1", [acct.id.uuidString, folder], { $0.int(0) }).first != nil {
                    _ = try SyncEngine.syncFolder(c, account: acct, path: folder, db: db)
                }
                return (left, wokenMsgs)
            }
            let now = Date().timeIntervalSince1970
            var notified = Set<String>()
            for m in woken {
                db.exec("INSERT OR REPLACE INTO bumps(account, thread_key, date) VALUES(?,?,?)", [m.accountId.uuidString, m.threadKey, now])
                if notified.insert(m.threadKey).inserted { Notifier.shared.notifySnoozeWake(m) }
            }
            applySnoozeCache(acctId, folder: folder, entries: remaining)
            if !woken.isEmpty { reload() }
        } catch {
            // Offline or a transient server error: the next tick tries again.
        }
    }

    // MARK: cache

    /// Syncs the snooze folder's messages (so threads can be shown) and returns its entries.
    nonisolated static func syncSnoozeFolder(_ c: IMAPClient, acct: Account, db: Database) throws -> [ServerSnooze.Entry] {
        let entries = try ServerSnooze.entries(c, folder: acct.snoozeFolderName)
        if !entries.isEmpty { _ = try SyncEngine.syncFolder(c, account: acct, path: acct.snoozeFolderName, db: db) }
        return entries
    }

    /// Rebuilds this account's server-derived rows in `snoozes` from the folder's entries.
    func applySnoozeCache(_ acctId: UUID, folder: String, entries: [ServerSnooze.Entry]) {
        let acct = acctId.uuidString
        let keyByUid = Dictionary(db.query("SELECT uid, thread_key FROM messages WHERE account=? AND folder=?", [acct, folder]) { (UInt32($0.int(0)), $0.string(1)) },
                                  uniquingKeysWith: { a, _ in a })
        var untilByThread: [String: Date] = [:]
        for e in entries {
            guard let until = e.until, let key = keyByUid[e.uid] else { continue }
            untilByThread[key] = max(untilByThread[key] ?? .distantPast, until)
        }
        let old = Dictionary(db.query("SELECT thread_key, until FROM snoozes WHERE account=? AND server=1", [acct]) { ($0.string(0), $0.double(1).rounded()) },
                             uniquingKeysWith: { a, _ in a })
        guard old != untilByThread.mapValues({ $0.timeIntervalSince1970.rounded() }) else { return }
        db.transaction {
            db.exec("DELETE FROM snoozes WHERE account=? AND server=1", [acct])
            for (key, until) in untilByThread {
                db.exec("INSERT OR REPLACE INTO snoozes(account, thread_key, until, server) VALUES(?,?,?,1)", [acct, key, until])
            }
        }
        reload()
    }

    /// Called from `tick()`: wakes due snoozes and picks up changes made on another Mac.
    func snoozeTick() {
        let now = Date()
        for a in settings.accounts where a.enabled && connections[a.id] != nil {
            let dueInCache = db.query("SELECT COUNT(*) FROM snoozes WHERE account=? AND server=1 AND until<=?", [a.id.uuidString, now.timeIntervalSince1970]) { $0.int(0) }.first ?? 0
            if dueInCache > 0 || now.timeIntervalSince(snoozeLast[a.id] ?? .distantPast) >= 60 {
                Task { await snoozeCycle(a.id) }
            }
        }
    }
}
