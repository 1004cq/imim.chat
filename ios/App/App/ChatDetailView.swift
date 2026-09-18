import SwiftData
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Kingfisher

struct ChatDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let chat: Chat

    @StateObject private var viewModel = ChatDetailViewModel()
    @StateObject private var voiceRecorder = VoiceRecorderManager()
    @ObservedObject private var socket = SocketManager.shared
    @FocusState private var isInputFocused: Bool
    @State private var activeCallSession: VideoCallSession?
    @State private var callPresentationError: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var photoPickerFilter: PHPickerFilter = .any(of: [.images, .videos])
    @State private var isFileImporterPresented = false
    @State private var lastVisibleMessageId: String?
    @State private var didRestoreScrollPosition = false
    @State private var isShowingMediaPanel = false
    @State private var isShowingVanishDurationPicker = false
    @State private var composerInsertion: ComposerInsertion?
    @State private var isShowingChatSettings = false
    @State private var chatBackgroundStyle: ChatBackgroundStyle = .paper
    @State private var isConversationLocked = false
    @State private var unlockPasscode = ""
    @State private var unlockError: String?

    private let mediaAndCallEnabled = true

    private var messages: [Message] {
        viewModel.sortedMessages(for: chat)
    }

    var body: some View {
        ZStack {
            ConversationBackground(style: chatBackgroundStyle).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                encryptionBanner
                statusStrip
                messagesView
            }

            if voiceRecorder.isRecording {
                VoiceRecordingOverlay(
                    duration: voiceRecorder.recordingDuration,
                    waveform: voiceRecorder.liveWaveform,
                    isCancelling: voiceRecorder.isCancelling
                )
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputBar
        }
        .overlay {
            if isConversationLocked {
                ConversationUnlockOverlay(
                    name: chat.name,
                    passcode: $unlockPasscode,
                    errorMessage: unlockError,
                    unlock: unlockConversation
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .preference(key: CQIMTabBarHiddenPreferenceKey.self, value: true)
        .onAppear {
            chatBackgroundStyle = ConversationPreferences.backgroundStyle(for: chat.chatId)
            isConversationLocked = ConversationPreferences.hasPasscode(for: chat.chatId)
            NotificationRouter.shared.setActiveConversation(chat.chatId)
            PushNotificationManager.shared.updatePresence(.foreground, activeChatId: chat.chatId)
            viewModel.markAsRead(chat, modelContext: modelContext)
        }
        .onDisappear {
            if NotificationRouter.shared.activeConversationId == chat.chatId {
                NotificationRouter.shared.setActiveConversation(nil)
                PushNotificationManager.shared.updatePresence(.foreground)
            }
            ConversationScrollPositionStore.save(lastVisibleMessageId, for: chat.chatId)
        }
        .task {
            await viewModel.loadMessages(for: chat, modelContext: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimPrivateMessageDidReceive)) { notification in
            guard let message = notification.object as? Message,
                  message.chatId == chat.chatId else { return }
            viewModel.handleSocketMessage(
                message,
                isAck: notification.userInfo?["ack"] as? Bool == true,
                in: chat,
                modelContext: modelContext
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimSocketErrorDidReceive)) { notification in
            guard let message = notification.object as? String else { return }
            viewModel.errorMessage = message
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimChatPrivacyDidReceive)) { notification in
            guard let privacy = notification.object as? RemoteChatPrivacy,
                  privacy.chatId == chat.chatId else { return }
            chat.vanishMode = privacy.vanishMode
            chat.vanishSeconds = privacy.vanishSeconds
            chat.restrictForwarding = privacy.restrictForwarding
            try? modelContext.save()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimConversationAppearanceDidChange)) { notification in
            guard let changedChatId = notification.object as? String, changedChatId == chat.chatId else { return }
            chatBackgroundStyle = ConversationPreferences.backgroundStyle(for: chat.chatId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimBurnReadDidReceive)) { notification in
            guard let event = notification.object as? BurnReadEvent,
                  event.chatId == chat.chatId,
                  let message = chat.messages.first(where: { $0.messageId == event.messageId }) else { return }
            let readAt = event.readAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) } ?? Date()
            message.readAt = readAt
            message.burnReadAt = readAt
            message.burnAfterRead = event.burnAfterRead ?? message.burnAfterRead
            message.burnExpireAt = event.burnExpireAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
                ?? message.burnAfterRead.map { readAt.addingTimeInterval(TimeInterval($0)) }
            try? modelContext.save()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimBurnDeleteDidReceive)) { notification in
            guard let event = notification.object as? BurnDeleteEvent,
                  event.chatId == chat.chatId,
                  let message = chat.messages.first(where: { $0.messageId == event.messageId }) else { return }
            chat.messages.removeAll { $0.messageId == message.messageId }
            modelContext.delete(message)
            try? modelContext.save()
        }
        .fullScreenCover(item: $activeCallSession) { session in
            VideoCallView(session: session)
        }
        .navigationDestination(isPresented: $isShowingChatSettings) {
            ChatSettingsView(chat: chat) {
                chatBackgroundStyle = ConversationPreferences.backgroundStyle(for: chat.chatId)
            }
        }
        .alert("无法发起通话", isPresented: Binding(
            get: { callPresentationError != nil },
            set: { if !$0 { callPresentationError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(callPresentationError ?? "")
        }
        .confirmationDialog("消失模式", isPresented: $isShowingVanishDurationPicker, titleVisibility: .visible) {
            Button("5 秒") { setVanishMode(seconds: 5) }
            Button("10 秒") { setVanishMode(seconds: 10) }
            Button("24 小时") { setVanishMode(seconds: 86_400) }
            if chat.vanishMode {
                Button("关闭消失模式", role: .destructive) { setVanishMode(seconds: nil) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("新消息在已读后按所选时长自动删除。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HeaderIconButton(systemName: "chevron.left") {
                dismiss()
            }

            VStack(spacing: 2) {
                Text(chat.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DoveTheme.ink)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    PresenceDot(isOnline: socket.isConnected)
                    Text(chat.type == "group" ? "\(max(chat.memberIds.count, 4)) 位成员" : (socket.isConnected ? "实时连接" : "等待重连"))
                    if chat.vanishMode {
                        Text("消失模式")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DoveTheme.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(DoveTheme.green.opacity(0.10), in: Capsule())
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 2) {
                Button { startCall(.audio) } label: {
                    Image(systemName: "phone")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DoveTheme.green)

                Button { startCall(.video) } label: {
                    Image(systemName: "video")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DoveTheme.green)

                Menu {
                    Button { isShowingChatSettings = true } label: {
                        Label("聊天详情", systemImage: "info.circle")
                    }
                    Button { isShowingVanishDurationPicker = true } label: {
                        Label("消失模式", systemImage: "timer")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(DoveTheme.ink)
                        .frame(width: 34, height: 34)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .background(Color(uiColor: .systemBackground).opacity(0.94))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DoveTheme.warmGray.opacity(0.55))
                .frame(height: 0.5)
        }
    }

    private var encryptionBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .bold))
            Text("端到端加密")
                .font(.system(size: 10, weight: .semibold))
            Text("Signal Protocol")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(DoveTheme.green)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(DoveTheme.green.opacity(0.08))
    }

    private var messagesView: some View {
        // `messages` sorts the SwiftData relationship. Capture one snapshot for
        // this render pass: calling it again from every row previously repeated
        // the sort while an incoming message was being inserted.
        let messageItems = messages
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(messageItems.enumerated()), id: \.element.messageId) { index, message in
                        if shouldShowTimeGroup(message, previous: index > 0 ? messageItems[index - 1] : nil) {
                            Text(message.createdAt.chatTimeGroupText)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(DoveTheme.warmGray.opacity(0.62), in: Capsule())
                                .padding(.vertical, 4)
                        }

                        MessageBubble(
                            message: message,
                            peerName: chat.name,
                            peerAvatar: chat.avatar,
                            isForwardingRestricted: chat.restrictForwarding || message.forwardRestricted,
                            voiceRecorder: voiceRecorder,
                            onReply: {
                                viewModel.beginReply(to: message)
                                isInputFocused = true
                            },
                            onMention: {
                                composerInsertion = ComposerInsertion(text: "@\(chat.name) ")
                                isInputFocused = true
                            },
                            onRecall: {
                                Task {
                                    await viewModel.recall(message, in: chat, modelContext: modelContext)
                                }
                            },
                            onRetry: {
                                Task { await viewModel.recoverEncryptionSession(for: chat, modelContext: modelContext) }
                            }
                        )
                            .id(message.messageId)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: MessageViewportPreferenceKey.self,
                                        value: [message.messageId: geometry.frame(in: .named("chatMessages")).minY]
                                    )
                                }
                            }
                    }
                }
                .padding(.horizontal, 0)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
            .coordinateSpace(name: "chatMessages")
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                restoreScrollPositionIfNeeded(proxy: proxy, messageItems: messageItems)
            }
            .onChange(of: messageItems.last?.messageId) { _, _ in
                guard didRestoreScrollPosition, !viewModel.isLoadingMessages else { return }
                scheduleScrollToBottom(proxy: proxy, animated: true)
            }
            .onChange(of: viewModel.isLoadingMessages) { _, isLoading in
                guard !isLoading else { return }
                restoreScrollPositionIfNeeded(proxy: proxy, messageItems: messageItems)
            }
            .onPreferenceChange(MessageViewportPreferenceKey.self) { positions in
                guard let visible = positions
                    .filter({ $0.value >= 0 })
                    .min(by: { $0.value < $1.value })?
                    .key else { return }
                lastVisibleMessageId = visible
            }
        }
    }

    private func restoreScrollPositionIfNeeded(proxy: ScrollViewProxy, messageItems: [Message]) {
        guard !didRestoreScrollPosition, !messageItems.isEmpty else { return }
        didRestoreScrollPosition = true

        let savedMessageId = ConversationScrollPositionStore.load(for: chat.chatId)
        let targetMessageId = messageItems.contains(where: { $0.messageId == savedMessageId })
            ? savedMessageId
            : messageItems.last?.messageId

        guard let targetMessageId else { return }
        DispatchQueue.main.async {
            withAnimation(nil) {
                proxy.scrollTo(targetMessageId, anchor: savedMessageId == targetMessageId ? .top : .bottom)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if let replyingTo = viewModel.replyingTo {
                replyPreview(replyingTo)
            }

            ChatTextComposer(
                insertion: composerInsertion,
                isInputFocused: $isInputFocused,
                isShowingAttachmentPanel: Binding(
                    get: { viewModel.isShowingAttachmentPanel },
                    set: { viewModel.isShowingAttachmentPanel = $0 }
                ),
                isShowingMediaPanel: $isShowingMediaPanel,
                isRecording: voiceRecorder.isRecording,
                canStartVoiceInput: viewModel.canStartVoiceInput,
                onSend: { content in
                    Task {
                        await viewModel.sendMessage(content, in: chat, modelContext: modelContext)
                    }
                },
                onVoiceTap: {
                    guard viewModel.canStartVoiceInput else { return }
                    voiceRecorder.errorMessage = "按住录音，松开发送；上滑取消。语音会走加密媒体链路。"
                },
                onVoiceChanged: { value in
                    guard mediaAndCallEnabled, viewModel.canStartVoiceInput else { return }
                    if !voiceRecorder.isRecording {
                        Task { await voiceRecorder.beginRecording() }
                    }
                    voiceRecorder.updateCancelState(translation: value.translation)
                },
                onVoiceEnded: { _ in
                    guard mediaAndCallEnabled, viewModel.canStartVoiceInput, voiceRecorder.isRecording else { return }
                    do {
                        let result = try voiceRecorder.finishRecording(cancelled: voiceRecorder.isCancelling)
                        Task {
                            await viewModel.sendVoiceMessage(result, in: chat, modelContext: modelContext)
                        }
                    } catch {
                        if (error as? VoiceRecorderError) != .missingRecording {
                            voiceRecorder.errorMessage = error.localizedDescription
                        }
                    }
                }
            )

            if viewModel.isShowingAttachmentPanel {
                attachmentPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isShowingMediaPanel {
                StickerMediaPanel { emoji in
                    composerInsertion = ComposerInsertion(text: emoji)
                    isShowingMediaPanel = false
                } onSelectSticker: { sticker, pack in
                    isShowingMediaPanel = false
                    Task {
                        await viewModel.sendSticker(sticker, from: pack, in: chat, modelContext: modelContext)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Color(uiColor: .systemBackground).opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DoveTheme.warmGray.opacity(0.45))
                .frame(height: 0.5)
        }
        .alert("语音消息", isPresented: Binding(
            get: { voiceRecorder.errorMessage != nil },
            set: { if !$0 { voiceRecorder.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(voiceRecorder.errorMessage ?? "")
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhotoItem, matching: photoPickerFilter)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await sendPhotoItem(item) }
        }
    }

    private var attachmentPanel: some View {
        Group {
            if mediaAndCallEnabled {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                    AttachmentAction(icon: "photo", title: "图片") {
                        photoPickerFilter = .images
                        isPhotoPickerPresented = true
                    }
                    AttachmentAction(icon: "video", title: "视频") {
                        photoPickerFilter = .videos
                        isPhotoPickerPresented = true
                    }
                    AttachmentAction(icon: "phone", title: "语音通话") {
                        startCall(.audio)
                    }
                    AttachmentAction(icon: "video.badge.waveform", title: "视频通话") {
                        startCall(.video)
                    }
                    AttachmentAction(icon: "doc", title: "文件") {
                        isFileImporterPresented = true
                    }
                    AttachmentAction(icon: "map", title: "位置共享")
                    AttachmentAction(
                        icon: chat.restrictForwarding ? "hand.raised.fill" : "hand.raised",
                        title: "防转发",
                        isSelected: chat.restrictForwarding
                    ) {
                        Task {
                            await viewModel.updatePrivacy(
                                in: chat,
                                vanishMode: chat.vanishMode,
                                vanishSeconds: chat.vanishSeconds,
                                restrictForwarding: !chat.restrictForwarding,
                                modelContext: modelContext
                            )
                        }
                    }
                    AttachmentAction(
                        icon: chat.vanishMode ? "timer.circle.fill" : "timer",
                        title: chat.vanishMode ? "消失模式 · \(vanishDurationLabel)" : "消失模式",
                        isSelected: chat.vanishMode
                    ) {
                        isShowingVanishDurationPicker = true
                    }
                }
            } else {
                Label("媒体、语音和通话入口已开启。私聊内容继续走端到端加密主路径。", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func replyPreview(_ message: Message) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(DoveTheme.green)
                .frame(width: 3, height: 32)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 2) {
                Text("回复 \(message.isOutgoing ? "我" : chat.name)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DoveTheme.green)
                Text(message.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                viewModel.cancelReply()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DoveTheme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var statusStrip: some View {
        if viewModel.isLoadingMessages {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.72)
                Text("正在同步消息...")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.thinMaterial)
        } else if let noticeMessage = viewModel.noticeMessage {
            Text(noticeMessage)
                .font(.caption)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.thinMaterial)
        } else if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.thinMaterial)
        }
    }

    private var vanishDurationLabel: String {
        switch chat.vanishSeconds {
        case 5: return "5 秒"
        case 10: return "10 秒"
        case 86_400: return "24 小时"
        case let seconds?: return "\(seconds) 秒"
        default: return "已开启"
        }
    }

    private func setVanishMode(seconds: Int?) {
        Task {
            await viewModel.updatePrivacy(
                in: chat,
                vanishMode: seconds != nil,
                vanishSeconds: seconds,
                restrictForwarding: chat.restrictForwarding,
                modelContext: modelContext
            )
        }
    }

    private func shouldShowTimeGroup(_ current: Message, previous: Message?) -> Bool {
        guard let previous else { return true }
        return current.createdAt.timeIntervalSince(previous.createdAt) > 300
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let lastId = messages.last?.messageId else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastId, anchor: .bottom)
        }
    }

    private func scheduleScrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        // LazyVStack lays out asynchronously after remote history is merged.
        // Deferring one run-loop turn makes the newest message a valid scroll target.
        DispatchQueue.main.async {
            scrollToBottom(proxy: proxy, animated: animated)
        }
    }

    private func startCall(_ type: VideoCallType) {
        guard let peerId = peerUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !peerId.isEmpty else {
            callPresentationError = "当前会话没有同步到对方账号，暂时无法发起通话。请返回会话列表后重新进入此会话。"
            return
        }
        activeCallSession = .outgoing(peerId: peerId, peerName: chat.name, peerAvatar: chat.avatar, callType: type)
    }

    private func sendPhotoItem(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                viewModel.errorMessage = "读取媒体失败"
                return
            }
            let contentType = item.supportedContentTypes.first
            let mimeType = contentType?.preferredMIMEType ?? (contentType?.conforms(to: .movie) == true ? "video/mp4" : "image/jpeg")
            let type = contentType?.conforms(to: .movie) == true ? "video" : "image"
            let ext = contentType?.preferredFilenameExtension ?? (type == "video" ? "mp4" : "jpg")
            await viewModel.sendMediaMessage(
                data: data,
                fileName: "\(type)_\(Int(Date().timeIntervalSince1970)).\(ext)",
                mimeType: mimeType,
                type: type,
                in: chat,
                modelContext: modelContext
            )
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
        selectedPhotoItem = nil
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }

            let data = try Data(contentsOf: url)
            let values = try? url.resourceValues(forKeys: [.contentTypeKey])
            let contentType = values?.contentType
            let mimeType = contentType?.preferredMIMEType ?? "application/octet-stream"
            let messageType = contentType?.conforms(to: .image) == true ? "image" :
                contentType?.conforms(to: .movie) == true ? "video" :
                "file"

            Task {
                await viewModel.sendMediaMessage(
                    data: data,
                    fileName: url.lastPathComponent,
                    mimeType: mimeType,
                    type: messageType,
                    in: chat,
                    modelContext: modelContext
                )
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private var peerUserId: String? {
        let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")
        if let currentUserId, let peer = chat.memberIds.first(where: { $0 != currentUserId }) {
            return peer
        }
        return chat.memberIds.first
    }

    private func unlockConversation() {
        guard ConversationPreferences.verify(passcode: unlockPasscode, for: chat.chatId) else {
            unlockError = "聊天密码不正确"
            unlockPasscode = ""
            return
        }
        unlockError = nil
        unlockPasscode = ""
        withAnimation(.easeOut(duration: 0.18)) {
            isConversationLocked = false
        }
    }
}

private struct ComposerInsertion: Identifiable {
    let id = UUID()
    let text: String
}

private struct ChatTextComposer: View {
    let insertion: ComposerInsertion?
    @FocusState.Binding var isInputFocused: Bool
    @Binding var isShowingAttachmentPanel: Bool
    @Binding var isShowingMediaPanel: Bool
    let isRecording: Bool
    let canStartVoiceInput: Bool
    let onSend: (String) -> Void
    let onVoiceTap: () -> Void
    let onVoiceChanged: (DragGesture.Value) -> Void
    let onVoiceEnded: (DragGesture.Value) -> Void

    @State private var inputText = ""

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isShowingMediaPanel = false
                    isShowingAttachmentPanel.toggle()
                }
            } label: {
                Image(systemName: isShowingAttachmentPanel ? "xmark" : "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DoveTheme.ink)
                    .frame(width: 40, height: 40)
                    .background(DoveTheme.warmGray.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain)

            HStack(alignment: .center, spacing: 8) {
                TextField("输入加密消息...", text: $inputText)
                    .font(.system(size: 15))
                    .focused($isInputFocused)
                    .lineLimit(1)
                    .submitLabel(.send)
                    .frame(height: 40)
                    .onTapGesture {
                        isShowingMediaPanel = false
                    }
                    .onSubmit {
                        submit()
                    }

                Button {
                    isInputFocused = false
                    isShowingAttachmentPanel = false
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        isShowingMediaPanel.toggle()
                    }
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 40)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(DoveTheme.warmGray.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 12, y: 4)

            if canSend {
                Button {
                    submit()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(DoveTheme.green, in: Circle())
                        .shadow(color: DoveTheme.green.opacity(0.24), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onVoiceTap) {
                    Image(systemName: isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(isRecording ? Color.red : DoveTheme.green, in: Circle())
                        .shadow(color: (isRecording ? Color.red : DoveTheme.green).opacity(0.24), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(!canStartVoiceInput && !isRecording)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged(onVoiceChanged)
                        .onEnded(onVoiceEnded)
                )
            }
        }
        .onChange(of: insertion?.id) { _, _ in
            guard let insertion else { return }
            inputText += insertion.text
        }
    }

    private func submit() {
        let content = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        inputText = ""
        onSend(content)
    }
}

private struct AttachmentAction: View {
    let icon: String
    let title: String
    var isSelected = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : DoveTheme.green)
                    .frame(width: 46, height: 46)
                    .background(isSelected ? DoveTheme.green : DoveTheme.cardSurface.opacity(0.84), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DoveTheme.green.opacity(isSelected ? 0 : 0.35), lineWidth: 1))

                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? DoveTheme.green : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

private struct EmojiPickerPanel: View {
    private enum Category: String, CaseIterable, Identifiable {
        case smileys = "笑脸"
        case gestures = "手势"
        case people = "人物"
        case objects = "常用"
        case symbols = "符号"

        var id: String { rawValue }

        var emoji: [String] {
            switch self {
            case .smileys:
                return ["😀", "😃", "😄", "😁", "😆", "🥹", "😅", "😂", "🙂", "🙃", "😉", "😊", "😇", "🥰", "😍", "😘", "😋", "😜", "🤪", "🤩", "🥳", "😎", "🤓", "🫠", "😐", "😶", "🙄", "😏", "😣", "😢", "😭", "😤", "😡", "🤯", "😱", "🤗", "🤔", "🫡", "🤫", "🤭"]
            case .gestures:
                return ["👍", "👎", "👏", "🙌", "🫶", "🤝", "🙏", "✌️", "🤞", "🤟", "👌", "🤌", "👋", "🫡", "💪", "🫵", "☝️", "✋", "🖐️", "🤚", "🫰", "🤙", "💅", "🫂", "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍"]
            case .people:
                return ["🙂", "🧑", "👤", "👥", "👋", "🙋", "🙆", "💁", "🙇", "🤦", "🤷", "🧘", "💃", "🕺", "🏃", "🚶", "🧑‍💻", "👨‍💻", "👩‍💻", "🧑‍🎤", "👑", "🎩", "🕶️", "🎓", "👶", "🧒", "🧔", "👩", "👨", "🧓"]
            case .objects:
                return ["💬", "📩", "📷", "🎥", "🎧", "🎵", "🔥", "✨", "🎉", "🎁", "💡", "📌", "📍", "✅", "❌", "⚠️", "💯", "💤", "☕️", "🍰", "🌈", "☀️", "🌙", "⭐️", "🚀", "✈️", "🏆", "🎮", "📱", "💻", "🔒", "🔑"]
            case .symbols:
                return ["❤️", "💕", "💔", "❣️", "💢", "💥", "💦", "💨", "💫", "💤", "✔️", "✅", "☑️", "❌", "⭕️", "‼️", "⁉️", "❓", "❗️", "〽️", "➕", "➖", "✖️", "➗", "©️", "®️", "™️", "#️⃣", "*️⃣", "0️⃣", "1️⃣", "2️⃣"]
            }
        }
    }

    let onSelect: (String) -> Void
    @State private var category: Category = .smileys

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 8)

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Category.allCases) { item in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                category = item
                            }
                        } label: {
                            Text(item.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(category == item ? Color.white : DoveTheme.ink)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(category == item ? DoveTheme.green : DoveTheme.warmGray.opacity(0.72), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(category.emoji, id: \.self) { emoji in
                        Button {
                            onSelect(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 25))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(emoji)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 178)
        }
        .padding(.top, 2)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .background(DoveTheme.mist, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DoveTheme.warmGray.opacity(0.55), lineWidth: 1)
        }
    }
}

