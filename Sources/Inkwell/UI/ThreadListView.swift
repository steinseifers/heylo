import SwiftUI

struct ThreadListView: View {
    @Bindable var store: MailStore
    @Environment(\.accent) private var accent
    @State private var customSnooze: [ThreadSummary]?
    @State private var searchText = ""

    private var showTabs: Bool {
        switch store.mailbox { case .allInboxes, .accountInbox: return true; default: return false }
    }

    var body: some View {
        content
            .navigationTitle(titleText)
            .navigationSubtitle(subtitle)
            // Standard search field in the window toolbar (⌘F focuses it); Return opens the results palette. ⌘K still opens it empty.
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search or ask anything")
            .onSubmit(of: .search) {
                store.paletteQuery = searchText
                searchText = ""
                store.searchPresented = true
            }
            .safeAreaInset(edge: .top, spacing: 0) { if showTabs { tabs } }
            .toolbar(id: "list") {
                ToolbarItem(id: "unread", placement: .primaryAction) {
                    Toggle(isOn: $store.unreadOnly) { Label("Unread Only", systemImage: "envelope.badge") }.help("Show unread only")
                }
                ToolbarItem(id: "compose", placement: .primaryAction) {
                    Button { store.compose() } label: { Label("New Message", systemImage: "square.and.pencil") }.help("New Message")
                }
            }
            .sheet(item: Binding(get: { customSnooze.map { IdentifiedThreads(threads: $0) } }, set: { customSnooze = $0?.threads })) { item in
                DatePickerSheet(title: "Snooze until…", action: "Snooze") { store.snooze(item.threads, until: $0) }
            }
    }

    @ViewBuilder private var content: some View {
        if case .scheduled = store.mailbox {
            ScheduledList(store: store)
        } else if store.threads.isEmpty && store.unreadOnly && !store.syncing.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading unread mail…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.threads.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: emptyIcon, description: Text(emptySubtitle))
        } else {
            ScrollViewReader { proxy in
                List(selection: $store.selection) {
                    ForEach(store.threads) { t in
                        ThreadRow(thread: t, account: store.account(t.accountId), store: store)
                            .tag(t.id)
                            .id(t.id)
                            .draggable(t.id)
                    }
                    .onAppear { Perf.mark("thread rows built"); DispatchQueue.main.async { Perf.mark("first list frame") } }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in contextMenu(for: menuTargets(ids)) }
                .onChange(of: store.selection) { if let s = store.selection.first { withAnimation { proxy.scrollTo(s) } } }
            }
        }
    }

    private func menuTargets(_ ids: Set<String>) -> [ThreadSummary] { store.threads.filter { ids.contains($0.id) } }

    private var titleText: String {
        switch store.mailbox {
        case .allInboxes: return "Inbox"
        case .accountInbox(let id): return store.account(id)?.label ?? "Inbox"
        case .folder(let id, _): return "\(store.account(id)?.label ?? "") › \(store.mailbox.title)"
        case .allRole: return "All inboxes › \(store.mailbox.title)"
        default: return store.mailbox.title
        }
    }

    private var subtitle: String {
        let unread = store.threads.filter(\.unread).count
        switch store.mailbox {
        default:
            return unread > 0 ? "\(unread) unread" : ""
        }
    }

    /// Inbox tabs as a standard segmented control.
    private var tabs: some View {
        Picker("Tab", selection: $store.tab) {
            ForEach(InboxTab.allCases) { t in
                if let n = store.tabUnread[t], n > 0, t != .all { Text("\(t.rawValue) · \(n)").tag(t) } else { Text(LocalizedStringKey(t.rawValue)).tag(t) }
            }
        }
        .pickerStyle(.segmented).labelsHidden()
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyTitle: String {
        switch store.mailbox { case .toReply: return "Nothing waiting on you"; case .snoozed: return "No snoozed mail"; default: return store.settings.accounts.isEmpty ? "No accounts yet" : store.unreadOnly ? "No unread mail" : "All caught up" }
    }
    private var emptyIcon: String { store.settings.accounts.isEmpty ? "person.crop.circle.badge.plus" : "checkmark.circle" }
    private var emptySubtitle: String { store.settings.accounts.isEmpty ? "Click “Add account” to connect Gmail, iCloud, Outlook, Yahoo, Fastmail or any IMAP account." : "" }

    @ViewBuilder
    private func contextMenu(for ts: [ThreadSummary]) -> some View {
        if !ts.isEmpty {
            Button("Archive") { Task { await store.archive(ts) } }
            Button("Move to Trash") { Task { await store.trash(ts) } }
            Divider()
            Button(ts.contains(where: \.unread) ? "Mark as Read" : "Mark as Unread") { Task { await store.toggleRead(ts) } }
            Button(ts.contains(where: \.flagged) ? "Unflag" : "Flag") { Task { await store.toggleFlag(ts) } }
            Menu("Snooze") {
                SnoozeMenu { d in store.snooze(ts, until: d) }
                Divider()
                Button("Pick Date & Time…") { customSnooze = ts }
            }
            if case .snoozed = store.mailbox { Button("Unsnooze") { store.unsnooze(ts) } }
            Menu("Move to") {
                ForEach(store.folders[ts[0].accountId]?.filter(\.selectable) ?? []) { f in
                    Button(MUTF7.decode(f.path)) { Task { await store.moveThreads(ts.filter { $0.accountId == f.accountId }, to: f.path) } }
                }
            }
            Divider()
            Button("Mute Conversation") { Task { await store.mute(ts) } }
            if ts.count == 1 {
                if !ts[0].latest.listUnsubscribe.isEmpty { Button("Unsubscribe") { Task { await store.unsubscribe(ts[0].latest) } } }
                Button("Block \(ts[0].latest.from.email)") { Task { await store.blockSender(ts[0].latest.from.email) } }
            }
            Button("Report Spam") { Task { await store.reportSpam(ts) } }
        }
    }
}

