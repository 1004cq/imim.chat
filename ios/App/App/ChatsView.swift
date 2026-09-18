import CoreImage.CIFilterBuiltins
import SwiftData
import SwiftUI
import UIKit

struct ChatsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("isDarkMode") private var isDarkMode = false
    @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]
    @StateObject private var viewModel = ChatsViewModel()
    @State private var isShowingAddFriend = false
    @State private var isShowingCreateGroup = false
    @State private var isShowingScanner = false
    @State private var isShowingQRCode = false
    @State private var isShowingPlusMenu = false
    @State private var scannedCode: String?

    private var conversations: [ChatConversationModel] {
        viewModel.conversations(from: chats)
    }

    private var totalUnread: Int {
        viewModel.totalUnread(in: chats)
    }

    var body: some View {
        ZStack {
            DoveTheme.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        searchAndFilters

                        if viewModel.isRefreshing && chats.isEmpty {
                            ChatListSkeleton()
                                .padding(.top, 8)
                        } else if conversations.isEmpty {
                            emptyState
                                .padding(.top, 44)
                        } else {
                            if let errorMessage = viewModel.errorMessage {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 8)
                            }

                            ForEach(conversations) { conversation in
                                if let chat = chats.first(where: { $0.chatId == conversation.id }) {
                                    ConversationCell(
                                        chat: chat,
                                        conversation: conversation
                                    )
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            viewModel.delete(chat, modelContext: modelContext)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button {
                                            viewModel.togglePinned(chat, modelContext: modelContext)
                                        } label: {
                                            Label(chat.isPinned ? "取消置顶" : "置顶", systemImage: "pin.fill")
                                        }
                                        .tint(DoveTheme.green)
                                    }
                                    .contextMenu {
                                        Button {
                                            viewModel.togglePinned(chat, modelContext: modelContext)
                                        } label: {
                                            Label(chat.isPinned ? "取消置顶" : "置顶聊天", systemImage: "pin")
                                        }

                                        Button(role: .destructive) {
                                            viewModel.delete(chat, modelContext: modelContext)
                                        } label: {
                                            Label("删除会话", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 18)
                }
                .refreshable {
                    await viewModel.refresh(chats: chats, modelContext: modelContext)
                }
            }

            if isShowingPlusMenu {
                PlusMenuOverlay(
                    onClose: {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                            isShowingPlusMenu = false
                        }
                    },
                    onCreateGroup: {
                        isShowingCreateGroup = true
                    },
                    onAddFriend: {
                        isShowingAddFriend = true
                    },
                    onScan: {
                        isShowingScanner = true
                    },
                    onQRCode: {
                        isShowingQRCode = true
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                .zIndex(10)
            }
        }
        .navigationTitle("消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        isDarkMode.toggle()
                    } label: {
                        Image(systemName: isDarkMode ? "sun.max.fill" : "moon.fill")
                            .foregroundStyle(isDarkMode ? .yellow : DoveTheme.ink)
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            isShowingPlusMenu.toggle()
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(DoveTheme.ink)
                    }
                    .buttonStyle(.plain)
                }
            }

            ToolbarItem(placement: .topBarLeading) {
                DoveUnreadBadge(count: totalUnread)
            }
        }
        .navigationDestination(for: Chat.self) { chat in
            ChatDetailView(chat: chat)
        }
        .sheet(isPresented: $isShowingAddFriend) {
            AddFriendView()
        }
        .sheet(isPresented: $isShowingCreateGroup) {
            CreateGroupSheet { group in
                upsertCreatedGroup(group)
            }
        }
        .sheet(isPresented: $isShowingScanner) {
            ScannerSheet(scannedCode: $scannedCode)
        }
        .sheet(isPresented: $isShowingQRCode) {
            MyQRCodeSheet()
        }
        .alert("扫码结果", isPresented: Binding(
            get: { scannedCode != nil },
            set: { if !$0 { scannedCode = nil } }
        )) {
            Button("复制") {
                if let scannedCode {
                    UIPasteboard.general.string = scannedCode
                }
                scannedCode = nil
            }
            Button("关闭", role: .cancel) {
                scannedCode = nil
            }
        } message: {
            Text(scannedCode ?? "")
        }
        .task {
            await viewModel.refresh(chats: chats, modelContext: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimAvatarDidChange)) { _ in
            Task { await viewModel.refresh(chats: chats, modelContext: modelContext) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimProfileDidChange)) { _ in
            Task { await viewModel.refresh(chats: chats, modelContext: modelContext) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimPrivateMessageDidReceive)) { notification in
            guard let message = notification.object as? Message else { return }
            viewModel.applyRealtimeMessage(message, to: chats, modelContext: modelContext)
        }
    }

    private var searchAndFilters: some View {
        VStack(alignment: .leading, spacing: 14) {
            ConversationFilterPills(
                selection: $viewModel.filter,
                groupUnread: viewModel.groupUnread(in: chats)
            )

            DoveSearchBar(text: $viewModel.searchText, placeholder: "搜索聊天记录")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(DoveTheme.green.opacity(0.55))

            Text(viewModel.searchText.isEmpty ? "暂无会话" : "没有匹配的会话")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DoveTheme.ink)

            Text(viewModel.searchText.isEmpty ? "下拉刷新同步服务器会话。" : "换个关键词再试试。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func upsertCreatedGroup(_ group: CreatedGroupDraft) {
        if let existing = chats.first(where: { $0.chatId == group.groupId }) {
            existing.name = group.name
            existing.type = "group"
            existing.memberIds = group.memberIds
            existing.updatedAt = Date()
            try? modelContext.save()
            return
        }

        let chat = Chat(
            chatId: group.groupId,
            name: group.name,
            type: "group",
            unreadCount: 0,
            lastMessage: "群聊已创建",
            updatedAt: Date(),
            isEncrypted: true,
            memberIds: group.memberIds
        )
        modelContext.insert(chat)
        try? modelContext.save()
    }
}