private struct MessageBubble: View {
    let message: Message
    let peerName: String
    let peerAvatar: String?
    let isForwardingRestricted: Bool
    @ObservedObject var voiceRecorder: VoiceRecorderManager
    let onReply: () -> Void
    let onMention: () -> Void
    let onRecall: () -> Void
    let onRetry: () -> Void
    @AppStorage("chatTextScale") private var chatTextScale = 1.0
    @State private var imageRetryToken = UUID()

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isOutgoing {
                Spacer(minLength: DoveTheme.Chat.avatarSize + 16)
            } else {
                DoveAvatar(name: peerName, url: peerAvatar, size: DoveTheme.Chat.avatarSize)
                    .padding(.top, 4)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                bubbleContent
                    .contextMenu {
                        if !isForwardingRestricted {
                            Button {
                                UIPasteboard.general.string = message.content
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                        }

                        Button {
                            onReply()
                        } label: {
                            Label("回复", systemImage: "arrowshape.turn.up.left")
                        }

                        Button {
                            onMention()
                        } label: {
                            Label("@提醒", systemImage: "at")
                        }

                        if message.isOutgoing {
                            Button(role: .destructive) {
                                onRecall()
                            } label: {
                                Label("撤回", systemImage: "trash")
                            }
                        }
                    }

                HStack(spacing: 4) {
                    if message.isOutgoing {
                        deliveryStatusView
                    }
                    Text(message.createdAt.messageTimeText)
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.82))
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.70, alignment: message.isOutgoing ? .trailing : .leading)