struct IdentifiedThreads: Identifiable { let id = UUID(); var threads: [ThreadSummary] }

struct ThreadRow: View {
    var thread: ThreadSummary
    var account: Account?
    var store: MailStore
    @Environment(\.accent) private var accent

    private var counterpart: EmailAddress {
        let m = thread.latest
        if m.isFromMe { return m.to.first ?? m.from }
        return thread.messages.first(where: { !$0.isFromMe })?.from ?? m.from
    }

    private var code: String? {
        let m = thread.latest
        guard m.category != .promos else { return nil }
        return Classifier.oneTimeCode(subject: m.subject, text: m.snippet)
    }

    var body: some View {
        let m = thread.latest
        let unread = thread.unread
        HStack(alignment: .top, spacing: 12) {
            AvatarView(address: counterpart, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(m.isFromMe ? "To: \(counterpart.display)" : counterpart.display)
                        .font(.system(size: 13.5, weight: unread ? .semibold : .medium))
                        .foregroundStyle(unread ? Theme.ink : Theme.ink2)
                        .lineLimit(1)
                    if thread.count > 1 { Text("\(thread.count)").font(.subheadline).foregroundStyle(Theme.faint) }
                    Spacer(minLength: 4)
                    Text(m.date.listLabel).font(.system(size: 11.5, weight: unread ? .semibold : .regular))
                        .foregroundStyle(unread ? accent : Theme.faint)
                }
                HStack(spacing: 5) {
                    if thread.flagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange) }
                    Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                        .font(.system(size: 13, weight: unread ? .semibold : .regular))
                        .foregroundStyle(unread ? Theme.ink : Theme.ink2)
                        .lineLimit(1)
                }
                if code == nil {
                    Text(m.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                chips
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .topLeading) {
            if unread { Circle().fill(accent).frame(width: 7, height: 7).offset(x: -13, y: 14) }
        }
    }

    @ViewBuilder private var chips: some View {
        let latestIn = thread.messages.first(where: { !$0.isFromMe })
        let needsReply = latestIn.map { $0.needsReply && !$0.answered } ?? false
        let files = thread.latest.attachmentNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let code {
            let copied = store.copiedCodes.contains(code)
            HStack(spacing: 8) {
                Text(Self.grouped(code)).font(.system(size: 15, weight: .semibold).monospacedDigit()).tracking(1.8)
                    .foregroundStyle(Theme.onCodeTile)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Theme.codeTile, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                    Sounds.play(.copy)
                    store.copiedCodes.insert(code)
                } label: {
                    Text(copied ? "Copied" : "Copy").font(.callout.weight(.semibold)).foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        } else if needsReply || !files.isEmpty {
            HStack(spacing: 10) {
                if needsReply { Label("Needs reply", systemImage: "arrowshape.turn.up.left").font(.caption).foregroundStyle(accent) }
                if !files.isEmpty {
                    Label(files.count == 1 ? files[0] : "\(files.count)", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.top, 2)
        }
    }

    /// "482913" → "482 913".
    static func grouped(_ code: String) -> String {
        guard code.allSatisfy(\.isNumber), code.count == 6 || code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[..<mid] + " " + code[mid...]
    }
}

struct ScheduledList: View {
    var store: MailStore
    @State private var items: [OutgoingDraft] = []
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(items) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("To: \(d.to)").font(.title3.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if let at = d.sendAt { Text(at.formatted(date: .abbreviated, time: .shortened)).font(.body).foregroundStyle(.secondary) }
                        }
                        Text(d.subject).font(.body).lineLimit(1)
                        Text(d.plain).font(.body).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Edit / Cancel Schedule") { store.cancelScheduled(d); items = store.scheduledDrafts() }
                        Button("Send Now") { store.sendScheduledNow(d); items = store.scheduledDrafts() }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .overlay { if items.isEmpty { ContentUnavailableView("Nothing scheduled", systemImage: "paperplane", description: Text("Use Send Later in the composer.")) } }
        .onAppear { items = store.scheduledDrafts() }
    }
}
