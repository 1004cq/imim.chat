import SwiftData
import SwiftUI

struct AddFriendView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]

    @State private var account: String
    @State private var note = ""
    @State private var searchResults: [RemoteUser] = []
    @State private var selectedUser: RemoteUser?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var isShowingSearch: Bool
    @State private var sentUserIDs: Set<String> = []
    @State private var inboxSyncError: String?
    @StateObject private var inbox = FriendRequestInbox()
    @Environment(\.scenePhase) private var scenePhase

    var onCreated: ((Chat) -> Void)?

    init(initialAccount: String = "", onCreated: ((Chat) -> Void)? = nil) {
        _account = State(initialValue: initialAccount)
        _isShowingSearch = State(initialValue: !initialAccount.isEmpty)
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            FriendRequestsContent(
                sections: inbox.sections, userID: inbox.userID, isLoading: inbox.isLoading,
                processingIDs: inbox.processingIDs, errorMessage: inbox.errorMessage ?? inboxSyncError,
                onClose: { dismiss() }, onSearch: { isShowingSearch = true },
                onRefresh: { await inbox.refresh() },
                onRespond: { request, accept in Task { await respond(request, accept: accept) } }
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isShowingSearch) {
                AddFriendContent(
                    account: $account, note: $note, searchResults: searchResults,
                    selectedUserID: selectedUser?.id, isLoading: isLoading,
                    errorMessage: errorMessage, successMessage: successMessage, sentUserIDs: sentUserIDs,
                    onCancel: { isShowingSearch = false },
                    onSearch: { Task { await searchUsers() } },
                    onAdd: { user in Task { await addFriendAndCreateChat(user) } }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .onChange(of: account) { _, _ in
            // A result belongs to the searched account, not the next input.
            searchResults = []
            errorMessage = nil
            successMessage = nil
        }
        .task {
            await inbox.refresh()
            if !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               searchResults.isEmpty {
                await searchUsers()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await inbox.refresh() } }
        }
    }

    private func searchUsers() async {
        guard !isLoading else { return }
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedAccount.count >= 3 else {
            errorMessage = "请输入有效的好友 ID、手机号或邮箱"
            return
        }

        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { isLoading = false }

        do {
            let users = try await APIClient.shared.searchUsers(keyword: normalizedAccount)
            guard account.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedAccount else { return }
            searchResults = users
            if users.isEmpty {
                errorMessage = "没有找到该用户"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addFriendAndCreateChat(_ user: RemoteUser) async {
        guard !isLoading, !sentUserIDs.contains(user.id),
              let owner = UserDefaults.standard.string(forKey: "current_user_id"), !owner.isEmpty else { return }
        selectedUser = user
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer {
            isLoading = false
            selectedUser = nil
        }

        do {
            let result = try await APIClient.shared.sendFriendRequest(
                to: user.id,
                message: note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard UserDefaults.standard.string(forKey: "current_user_id") == owner else { return }
            guard result.success else {
                throw APIClientError.server(result.message ?? "发送好友申请失败")
            }
            // A conversation is not proof of friendship. Pending requests must
            // wait for approval rather than immediately creating/opening a chat.
            if result.autoAccepted != true && result.request?.status != "accepted" {
                sentUserIDs.insert(user.id)
                successMessage = "好友申请已发送，等待对方同意"
                await inbox.refresh()
                return
            }
            let remoteChat = try await APIClient.shared.createChat(targetUserId: user.id)
            guard UserDefaults.standard.string(forKey: "current_user_id") == owner else { return }
            let chat = upsert(remoteChat: remoteChat, currentUserId: owner)
            successMessage = "已创建会话"
            onCreated?(chat)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func respond(_ request: RemoteFriendRequest, accept: Bool) async {
        guard let owner = inbox.userID else { return }
        inboxSyncError = nil
        guard await inbox.respond(id: request.id, accept: accept) else { return }
        guard UserDefaults.standard.string(forKey: "current_user_id") == owner else { return }
        NotificationCenter.default.post(name: .cqimFriendshipDidChange, object: nil)
        guard accept else { return }
        do {
            let remoteChat = try await APIClient.shared.createChat(targetUserId: request.fromId)
            guard UserDefaults.standard.string(forKey: "current_user_id") == owner else { return }
            _ = upsert(remoteChat: remoteChat, currentUserId: owner)
        } catch {
            inboxSyncError = "已同意申请，聊天暂未同步，请稍后刷新。"
        }
    }

    private func upsert(remoteChat: RemoteChat, currentUserId: String?) -> Chat {
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

        let chat = remoteChat.toLocalChat(currentUserId: currentUserId)
        modelContext.insert(chat)
        try? modelContext.save()
        return chat
    }
}

extension Notification.Name {
    static let cqimFriendshipDidChange = Notification.Name("CQIMFriendshipDidChange")
}

struct FriendRequestSection: Identifiable {
    let id: String
    let title: String
    let requests: [RemoteFriendRequest]
}

/// UI-owned request state. Decisions only affect incoming, pending requests,
/// and statuses change only after the authenticated API succeeds.
@MainActor
final class FriendRequestInbox: ObservableObject {
    @Published private(set) var requests: [RemoteFriendRequest] = []
    @Published private(set) var userID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var processingIDs: Set<String> = []
    @Published private(set) var errorMessage: String?

    private let fetch: () async throws -> [RemoteFriendRequest]
    private let decide: (String, Bool) async throws -> Void
    private let identity: () -> String?

    init(fetch: @escaping () async throws -> [RemoteFriendRequest] = { try await APIClient.shared.fetchFriendRequests() },
         decide: @escaping (String, Bool) async throws -> Void = { id, accept in
             _ = try await APIClient.shared.respondToFriendRequest(id: id, accept: accept)
         }, identity: @escaping () -> String? = { UserDefaults.standard.string(forKey: "current_user_id") }) {
        self.fetch = fetch
        self.decide = decide
        self.identity = identity
    }

    var sections: [FriendRequestSection] { Self.group(requests, userID: userID) }

    func refresh() async {
        guard !isLoading, processingIDs.isEmpty else { return }
        guard let owner = identity(), !owner.isEmpty else {
            requests = []
            userID = nil
            errorMessage = "请先登录后查看好友申请"
            return
        }
        if userID != owner { requests = [] }
        userID = owner
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await fetch()
            try Task.checkCancellation()
            guard identity() == owner else { resetForChangedAccount(); return }
            requests = result.filter { $0.fromId == owner || $0.toId == owner }
            AvatarImageLoader.shared.prefetch(requests.map {
                .init(userId: $0.peerId(for: owner), urlString: $0.peerAvatar(for: owner))
            })
        } catch {
            guard identity() == owner else { resetForChangedAccount(); return }
            if !Task.isCancelled && !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    func respond(id: String, accept: Bool) async -> Bool {
        guard !isLoading, !processingIDs.contains(id), let owner = userID, identity() == owner,
              let request = requests.first(where: { $0.id == id }),
              request.status == "pending", request.toId == owner else { return false }
        processingIDs.insert(id)
        errorMessage = nil
        defer { processingIDs.remove(id) }
        do {
            try await decide(id, accept)
            guard identity() == owner else { resetForChangedAccount(); return false }
            if let index = requests.firstIndex(where: { $0.id == id }) {
                requests[index].status = accept ? "accepted" : "rejected"
            }
            return true
        } catch {
            guard identity() == owner else { resetForChangedAccount(); return false }
            if !Task.isCancelled && !(error is CancellationError) { errorMessage = error.localizedDescription }
            return false
        }
    }

    private func resetForChangedAccount() {
        requests = []
        userID = identity()
        errorMessage = nil
    }

    static func group(_ requests: [RemoteFriendRequest], userID: String?, now: Date = Date(),
                      calendar: Calendar = .current) -> [FriendRequestSection] {
        let sorted = requests.sorted { ($0.requestDate ?? .distantPast) > ($1.requestDate ?? .distantPast) }
        let pending = sorted.filter { $0.status == "pending" && $0.incoming(for: userID) }
        let others = sorted.filter { !($0.status == "pending" && $0.incoming(for: userID)) }
        let recent = others.filter {
            guard let date = $0.requestDate else { return false }
            return (calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                             to: calendar.startOfDay(for: now)).day ?? 4) < 3
        }
        let recentIDs = Set(recent.map(\.id))
        let earlier = others.filter { !recentIDs.contains($0.id) }
        return [
            FriendRequestSection(id: "pending", title: "待处理", requests: pending),
            FriendRequestSection(id: "recent", title: "最近三天", requests: recent),
            FriendRequestSection(id: "earlier", title: "更早", requests: earlier)
        ].filter { !$0.requests.isEmpty }
    }
}

struct FriendRequestsContent: View {
    let sections: [FriendRequestSection]
    let userID: String?
    var isLoading = false
    var processingIDs: Set<String> = []
    var errorMessage: String? = nil
    var onClose: () -> Void = {}
    var onSearch: () -> Void = {}
    var onRefresh: () async -> Void = {}
    var onRespond: (RemoteFriendRequest, Bool) -> Void = { _, _ in }

    var body: some View {
        VStack(spacing: 0) {
            header
            Button(action: onSearch) {
                Label("账号 / 手机号 / 邮箱", systemImage: "magnifyingglass")
                    .font(.body)
                    .foregroundStyle(DoveTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(DoveTheme.warmGray.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索账号，添加朋友")
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)

            List {
                if let errorMessage {
                    Label(LocalizedStringKey(errorMessage), systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .listRowSeparator(.hidden)
                        .listRowBackground(DoveTheme.cardSurface)
                }
                if isLoading && sections.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在加载好友申请…").foregroundStyle(DoveTheme.secondaryText)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(DoveTheme.cardSurface)
                } else if sections.isEmpty && errorMessage == nil {
                    ContentUnavailableView("暂无好友申请", systemImage: "person.badge.plus",
                                           description: Text("收到的申请会显示在这里，你可以选择同意或拒绝。"))
                        .listRowSeparator(.hidden)
                        .listRowBackground(DoveTheme.cardSurface)
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.requests) { request in
                            FriendRequestRow(request: request, userID: userID,
                                             isBusy: processingIDs.contains(request.id), isDisabled: isLoading) { accept in
                                onRespond(request, accept)
                            }
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                            .listRowBackground(DoveTheme.cardSurface)
                            .listRowSeparatorTint(DoveTheme.separator.opacity(0.4))
                        }
                    } header: {
                        AppLocalizedText(section.title).font(.footnote).foregroundStyle(DoveTheme.secondaryText)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DoveTheme.cardSurface)
            .refreshable { await onRefresh() }
        }
        .foregroundStyle(DoveTheme.ink)
        .background(DoveTheme.paper.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭新的朋友")
            Spacer()
            Text("新的朋友").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button("添加朋友", systemImage: "person.badge.plus", action: onSearch)
                Button("刷新申请", systemImage: "arrow.clockwise") { Task { await onRefresh() } }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("新的朋友，更多操作")
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
    }
}

struct FriendRequestRow: View {
    let request: RemoteFriendRequest
    let userID: String?
    var isBusy = false
    var isDisabled = false
    var onRespond: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DoveCachedAvatarImage(name: request.peerName(for: userID), url: request.peerAvatar(for: userID),
                                  userId: request.peerId(for: userID), size: 44, isGroup: false)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(request.peerName(for: userID))
            VStack(alignment: .leading, spacing: 5) {
                Text(request.peerName(for: userID)).font(.body).lineLimit(1)
                Text(verificationMessage).font(.subheadline).foregroundStyle(DoveTheme.secondaryText).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if request.status == "pending" && request.incoming(for: userID) {
                if isBusy {
                    ProgressView().frame(width: 108, height: 44)
                        .accessibilityLabel("正在处理申请")
                } else {
                    HStack(spacing: 6) {
                        decisionButton("拒绝", accept: false)
                        decisionButton("同意", accept: true)
                    }
                }
            } else {
                HStack(spacing: 3) {
                    if !request.incoming(for: userID) {
                        Image(systemName: "arrow.up.right").font(.caption)
                    }
                    AppLocalizedText(statusTitle).font(.subheadline)
                }
                .foregroundStyle(DoveTheme.secondaryText)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: 48)
    }

    private var verificationMessage: String {
        let text = request.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = text?.isEmpty == false ? text! : AppLocalization.string("请求添加你为好友")
        return request.incoming(for: userID) ? message : AppLocalization.text("我：\(message)")
    }

    private var statusTitle: String {
        switch request.status {
        case "accepted": return "已添加"
        case "rejected": return "已拒绝"
        case "expired": return "已过期"
        case "pending": return "等待验证"
        default: return "已处理"
        }
    }

    private func decisionButton(_ title: String, accept: Bool) -> some View {
        Button { onRespond(accept) } label: {
            AppLocalizedText(title).font(.subheadline.weight(accept ? .semibold : .regular))
                .frame(minWidth: 40, minHeight: 44)
                .padding(.horizontal, 5)
                .foregroundStyle(accept ? DoveTheme.paper : DoveTheme.ink)
                .background(accept ? DoveTheme.ink : DoveTheme.warmGray, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isBusy)
        .accessibilityLabel("\(title) \(request.peerName(for: userID)) 的好友申请")
        .accessibilityIdentifier("friend-request.\(accept ? "accept" : "reject").\(request.id)")
    }
}

/// Presentation only: previews never fetch users or send friend requests.
struct AddFriendContent: View {
    @Binding var account: String
    @Binding var note: String
    var searchResults: [RemoteUser] = []
    var selectedUserID: String? = nil
    var isLoading = false
    var errorMessage: String? = nil
    var successMessage: String? = nil
    var sentUserIDs: Set<String> = []
    var onCancel: () -> Void = {}
    var onSearch: () -> Void = {}
    var onAdd: (RemoteUser) -> Void = { _ in }

    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case account, note }

    private var canSearch: Bool {
        !isLoading && account.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    introduction
                    accountInput
                    verificationInput

                    if let errorMessage {
                        statusMessage(errorMessage, symbol: "exclamationmark.circle", color: .red)
                    }
                    if let successMessage {
                        statusMessage(successMessage, symbol: "checkmark.circle", color: DoveTheme.green)
                    }
                    if !searchResults.isEmpty { results }

                    Label {
                        Text("发送好友申请后，等待对方同意即可开始聊天。若对方已向你发送申请，将自动通过。")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    .font(.footnote)
                    .foregroundStyle(DoveTheme.secondaryText)
                    .labelStyle(.titleAndIcon)
                    .padding(.top, 2)
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(DoveTheme.paper.ignoresSafeArea())
        .foregroundStyle(DoveTheme.ink)
    }

    private var header: some View {
        ZStack {
            Text("添加朋友")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(DoveTheme.warmGray.opacity(0.65), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭添加朋友")
                .accessibilityIdentifier("add-friend.close")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("找到你的朋友")
                .font(.title2.weight(.semibold))
            Text("通过账号、手机号或邮箱搜索")
                .font(.subheadline)
                .foregroundStyle(DoveTheme.secondaryText)
        }
    }

    private var accountInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("好友账号")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DoveTheme.secondaryText)
                TextField("ID / 手机号 / 邮箱", text: $account)
                    .font(.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .account)
                    .submitLabel(.search)
                    .onSubmit { search() }
                    .disabled(isLoading)
                    .accessibilityLabel("好友账号、手机号或邮箱")
                    .accessibilityIdentifier("add-friend.account")
                if !account.isEmpty {
                    Button {
                        account = ""
                        focusedField = .account
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DoveTheme.secondaryText)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                    .accessibilityLabel("清空账号")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, account.isEmpty ? 16 : 4)
            .frame(minHeight: 54)
            .background(DoveTheme.warmGray.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(DoveTheme.ink.opacity(focusedField == .account ? 0.3 : 0.06), lineWidth: 1)
            }

            Button(action: search) {
                HStack(spacing: 8) {
                    if isLoading && selectedUserID == nil {
                        ProgressView().tint(DoveTheme.paper)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(isLoading && selectedUserID == nil ? AppLocalization.text("正在搜索…") : AppLocalization.text("搜索用户"))
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(canSearch || isLoading ? DoveTheme.paper : DoveTheme.secondaryText)
                .background(canSearch || isLoading ? DoveTheme.ink : DoveTheme.warmGray,
                            in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(!canSearch)
            .accessibilityIdentifier("add-friend.search")
        }
    }

    private var verificationInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("验证消息").font(.subheadline.weight(.semibold))
                Text("选填").font(.caption).foregroundStyle(DoveTheme.secondaryText)
            }
            TextField("介绍一下自己，让对方认出你", text: $note, axis: .vertical)
                .font(.body)
                .lineLimit(2...3)
                .focused($focusedField, equals: .note)
                .disabled(isLoading)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DoveTheme.warmGray.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(DoveTheme.ink.opacity(focusedField == .note ? 0.3 : 0.06), lineWidth: 1)
                }
                .accessibilityLabel("验证消息，选填")
                .accessibilityIdentifier("add-friend.note")
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("搜索结果 · \(searchResults.count)")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(searchResults) { user in
                HStack(spacing: 12) {
                    DoveAvatar(name: user.nickname ?? user.username, url: user.avatar, userId: user.id, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.nickname ?? user.username).font(.body.weight(.semibold))
                        Text("ID：\(user.username)").font(.caption).foregroundStyle(DoveTheme.secondaryText)
                        if let bio = user.bio, !bio.isEmpty {
                            Text(bio).font(.caption).foregroundStyle(DoveTheme.secondaryText).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        focusedField = nil
                        onAdd(user)
                    } label: {
                        Group {
                            if isLoading && selectedUserID == user.id {
                                ProgressView().tint(DoveTheme.paper)
                            } else {
                                Text(sentUserIDs.contains(user.id) ? AppLocalization.text("已发送") : AppLocalization.text("添加"))
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 10)
                        .foregroundStyle(DoveTheme.paper)
                        .background(DoveTheme.ink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading || sentUserIDs.contains(user.id))
                    .accessibilityLabel("添加 \(user.nickname ?? user.username)")
                    .accessibilityIdentifier("add-friend.add.\(user.id)")
                }
                .padding(14)
                .background(DoveTheme.warmGray.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    private func statusMessage(_ message: String, symbol: String, color: Color) -> some View {
        Label(LocalizedStringKey(message), systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func search() {
        guard canSearch else { return }
        focusedField = nil
        onSearch()
    }
}

#if DEBUG
#Preview("添加朋友 · 空白") {
    AddFriendContent(account: .constant(""), note: .constant(""))
}

#Preview("添加朋友 · 搜索结果") {
    AddFriendContent(account: .constant("lin"), note: .constant("你好，我是林。"), searchResults: [
        RemoteUser(id: "preview-lin", username: "lin", nickname: "林", avatar: nil, bio: "保持联系，保持真实。")
    ])
}

#Preview("添加朋友 · 网络错误") {
    AddFriendContent(account: .constant("lin"), note: .constant(""), errorMessage: "网络连接失败，请重试。")
        .preferredColorScheme(.dark)
}
#endif
