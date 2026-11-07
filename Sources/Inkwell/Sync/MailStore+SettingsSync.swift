import Foundation

/// Connects `SettingsSync` to the live settings: local edits are recorded, and every tick the
/// shared iCloud file is merged in and applied.
extension MailStore {
    private func syncList(_ key: String, _ s: AppSettings) -> [String] {
        switch key {
        case "mutedThreads": return s.mutedThreads
        case "blockedSenders": return s.blockedSenders
        default: return s.allowedImageSenders
        }
    }

    private func setSyncList(_ key: String, _ list: [String]) {
        switch key {
        case "mutedThreads": settings.mutedThreads = list
        case "blockedSenders": settings.blockedSenders = list
        default: settings.allowedImageSenders = list
        }
    }

    /// Called from `settingsChanged`: remember what the user added or removed.
    func recordSyncedSettingsChange(old: AppSettings) {
        guard syncLoaded, !syncApplying else { return }
        let now = Date().timeIntervalSince1970
        var changed = false
        for k in SyncState.keys where syncList(k, old) != syncList(k, settings) {
            syncState.sets[k, default: SetState()].record(old: syncList(k, old), new: syncList(k, settings), now: now)
            changed = true
        }
        if changed { SettingsSync.write(syncState, to: SettingsSync.localStateURL) }
    }

    /// Called from `tick()`.
    func settingsSyncTick() {
        let now = Date().timeIntervalSince1970
        if !syncLoaded {
            syncState = SettingsSync.read(SettingsSync.localStateURL) ?? SyncState()
            for k in SyncState.keys { syncState.sets[k, default: SetState()].seed(syncList(k, settings), now: now) }
            syncLoaded = true
        }
        guard let dir = SettingsSync.directory else { return }
        let before = syncState
        SettingsSync.round(local: &syncState, shared: dir.appendingPathComponent(SettingsSync.fileName))
        guard syncState != before else { return }
        SettingsSync.write(syncState, to: SettingsSync.localStateURL)
        syncApplying = true
        for k in SyncState.keys {
            let merged = syncState.sets[k, default: SetState()].list(keepingOrderOf: syncList(k, settings))
            if merged != syncList(k, settings) { setSyncList(k, merged) }
        }
        syncApplying = false
    }
}
