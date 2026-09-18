import Foundation
import Security
import SwiftData
import SwiftUI
import UIKit

extension Notification.Name {
    static let cqimConversationAppearanceDidChange = Notification.Name("cqimConversationAppearanceDidChange")
}

enum ChatBackgroundStyle: String, CaseIterable, Identifiable {
    case paper
    case mint
    case sky
    case dusk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: "简洁白"
        case .mint: "薄荷"
        case .sky: "晴空"
        case .dusk: "暮色"
        }
    }

    var colors: [Color] {
        switch self {
        case .paper: [DoveTheme.paper, DoveTheme.mist]
        case .mint: [Color(red: 0.88, green: 0.98, blue: 0.92), Color(red: 0.80, green: 0.94, blue: 0.89)]
        case .sky: [Color(red: 0.83, green: 0.95, blue: 1.0), Color(red: 0.88, green: 0.92, blue: 1.0)]
        case .dusk: [Color(red: 0.20, green: 0.18, blue: 0.32), Color(red: 0.38, green: 0.25, blue: 0.45)]
        }
    }
}

struct ConversationBackground: View {
    let style: ChatBackgroundStyle

    var body: some View {
        LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

enum ConversationPreferences {
    private static let defaults = UserDefaults.standard
    private static let service = "chat.imim.conversation-passcode"

    static func backgroundStyle(for chatId: String) -> ChatBackgroundStyle {
        ChatBackgroundStyle(rawValue: defaults.string(forKey: "chat.background.\(chatId)") ?? "") ?? .paper
    }

    static func setBackgroundStyle(_ style: ChatBackgroundStyle, for chatId: String) {
        defaults.set(style.rawValue, forKey: "chat.background.\(chatId)")
        NotificationCenter.default.post(name: .cqimConversationAppearanceDidChange, object: chatId)
    }

    static func readReceiptsEnabled(for chatId: String) -> Bool {
        let key = "chat.read-receipts.\(chatId)"
        return defaults.object(forKey: key) as? Bool ?? true
    }

    static func setReadReceiptsEnabled(_ isEnabled: Bool, for chatId: String) {
        defaults.set(isEnabled, forKey: "chat.read-receipts.\(chatId)")
    }

    static func isMuted(for chatId: String) -> Bool {
        defaults.bool(forKey: "chat.muted.\(chatId)")
    }

    static func setMuted(_ isMuted: Bool, for chatId: String) {
        defaults.set(isMuted, forKey: "chat.muted.\(chatId)")
    }

    static func hasPasscode(for chatId: String) -> Bool {
        readPasscode(for: chatId) != nil
    }

    static func verify(passcode: String, for chatId: String) -> Bool {
        readPasscode(for: chatId) == passcode
    }

    static func save(passcode: String, for chatId: String) {
        let data = Data(passcode.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: chatId,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func removePasscode(for chatId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: chatId,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func readPasscode(for chatId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: chatId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct ChatSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let chat: Chat
    let onBackgroundChanged: () -> Void

    @State private var isReadReceiptEnabled: Bool
    @State private var isPasswordProtected: Bool
    @State private var isShowingPasswordSheet = false
    @State private var isShowingClearConfirmation = false
    @State private var isShowingReportSheet = false

    init(chat: Chat, onBackgroundChanged: @escaping () -> Void) {
        self.chat = chat
        self.onBackgroundChanged = onBackgroundChanged
        _isReadReceiptEnabled = State(initialValue: ConversationPreferences.readReceiptsEnabled(for: chat.chatId))
        _isPasswordProtected = State(initialValue: ConversationPreferences.hasPasscode(for: chat.chatId))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                profileHeader
                settingsCard {
                    NavigationLink { ChatMessageSearchView(chat: chat) } label: {
                        SettingsNavigationRow(title: "查找聊天内容", icon: "magnifyingglass")
                    }
                }
                settingsCard {
                    Toggle("消息免打扰", isOn: mutedBinding)
                    Divider()
                    Toggle("置顶聊天", isOn: chatBooleanBinding(\.isPinned))
                    Divider()
                    Toggle("聊天密码", isOn: passwordBinding)
                    Divider()
                    Toggle("消息回执", isOn: $isReadReceiptEnabled)
                        .onChange(of: isReadReceiptEnabled) { _, value in
                            ConversationPreferences.setReadReceiptsEnabled(value, for: chat.chatId)
                        }
                    Text("开启后，对方可看到你已阅读其消息。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                settingsCard {
                    NavigationLink {
                        ConversationBackgroundPicker(chatId: chat.chatId, onBackgroundChanged: onBackgroundChanged)
                    } label: {
                        SettingsNavigationRow(title: "设置当前聊天背景", icon: "paintpalette")
                    }
                    Divider()
                    Button { openNotificationSettings() } label: {
                        SettingsNavigationRow(title: "消息通知设置", icon: "bell")
                    }
                    .buttonStyle(.plain)
                    Divider()
                    Button { isShowingReportSheet = true } label: {
                        SettingsNavigationRow(title: "投诉", icon: "exclamationmark.bubble")
                    }
                    .buttonStyle(.plain)
                }
                Button(role: .destructive) { isShowingClearConfirmation = true } label: {
                    Text("清空聊天记录")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                }
                .background(DoveTheme.cardSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("仅清理这台设备上的记录，不会撤回对方消息。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, -8)
            }
            .padding(16)
        }
        .background(DoveTheme.mist.ignoresSafeArea())
        .navigationTitle("聊天详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingPasswordSheet) {
            ConversationPasscodeSheet(chatName: chat.name) { passcode in
                ConversationPreferences.save(passcode: passcode, for: chat.chatId)
                isPasswordProtected = true
            }
        }
        .sheet(isPresented: $isShowingReportSheet) {
            ConversationReportSheet(chatName: chat.name, chatId: chat.chatId)
        }
        .alert("清空本机聊天记录？", isPresented: $isShowingClearConfirmation) {
            Button("清空", role: .destructive, action: clearLocalHistory)
            Button("取消", role: .cancel) {}
        } message: {
            Text("图片、文件和文字记录都会从此设备移除。")
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 10) {
            DoveAvatar(name: chat.name, url: chat.avatar, size: 76, isGroup: chat.type == "group")
            Text(chat.name).font(.title3.weight(.semibold)).foregroundStyle(DoveTheme.ink)
            Text(chat.type == "group" ? "群聊" : "端到端加密私聊")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(DoveTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var passwordBinding: Binding<Bool> {
        Binding(
            get: { isPasswordProtected },
            set: { enabled in
                if enabled {
                    isShowingPasswordSheet = true
                } else {
                    ConversationPreferences.removePasscode(for: chat.chatId)
                    isPasswordProtected = false
                }
            }
        )
    }

    private var mutedBinding: Binding<Bool> {
        Binding(
            get: { chat.isMuted },
            set: { value in
                chat.isMuted = value
                ConversationPreferences.setMuted(value, for: chat.chatId)
                try? modelContext.save()
            }
        )
    }

    private func chatBooleanBinding(_ keyPath: ReferenceWritableKeyPath<Chat, Bool>) -> Binding<Bool> {
        Binding(
            get: { chat[keyPath: keyPath] },
            set: { value in
                chat[keyPath: keyPath] = value
                try? modelContext.save()
            }
        )
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(16)
            .background(DoveTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func clearLocalHistory() {
        let messages = chat.messages
        chat.messages.removeAll()
        messages.forEach(modelContext.delete)
        chat.lastMessage = ""
        chat.updatedAt = Date()
        chat.unreadCount = 0
        try? modelContext.save()
        dismiss()
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct SettingsNavigationRow: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(DoveTheme.green)
                .frame(width: 22)
            Text(title).foregroundStyle(DoveTheme.ink)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct ConversationBackgroundPicker: View {
    @Environment(\.dismiss) private var dismiss
    let chatId: String
    let onBackgroundChanged: () -> Void
    @State private var selectedStyle: ChatBackgroundStyle

    init(chatId: String, onBackgroundChanged: @escaping () -> Void) {
        self.chatId = chatId
        self.onBackgroundChanged = onBackgroundChanged
        _selectedStyle = State(initialValue: ConversationPreferences.backgroundStyle(for: chatId))
    }

    var body: some View {
        List(ChatBackgroundStyle.allCases) { style in
            Button {
                selectedStyle = style
                ConversationPreferences.setBackgroundStyle(style, for: chatId)
                onBackgroundChanged()
            } label: {
                HStack {
                    ConversationBackground(style: style)
                        .frame(width: 76, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(style.title).foregroundStyle(DoveTheme.ink)
                    Spacer()
                    if selectedStyle == style { Image(systemName: "checkmark.circle.fill").foregroundStyle(DoveTheme.green) }
                }
            }
        }
        .navigationTitle("聊天背景")
    }
}

private struct ChatMessageSearchView: View {
    let chat: Chat
    @State private var query = ""

    private var results: [Message] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        return chat.messages
            .filter { $0.content.localizedCaseInsensitiveContains(keyword) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            if query.isEmpty {
                ContentUnavailableView("搜索聊天记录", systemImage: "magnifyingglass", description: Text("输入关键词后查找本机消息。"))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(results, id: \.messageId) { message in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(message.isOutgoing ? "我" : chat.name).font(.caption).foregroundStyle(.secondary)
                        Text(message.content).foregroundStyle(DoveTheme.ink).lineLimit(2)
                        Text(message.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .searchable(text: $query, prompt: "搜索聊天内容")
        .navigationTitle("查找聊天内容")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConversationPasscodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chatName: String
    let save: (String) -> Void
    @State private var passcode = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("为 \(chatName) 设置聊天密码") {
                    SecureField("输入 4–8 位密码", text: $passcode)
                        .keyboardType(.numberPad)
                    SecureField("再次输入密码", text: $confirmation)
                        .keyboardType(.numberPad)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("聊天密码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: submit).disabled(passcode.isEmpty || confirmation.isEmpty) }
            }
        }
    }

    private func submit() {
        guard (4...8).contains(passcode.count), passcode.allSatisfy(\.isNumber) else {
            errorMessage = "请输入 4–8 位数字密码"
            return
        }
        guard passcode == confirmation else {
            errorMessage = "两次输入的密码不一致"
            return
        }
        save(passcode)
        dismiss()
    }
}

struct ConversationUnlockOverlay: View {
    let name: String
    @Binding var passcode: String
    let errorMessage: String?
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.system(size: 30)).foregroundStyle(DoveTheme.green)
            Text("已锁定 \(name) 的聊天").font(.headline)
            SecureField("输入聊天密码", text: $passcode)
                .keyboardType(.numberPad)
                .textContentType(.password)
                .multilineTextAlignment(.center)
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            Button("解锁", action: unlock)
                .buttonStyle(.borderedProminent)
                .tint(DoveTheme.green)
                .disabled(passcode.isEmpty)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).opacity(0.98))
        .contentShape(Rectangle())
        .ignoresSafeArea()
    }
}

private struct ConversationReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chatName: String
    let chatId: String
    @State private var reason = "骚扰或垃圾信息"
    @State private var details = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("投诉原因", selection: $reason) {
                    Text("骚扰或垃圾信息").tag("骚扰或垃圾信息")
                    Text("冒充他人").tag("冒充他人")
                    Text("不当内容").tag("不当内容")
                    Text("其他").tag("其他")
                }
                TextEditor(text: $details).frame(minHeight: 110)
            }
            .navigationTitle("投诉 \(chatName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("通过邮件提交", action: submit) }
            }
        }
    }

    private func submit() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "support@imim.chat"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "CQIM 投诉：\(reason)"),
            URLQueryItem(name: "body", value: "会话：\(chatName)\n会话 ID：\(chatId)\n原因：\(reason)\n说明：\(details)"),
        ]
        if let url = components.url { UIApplication.shared.open(url) }
        dismiss()
    }
}
