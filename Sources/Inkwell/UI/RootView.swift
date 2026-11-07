import SwiftUI

struct RootView: View {
    @Bindable var store: MailStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Theme.accent(store.settings.accentHex) }

    /// Standard three-column split view (sidebar, message list, conversation): the system provides the
    /// sidebar toggle, column resizing, vibrancy and, on current macOS, the glass material.
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } content: {
            ThreadListView(store: store)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 540)
        } detail: {
            detail
        }
        .overlay(alignment: .top) {
            if let t = store.toast {
                ToastView(toast: t) { store.performUndo() }
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: store.toast)
        // ⌘K palette as a standard sheet: system material, shadow, Esc and click-outside handling.
        .sheet(isPresented: $store.searchPresented) {
            SearchPalette(store: store, openSettings: { openSettings() })
        }
        .environment(\.accent, accent)
        .environment(\.onAccent, Theme.onAccent(store.settings.accentHex))
        .environment(\.accentFill, Theme.accentFill(store.settings.accentHex))
        .tint(accent)
        .sheet(item: $store.pendingApproval) { p in SendApprovalView(store: store, approval: p) }
        .onAppear { store.openCompose = { id in openWindow(id: "compose", value: id) } }
    }

    @ViewBuilder private var detail: some View {
        if let t = store.focusedThread ?? (store.selection.count == 1 ? store.selectedThreads.first : nil) {
            ConversationView(thread: t, store: store).id(t.id)
        } else if store.selection.count > 1 {
            let ts = store.selectedThreads
            ContentUnavailableView {
                Label("\(ts.count) conversations selected", systemImage: "square.stack.3d.up")
            } actions: {
                Button("Archive") { Task { await store.archive(ts) } }
                Button("Move to Trash") { Task { await store.trash(ts) } }
                Button(ts.contains(where: \.unread) ? "Mark as Read" : "Mark as Unread") { Task { await store.toggleRead(ts) } }
                Menu("Snooze") { SnoozeMenu { store.snooze(ts, until: $0) } }
            }
        } else {
            ContentUnavailableView("No conversation selected", systemImage: "tray")
        }
    }
}

/// Shown when an AI app (via MCP) asks to send a draft.
struct SendApprovalView: View {
    var store: MailStore
    var approval: PendingSendApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(approval.app) wants to send an email", systemImage: "sparkles").font(.headline)
            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow { Text("From").foregroundStyle(.secondary); Text(approval.draft.fromEmail) }
                GridRow { Text("To").foregroundStyle(.secondary); Text(approval.draft.to) }
                if !approval.draft.cc.isEmpty { GridRow { Text("Cc").foregroundStyle(.secondary); Text(approval.draft.cc) } }
                GridRow { Text("Subject").foregroundStyle(.secondary); Text(approval.draft.subject) }
            }
            ScrollView { Text(approval.draft.plain).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(height: 180).padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Trust these recipients for this session") { store.approvePendingSend(trustRecipients: true, edit: false) }
                Spacer()
                Button("Don't Send") { store.rejectPendingSend() }.keyboardShortcut(.cancelAction)
                Button("Edit in Inkwell") { store.approvePendingSend(trustRecipients: false, edit: true) }
                Button("Send") { store.approvePendingSend(trustRecipients: false, edit: false) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