            if message.isOutgoing {
                DoveAvatar(name: "我", size: DoveTheme.Chat.avatarSize)
                    .padding(.top, 4)
            } else {
                Spacer(minLength: DoveTheme.Chat.avatarSize + 16)
            }
        }
        .padding(.horizontal, DoveTheme.Chat.horizontalPadding)
        .padding(.vertical, 3)
    }

    private var bubbleContent: some View {
        Group {
            if message.type == "voice" {
                VoiceMessageBubble(
                    message: message,
                    isPlaying: voiceRecorder.playingMessageId == message.messageId && voiceRecorder.isPlaying,
                    progress: voiceRecorder.playingMessageId == message.messageId ? voiceRecorder.playbackProgress : 0
                ) {
                    voiceRecorder.togglePlayback(messageId: message.messageId, urlString: message.voiceURL)
                }
            } else if message.type == "sticker" || message.type == "gif" || message.type == "meme" {
                stickerBubble
            } else if message.stickerRenderSource != nil {
                stickerBubble
            } else if message.type == "image" {
                imageBubble
            } else if message.type == "video" || message.type == "file" {
                fileBubble
            } else {
                textBubble
            }
        }
    }

    @ViewBuilder
    private var textBubble: some View {
        if message.content.contains("等待密钥同步") {
            Button(action: onRetry) {
                Label("加密消息未同步，点按重建会话", systemImage: "lock")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DoveTheme.Chat.bubbleHPadding)
                    .padding(.vertical, DoveTheme.Chat.bubbleVPadding)
                    .background {
                        bubbleBackground.clipShape(bubbleShape)
                    }
            }
            .buttonStyle(.plain)
        } else if isForwardingRestricted {
            baseTextBubble
        } else {
            baseTextBubble.textSelection(.enabled)
        }
    }

    private var baseTextBubble: some View {
        Text(message.content)
            .font(.system(size: 14.5 * chatTextScale))
            .lineSpacing(2)
            .foregroundStyle(DoveTheme.ink)
            .padding(.horizontal, DoveTheme.Chat.bubbleHPadding)
            .padding(.vertical, DoveTheme.Chat.bubbleVPadding)
            .background(bubbleBackground)
            .overlay(bubbleBorder)
            .clipShape(bubbleShape)
            .shadow(color: .black.opacity(message.isOutgoing ? 0.045 : 0.035), radius: 8, y: 3)
    }

    private var imageBubble: some View {
        Group {
            if let url = CQIMMediaURL.resolve(message.mediaURL) {
                AuthenticatedRemoteImage(url: url, contentMode: .fill) {
                    unavailableMediaView(title: "图片加载失败，点按重试", icon: "photo") {
                        imageRetryToken = UUID()
                    }
                }
                .id(imageRetryToken)
                .frame(width: 190, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                unavailableMediaView(title: message.status == "sending" ? "正在发送图片..." : "图片不可用", icon: "photo") {}
            }
        }
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }

    private var stickerBubble: some View {
        VStack(spacing: 6) {
            if let source = message.stickerRenderSource {
                StickerAssetView(source: source)
            } else {
                stickerFallback
            }

            if let name = message.stickerName, !name.isEmpty {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var stickerFallback: some View {
        Text(message.stickerEmoji?.isEmpty == false ? message.stickerEmoji! : "🔒")
            .font(.system(size: 54))
            .frame(width: 118, height: 118)
    }

    private var fileBubble: some View {
        HStack(spacing: 10) {
            Image(systemName: message.type == "video" ? "play.rectangle.fill" : "doc.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(DoveTheme.green)
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(message.fileName ?? message.content)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DoveTheme.ink)
                    .lineLimit(2)
                Text(fileMetaText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(minWidth: 190, alignment: .leading)
        .background(bubbleBackground)
        .overlay(bubbleBorder)
        .clipShape(bubbleShape)
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }

    private func unavailableMediaView(title: String, icon: String, retry: @escaping () -> Void = {}) -> some View {
        Button(action: retry) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(width: 190, height: 120)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var fileMetaText: String {
        guard let fileSize = message.fileSize, fileSize > 0 else {
            return message.mimeType ?? "文件"
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }

    private var bubbleShape: UnevenRoundedRectangle {
        if message.isOutgoing {
            UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 6, style: .continuous)
        } else {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous)
        }
    }

    private var bubbleBackground: some View {
        Group {
            if message.isOutgoing {
                DoveTheme.sentBubble
            } else {
                DoveTheme.receivedBubble
            }
        }
    }

    private var bubbleBorder: some View {
        bubbleShape.stroke(message.isOutgoing ? DoveTheme.sentBubbleEdge.opacity(0.42) : .white.opacity(0.95), lineWidth: 1)
    }

    @ViewBuilder
    private var deliveryStatusView: some View {
        switch message.status {
        case "sending":
            ProgressView()
                .scaleEffect(0.55)
        case "read":
            HStack(spacing: 2) {
                Image(systemName: "checkmark")
                Text("已读")
            }
        case "sent":
            Image(systemName: "checkmark")
        case "failed":
            Text("发送失败")
                .foregroundStyle(DoveTheme.seal)
        default:
            Image(systemName: "checkmark")
        }
    }
}

private struct HeaderIconButton: View {
    let systemName: String
    var tint: Color = DoveTheme.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(DoveTheme.warmGray.opacity(0.42), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private struct AuthenticatedRemoteImage<Failure: View>: View {
    let url: URL
    var contentMode: ContentMode = .fill
    @ViewBuilder var failure: () -> Failure

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if didFail {
                failure()
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        image = nil
        didFail = false

        if url.isFileURL {
            do {
                let data = try Data(contentsOf: url)
                guard let uiImage = UIImage(data: data) else {
                    didFail = true
                    return
                }
                image = uiImage
            } catch {
                didFail = true
            }
            return
        }

        var request = URLRequest(url: url)
        if let token = AuthTokenStore.shared.token, url.path.hasPrefix("/api/") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let uiImage = UIImage(data: data) else {
                didFail = true
                return
            }
            image = uiImage
        } catch {
            didFail = true
        }
    }
}

private struct PresenceDot: View {
    let isOnline: Bool

    var body: some View {
        Circle()
            .fill(isOnline ? Color.green : Color.gray)
            .frame(width: 6, height: 6)
            .shadow(color: isOnline ? .green.opacity(0.45) : .clear, radius: 4)
    }
}

private extension Date {
    var chatTimeGroupText: String {
        let calendar = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(self) {
            return "今天 \(time)"
        }
        if calendar.isDateInYesterday(self) {
            return "昨天 \(time)"
        }
        return formatted(.dateTime.month().day().hour().minute())
    }
}

private enum ConversationScrollPositionStore {
    private static let keyPrefix = "chat_last_visible_message_"

    static func load(for chatId: String) -> String? {
        UserDefaults.standard.string(forKey: keyPrefix + chatId)
    }

    static func save(_ messageId: String?, for chatId: String) {
        let key = keyPrefix + chatId
        if let messageId, !messageId.isEmpty {
            UserDefaults.standard.set(messageId, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private struct MessageViewportPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
