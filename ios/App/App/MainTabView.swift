import SwiftData
import SwiftUI
import UIKit

struct MainTabView: View {
    @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]
    @ObservedObject private var notificationRouter = NotificationRouter.shared
    @State private var selectedTab = 0
    @State private var messageNavigationPath = NavigationPath()
    @State private var isCustomTabBarHidden = false
    @State private var isKeyboardVisible = false
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
                if !isCustomTabBarHidden && !isKeyboardVisible {
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
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    // SwiftUI resets this even when the gesture is cancelled or the bar disappears.
    @GestureState private var dragLocation: CGFloat?

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
        tabBarShell
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .sensoryFeedback(.selection, trigger: selectedTab)
    }

    private var tabBarShell: some View {
        tabBarContent
            .padding(6)
            .background { tabBarSurface }
    }

    private var tabBarContent: some View {
        GeometryReader { proxy in
            let layout = DoveTabBarLayout(
                width: proxy.size.width,
                count: tabs.count,
                isRightToLeft: layoutDirection == .rightToLeft
            )
            let lensCenter = dragLocation.map { layout.clampedCenter($0) }
                ?? layout.center(for: selectedTab)

            ZStack(alignment: .leading) {
                // Only the lens participates in glass rendering. Labels and
                // badges must stay outside its container, above the backdrop.
                selectionBackdrop
                    .frame(width: layout.selectionWidth, height: 50)
                    .scaleEffect(dragLocation != nil && !reduceMotion ? 1.04 : 1)
                    .position(x: lensCenter, y: 28)
                    .animation(dragLocation == nil ? selectionAnimation : nil, value: selectedTab)
                    .animation(selectionAnimation, value: dragLocation == nil)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                HStack(spacing: layout.spacing) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        Button {
                            withAnimation(selectionAnimation) {
                                selectedTab = index
                            }
                        } label: {
                            VStack(spacing: 4) {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: selectedTab == index ? tab.selectedIcon : tab.icon)
                                        .font(.system(size: 21, weight: selectedTab == index ? .bold : .semibold))
                                        .symbolRenderingMode(.monochrome)
                                        .foregroundStyle(selectedTab == index ? selectedForeground : unselectedForeground)

                                    if index == 0 {
                                        DoveUnreadBadge(count: totalUnread)
                                            .offset(x: 15, y: -8)
                                    }
                                }
                                .frame(height: 24)

                                AppLocalizedText(tab.title)
                                    .font(.system(size: 11, weight: selectedTab == index ? .bold : .semibold))
                                    .foregroundStyle(selectedTab == index ? selectedForeground : unselectedForeground)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bottom-tab-\(index)")
                        .accessibilityLabel(LocalizedStringKey(tab.title))
                        .accessibilityValue(selectedTab == index ? "已选择" : "")
                        .accessibilityAddTraits(selectedTab == index ? .isSelected : [])
                    }
                }
            }
            .contentShape(Rectangle())
            // A recognized scrub wins over the original button's tap and the
            // page-style TabView pan, so release cannot jump back to the start tab.
            .highPriorityGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .local)
                    .updating($dragLocation) { value, location, transaction in
                        transaction.disablesAnimations = true
                        location = value.location.x
                    }
                    .onChanged { value in
                        let nextTab = layout.tab(at: value.location.x)
                        guard selectedTab != nextTab else { return }
                        // Only switch at cell boundaries, not on every pixel.
                        // The glass follows absolute touch position independently.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            selectedTab = nextTab
                        }
                    }
                    .onEnded { value in
                        withAnimation(selectionAnimation) {
                            selectedTab = layout.tab(at: value.location.x)
                        }
                    }
            )
        }
        .frame(height: 56)
    }

    private var unselectedForeground: Color {
        Color(uiColor: .label).opacity(colorScheme == .dark ? 0.84 : 0.72)
    }

    private var selectedForeground: Color {
        Color(uiColor: .label)
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.84, blendDuration: 0.08)
    }

    @ViewBuilder
    private var tabBarSurface: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(DoveTheme.cardSurface.opacity(0.96))
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(DoveTheme.ink.opacity(0.16), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        } else {
            // A material shell avoids overlapping two refractive glass surfaces.
            // The moving selection lens below is the sole Liquid Glass layer.
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(DoveTheme.ink.opacity(0.14), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        }
    }

    @ViewBuilder
    private var selectionBackdrop: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: 0) {
                selectedTabSurface
            }
        } else {
            selectedTabSurface
        }
    }

    @ViewBuilder
    private var selectedTabSurface: some View {
        if reduceTransparency {
            Capsule(style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .overlay { selectionEdge }
        } else if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.clear.interactive(), in: .capsule)
                .overlay { selectionEdge }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 5, y: 2)
        } else {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay { selectionEdge }
                .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        }
    }

    private var selectionEdge: some View {
        Capsule(style: .continuous)
            .strokeBorder(Color(uiColor: .label).opacity(colorScheme == .dark ? 0.24 : 0.14), lineWidth: 0.7)
    }
}

/// Coordinates are local to the bar's content, excluding its outer padding.
/// Keeping them independent of selectedTab prevents feedback as pages switch.
private struct DoveTabBarLayout {
    let width: CGFloat
    let count: Int
    var isRightToLeft = false
    let spacing: CGFloat = 2

    var tabWidth: CGFloat {
        guard width.isFinite, count > 0 else { return 0 }
        return max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    var stride: CGFloat { tabWidth + spacing }

    var selectionWidth: CGFloat { min(tabWidth, min(72, max(58, tabWidth - 12))) }

    func center(for tab: Int) -> CGFloat {
        guard count > 0, tabWidth > 0 else { return 0 }
        let logicalIndex = min(max(tab, 0), count - 1)
        let visualIndex = isRightToLeft ? count - 1 - logicalIndex : logicalIndex
        return tabWidth / 2 + CGFloat(visualIndex) * stride
    }

    func clampedCenter(_ x: CGFloat) -> CGFloat {
        guard count > 0, tabWidth > 0, x.isFinite else { return center(for: 0) }
        return min(max(x, tabWidth / 2), tabWidth / 2 + CGFloat(count - 1) * stride)
    }

    func tab(at x: CGFloat) -> Int {
        guard count > 0, tabWidth > 0, x.isFinite else { return 0 }
        let visualIndex = Int(((clampedCenter(x) - tabWidth / 2) / stride).rounded())
        let boundedIndex = min(max(visualIndex, 0), count - 1)
        return isRightToLeft ? count - 1 - boundedIndex : boundedIndex
    }
}

private struct DoveBottomTabBarPreview: View {
    @State private var selection = 0
    private let titles = ["消息", "通讯录", "发现", "设置"]

    var body: some View {
        VStack {
            Text("当前页面：\(titles[selection])")
                .font(.headline)
            Spacer()
            DoveBottomTabBar(selectedTab: $selection, totalUnread: 23)
        }
        .padding(.top, 32)
        .background(Color(uiColor: .systemBackground))
    }
}

#Preview("透明导航 · 拖动切换") {
    DoveBottomTabBarPreview()
}

#Preview("透明导航 · 深色") {
    DoveBottomTabBarPreview()
        .preferredColorScheme(.dark)
}

#Preview("透明导航 · 从右往左") {
    DoveBottomTabBarPreview()
        .environment(\.layoutDirection, .rightToLeft)
}
