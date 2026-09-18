import SwiftData
import SwiftUI

struct AddFriendView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]

    @State private var account = ""
    @State private var note = ""
    @State private var searchResults: [RemoteUser] = []
    @State private var selectedUser: RemoteUser?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var onCreated: ((Chat) -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section("好友信息") {
                    TextField("好友 ID / 手机号 / 邮箱", text: $account)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("验证消息（可选）", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    Button {
                        Task { await searchUsers() }
                    } label: {
                        HStack {
                            Label("搜索用户", systemImage: "magnifyingglass")
                            Spacer()
                            if isLoading {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isLoading || account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !searchResults.isEmpty {
                    Section("搜索结果") {
                        ForEach(searchResults) { user in
                            Button {
                                Task { await addFriendAndCreateChat(user) }
                            } label: {
                                HStack(spacing: 12) {
                                    DoveAvatar(
                                        name: user.nickname ?? user.username,
                                        url: user.avatar,
                                        size: 42
                                    )

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(user.nickname ?? user.username)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text("ID: \(user.username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let bio = user.bio, !bio.isEmpty {
                                            Text(bio)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()

                                    if selectedUser?.id == user.id && isLoading {
                                        ProgressView()
                                    } else {
                                        Text("添加")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(DoveTheme.green)
                                    }
                                }
                            }
                            .disabled(isLoading)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                if let successMessage {
                    Section {
                        Text(successMessage)
                            .foregroundStyle(DoveTheme.green)
                            .font(.footnote)
                    }
                }

                Section("说明") {
                    Text("搜索到用户后会向服务器发送好友申请，并创建或打开对应私聊会话。若对方已经向你发送申请，服务器会自动通过。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加朋友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        Task { await searchOrAddFirstUser() }
                    }
                    .disabled(isLoading || account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func searchOrAddFirstUser() async {
        if let first = searchResults.first {
            await addFriendAndCreateChat(first)
        } else {
            await searchUsers()
            if let first = searchResults.first {
                await addFriendAndCreateChat(first)
            }
        }
    }

    private func searchUsers() async {
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
            searchResults = users
            if users.isEmpty {
                errorMessage = "没有找到该用户"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addFriendAndCreateChat(_ user: RemoteUser) async {
        selectedUser = user
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer {
            isLoading = false
            selectedUser = nil
        }

        if let existing = chats.first(where: { $0.memberIds.contains(user.id) || $0.chatId == user.id }) {
            onCreated?(existing)
            dismiss()
            return
        }

        do {
            _ = try await APIClient.shared.sendFriendRequest(
                to: user.id,
                message: note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let remoteChat = try await APIClient.shared.createChat(targetUserId: user.id)
            let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")
            let chat = upsert(remoteChat: remoteChat, currentUserId: currentUserId)
            successMessage = "已创建会话"
            onCreated?(chat)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
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
