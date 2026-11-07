import Foundation

/// Syncs a few list-valued settings (muted threads, blocked senders, allowed image senders)
/// between Macs through a plain JSON file in iCloud Drive (no CloudKit). Each list is a
/// last-writer-wins element set: per entry we remember when it was added and when it was
/// removed; an entry is present if its add is newer than its removal. Merging two states takes
/// the newer timestamp per entry, so concurrent changes on both Macs never overwrite each other
/// and both converge to the same result. Passwords and tokens never leave the Keychain.
struct SetState: Codable, Equatable {
    var added: [String: Double] = [:]
    var removed: [String: Double] = [:]

    var present: Set<String> { Set(added.filter { $0.value > (removed[$0.key] ?? 0) }.keys) }

    mutating func merge(_ other: SetState) {
        for (k, v) in other.added { added[k] = max(added[k] ?? 0, v) }
        for (k, v) in other.removed { removed[k] = max(removed[k] ?? 0, v) }
    }

    /// Records a local edit of the list.
    mutating func record(old: [String], new: [String], now: Double) {
        let o = Set(old), n = Set(new)
        for k in n.subtracting(o) { added[k] = now }
        for k in o.subtracting(n) { removed[k] = now }
    }

    /// First run: entries that exist locally but were never recorded count as added now.
    mutating func seed(_ list: [String], now: Double) {
        for k in list where added[k] == nil && removed[k] == nil { added[k] = now }
    }

    /// Entries removed long ago no longer need their tombstone.
    mutating func prune(olderThan cutoff: Double) {
        for (k, v) in removed where v < cutoff && v >= (added[k] ?? 0) { removed[k] = nil; added[k] = nil }
    }

    /// The list for settings: keeps local order, appends new entries sorted.
    func list(keepingOrderOf local: [String]) -> [String] {
        let p = present
        let kept = local.filter { p.contains($0) }
        return kept + p.subtracting(kept).sorted()
    }
}

struct SyncState: Codable, Equatable {
    static let keys = ["mutedThreads", "blockedSenders", "allowedImageSenders"]
    var version = 1
    var sets: [String: SetState] = [:]

    mutating func merge(_ other: SyncState) {
        for (k, s) in other.sets { sets[k, default: SetState()].merge(s) }
    }
}

enum SettingsSync {
    static let fileName = "settings-sync.json"
    static let tombstoneLifetime: Double = 90 * 86400

    /// Shared folder: INKWELL_SYNC_DIR (tests), else "Stein's Mail" in iCloud Drive if iCloud Drive exists.
    static var directory: URL? {
        if let d = ProcessInfo.processInfo.environment["INKWELL_SYNC_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        let icloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: icloud.path) else { return nil }
        return icloud.appendingPathComponent("Stein's Mail", isDirectory: true)
    }

    static var localStateURL: URL { Paths.appSupport.appendingPathComponent("sync-state.json") }

    static func read(_ url: URL) -> SyncState? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) } }

    static func write(_ s: SyncState, to url: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? enc.encode(s) { try? d.write(to: url, options: .atomic) }
    }

    /// One sync round: merge the shared file into `local`, write the result back if it differs.
    /// Returns true if `local` changed. An unreadable shared file is left alone (not overwritten).
    @discardableResult
    static func round(local: inout SyncState, shared: URL, now: Double = Date().timeIntervalSince1970) -> Bool {
        let before = local
        let exists = FileManager.default.fileExists(atPath: shared.path)
        let remote = read(shared)
        if exists && remote == nil { return false }
        if let remote { local.merge(remote) }
        for k in local.sets.keys { local.sets[k]?.prune(olderThan: now - tombstoneLifetime) }
        if remote != local { write(local, to: shared) }
        return local != before
    }
}
