import SwiftUI

/// Native sidebar: a `List` in the sidebar style (system vibrancy, selection and badges), grouped like Apple Mail:
/// mailboxes, then accounts with their folders.
struct SidebarView: View {
    @Bindable var store: MailStore
    @Environment(\.openSettings) private var openSettings
    @State private var showSubscriptions = false
    @State private var showSyncing = false
    @AppStorage("expandedAccounts") private var expandedRaw = ""
    private var expanded: Set<String> { Set(expandedRaw.split(separator: ",").map(String.init)) }
    private func expansion(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expanded.contains(id.uuidString) }, set: { on in
            var e = expanded
            if on { e.insert(id.uuidString) } else { e.remove(id.uuidString) }
            expandedRaw = e.sorted().joined(separator: ",")
        })
    }

    var body: some View {
        List(selection: Binding<Mailbox?>(get: { store.mailbox }, set: { if let m = $0 { store.mailbox = m } })) {
            Section {
                mailboxRow(.allInboxes, "tray", "Inbox", count: store.unreadCounts.values.reduce(0, +))
                mailboxRow(.toReply, "arrowshape.turn.up.left", "To reply", count: store.toReplyCount)
                mailboxRow(.flagged, "flag", "Flagged", count: store.flaggedCount)
                mailboxRow(.snoozed, "clock", "Snoozed", count: store.snoozedCount)
                mailboxRow(.allRole(.sent), "paperplane", "Sent")
                mailboxRow(.scheduled, "calendar.badge.clock", "Scheduled")
                Button { showSubscriptions = true } label: { Label("Subscriptions", systemImage: "newspaper") }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showSubscriptions, arrowEdge: .trailing) { SubscriptionsSettings(store: store).frame(width: 460, height: 480) }
            }
            Section("Accounts") {
                ForEach(store.accounts) { acct in
                    DisclosureGroup(isExpanded: expansion(acct.id)) {
                        ForEach(folderTree(acct)) { n in folderRow(acct, n) }
                    } label: { accountLabel(acct) }
                }
                Button { openSettings() } label: { Label("Add account", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    // MARK: rows

    private func mailboxRow(_ m: Mailbox, _ icon: String, _ title: LocalizedStringKey, count: Int = 0) -> some View {
        Label(title, systemImage: icon)
            .badge(count)
            .tag(m)
            .dropDestination(for: String.self) { ids, _ in handleDrop(ids, onto: m); return true }
    }

    private func accountLabel(_ acct: Account) -> some View {
        let m = Mailbox.accountInbox(acct.id)
        return Label {
            Text(acct.label).lineLimit(1)
        } icon: {
            if store.accountErrors[acct.id] != nil {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "circle.fill").foregroundStyle(acct.color).imageScale(.small)
            }
        }
        .badge(store.unreadCounts[acct.id] ?? 0)
        .tag(m)
        .help(store.accountErrors[acct.id] ?? acct.email)
        .draggable("acct:" + acct.id.uuidString) {
            Label(acct.label, systemImage: "circle.fill").foregroundStyle(acct.color).padding(6)
        }
        .dropDestination(for: String.self) { ids, _ in
            // Another account dropped here: reorder. Mail dropped here: move it to this inbox.
            if let a = ids.first, a.hasPrefix("acct:"), let from = UUID(uuidString: String(a.dropFirst(5))) {
                moveAccount(from, before: acct.id); return true
            }
            handleDrop(ids, onto: .folder(accountId: acct.id, path: "INBOX")); return true
        }
        .contextMenu {
            Button("Move Up") { shiftAccount(acct.id, by: -1) }.disabled(store.settings.accounts.first?.id == acct.id)
            Button("Move Down") { shiftAccount(acct.id, by: 1) }.disabled(store.settings.accounts.last?.id == acct.id)
            Divider()
            Button("Check for New Mail") { store.sync(accountId: acct.id) }
            if let e = store.accountErrors[acct.id] { Text(e) }
            Button("Account Settings…") { openSettings() }
        }
    }

    private func folderRow(_ acct: Account, _ n: FolderNode) -> some View {
        let m = Mailbox.folder(accountId: acct.id, path: n.folder.path)
        return Label(MUTF7.decode(n.folder.displayName), systemImage: icon(n.folder.role))
            .padding(.leading, CGFloat(n.depth) * 10)
            .tag(m)
            .dropDestination(for: String.self) { ids, _ in handleDrop(ids, onto: m); return true }
    }

    // MARK: footer

    /// Sync status, like the line under the mailbox list in Apple Mail.
    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            Text(status(at: ctx.date)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        // Most syncs finish in well under a second; only say "Syncing…" for ones that take a while.
        .task(id: store.syncing.isEmpty) {
            if store.syncing.isEmpty { showSyncing = false; return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled && !store.syncing.isEmpty { showSyncing = true }
        }
    }

    private func status(at now: Date) -> String {
        if showSyncing { return "Syncing…" }
        if !store.accountErrors.isEmpty { return "Can't reach \(store.accountErrors.count == 1 ? "server" : "servers")" }
        if store.accounts.isEmpty { return "Add an account to start" }
        guard let last = store.lastSynced else { return store.syncing.isEmpty ? "Not synced yet" : "Syncing…" }
        let mins = Int(now.timeIntervalSince(last) / 60)
        return mins < 1 ? "Updated just now" : mins < 60 ? "Updated \(mins) min ago" : "Updated \(last.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: folders

    struct FolderNode: Identifiable { var id: String { folder.id }; var folder: MailFolder; var depth: Int }

    private func folderTree(_ acct: Account) -> [FolderNode] {
        let fs = (store.folders[acct.id] ?? []).filter { $0.role != .inbox && $0.selectable }
        let order: [FolderRole] = [.drafts, .sent, .archive, .all, .flagged, .spam, .trash]
        let special = fs.filter { $0.role != .other }.sorted { (order.firstIndex(of: $0.role) ?? 99) < (order.firstIndex(of: $1.role) ?? 99) }
        let others = fs.filter { $0.role == .other }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return special.map { FolderNode(folder: $0, depth: 0) } + others.map {
            FolderNode(folder: $0, depth: max(0, $0.path.components(separatedBy: $0.delimiter.isEmpty ? "/" : $0.delimiter).count - 1))
        }
    }

    private func icon(_ r: FolderRole) -> String {
        switch r {
        case .sent: return "paperplane"; case .drafts: return "doc"; case .trash: return "trash"; case .spam: return "exclamationmark.circle"
        case .archive, .all: return "archivebox"; case .flagged: return "flag"; default: return "folder"
        }
    }

    // MARK: reordering

    private func moveAccount(_ id: UUID, before target: UUID) {
        guard id != target, let from = store.settings.accounts.firstIndex(where: { $0.id == id }),
              let to = store.settings.accounts.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.snappy) {
            store.settings.accounts.move(fromOffsets: [from], toOffset: from < to ? to + 1 : to)
        }
    }

    private func shiftAccount(_ id: UUID, by delta: Int) {
        guard let i = store.settings.accounts.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard store.settings.accounts.indices.contains(j) else { return }
        withAnimation(.snappy) { store.settings.accounts.swapAt(i, j) }
    }

    private func handleDrop(_ ids: [String], onto m: Mailbox) {
        let threads = store.threads.filter { ids.contains($0.id) }
        guard !threads.isEmpty else { return }
        Task {
            switch m {
            case .folder(let acct, let path): await store.moveThreads(threads.filter { $0.accountId == acct }, to: path)
            case .flagged: await store.setFlag(threads.map(\.latest), true)
            case .snoozed: store.snooze(threads, until: SnoozeChoice.tomorrow.date)
            case .allRole(.trash): await store.trash(threads)
            case .allRole(.spam): await store.reportSpam(threads)
            default: break
            }
        }
    }
}
