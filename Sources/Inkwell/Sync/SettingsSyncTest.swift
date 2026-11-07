import Foundation

/// `Inkwell --settingssynctest`: two simulated Macs share one folder (no network, no Keychain).
enum SettingsSyncTest {
    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "✓ \(what)" : "✗ \(what)"); if !ok { failures += 1 } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
        let file = dir.appendingPathComponent(SettingsSync.fileName)
        let key = "mutedThreads"
        var a = SyncState(), b = SyncState()
        a.sets[key, default: SetState()].record(old: [], new: ["t1", "t2"], now: 100)
        SettingsSync.round(local: &a, shared: file, now: 101)
        SettingsSync.round(local: &b, shared: file, now: 102)
        check(b.sets[key]?.present == ["t1", "t2"], "Mac B receives Mac A's entries")

        // Both Macs change at the same time: A mutes t3, B unmutes t1.
        a.sets[key]!.record(old: ["t1", "t2"], new: ["t1", "t2", "t3"], now: 200)
        b.sets[key]!.record(old: ["t1", "t2"], new: ["t2"], now: 201)
        SettingsSync.round(local: &a, shared: file, now: 202)
        SettingsSync.round(local: &b, shared: file, now: 203)
        SettingsSync.round(local: &a, shared: file, now: 204)
        check(a.sets[key]?.present == ["t2", "t3"] && b.sets[key]?.present == ["t2", "t3"], "concurrent edits merge on both Macs")
        check(a == b, "both Macs converge to the same state")

        // Re-adding after a removal wins when it is newer.
        a.sets[key]!.record(old: ["t2", "t3"], new: ["t2", "t3", "t1"], now: 300)
        SettingsSync.round(local: &a, shared: file, now: 301)
        SettingsSync.round(local: &b, shared: file, now: 302)
        check(b.sets[key]?.present == ["t1", "t2", "t3"], "re-adding a removed entry propagates")

        // A corrupt shared file must not be overwritten.
        try? Data("not json".utf8).write(to: file)
        var c = a
        SettingsSync.round(local: &c, shared: file, now: 400)
        check((try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } == "not json", "unreadable shared file is left untouched")

        // Seeding and list order.
        var s = SetState(); s.seed(["x", "y"], now: 500)
        check(s.list(keepingOrderOf: ["y", "x"]) == ["y", "x"], "local order is kept")
        // Old tombstones are pruned.
        var p = SetState(); p.record(old: ["old"], new: [], now: 10); p.prune(olderThan: 20)
        check(p.removed.isEmpty && p.added.isEmpty, "old tombstones are pruned")
        try? FileManager.default.removeItem(at: dir)
        print(failures == 0 ? "All settings sync checks passed" : "settings sync FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