private struct ConversationCell: View {
    let chat: Chat
    let conversation: ChatConversationModel

    var body: some View {
        NavigationLink(value: chat) {
            HStack(alignment: .center, spacing: 12) {
                DoveAvatar(
                    name: conversation.title,
                    url: conversation.avatarURL,
                    size: 56,
                    isGroup: conversation.isGroup,
                    isOnline: conversation.isOnline
                )
                conversationSummary
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开与\(conversation.title)的聊天")
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minHeight: 76)
        .background(conversation.isPinned ? DoveTheme.greenSoft.opacity(0.40) : Color.clear)
        .contentShape(Rectangle())
    }

    private var conversationSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(conversation.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DoveTheme.ink)
                    .lineLimit(1)

                if conversation.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.yellow)
                }

                if conversation.isEncrypted {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DoveTheme.green.opacity(0.82))
                }

                if conversation.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.75))
                }

                Spacer(minLength: 8)

                Text(conversation.timeString)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary.opacity(0.8))
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(conversation.subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                ConversationUnreadBadge(
                    count: conversation.unreadCount,
                    isMuted: conversation.isMuted
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DoveTheme.separator)
                .frame(maxWidth: .infinity)
                .frame(height: 0.5)
        }
    }
}

private struct ConversationUnreadBadge: View {
    let count: Int
    let isMuted: Bool

    var body: some View {
        if count > 0 {
            Text(count > 9_999 ? "9.9K" : "\(count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.horizontal, count > 9 ? 8 : 6)
                .frame(minWidth: 22, minHeight: 22)
                .background(isMuted ? Color.secondary.opacity(0.55) : DoveTheme.accent, in: Capsule())
        }
    }
}

private struct ConversationFilterPills: View {
    @Binding var selection: IMConversationViewModel.Filter
    let groupUnread: Int

    var body: some View {
        HStack(spacing: 8) {
            filterButton(title: "全部", value: .all, badge: nil)
            filterButton(title: "群聊", value: .group, badge: groupUnread)
        }
    }

