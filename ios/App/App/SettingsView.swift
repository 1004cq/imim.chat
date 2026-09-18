import SwiftData
import SwiftUI
import UserNotifications
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var pushManager: PushNotificationManager
    @AppStorage("isDarkMode") private var isDarkMode = false
    @Query private var chats: [Chat]

    @State private var isShowingQRCode = false

    private var currentUser: CurrentUser? {
        authSession.currentUser
    }

    private var displayName: String {
        currentUser?.nickname.isEmpty == false ? currentUser!.nickname : (currentUser?.account ?? "未登录")
    }

    private var fullAccountText: String {
        let id = currentUser?.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !id.isEmpty { return id }
        let account = currentUser?.account.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !account.isEmpty, account != "0" { return account }
        return UserDefaults.standard.string(forKey: "current_user_id") ?? "未绑定账号"
    }

    private var accountText: String {
        let account = currentUser?.account.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !account.isEmpty, account.count <= 16, account != "0" { return "@\(account)" }
        let id = fullAccountText
        return id.count > 6 ? "ID · \(id.suffix(6))" : id
    }

    var body: some View {
        ZStack {
            DoveTheme.paper.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    profileHeader
                    settingsGroups
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingQRCode) {
            NavigationStack {
                QRCodeCardView(
                    title: displayName,
                    account: fullAccountText,
                    avatar: currentUser?.avatar
                )
            }
        }
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("设置")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(DoveTheme.ink)

            HStack(spacing: 18) {
                NavigationLink {
                    ProfileView()
                } label: {
                    DoveAvatar(
                        name: displayName,
                        url: currentUser?.avatar,
                        size: 82
                    )
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    Text(displayName)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(DoveTheme.ink)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("账号：")
                        Text(accountText)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    isShowingQRCode = true
                } label: {
                    Image(systemName: "qrcode")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }

            HStack {
                Spacer()
                Label("E2EE", systemImage: "shield.checkered")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DoveTheme.green)
            }
        }
    }

    private var settingsGroups: some View {
        VStack(spacing: 22) {
            SettingsCard {
                NavigationLink {
                    AccountSecurityPanel(account: fullAccountText)
                } label: {
                    SettingsRowContent(
                        title: "账号与安全",
                        subtitle: "密钥管理、安全号码、设备",
                        systemImage: "shield",
                        tint: DoveTheme.green
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                SettingsRow(
                    title: "我的二维码",
                    systemImage: "qrcode",
                    tint: Color(red: 0.86, green: 0.65, blue: 0.20)
                ) {
                    isShowingQRCode = true
                }
            }

            SettingsCard {
                NavigationLink {
                    SavedChatsPanel()
                } label: {
                    SettingsRowContent(title: "收藏", systemImage: "bookmark", tint: .orange)
                }
                .buttonStyle(.plain)
                SettingsDivider()
                NavigationLink {
                    GeneralSettingsPanel()
                } label: {
                    SettingsRowContent(title: "通用设置", systemImage: "gearshape", tint: .gray)
                }
                .buttonStyle(.plain)
                SettingsDivider()
                NavigationLink {
                    NotificationSettingsPanel()
                        .environmentObject(pushManager)
                } label: {
                    SettingsRowContent(
                        title: "消息通知",
                        subtitle: pushManager.isSystemDeliveryReady ? "已开启" : "未开启",
                        systemImage: "bell",
                        tint: .red
                    )
                }
                .buttonStyle(.plain)
                SettingsDivider()
                NavigationLink {
                    AppearanceSettingsPanel()
                } label: {
                    SettingsRowContent(title: "外观", subtitle: isDarkMode ? "深色" : "浅色", systemImage: "paintpalette", tint: .purple)
                }
                .buttonStyle(.plain)
            }

            SettingsCard {
                NavigationLink {
                    StorageSettingsPanel()
                } label: {
                    SettingsRowContent(title: "存储空间", subtitle: cacheSizeText, systemImage: "externaldrive", tint: DoveTheme.green)
                }
                .buttonStyle(.plain)
                SettingsDivider()
                NavigationLink {
                    LanguageSettingsPanel()
                } label: {
                    SettingsRowContent(title: "语言", subtitle: "简体中文", systemImage: "globe", tint: .teal)
                }
                .buttonStyle(.plain)
                SettingsDivider()
                NavigationLink {
                    PrivacySettingsPanel()
                } label: {
                    SettingsRowContent(title: "隐私", systemImage: "lock", tint: .pink)
                }
                .buttonStyle(.plain)
            }

            SettingsCard {
                NavigationLink {
                    HelpAndFeedbackPanel()
                } label: {
                    SettingsRowContent(title: "帮助与反馈", systemImage: "questionmark.circle", tint: DoveTheme.green)
                }
                .buttonStyle(.plain)
                SettingsDivider()
                NavigationLink {
                    AboutSettingsPanel()
                } label: {
                    SettingsRowContent(title: "关于 IMIM Chat", subtitle: appVersion, systemImage: "info.circle", tint: DoveTheme.green)
                }
                .buttonStyle(.plain)
            }

            Button(role: .destructive) {
                authSession.signOut()
            } label: {
                Text("退出登录")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }

    private var cacheSizeText: String {
        let messageCount = chats.reduce(0) { $0 + $1.messages.count }
        return messageCount == 0 ? "0 MB" : "\(max(1, messageCount / 8)) MB"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(DoveTheme.cardSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 18, y: 8)
    }
}

private struct SettingsRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRowContent(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsRowContent: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: Circle())

            Text(title)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(DoveTheme.ink)

            Spacer()

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.45))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 17)
        .contentShape(Rectangle())
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 74)
    }
}

