import SwiftData
import SwiftUI

struct ContactsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]
    @State private var isShowingAddFriend = false
    @State private var isShowingScanner = false
    @State private var friends: [RemoteFriend] = []
    @State private var selectedChat: Chat?
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var privateChats: [Chat] {
        chats
            .filter { $0.type == "private" && !$0.isBot && !$0.isOfficial }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private var allContacts: [ContactListItem] {
        if !friends.isEmpty {
            return friends.map(ContactListItem.friend)
        }
        return privateChats.map(ContactListItem.chat)
    }

    private var filteredContacts: [ContactListItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return allContacts }
        return allContacts.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    private var groupedContacts: [(letter: String, contacts: [ContactListItem])] {
        let groups = Dictionary(grouping: filteredContacts) { item in
            item.letter
        }
        return groups.keys.sorted().map { key in
            (key, groups[key, default: []].sorted { $0.name.localizedCompare($1.name) == .orderedAscending })
        }
    }

    private var contactIndexLetters: [String] {
        groupedContacts.map(\.letter)
    }

    var body: some View {
        ZStack {
            DoveTheme.paper.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        DoveSearchBar(text: $searchText, placeholder: "搜索联系人")
                        quickEntries
                        contactsContent
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .overlay(alignment: .trailing) {
                    if contactIndexLetters.count > 1 {
                        ContactLetterIndex(letters: contactIndexLetters) { letter in
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(letter, anchor: .top)
                            }
                        }
                        .padding(.trailing, 5)
                    }
                }
            }
            .refreshable {
                await loadFriends()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: Chat.self) { chat in
            ChatDetailView(chat: chat)
        }
        .sheet(isPresented: $isShowingAddFriend) {
            AddFriendView { chat in
                selectedChat = chat
                Task { await loadFriends() }
            }
        }
        .sheet(isPresented: $isShowingScanner) {
            QRCodeScannerView { _ in
                isShowingScanner = false
            }
        }
        .sheet(item: $selectedChat) { chat in
            NavigationStack {
                ChatDetailView(chat: chat)
            }
        }
        .task {
            await loadFriends()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimAvatarDidChange)) { _ in
            Task { await loadFriends() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimProfileDidChange)) { _ in
            Task { await loadFriends() }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("通讯录")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(DoveTheme.ink)

            Spacer()

            Button {
                isShowingAddFriend = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(DoveTheme.ink)
                        .frame(width: 42, height: 42)

                    if pendingFriendCount > 0 {
                        DoveUnreadBadge(count: pendingFriendCount)
                            .offset(x: 8, y: -3)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var quickEntries: some View {
        VStack(spacing: 18) {
            ContactQuickEntry(
                title: "新的朋友",
                systemImage: "person.badge.plus",
                tint: .orange,
                badge: pendingFriendCount
            ) {
                isShowingAddFriend = true
            }

            ContactQuickEntry(
                title: "群聊",
                systemImage: "person.2.fill",
                tint: DoveTheme.green,
                badge: groupChats.count
            ) {}

            ContactQuickEntry(
                title: "扫一扫",
                systemImage: "qrcode.viewfinder",
                tint: .blue
            ) {
                isShowingScanner = true
            }
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private var contactsContent: some View {
        if isLoading && filteredContacts.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在同步好友...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        } else if filteredContacts.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "还没有好友" : "没有匹配的联系人",
                systemImage: "person.badge.plus",
                description: Text(searchText.isEmpty ? "点击右上角添加朋友，创建会话后就可以聊天。" : "换个关键词再试试。")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groupedContacts, id: \.letter) { group in
                    Text(group.letter)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DoveTheme.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 10)
                        .id(group.letter)

                    VStack(spacing: 0) {
                        ForEach(group.contacts) { item in
                            Button {
                                Task { await open(item) }
                            } label: {
                                ContactRow(item: item)
                            }
                            .buttonStyle(.plain)

                            if item.id != group.contacts.last?.id {
                                Divider()
                                    .padding(.leading, 64)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.top, 8)
        }
    }

    private var pendingFriendCount: Int {
        1
    }

    private var groupChats: [Chat] {
        chats.filter { $0.type == "group" }
    }

    private func loadFriends() async {
        guard AuthTokenStore.shared.token != nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            friends = try await APIClient.shared.fetchFriends()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ item: ContactListItem) async {
        switch item.source {
        case .friend(let friend):
            await openChat(with: friend)
        case .chat(let chat):
            selectedChat = chat
        }
    }

    private func openChat(with friend: RemoteFriend) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let remoteChat = try await APIClient.shared.createChat(targetUserId: friend.id)
            let chat = upsert(remoteChat: remoteChat)
            selectedChat = chat
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upsert(remoteChat: RemoteChat) -> Chat {
        if let existing = chats.first(where: { $0.chatId == remoteChat.id }) {
            existing.name = remoteChat.peer?.nickname ?? remoteChat.peer?.username ?? existing.name
            existing.avatar = remoteChat.peer?.avatar
            existing.lastMessage = remoteChat.lastMessage ?? existing.lastMessage
            existing.unreadCount = remoteChat.unreadCount ?? existing.unreadCount
            existing.updatedAt = Date(milliseconds: remoteChat.lastMessageAt ?? remoteChat.createdAt)
            existing.memberIds = [remoteChat.participantA, remoteChat.participantB]
            try? modelContext.save()
            return existing
        }

        let chat = remoteChat.toLocalChat(currentUserId: UserDefaults.standard.string(forKey: "current_user_id"))
        modelContext.insert(chat)
        try? modelContext.save()
        return chat
    }
}

private struct ContactLetterIndex: View {
    let letters: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(letters, id: \.self) { letter in
                Button(letter) { onSelect(letter) }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DoveTheme.green)
                    .frame(width: 20, height: 13)
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .background(DoveTheme.cardSurface.opacity(0.82), in: Capsule())
    }
}

private struct ContactQuickEntry: View {
    let title: String
    let systemImage: String
    let tint: Color
    var badge = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DoveTheme.ink)

                Spacer()

                DoveUnreadBadge(count: badge)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ContactRow: View {
    let item: ContactListItem

    var body: some View {
        HStack(spacing: 14) {
            DoveAvatar(
                name: item.name,
                url: item.avatar,
                size: 52,
                isGroup: item.isGroup,
                isOnline: item.isOnline
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DoveTheme.ink)
                    .lineLimit(1)

                Text(item.statusText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

private struct ContactListItem: Identifiable {
    enum Source {
        case friend(RemoteFriend)
        case chat(Chat)
    }

    let source: Source

    static func friend(_ friend: RemoteFriend) -> ContactListItem {
        ContactListItem(source: .friend(friend))
    }

    static func chat(_ chat: Chat) -> ContactListItem {
        ContactListItem(source: .chat(chat))
    }

    var id: String {
        switch source {
        case .friend(let friend): friend.id
        case .chat(let chat): chat.chatId
        }
    }

    var name: String {
        switch source {
        case .friend(let friend): friend.name
        case .chat(let chat): chat.name
        }
    }

    var avatar: String? {
        switch source {
        case .friend(let friend): friend.avatar
        case .chat(let chat): chat.avatar
        }
    }

    var isGroup: Bool {
        switch source {
        case .friend: false
        case .chat(let chat): chat.type == "group"
        }
    }

    var isOnline: Bool {
        switch source {
        case .friend(let friend): friend.online == true
        case .chat: false
        }
    }

    var statusText: String {
        switch source {
        case .friend(let friend):
            if friend.online == true { return "在线" }
            if let lastSeen = friend.lastSeen {
                let date = Date(milliseconds: lastSeen)
                return "最后在线 \(date.chatListTimeText)"
            }
            return friend.bio?.isEmpty == false ? friend.bio! : "离线"
        case .chat(let chat):
            return chat.lastMessage.isEmpty ? "点击开始聊天" : chat.lastMessage
        }
    }

    var letter: String {
        switch source {
        case .friend(let friend):
            if let letter = friend.letter, !letter.isEmpty { return letter.uppercased() }
        case .chat:
            break
        }
        let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "#"
        return first.range(of: "[A-Za-z]", options: .regularExpression) == nil ? "#" : first.uppercased()
    }
}