    private func filterButton(title: String, value: IMConversationViewModel.Filter, badge: Int?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selection = value
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if let badge, badge > 0 {
                    Text("\(badge > 99 ? "99+" : "\(badge)")")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DoveTheme.green, in: Capsule())
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(selection == value ? .white : DoveTheme.green)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(selection == value ? DoveTheme.green : DoveTheme.mist, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PlusMenuOverlay: View {
    let onClose: () -> Void
    let onCreateGroup: () -> Void
    let onAddFriend: () -> Void
    let onScan: () -> Void
    let onQRCode: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 4) {
                plusMenuButton(title: "发起群聊", systemImage: "person.3.fill", action: onCreateGroup)
                plusMenuButton(title: "添加朋友", systemImage: "person.badge.plus", action: onAddFriend)
                plusMenuButton(title: "扫一扫", systemImage: "qrcode.viewfinder", action: onScan)
                plusMenuButton(title: "我的二维码", systemImage: "qrcode", action: onQRCode)
            }
            .padding(8)
            .frame(width: 172)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.55), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 22, y: 10)
            .padding(.top, 64)
            .padding(.trailing, 14)
        }
    }

    private func plusMenuButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            onClose()
            action()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DoveTheme.green)
                    .frame(width: 28, height: 28)
                    .background(DoveTheme.greenSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DoveTheme.ink)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ChatListSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(DoveTheme.warmGray.opacity(0.7))
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DoveTheme.warmGray.opacity(0.82))
                            .frame(width: index.isMultiple(of: 2) ? 116 : 152, height: 13)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DoveTheme.warmGray.opacity(0.55))
                            .frame(width: index.isMultiple(of: 2) ? 190 : 142, height: 11)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .redacted(reason: .placeholder)
            }
        }
    }
}

private struct CreatedGroupDraft {
    let groupId: String
    let name: String
    let memberIds: [String]
}