private struct GeneralSettingsPanel: View {
    @AppStorage("chatTextScale") private var chatTextScale = 1.0
    @AppStorage("autoDownloadMedia") private var autoDownloadMedia = true
    @AppStorage("keepOriginalMedia") private var keepOriginalMedia = false

    var body: some View {
        Form {
            Section {
                Picker("消息文字大小", selection: $chatTextScale) {
                    Text("小").tag(0.88)
                    Text("标准").tag(1.0)
                    Text("大").tag(1.14)
                    Text("特大").tag(1.28)
                }
                Text("该设置会立即应用到本机聊天气泡。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("聊天显示")
            }

            Section {
                Toggle("自动下载媒体", isOn: $autoDownloadMedia)
                Toggle("保留原始媒体", isOn: $keepOriginalMedia)
            } header: {
                Text("媒体")
            }
        }
        .navigationTitle("通用设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SavedChatsPanel: View {
    @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]

    private var pinnedChats: [Chat] {
        chats.filter(\.isPinned)
    }

    var body: some View {
        Group {
            if pinnedChats.isEmpty {
                ContentUnavailableView(
                    "暂无收藏内容",
                    systemImage: "bookmark",
                    description: Text("在会话列表向右滑动并选择“置顶”，即可在这里快速找到该会话。")
                )
            } else {
                List(pinnedChats) { chat in
                    NavigationLink {
                        ChatDetailView(chat: chat)
                    } label: {
                        HStack(spacing: 12) {
                            DoveAvatar(name: chat.name, url: chat.avatar, size: 42, isGroup: chat.type == "group")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chat.name)
                                    .foregroundStyle(DoveTheme.ink)
                                Text(chat.lastMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .background(DoveTheme.paper)
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StorageSettingsPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var chats: [Chat]
    @State private var isShowingClearConfirmation = false

    private var messageCount: Int {
        chats.reduce(0) { $0 + $1.messages.count }
    }

    private var cacheSizeText: String {
        messageCount == 0 ? "0 MB" : "约 \(max(1, messageCount / 8)) MB"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("会话") { Text("\(chats.count)") }
                LabeledContent("消息") { Text("\(messageCount)") }
                LabeledContent("估算占用") { Text(cacheSizeText) }
            } header: {
                Text("本机缓存")
            } footer: {
                Text("缓存仅存储在这台设备；清理后会在下次打开会话时从服务器重新同步。")
            }

            Section {
                Button("清除本地聊天缓存", role: .destructive) {
                    isShowingClearConfirmation = true
                }
            }
        }
        .navigationTitle("存储空间")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清除本地聊天缓存？", isPresented: $isShowingClearConfirmation, titleVisibility: .visible) {
            Button("清除", role: .destructive, action: clearChatCache)
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除本机 SwiftData 中的会话和消息，不影响服务器数据。")
        }
    }

    private func clearChatCache() {
        for chat in chats {
            modelContext.delete(chat)
        }
        try? modelContext.save()
    }
}

private struct LanguageSettingsPanel: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Text("当前语言")
                    Spacer()
                    Text("简体中文")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("应用语言")
            } footer: {
                Text("当前原生客户端已完整适配简体中文；系统语言变化不会破坏聊天和加密内容的显示。")
            }
        }
        .navigationTitle("语言")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacySettingsPanel: View {
    @AppStorage("privacy_biometric_lock") private var biometricLockEnabled = false
    @AppStorage("privacy_hide_message_previews") private var hideMessagePreviews = false
    @AppStorage("privacy_link_previews") private var linkPreviewsEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("使用 Face ID 解锁", isOn: $biometricLockEnabled)
                Toggle("隐藏通知消息预览", isOn: $hideMessagePreviews)
            } header: {
                Text("本机保护")
            } footer: {
                Text("通知内容是否在锁屏显示还会受 iOS 系统通知设置控制。")
            }

            Section {
                Toggle("显示链接预览", isOn: $linkPreviewsEnabled)
            } header: {
                Text("聊天")
            }

            Section {
                Label("私聊默认开启 Signal Protocol 端到端加密", systemImage: "lock.shield")
                    .foregroundStyle(DoveTheme.green)
            } header: {
                Text("端到端加密")
            }
        }
        .navigationTitle("隐私")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AccountSecurityPanel: View {
    let account: String
    @State private var diagnostics: E2EEDiagnostics?

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(DoveTheme.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Signal Protocol 已启用")
                            .font(.headline)
                        Text("密钥保存在本机钥匙串中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }

            Section {
                NavigationLink { KeyManagementPanel(diagnostics: diagnostics) } label: {
                    securityRow("密钥管理", detail: diagnostics.map { "\($0.availablePreKeyCount) 个 PreKeys" } ?? "正在读取", icon: "key.fill", tint: .green)
                }
                NavigationLink { SafetyNumberPanel(diagnostics: diagnostics) } label: {
                    securityRow("安全号码", detail: "验证本机身份指纹", icon: "number.square.fill", tint: .blue)
                }
                NavigationLink { DeviceManagementPanel(account: account) } label: {
                    securityRow("设备管理", detail: "当前设备", icon: "iphone", tint: .indigo)
                }
                NavigationLink { LoginActivityPanel(account: account) } label: {
                    securityRow("登录记录", detail: "本机登录会话", icon: "clock.arrow.circlepath", tint: .orange)
                }
            } header: {
                Text("安全")
            }
        }
        .navigationTitle("账号与安全")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await E2EEManager.shared.bootstrapForCurrentUser()
            diagnostics = E2EEManager.shared.diagnosticsForCurrentUser()
        }
    }

    private func securityRow(_ title: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .foregroundStyle(DoveTheme.ink)
            Spacer()
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct KeyManagementPanel: View {
    let diagnostics: E2EEDiagnostics?

    var body: some View {
        List {
            Section {
                LabeledContent("Registration ID") { Text(diagnostics.map { "\($0.registrationId)" } ?? "未初始化") }
                LabeledContent("可用 PreKeys") { Text(diagnostics.map { "\($0.availablePreKeyCount)" } ?? "-") }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Identity Key 指纹")
                    Text(diagnostics?.identityFingerprint ?? "未初始化")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("本机密钥状态")
            } footer: {
                Text("此页面仅显示公钥指纹和数量，不会显示或导出任何私钥。")
            }
        }
        .navigationTitle("密钥管理")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SafetyNumberPanel: View {
    let diagnostics: E2EEDiagnostics?

    var body: some View {
        List {
            Section {
                Text(diagnostics?.identityFingerprint ?? "尚未初始化加密身份")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button("复制安全号码") {
                    UIPasteboard.general.string = diagnostics?.identityFingerprint
                }
                .disabled(diagnostics == nil)
            } header: {
                Text("本机安全号码")
            } footer: {
                Text("与联系人面对面或通过可信通道比对安全号码，可确认通信身份没有被替换。")
            }
        }
        .navigationTitle("安全号码")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DeviceManagementPanel: View {
    let account: String

    private var deviceName: String { UIDevice.current.name }
    private var deviceDetail: String { "iOS \(UIDevice.current.systemVersion) · 当前设备" }

    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(deviceName)
                        Text(deviceDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone")
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(DoveTheme.green, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            } header: {
                Text("当前设备")
            }

            Section {
                Text("多设备登录需要服务端会话管理接口。当前客户端不会伪造其他设备或远程登出状态。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("多设备")
            }
        }
        .navigationTitle("设备管理")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LoginActivityPanel: View {
    let account: String

    var body: some View {
        List {
            Section {
                LabeledContent("账号") { Text(account) }
                LabeledContent("设备") { Text(UIDevice.current.name) }
                LabeledContent("会话保护") { Text("钥匙串") }
            } header: {
                Text("当前会话")
            } footer: {
                Text("服务器登录历史接口接入后，其他设备和登录地点会显示在这里。")
            }
        }
        .navigationTitle("登录记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HelpAndFeedbackPanel: View {
    var body: some View {
        List {
            Section {
                Label("端到端加密", systemImage: "lock.shield")
                Label("通知与离线推送", systemImage: "bell.badge")
                Label("音视频通话", systemImage: "video")
            } header: {
                Text("帮助")
            }

            Section {
                Link(destination: URL(string: "mailto:support@imim.chat?subject=IMIM%20Chat%20Feedback")!) {
                    Label("发送邮件反馈", systemImage: "envelope")
                }
                Button {
                    UIPasteboard.general.string = "IMIM Chat iOS \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")"
                } label: {
                    Label("复制版本诊断信息", systemImage: "doc.on.doc")
                }
            } header: {
                Text("反馈")
            }
        }
        .navigationTitle("帮助与反馈")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutSettingsPanel: View {
    private var version: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(shortVersion) (\(build))"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("版本") { Text(version) }
                LabeledContent("Bundle ID") { Text(Bundle.main.bundleIdentifier ?? "-") }
                LabeledContent("加密") { Text("Signal Protocol") }
            }
        }
        .navigationTitle("关于 IMIM Chat")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppearanceSettingsPanel: View {
    @AppStorage("isDarkMode") private var isDarkMode = false

    var body: some View {
        Form {
            Section {
                Toggle("深色模式", isOn: $isDarkMode)
            } header: {
                Text("显示模式")
            }
        }
        .navigationTitle("外观")
    }
}

private struct NotificationSettingsPanel: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var pushManager: PushNotificationManager

    @AppStorage("notification_private_chats") private var privateChatsEnabled = true
    @AppStorage("notification_group_chats") private var groupChatsEnabled = true
    @AppStorage("notification_channels") private var channelsEnabled = true
    @AppStorage("notification_stories") private var storiesEnabled = true
    @AppStorage("notification_reactions") private var reactionsEnabled = true
    @AppStorage("notification_in_app_sound") private var inAppSoundEnabled = true
    @AppStorage("notification_in_app_vibration") private var inAppVibrationEnabled = true
    @AppStorage("notification_in_app_preview") private var inAppPreviewEnabled = true
    @AppStorage("notification_lock_screen_names") private var lockScreenNamesEnabled = true

    private var deliveryEnabled: Binding<Bool> {
        Binding(
            get: { pushManager.isDeliveryEnabled },
            set: { pushManager.setDeliveryEnabled($0) }
        )
    }

    var body: some View {
        ZStack {
            DoveTheme.paper.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(DoveTheme.ink)
                                .frame(width: 48, height: 48)
                                .background(.white.opacity(0.78), in: Circle())
                                .overlay(Circle().stroke(DoveTheme.warmGray.opacity(0.7), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text("通知")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(DoveTheme.ink)

                        Spacer()

                        Color.clear.frame(width: 48, height: 48)
                    }

                    notificationSection(title: "显示通知") {
                        NotificationToggleRow(title: "全部账号", isOn: deliveryEnabled)
                    }

                    if !pushManager.isDeliveryEnabled || pushManager.needsNotificationSettings {
                        Button {
                            pushManager.openNotificationSettings()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "gearshape")
                                Text("打开系统通知设置")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(DoveTheme.green)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 18)
                .background(DoveTheme.cardSurface.opacity(0.9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    notificationSection(title: "消息通知") {
                        NotificationToggleRow(title: "私聊", icon: "person.fill", tint: .blue, isOn: $privateChatsEnabled)
                        NotificationDivider()
                        NotificationToggleRow(title: "群聊", icon: "person.3.fill", tint: .green, isOn: $groupChatsEnabled)
                        NotificationDivider()
                        NotificationToggleRow(title: "频道", icon: "megaphone.fill", tint: .orange, isOn: $channelsEnabled)
                        NotificationDivider()
                        NotificationToggleRow(title: "动态", detail: "前 5 名", icon: "circle.dotted", tint: .indigo, isOn: $storiesEnabled)
                        NotificationDivider()
                        NotificationToggleRow(title: "回应", detail: "消息、动态", icon: "heart.fill", tint: .pink, isOn: $reactionsEnabled)
                    }

                    notificationSection(title: "应用内通知") {
                        NotificationToggleRow(title: "应用内提示音", isOn: $inAppSoundEnabled)
                        NotificationDivider()
                        NotificationToggleRow(title: "应用内振动", isOn: $inAppVibrationEnabled)
                        NotificationDivider()
                        NotificationToggleRow(title: "应用内消息预览", isOn: $inAppPreviewEnabled)
                    }

                    notificationSection(title: "隐私") {
                        NotificationToggleRow(title: "在锁定屏幕上的名称", isOn: $lockScreenNamesEnabled)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 36)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            pushManager.refreshAuthorizationStatus(registerIfAuthorized: false)
        }
    }

    @ViewBuilder
    private func notificationSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            VStack(spacing: 0, content: content)
                .padding(.horizontal, 18)
                .background(DoveTheme.cardSurface.opacity(0.9), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

private struct NotificationToggleRow: View {
    let title: String
    var detail: String? = nil
    var icon: String? = nil
    var tint: Color = DoveTheme.green
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DoveTheme.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(DoveTheme.green)
        }
        .padding(.vertical, 16)
    }
}

private struct NotificationDivider: View {
    var body: some View {
        Divider()
            .overlay(DoveTheme.warmGray.opacity(0.55))
            .padding(.leading, 50)
    }
}

private struct QRCodeCardView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let account: String
    let avatar: String?

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                DoveAvatar(name: title, url: avatar, size: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.bold())
                    Text(account)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Image(systemName: "qrcode")
                .font(.system(size: 190, weight: .regular))
                .foregroundStyle(DoveTheme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(DoveTheme.paper, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

            Text("扫一扫上面的二维码，加我为好友")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
        .navigationTitle("我的二维码")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }
}

private extension UNAuthorizationStatus {
    var displayName: String {
        switch self {
        case .notDetermined: "未决定"
        case .denied: "已拒绝"
        case .authorized: "已授权"
        case .provisional: "临时授权"
        case .ephemeral: "临时会话授权"
        @unknown default: "未知"
        }
    }
}
