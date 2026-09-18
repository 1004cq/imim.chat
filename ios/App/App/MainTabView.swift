import SwiftData
import SwiftUI

struct MainTabView: View {
    @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]
    @ObservedObject private var notificationRouter = NotificationRouter.shared
    @State private var selectedTab = 0
    @State private var messageNavigationPath = NavigationPath()
    @State private var isCustomTabBarHidden = false
    @AppStorage("notification_private_chats") private var privateChatsNotificationsEnabled = true
    @State private var inAppMessageNotification: InAppMessageNotification?

    @State private var activeCallSession: VideoCallSession?

    var body: some View {
        ZStack {
            // A page-style TabView does not create UIKit's bottom tab bar.
            // The only navigation surface is DoveBottomTabBar below.
            TabView(selection: $selectedTab) {
                // 1. 消息 Tab (全原生)
                NavigationStack(path: $messageNavigationPath) {
                    ChatsView()
                }
                .tabItem {
                    Label("消息", systemImage: selectedTab == 0 ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                }
                .tag(0)

                // 2. 通讯录 Tab (全原生)
                NavigationStack {
                    ContactsView()
                }
                .tabItem {
                    Label("通讯录", systemImage: selectedTab == 1 ? "person.2.fill" : "person.2")
                }
                .tag(1)

                // 3. 发现 Tab (全原生)
                NavigationStack {
                    DiscoveryView()
                }
                .tabItem {
                    Label("发现", systemImage: selectedTab == 2 ? "safari.fill" : "safari")
                }
                .tag(2)

                // 4. 设置 Tab (全原生)
                NavigationStack {
                    SettingsView()
                }
                .tabItem {
                    Label("设置", systemImage: selectedTab == 3 ? "gearshape.fill" : "gearshape")
                }
                .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isCustomTabBarHidden {
                    DoveBottomTabBar(
                        selectedTab: $selectedTab,
                        totalUnread: chats.reduce(0) { $0 + $1.unreadCount }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onPreferenceChange(CQIMTabBarHiddenPreferenceKey.self) { hidden in
                withAnimation(.easeInOut(duration: 0.18)) {
                    isCustomTabBarHidden = hidden
                }
            }

            if let notification = inAppMessageNotification {
                NotificationBannerView(
                    title: notification.title,
                    bodyText: notification.bodyText,
                    avatarURL: notification.avatarURL
                ) {
                    inAppMessageNotification = nil
                    openChat(chatId: notification.chatId)
                }
                .id(notification.id)
                .zIndex(10)
            }
        }
        .fullScreenCover(item: $activeCallSession) { session in
            VideoCallView(session: session)
        }
        .onAppear {
            if let chatId = notificationRouter.targetConversationId {
                openChat(chatId: chatId)
            }
            if let descriptor = CallManager.shared.takePendingAcceptedCall() {
                presentIncomingCall(descriptor.userInfo, autoAccept: true)
            }
        }
        .onChange(of: notificationRouter.targetConversationId) { _, chatId in
            guard let chatId else { return }
            openChat(chatId: chatId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimCallInviteDidReceive)) { notification in
            guard let descriptor = IncomingCallDescriptor(payload: notification.userInfo ?? [:], requireCallId: false) else { return }
            CallManager.shared.reportIncoming(descriptor) { error in
                if let error { print("[CallKit] foreground report failed: \(error.localizedDescription)") }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CQIMShowBanner"))) { notification in
            guard privateChatsNotificationsEnabled,
                  let userInfo = notification.userInfo,
                  let chatId = userInfo["chatId"] as? String,
                  !chatId.isEmpty,
                  NotificationRouter.shared.activeConversationId != chatId else {
                return
            }

            let fallbackTitle = chats.first(where: { $0.chatId == chatId })?.name ?? "新消息"
            inAppMessageNotification = InAppMessageNotification(
                chatId: chatId,
                title: (userInfo["title"] as? String)?.trimmedNonEmpty ?? fallbackTitle,
                bodyText: (userInfo["body"] as? String)?.trimmedNonEmpty ?? "你收到一条新消息",
                avatarURL: (userInfo["avatarURL"] as? String)?.trimmedNonEmpty
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimCallAnsweredFromSystem)) { notification in
            presentIncomingCall(notification.userInfo, autoAccept: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimCallEnded)) { notification in
            let id = notification.userInfo?["uuid"] as? String
            let peerId = notification.userInfo?["from"] as? String
            if activeCallSession?.id == id || activeCallSession?.peerId == peerId {
                activeCallSession = nil
            }
        }
    }

    private func openChat(chatId: String) {
        guard !chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        selectedTab = 0

        // The tab must be active before its NavigationStack receives the chat value.
        DispatchQueue.main.async {
            navigateToChatIfAvailable(chatId)
        }
        // A cold launch may receive the notification before the first chat refresh finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            navigateToChatIfAvailable(chatId)
        }
    }

    private func navigateToChatIfAvailable(_ chatId: String) {
        guard let chat = chats.first(where: { $0.chatId == chatId }) else { return }
        messageNavigationPath = NavigationPath()
        messageNavigationPath.append(chat)
    }

    private func presentIncomingCall(_ userInfo: [AnyHashable: Any]?, autoAccept: Bool) {
        guard let from = userInfo?["from"] as? String,
              !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let roomId = userInfo?["roomId"] as? String ?? "room-\(from)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let rawType = userInfo?["callType"] as? String ?? "audio"
        let callType = VideoCallType(rawValue: rawType) ?? .audio
        let callerName = userInfo?["callerName"] as? String ?? "来电"
        let callerAvatar = userInfo?["callerAvatar"] as? String
        var session = VideoCallSession.incoming(
            id: userInfo?["uuid"] as? String ?? "call-\(Date().timeIntervalSince1970)",
            callId: userInfo?["callId"] as? String,
            peerId: from,
            peerName: callerName,
            peerAvatar: callerAvatar,
            roomId: roomId,
            callType: callType
        )
        if autoAccept {
            session.status = .connecting
            SocketManager.shared.sendCallAccept(to: from)
        }
        activeCallSession = session
    }
}

private struct InAppMessageNotification: Identifiable {
    let id = UUID()
    let chatId: String
    let title: String
    let bodyText: String
    let avatarURL: String?
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CQIMTabBarHiddenPreferenceKey: PreferenceKey {
    static var defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct DoveBottomTabBar: View {
    @Binding var selectedTab: Int
    let totalUnread: Int
    @State private var dragOffset: CGFloat = 0

    private let tabs: [(title: String, icon: String, selectedIcon: String)] = [
        ("消息", "bubble.left.and.bubble.right", "bubble.left.and.bubble.right.fill"),
        ("通讯录", "person.2", "person.2.fill"),
        ("发现", "safari", "safari.fill"),
        ("设置", "gearshape", "gearshape.fill")
    ]

    var body: some View {
        decoratedTabBar
    }

    private var decoratedTabBar: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    tabBarContent
                }
            } else {
                tabBarContent
            }
        }
            .padding(6)
            .background {
                tabBarSurface
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }

    private var tabBarContent: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let tabWidth = max(0, (proxy.size.width - spacing * CGFloat(tabs.count - 1)) / CGFloat(tabs.count))
            let tabStride = tabWidth + spacing
            let selectedOffset = CGFloat(selectedTab) * tabStride
            let draggedOffset = min(
                max(0, selectedOffset + dragOffset),
                tabStride * CGFloat(tabs.count - 1)
            )

            ZStack(alignment: .leading) {
                selectedTabSurface
                    .frame(width: tabWidth, height: 58)
                    .offset(x: draggedOffset)
                    .animation(dragOffset == 0 ? .spring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.1) : nil, value: selectedTab)

                HStack(spacing: spacing) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                selectedTab = index
                            }
                        } label: {
                            VStack(spacing: 4) {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: selectedTab == index ? tab.selectedIcon : tab.icon)
                                        .font(.system(size: 20, weight: selectedTab == index ? .semibold : .regular))
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(selectedTab == index ? DoveTheme.green : Color.secondary.opacity(0.68))
                                        .scaleEffect(selectedTab == index ? 1.08 : 1)
                                        .offset(y: selectedTab == index ? -1 : 0)

                                    if index == 0 {
                                        DoveUnreadBadge(count: totalUnread)
                                            .offset(x: 15, y: -8)
                                    }
                                }
                                .frame(height: 24)

                                Text(tab.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(selectedTab == index ? DoveTheme.green : Color.secondary.opacity(0.55))
                                    .opacity(selectedTab == index ? 1 : 0.62)
                            }
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        let target = Int(((selectedOffset + value.translation.width) / tabStride).rounded())
                        let nextTab = min(max(target, 0), tabs.count - 1)
                        dragOffset = 0
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.1)) {
                            selectedTab = nextTab
                        }
                    }
            )
        }
        .frame(height: 58)
    }

    @ViewBuilder
    private var tabBarSurface: some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(0.38), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        } else {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(0.24), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        }
    }

    @ViewBuilder
    private var selectedTabSurface: some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(
                    .regular.tint(DoveTheme.green.opacity(0.34)).interactive(),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(0.48), lineWidth: 0.9)
                }
                .shadow(color: DoveTheme.green.opacity(0.14), radius: 11, y: 4)
        } else {
            Capsule(style: .continuous)
                .fill(DoveTheme.green.opacity(0.13))
                .background(.thinMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(0.25), lineWidth: 0.8)
                }
        }
    }
}