private struct CreateGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var friends: [RemoteFriend] = []
    @State private var selectedIds: Set<String> = []
    @State private var searchText = ""
    @State private var groupName = ""
    @State private var step: Step = .select
    @State private var isLoading = false
    @State private var errorMessage: String?

    let onCreated: (CreatedGroupDraft) -> Void

    private enum Step {
        case select
        case name
    }

    private var filteredFriends: [RemoteFriend] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return friends }
        return friends.filter {
            $0.name.localizedCaseInsensitiveContains(keyword)
                || ($0.uniqueId ?? "").localizedCaseInsensitiveContains(keyword)
                || ($0.bio ?? "").localizedCaseInsensitiveContains(keyword)
        }
    }

    private var selectedFriends: [RemoteFriend] {
        friends.filter { selectedIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Capsule()
                    .fill(.secondary.opacity(0.25))
                    .frame(width: 42, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                header

                if step == .select {
                    selectStep
                } else {
                    nameStep
                }
            }
            .background(DoveTheme.paper.ignoresSafeArea())
            .task {
                await loadFriends()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if step == .name {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                        step = .select
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DoveTheme.ink)
                        .frame(width: 30, height: 30)
                        .background(DoveTheme.warmGray.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
            }

            Text(step == .select ? "发起群聊" : "设置群名称")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DoveTheme.ink)

            if step == .select && !selectedIds.isEmpty {
                Text("已选 \(selectedIds.count) 人")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DoveTheme.green)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(DoveTheme.warmGray.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var selectStep: some View {
        VStack(spacing: 0) {
            if !selectedFriends.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(selectedFriends) { friend in
                            VStack(spacing: 4) {
                                ZStack(alignment: .topTrailing) {
                                    DoveAvatar(name: friend.name, url: friend.avatar, size: 38)
                                    Button {
                                        selectedIds.remove(friend.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, height: 16)
                                            .background(.secondary, in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 3, y: -3)
                                }
                                Text(friend.name)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(width: 46)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
            }

            DoveSearchBar(text: $searchText, placeholder: "搜索联系人")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Group {
                if isLoading && friends.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("加载联系人...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredFriends.isEmpty {
                    ContentUnavailableView("暂无联系人", systemImage: "person.2.slash", description: Text("先添加好友，再发起群聊。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredFriends) { friend in
                                Button {
                                    toggle(friend.id)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selectedIds.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 21, weight: .semibold))
                                            .foregroundStyle(selectedIds.contains(friend.id) ? DoveTheme.green : .secondary.opacity(0.45))

                                        DoveAvatar(name: friend.name, url: friend.avatar, size: 42, isOnline: friend.online == true)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(friend.name)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(DoveTheme.ink)
                                            Text(friend.bio?.isEmpty == false ? friend.bio! : "@\(friend.uniqueId ?? friend.id)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 11)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Button {
                prepareNameStep()
            } label: {
                Text("下一步（\(selectedIds.count) 人）")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selectedIds.isEmpty ? Color.secondary : Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(selectedIds.isEmpty ? DoveTheme.warmGray.opacity(0.75) : DoveTheme.green, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(selectedIds.isEmpty)
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var nameStep: some View {
        VStack(spacing: 16) {
            HStack(spacing: -6) {
                ForEach(selectedFriends.prefix(5)) { friend in
                    DoveAvatar(name: friend.name, url: friend.avatar, size: 42)
                }
                if selectedFriends.count > 5 {
                    Text("+\(selectedFriends.count - 5)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, height: 42)
                        .background(DoveTheme.warmGray.opacity(0.75), in: Circle())
                }
            }
            .padding(.top, 26)

            Text("共 \(selectedIds.count + 1) 人（含你）")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("群名称")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("请输入群名称", text: $groupName)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(DoveTheme.warmGray.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("\(groupName.count)/30")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 20)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }

            Button {
                Task { await createGroup() }
            } label: {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "person.3.fill")
                    }
                    Text(isLoading ? "创建中..." : "创建群聊")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DoveTheme.warmGray.opacity(0.75) : DoveTheme.green, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(isLoading || groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(.plain)
            .padding(.horizontal, 20)

            Spacer()
        }
    }

    private func toggle(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func loadFriends() async {
        guard AuthTokenStore.shared.token != nil else {
            errorMessage = "请先登录后再发起群聊"
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            friends = try await APIClient.shared.fetchFriends()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareNameStep() {
        guard !selectedIds.isEmpty else { return }
        let currentName = UserDefaults.standard.string(forKey: "current_user_name") ?? "我"
        let names = ([currentName] + selectedFriends.map(\.name)).prefix(3).joined(separator: "、")
        groupName = names + ((selectedFriends.count + 1) > 3 ? "..." : "")
        withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
            step = .name
        }
    }

    private func createGroup() async {
        guard let ownerId = UserDefaults.standard.string(forKey: "current_user_id") else {
            errorMessage = "请先登录后再创建群聊"
            return
        }

        let trimmedName = String(groupName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !trimmedName.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await APIClient.shared.createGroup(
                name: trimmedName,
                ownerId: ownerId,
                memberIds: Array(selectedIds)
            )
            onCreated(
                CreatedGroupDraft(
                    groupId: response.groupId,
                    name: trimmedName,
                    memberIds: [ownerId] + Array(selectedIds)
                )
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var scannedCode: String?

    var body: some View {
        NavigationStack {
            QRCodeScannerView { result in
                scannedCode = result
                dismiss()
            }
            .ignoresSafeArea()
            .navigationTitle("扫一扫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct MyQRCodeSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var userName: String {
        UserDefaults.standard.string(forKey: "current_user_name") ?? "IMIMChat"
    }

    private var userId: String {
        UserDefaults.standard.string(forKey: "current_user_id") ?? "guest"
    }

    private var avatar: String? {
        UserDefaults.standard.string(forKey: "current_user_avatar")
    }

    private var qrPayload: String {
        "https://wed.imim.chat/im/user/\(userId)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Capsule()
                    .fill(.secondary.opacity(0.25))
                    .frame(width: 42, height: 4)
                    .padding(.top, 10)

                VStack(spacing: 14) {
                    DoveAvatar(name: userName, url: avatar, size: 72)

                    VStack(spacing: 4) {
                        Text(userName)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(DoveTheme.ink)
                        Text("IMIM ID: \(userId)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let image = QRCodeGenerator.makeImage(from: qrPayload) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 214, height: 214)
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }

                    Text("扫一扫上面的二维码，加我为好友")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 320)
                .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 24, y: 10)

                Button {
                    UIPasteboard.general.string = qrPayload
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DoveTheme.green)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(DoveTheme.greenSoft, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 20)
            .background(DoveTheme.paper.ignoresSafeArea())
            .navigationTitle("我的二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private enum QRCodeGenerator {
    static func makeImage(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
