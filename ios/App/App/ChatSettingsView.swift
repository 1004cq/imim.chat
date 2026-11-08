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
            VStack(spacing: 20) {
                profileHeader
                settingsCard {
                    NavigationLink { ChatMessageSearchView(chat: chat) } label: {
                        SettingsNavigationRow(title: "查找聊天内容", icon: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                }
                preferencesSection
                settingsCard {
                    NavigationLink {
                        ConversationBackgroundPicker(chatId: chat.chatId, onBackgroundChanged: onBackgroundChanged)
                    } label: {
                        SettingsNavigationRow(title: "设置当前聊天背景", icon: "paintpalette")
                    }
                    .buttonStyle(.plain)
                    settingsDivider
                    Button { openNotificationSettings() } label: {
                        SettingsNavigationRow(title: "消息通知设置", icon: "bell")
                    }
                    .buttonStyle(.plain)
                    settingsDivider
                    Button { isShowingReportSheet = true } label: {
                        SettingsNavigationRow(title: "投诉", icon: "exclamationmark.bubble")
                    }
                    .buttonStyle(.plain)
                }
                clearHistorySection
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("聊天详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .tint(DoveTheme.accent)
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
        HStack(spacing: 16) {
            DoveAvatar(name: chat.name, url: chat.avatar, userId: chat.avatarCacheIdentity, size: 68, isGroup: chat.type == "group")
            VStack(alignment: .leading, spacing: 8) {
                Text(chat.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(DoveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Image(systemName: AIConversation.matches(chat.chatId) ? "sparkles" : chat.type == "group" ? "person.2" : "lock.shield")
                        .accessibilityHidden(true)
                    AppLocalizedText(AIConversation.matches(chat.chatId) ? "AI 对话由 DeepSeek 处理" : chat.type == "group" ? "群聊" : "端到端加密私聊")
                }
                .font(.caption)
                .foregroundStyle(DoveTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DoveTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsCard {
                settingsToggle("消息免打扰", icon: "bell.slash", isOn: mutedBinding)
                if !chat.isBuiltinSystemConversation {
                    settingsDivider
                    settingsToggle("置顶聊天", icon: "pin", isOn: chatBooleanBinding(\.isPinned))
                }
                settingsDivider
                settingsToggle("聊天密码", icon: "lock", isOn: passwordBinding)
                settingsDivider
                settingsToggle("消息回执", icon: "checkmark.bubble", isOn: $isReadReceiptEnabled)
                    .onChange(of: isReadReceiptEnabled) { _, value in
                        ConversationPreferences.setReadReceiptsEnabled(value, for: chat.chatId)
                    }
            }
            Text("开启后，对方可看到你已阅读其消息。")
                .font(.caption)
                .foregroundStyle(DoveTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
    }

    private func settingsToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                ChatSettingsRowIcon(icon: icon)
                AppLocalizedText(title)
                    .foregroundStyle(DoveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.body)
        .toggleStyle(.switch)
        .tint(DoveTheme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
    }

    private var settingsDivider: some View {
        Divider().padding(.leading, 60)
    }

    private var clearHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(role: .destructive) { isShowingClearConfirmation = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.body)
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    Text("清空聊天记录")
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(DoveTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("仅清理这台设备上的记录，不会撤回对方消息。")
                .font(.caption)
                .foregroundStyle(DoveTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
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
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(DoveTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
            ChatSettingsRowIcon(icon: icon)
            AppLocalizedText(title)
                .font(.body)
                .foregroundStyle(DoveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 60)
        .contentShape(Rectangle())
    }
}

private struct ChatSettingsRowIcon: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(DoveTheme.accent)
            .frame(width: 32, height: 32)
            .background(DoveTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

#if DEBUG
@MainActor
private struct ChatSettingsDesignPreview: View {
    private let container: ModelContainer
    private let chat: Chat

    init(name: String, isGroup: Bool = false) {
        let schema = Schema([User.self, Chat.self, Message.self])
        container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        chat = Chat(chatId: "chat-settings-design-fixture", name: name, type: isGroup ? "group" : "private")
        container.mainContext.insert(chat)
    }

    var body: some View {
        NavigationStack {
            ChatSettingsView(chat: chat, onBackgroundChanged: {})
        }
        .modelContainer(container)
        // Preview controls must never write to real preferences or Keychain.
        .allowsHitTesting(false)
    }
}

#Preview("Chat details · Light") {
    ChatSettingsDesignPreview(name: "林小满")
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .preferredColorScheme(.light)
}

#Preview("Chat details · Dark group") {
    ChatSettingsDesignPreview(name: "设计小组", isGroup: true)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .preferredColorScheme(.dark)
}

#Preview("Chat details · English accessibility") {
    ChatSettingsDesignPreview(name: "Alexandria · Design and Engineering")
        .environment(\.locale, Locale(identifier: "en"))
        .environment(\.dynamicTypeSize, .accessibility2)
        .preferredColorScheme(.light)
}
#endif

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
                    AppLocalizedText(style.title).foregroundStyle(DoveTheme.ink)
                    Spacer()
                    if selectedStyle == style { Image(systemName: "checkmark.circle.fill").foregroundStyle(DoveTheme.green) }
                }
            }
        }
        .navigationTitle("聊天背景")
    }
}

// MARK: - Chat search projection

/// Ephemeral presentation of existing messages, not a second persistent cache.
/// Local call metadata must never be searched/rendered as serialized JSON.
enum ChatMessageSearchProjection {
    struct Row: Identifiable {
        let message: Message
        let text: String
        var id: String { message.messageId }
    }

    static func rows(messages: [Message], query: String, language: AppLanguage) -> [Row] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        return messages.compactMap { message in
            guard let text = displayText(message, language: language),
                  text.localizedCaseInsensitiveContains(keyword) else { return nil }
            return Row(message: message, text: text)
        }.sorted { left, right in
            if left.message.createdAt != right.message.createdAt { return left.message.createdAt > right.message.createdAt }
            return left.id < right.id
        }
    }

    static func displayText(_ message: Message, language: AppLanguage) -> String? {
        guard message.type == "call" else { return message.content }
        guard let entry = CallHistoryEntry.decode(message) else { return nil }
        let title = AppLocalization.string(entry.titleKey, language: language)
        return entry.connectedAt == nil ? title : title + " · " + entry.formattedDuration
    }
}

// MARK: - End chat search projection

private struct ChatMessageSearchView: View {
    @Environment(\.locale) private var locale
    let chat: Chat
    @State private var query = ""

    var body: some View {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let language: AppLanguage = locale.identifier.hasPrefix("zh") ? .simplifiedChinese : .english
        let rows = ChatMessageSearchProjection.rows(messages: chat.messages, query: keyword, language: language)
        return List {
            if keyword.isEmpty {
                ContentUnavailableView("搜索聊天记录", systemImage: "magnifyingglass", description: Text("输入关键词后查找本机消息。"))
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(rows) { row in
                    let message = row.message
                    VStack(alignment: .leading, spacing: 5) {
                        Text(message.isOutgoing ? AppLocalization.text("我") : chat.name).font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: row.text).foregroundStyle(DoveTheme.ink).lineLimit(2)
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
                if let errorMessage { AppLocalizedText(errorMessage).foregroundStyle(.red) }
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
            if let errorMessage { AppLocalizedText(errorMessage).font(.footnote).foregroundStyle(.red) }
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
