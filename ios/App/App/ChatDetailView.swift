import SwiftData
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Kingfisher
import AVKit
import ImageIO
import AVFoundation
import VisionKit

private enum AIConsentKind: String, Identifiable {
    case text, holdVoice, continuousVoice
    var id: String { rawValue }
}

struct ChatDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var authSession: AuthSession
    let chat: Chat

    @StateObject private var viewModel = ChatDetailViewModel()
    @StateObject private var voiceState = ChatVoiceRecordingState()
    @StateObject private var aiVoice = AIVoiceController()
    @State private var aiConsent: AIConsentKind?
    @State private var consentWasAccepted = false
    @State private var hasAIVoiceConsent = false
    @ObservedObject private var socket = SocketManager.shared
    @ObservedObject private var friendPresence = FriendPresenceStore.shared
    @FocusState private var isInputFocused: Bool
    @State private var activeCallSession: VideoCallSession?
    @State private var callPresentationError: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var isCameraPresented = false
    @State private var photoPickerFilter: PHPickerFilter = .any(of: [.images, .videos])
    @State private var isFileImporterPresented = false
    @State private var didPerformInitialScroll = false
    @State private var isNearMessageBottom = true
    @State private var isUserScrollingMessages = false
    @State private var bottomScrollPolicy = ChatBottomScrollPolicy()
    @State private var isShowingMediaPanel = false
    @State private var isShowingVanishDurationPicker = false
    @State private var composerInsertion: ComposerInsertion?
    @State private var isShowingChatSettings = false
    @State private var isShowingEncryptionInfo = false
    @State private var chatBackgroundStyle: ChatBackgroundStyle = .paper
    @State private var isConversationLocked = false
    @State private var unlockPasscode = ""
    @State private var unlockError: String?

    private var isAIConversation: Bool { AIConversation.matches(chat.chatId) }
    private var mediaAndCallEnabled: Bool { !isAIConversation }

    private var presencePeerID: String? {
        guard chat.type == "private", !chat.isOfficial, !chat.isBot else { return nil }
        return chat.avatarPeerUserId
    }

    private var presenceRefreshIdentity: String {
        "\(authSession.currentUser?.id ?? "")|\(presencePeerID ?? "")|\(scenePhase == .active)|\(socket.isConnected)"
    }

    private var peerStatusText: String {
        if isAIConversation { return "DeepSeek" }
        if chat.type == "group" { return AppLocalization.text("\(max(chat.memberIds.count, 4)) 位成员") }
        if chat.isOfficial { return AppLocalization.string("官方账号") }
        guard let value = friendPresence.snapshot(for: presencePeerID) else { return AppLocalization.string("在线状态未知") }
        if value.online { return AppLocalization.string("在线") }
        if let lastSeen = value.lastSeen, lastSeen > 0 {
            return AppLocalization.text("最后在线 \(Date(milliseconds: lastSeen).chatListTimeText)")
        }
        return AppLocalization.string("离线")
    }

    private var voiceRecorder: VoiceRecorderManager { voiceState.recorder }

    private var messages: [Message] {
        viewModel.sortedMessages(for: chat)
    }

    private var chatBaseContent: some View {
        ZStack {
            ConversationBackground(style: chatBackgroundStyle).ignoresSafeArea(.container)

            VStack(spacing: 0) {
                statusStrip
                messagesView
            }
            .modifier(ConversationFloatingTopBar(isEnabled: true) {
                conversationHeader
            })

            if voiceRecorder.isRecording {
                ChatVoiceRecordingOverlay(recorder: voiceRecorder)
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
            if isAIConversation { aiVoice.activate(owner: authSession.currentUser?.id, token: AuthTokenStore.shared.token) }
            chatBackgroundStyle = ConversationPreferences.backgroundStyle(for: chat.chatId)
            isConversationLocked = ConversationPreferences.hasPasscode(for: chat.chatId)
            NotificationRouter.shared.setActiveConversation(chat.chatId)
            PushNotificationManager.shared.updatePresence(.foreground, activeChatId: chat.chatId)
            if chat.type == "group" { SocketManager.shared.joinGroup(chat.chatId) }
            markVisibleMessagesAsRead()
        }
        .onDisappear {
            if isAIConversation { aiVoice.deactivate(); viewModel.cancelAIRequest() }
            bottomScrollPolicy.cancel()
            isUserScrollingMessages = false
            if chat.type == "group" { SocketManager.shared.leaveGroup(chat.chatId) }
            if NotificationRouter.shared.activeConversationId == chat.chatId {
                NotificationRouter.shared.setActiveConversation(nil)
                PushNotificationManager.shared.updatePresence(.foreground)
            }
        }
        .task {
            await viewModel.loadMessages(for: chat, modelContext: modelContext)
            if !Task.isCancelled { markVisibleMessagesAsRead() }
        }
        .task(id: presenceRefreshIdentity) {
            guard scenePhase == .active, let id = presencePeerID else { return }
            while !Task.isCancelled {
                await friendPresence.refresh(id)
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
    }

    private var voiceAwareContent: some View {
        chatBaseContent
        .sheet(item: $aiConsent, onDismiss: {
            if viewModel.isShowingAIConsent {
                composerInsertion = ComposerInsertion(text: viewModel.cancelAIConsent())
            }
            if !consentWasAccepted { aiVoice.stopAll() }
            consentWasAccepted = false
        }) { kind in
            AIConsentPanel(kind: kind) {
                guard scenePhase == .active, !isConversationLocked else { return }
                consentWasAccepted = true
                if kind == .text {
                    if let text = viewModel.acceptAIConsent() {
                        Task { await viewModel.sendMessage(text, in: chat, modelContext: modelContext) }
                    }
                } else {
                    hasAIVoiceConsent = true
                    if kind == .holdVoice { aiVoice.preparePushToTalk() }
                    else { aiVoice.startConversation() }
                }
            }
        }
        .onChange(of: viewModel.isShowingAIConsent) { _, showing in
            guard isAIConversation else { return }
            if showing {
                consentWasAccepted = false
                aiConsent = .text
                AIFlowTrace.record(.consentShown)
            } else if aiConsent == .text { aiConsent = nil }
        }
        .onChange(of: aiVoice.submittedUtterance) { _, utterance in
            guard isAIConversation, let utterance, scenePhase == .active, !isConversationLocked,
                  utterance.ownerID == authSession.currentUser?.id, !viewModel.isSending else { aiVoice.stopAll(); return }
            Task { await viewModel.sendMessage(utterance.text, in: chat, modelContext: modelContext) }
        }
        .onChange(of: viewModel.completedAIReply) { _, reply in
            guard isAIConversation, let reply, scenePhase == .active, !isConversationLocked,
                  reply.ownerID == authSession.currentUser?.id else { return }
            aiVoice.receiveReply(reply.text)
        }
        .onChange(of: viewModel.isSending) { _, sending in
            if isAIConversation, !sending, viewModel.errorMessage != nil { aiVoice.stopAll() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { markVisibleMessagesAsRead() }
            if isAIConversation, phase == .background || (phase == .inactive && !aiVoice.isPreparing) {
                aiVoice.stopAll(); viewModel.cancelAIRequest()
            }
        }
        .onChange(of: authSession.currentUser?.id) { _, _ in
            guard isAIConversation else { return }
            viewModel.cancelAIRequest()
            hasAIVoiceConsent = false
            aiConsent = nil
            aiVoice.activate(owner: authSession.currentUser?.id, token: AuthTokenStore.shared.token)
        }
        .onChange(of: locale.identifier) { _, _ in
            if isAIConversation { aiVoice.stopAll() }
        }
    }

    private var messageEventContent: some View {
        voiceAwareContent
        .onReceive(NotificationCenter.default.publisher(for: .cqimPrivateMessageDidReceive)) { notification in
            guard let message = notification.object as? Message,
                  message.chatId == chat.chatId else { return }
            viewModel.handleSocketMessage(
                message,
                isAck: notification.userInfo?["ack"] as? Bool == true,
                in: chat,
                modelContext: modelContext
            )
            if notification.userInfo?["ack"] as? Bool != true { markVisibleMessagesAsRead() }
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
    }

    var body: some View {
        messageEventContent
        .fullScreenCover(item: $activeCallSession) { session in
            VideoCallView(session: session)
        }
        .navigationDestination(isPresented: $isShowingChatSettings) {
            ChatSettingsView(chat: chat) {
                chatBackgroundStyle = ConversationPreferences.backgroundStyle(for: chat.chatId)
            }
        }
        .sheet(isPresented: $isShowingEncryptionInfo) {
            if chat.type == "group" {
                GroupEncryptionInfo(groupID: chat.chatId, groupName: chat.name)
            } else {
                ConversationEncryptionInfo(isGroup: chat.type == "group", peerID: presencePeerID, peerName: chat.name)
            }
        }
        .alert("无法发起通话", isPresented: Binding(
            get: { callPresentationError != nil },
            set: { if !$0 { callPresentationError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            AppLocalizedText(callPresentationError ?? "")
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

    private var conversationHeader: some View {
        ConversationGlassGroup {
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .modifier(ConversationGlassSurface())
                .accessibilityLabel(Text("返回"))
                .accessibilityIdentifier("chat.header.back")

                Spacer(minLength: 12)

                conversationEncryptionBanner

                Spacer(minLength: 12)

                Button {
                    dismissInputSurfaces()
                    isShowingChatSettings = true
                } label: {
                    DoveAvatar(name: chat.name, url: chat.avatar, userId: chat.avatarCacheIdentity,
                               size: 42, isGroup: chat.type == "group")
                        .padding(5)
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .modifier(ConversationGlassSurface())
                .accessibilityLabel(Text("聊天详情"))
                .accessibilityIdentifier("chat.header.details")
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }

    private var conversationEncryptionBanner: some View {
        Button {
            isInputFocused = false
            if isAIConversation { isShowingChatSettings = true }
            else { isShowingEncryptionInfo = true }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Text(chat.name).font(.headline).lineLimit(1)
                    if chat.vanishMode { Image(systemName: "timer").font(.caption) }
                }
                .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Image(systemName: isAIConversation ? "sparkles" : "lock.shield").accessibilityHidden(true)
                    if presencePeerID != nil { PresenceDot(isOnline: friendPresence.snapshot(for: presencePeerID)?.online == true) }
                    Text(verbatim: peerStatusText).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).accessibilityHidden(true)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 240 : 200, minHeight: 52)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ConversationGlassSurface())
        .accessibilityLabel(Text(chat.name))
        .accessibilityValue(Text(verbatim: isAIConversation ? AppLocalization.string("AI 对话由 DeepSeek 处理") : peerStatusText + " · " + (chat.type == "group" ? "MLS" : "Signal Protocol")))
        .accessibilityIdentifier("chat.encryption.info")
        .accessibilityHint(Text(isAIConversation ? "聊天详情" : "打开加密说明"))
    }

    private var messagesView: some View {
        // `messages` sorts the SwiftData relationship. Capture one snapshot for
        // this render pass: calling it again from every row previously repeated
        // the sort while an incoming message was being inserted.
        let messageItems = messages
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    // The API returns at most 50 messages. A regular VStack keeps
                    // every row's measured height stable while media and status
                    // views update. LazyVStack's estimated heights caused visible
                    // jumps and large blank gaps during interactive scrolling.
                    VStack(spacing: 2) {
                        ForEach(Array(messageItems.enumerated()), id: \.element.messageId) { index, message in
                            let sender = avatarSource(for: message)
                            if shouldShowTimeGroup(message, previous: index > 0 ? messageItems[index - 1] : nil) {
                                AppLocalizedText(message.createdAt.chatTimeGroupText)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(DoveTheme.warmGray.opacity(0.62), in: Capsule())
                                    .padding(.vertical, 4)
                            }

                            MessageBubble(
                                message: message,
                                peerName: sender.name ?? message.senderId,
                                peerAvatar: sender.urlString,
                                peerUserId: sender.userId,
                                isCurrentUserAvatar: message.isOutgoing && sender.userId != nil && sender.userId == authSession.currentUser?.id,
                                stickerViewport: StickerViewport(name: "chatMessages", size: viewport.size),
                                isForwardingRestricted: chat.restrictForwarding || message.forwardRestricted,
                                voiceRecorder: voiceRecorder,
                                onReply: {
                                    dismissInputSurfaces()
                                    viewModel.beginReply(to: message)
                                    isInputFocused = true
                                },
                                onMention: {
                                    dismissInputSurfaces()
                                    composerInsertion = ComposerInsertion(text: "@\(chat.name) ")
                                    isInputFocused = true
                                },
                                onRecall: {
                                    Task {
                                        await viewModel.recall(message, in: chat, modelContext: modelContext)
                                    }
                                },
                                onRetry: {
                                    if isAIConversation {
                                        composerInsertion = ComposerInsertion(text: message.content)
                                        isInputFocused = true
                                    } else {
                                        Task { await viewModel.retryEncryptedMessage(message, in: chat, modelContext: modelContext) }
                                    }
                                },
                                onMediaRetry: {
                                    Task { await viewModel.retryMedia(message, modelContext: modelContext) }
                                },
                                onCall: { startCall($0) },
                                isAIConversation: isAIConversation
                            )
                            .id(message.messageId)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.messageBottomAnchorId)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: MessageBottomPreferenceKey.self,
                                        value: geometry.frame(in: .named("chatMessages")).maxY
                                    )
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 0)
                    .padding(.top, 12)
                    .padding(.bottom, 18)
                }
                .coordinateSpace(name: "chatMessages")
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        dismissInputSurfaces()
                    }
                )
                .scrollDismissesKeyboard(.interactively)
                .modifier(ChatUserScrollTracking { isScrolling in
                    isUserScrollingMessages = isScrolling
                    if isScrolling { bottomScrollPolicy.cancel() }
                })
                .onAppear {
                    performInitialScrollIfNeeded(proxy: proxy, messageItems: messageItems)
                }
                .onChange(of: messageItems.last?.messageId) { oldValue, newValue in
                    guard didPerformInitialScroll,
                          !viewModel.isLoadingMessages,
                          oldValue != newValue,
                          oldValue.map({ oldId in
                              messageItems.contains(where: { $0.messageId == oldId })
                          }) == true,
                          let lastMessage = messageItems.last,
                          lastMessage.isOutgoing || isNearMessageBottom else { return }
                    scheduleScrollToBottom(proxy: proxy, reason: lastMessage.isOutgoing ? .outgoing : .incoming)
                }
                .onChange(of: viewModel.isLoadingMessages) { _, isLoading in
                    guard !isLoading else { return }
                    if didPerformInitialScroll {
                        if isNearMessageBottom {
                            scheduleScrollToBottom(proxy: proxy, reason: .historyLoaded)
                        }
                    } else {
                        performInitialScrollIfNeeded(proxy: proxy, messageItems: messageItems)
                    }
                }
                .onPreferenceChange(MessageBottomPreferenceKey.self) { bottomY in
                    guard bottomY.isFinite else { return }
                    let nearBottom = bottomY <= viewport.size.height + 100
                    if nearBottom != isNearMessageBottom {
                        isNearMessageBottom = nearBottom
                    }
                }
            }
        }
    }

    private func performInitialScrollIfNeeded(proxy: ScrollViewProxy, messageItems: [Message]) {
        guard !didPerformInitialScroll, !messageItems.isEmpty else { return }
        didPerformInitialScroll = true
        scheduleScrollToBottom(proxy: proxy, reason: .initial)
    }

    private static let messageBottomAnchorId = "chat-message-bottom-anchor"

    private func requestAIVoice(hold: Bool) {
        guard !isConversationLocked, scenePhase == .active, !viewModel.isSending else { return }
        isInputFocused = false
        voiceRecorder.stopPlayback()
        aiVoice.activate(owner: authSession.currentUser?.id, token: AuthTokenStore.shared.token)
        if hasAIVoiceConsent {
            if hold { aiVoice.beginPushToTalk() }
            else { aiVoice.startConversation() }
        } else {
            consentWasAccepted = false
            aiConsent = hold ? .holdVoice : .continuousVoice
            AIFlowTrace.record(.consentShown)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if isAIConversation {
                AIMessageComposer(voice: aiVoice, insertion: composerInsertion,
                    isSending: viewModel.isSending, isInputFocused: $isInputFocused,
                    onSend: { content in
                        aiVoice.stopAll()
                        Task { await viewModel.sendMessage(content, in: chat, modelContext: modelContext) }
                }, onStartConversation: {
                    requestAIVoice(hold: false)
                }, onHoldBegan: {
                    requestAIVoice(hold: true)
                }, onHoldEnded: { cancelled in
                    aiVoice.endPushToTalk(cancelled: cancelled)
                }, onStop: {
                    aiVoice.stopAll()
                    viewModel.cancelAIRequest()
                })
            } else {
            if let replyingTo = viewModel.replyingTo {
                replyPreview(replyingTo)
            }

            ChatTextComposer(
                insertion: composerInsertion,
                placeholder: AppLocalization.string(isAIConversation ? "询问 imim AI…" : "输入加密消息..."),
                mediaEnabled: mediaAndCallEnabled,
                isSending: viewModel.isSending,
                sendingStatus: viewModel.sendingMessageStatus,
                isInputFocused: $isInputFocused,
                isShowingAttachmentPanel: Binding(
                    get: { viewModel.isShowingAttachmentPanel },
                    set: { viewModel.isShowingAttachmentPanel = $0 }
                ),
                isShowingMediaPanel: $isShowingMediaPanel,
                isRecording: voiceRecorder.isRecording,
                canStartVoiceInput: mediaAndCallEnabled && viewModel.canStartVoiceInput,
                onSend: { content in
                    await viewModel.submitComposerMessage(content, in: chat, modelContext: modelContext)
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
            }

            if mediaAndCallEnabled && viewModel.isShowingAttachmentPanel {
                attachmentPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if mediaAndCallEnabled && isShowingMediaPanel {
                StickerMediaPanel(ownerID: authSession.currentUser?.id ?? "") { emoji in
                    composerInsertion = ComposerInsertion(text: emoji)
                    isShowingMediaPanel = false
                } onSelectSticker: { sticker, pack in
                    isShowingMediaPanel = false
                    Task {
                        await viewModel.sendSticker(sticker, from: pack, in: chat, modelContext: modelContext)
                    }
                } onDismiss: {
                    dismissInputSurfaces()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background {
            DoveTheme.paper
                .ignoresSafeArea(.container, edges: .bottom)
        }
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
            AppLocalizedText(voiceRecorder.errorMessage ?? "")
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhotoItem, matching: photoPickerFilter)
        .fullScreenCover(isPresented: $isCameraPresented) {
            DualCameraView(allowsVideo: true) { result in
                Task { await sendCameraCapture(result) }
            }
        }
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
                    AttachmentAction(icon: "camera.on.rectangle", title: "拍摄") {
                        guard !voiceRecorder.isRecording else { return }
                        isInputFocused = false
                        isCameraPresented = true
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
                        title: chat.vanishMode ? AppLocalization.text("消失模式 · \(vanishDurationLabel)") : AppLocalization.string("消失模式"),
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
                Text("回复 \(message.isOutgoing ? AppLocalization.string("我") : chat.name)")
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
        if let sendingStatus = viewModel.sendingMessageStatus {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.72)
                AppLocalizedText(sendingStatus)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.thinMaterial)
            .accessibilityIdentifier("chat.sendingStatus")
        } else if let errorMessage = viewModel.errorMessage {
            AppLocalizedText(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.thinMaterial)
                .accessibilityIdentifier("chat.sendError")
        } else if viewModel.isLoadingMessages {
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
            AppLocalizedText(noticeMessage)
                .font(.caption)
                .foregroundStyle(.green)
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
        case let seconds?: return AppLocalization.text("\(seconds) 秒")
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

    private func dismissInputSurfaces() {
        isInputFocused = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            isShowingMediaPanel = false
            viewModel.isShowingAttachmentPanel = false
        }
    }

    private func shouldShowTimeGroup(_ current: Message, previous: Message?) -> Bool {
        guard let previous else { return true }
        return current.createdAt.timeIntervalSince(previous.createdAt) > 300
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(Self.messageBottomAnchorId, anchor: .bottom)
            }
        } else {
            withAnimation(nil) {
                proxy.scrollTo(Self.messageBottomAnchorId, anchor: .bottom)
            }
        }
    }

    private func scheduleScrollToBottom(proxy: ScrollViewProxy, reason: ChatBottomScrollPolicy.Reason) {
        guard let ticket = bottomScrollPolicy.request(
            reason, isNearBottom: isNearMessageBottom, isUserScrolling: isUserScrollingMessages
        ) else { return }
        // Defer one run-loop turn so the bottom anchor reflects the newly
        // inserted message. Coalesce requests and recheck the current UI state:
        // an incoming-message callback must not override a new user scroll.
        DispatchQueue.main.async {
            guard let animated = bottomScrollPolicy.consume(
                ticket, isUserScrolling: isUserScrollingMessages, reduceMotion: reduceMotion
            ) else { return }
            scrollToBottom(proxy: proxy, animated: animated)
        }
    }

    private func startCall(_ type: VideoCallType) {
        guard mediaAndCallEnabled else { return }
        guard let peerId = peerUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !peerId.isEmpty else {
            callPresentationError = "当前会话没有同步到对方账号，暂时无法发起通话。请返回会话列表后重新进入此会话。"
            return
        }
        activeCallSession = .outgoing(peerId: peerId, peerName: chat.name, peerAvatar: chat.avatar, callType: type, chatID: chat.chatId)
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

    private func sendCameraCapture(_ result: CameraCaptureResult) async {
        defer { result.discard() }
        let owner = authSession.currentUser?.id
        do {
            let data: Data
            let type: String
            switch result {
            case .photo(let jpeg): data = jpeg; type = "image"
            case .video(let url):
                data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                type = "video"
            }
            guard owner == authSession.currentUser?.id, !Task.isCancelled else { return }
            await viewModel.sendMediaMessage(data: data,
                fileName: "camera_\(Int(Date().timeIntervalSince1970)).\(type == "video" ? "mp4" : "jpg")",
                mimeType: type == "video" ? "video/mp4" : "image/jpeg", type: type,
                in: chat, modelContext: modelContext)
        } catch { viewModel.errorMessage = error.localizedDescription }
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

    private func avatarSource(for message: Message) -> AvatarImageLoader.Source {
        if message.isOutgoing, let user = authSession.currentUser,
           message.senderId == user.id || message.senderId == "me" {
            return .init(userId: user.id, urlString: user.avatar, name: user.nickname)
        }
        if !message.isOutgoing, chat.type == "private",
           chat.isOfficial || chat.isBot || chat.avatarPeerUserId == message.senderId {
            return .init(userId: chat.avatarPeerUserId, urlString: chat.avatar, name: chat.name)
        }
        // Group rows belong to the sender, never to the group or first member.
        return viewModel.senderAvatars[message.senderId]
            ?? .init(userId: message.senderId, urlString: nil, name: message.senderId)
    }

    private var peerUserId: String? {
        let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")
        if let currentUserId, let peer = chat.memberIds.first(where: { $0 != currentUserId }) {
            return peer
        }
        return chat.memberIds.first
    }

    private func markVisibleMessagesAsRead() {
        guard scenePhase == .active, !isConversationLocked,
              NotificationRouter.shared.activeConversationId == chat.chatId else { return }
        viewModel.markAsRead(chat, modelContext: modelContext)
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
        markVisibleMessagesAsRead()
    }
}

/// A real safe-area bar lets scrolling content pass behind the glass controls
/// without an overlay hiding the first message, shared by peer and AI chats.
private struct ConversationFloatingTopBar<Bar: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let bar: () -> Bar
    @ViewBuilder func body(content: Content) -> some View {
        if !isEnabled { content }
        else if #available(iOS 26, *) {
            content.safeAreaBar(edge: .top, spacing: 0) { bar() }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { bar() }
        }
    }
}

private struct ConversationGlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder var body: some View {
        if #available(iOS 26, *) {
            // Keep the three controls distinct instead of merging them.
            GlassEffectContainer(spacing: 6) { content() }
        } else { content() }
    }
}

private struct ConversationGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(DoveTheme.cardSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.16), lineWidth: 0.5))
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(!reduceMotion), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        }
    }
}

// Value-only admission gate: timeout/cancelled reads cannot revive stale UI.
private struct SecurityInfoLoadGate {
    private(set) var ticket: UInt64 = 0
    private(set) var isLoading = false
    mutating func begin() -> UInt64 {
        ticket &+= 1
        isLoading = true
        return ticket
    }
    @discardableResult mutating func finish(_ candidate: UInt64) -> Bool {
        guard candidate == ticket, isLoading else { return false }
        isLoading = false
        return true
    }
}

private struct GroupEncryptionInfo: View {
    private enum Destination: String, Identifiable { case scanner; var id: String { rawValue } }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("current_user_id") private var ownerID = ""
    let groupID: String
    let groupName: String
    @State private var info: MLSGroupSecurityInfo?
    @State private var loadError: String?
    @State private var loadGate = SecurityInfoLoadGate()
    @State private var refreshNonce: UInt64 = 0
    @State private var destination: Destination?
    @State private var scannedPayload: String?
    @State private var comparison: (code: IMIMGroupVerification, matches: Bool)?
    @State private var scanOwnerID: String?
    @State private var qrImage: UIImage?

    private var refreshIdentity: String { "\(ownerID)|\(groupID)|\(scenePhase == .background)|\(refreshNonce)" }
    private var currentInfo: MLSGroupSecurityInfo? {
        guard let info, info.ownerID == ownerID, info.groupID == groupID,
              scenePhase != .background, AuthTokenStore.shared.token?.isEmpty == false else { return nil }
        return info
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("MLS 群聊安全", systemImage: "lock.shield")
                        .foregroundStyle(DoveTheme.ink)
                    Text(verbatim: groupName).font(.headline)
                    LabeledContent("加密协议") { Text(verbatim: "MLS") }
                }
                if let value = currentInfo {
                    groupSections(value)
                } else {
                    Section {
                        if let loadError { AppLocalizedText(loadError).foregroundStyle(.secondary) }
                        else if loadGate.isLoading { ProgressView("正在读取安全信息…") }
                        else { Text("暂无可显示的安全信息，请点击刷新。").foregroundStyle(.secondary) }
                    }
                }
                Section {
                    Text("核对码仅比较双方当前保存的群密钥状态，不认证成员身份，也不代表全群已验证。请当面或通过可信渠道核对；成员或纪元变化后需重新核对。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("打开或刷新此页不会创建、导出或重置群密钥，也不会自动发起重新加群。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("群聊安全详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("刷新") { refreshNonce &+= 1 }
                        .disabled(loadGate.isLoading)
                        .accessibilityIdentifier("chat.group.security.refresh")
                }
                ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: refreshIdentity) { await reloadGroup() }
        .task(id: loadGate.ticket) {
            let ticket = loadGate.ticket
            guard loadGate.isLoading else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard !Task.isCancelled, loadGate.finish(ticket) else { return }
            info = nil
            loadError = "安全信息读取超时，请点击刷新重试。不会重置密钥或聊天记录。"
        }
        .sheet(item: $destination) { _ in
            SecurityCodeScannerSheet { payload in
                scannedPayload = payload
                destination = nil
            }
        }
        .task(id: scannedPayload) {
            guard let payload = scannedPayload, scanOwnerID == ownerID else { return }
            let scanOwner = ownerID
            // Re-read the actor after scanning. Never compare against the snapshot
            // that was displayed before the camera opened.
            await reloadGroup()
            guard !Task.isCancelled, scanOwner == ownerID, let code = currentInfo?.verification else { return }
            comparison = (code, code.matches(payload))
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if scenePhase == .active, destination == nil, !loadGate.isLoading, currentInfo != nil {
                    await reloadGroup()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { destination = nil; comparison = nil; scannedPayload = nil; qrImage = nil }
        }
        .onChange(of: ownerID) { _, _ in
            destination = nil; comparison = nil; scannedPayload = nil; scanOwnerID = nil; qrImage = nil
        }
    }

    @ViewBuilder private func groupSections(_ value: MLSGroupSecurityInfo) -> some View {
        Section {
            if let code = value.verification {
                Text(verbatim: code.number)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("chat.group.security.number")
                Button("复制安全码") { UIPasteboard.general.string = code.number }
                if let qrImage {
                    Image(uiImage: qrImage).interpolation(.none).resizable().scaledToFit()
                        .frame(maxWidth: 280).padding(12).background(.white)
                        .accessibilityLabel("群纪元核对二维码")
                } else {
                    Text("二维码生成失败，请点击刷新重试。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("扫描群成员核对码") { scannedPayload = nil; comparison = nil; scanOwnerID = ownerID; destination = .scanner }
                    .accessibilityIdentifier("chat.group.security.scan")
                if let comparison, comparison.code == code {
                    AppLocalizedText(comparison.matches
                        ? "本次扫码一致，仅表示双方保存的该群纪元状态一致。"
                        : "核对失败：群、纪元或密钥状态不一致，或二维码格式不受支持。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("本机没有可核对的完整群密钥状态，暂不能生成安全码或二维码。")
                    .foregroundStyle(.secondary)
            }
        } header: { Text("群安全码与二维码") }
        footer: { Text("IMIM v1 群纪元核对码，不是标准 MLS 纪元验证值或私聊安全码。二维码不包含群密钥。") }
        .disabled(loadGate.isLoading)

        Section {
            LabeledContent("本机群密钥状态") {
                AppLocalizedText(value.hasLocalState ? "本机已保存" : "本机尚未同步")
            }
            if !value.hasLocalState {
                Text("本机尚无此群的 MLS 状态。请等待已有成员设备正常同步群密钥后再刷新；刷新此页不能恢复已丢失的密钥。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let epoch = value.epoch {
                LabeledContent("本机当前纪元 (Epoch)") { Text(verbatim: String(epoch)) }
            }
            if let count = value.memberCount {
                LabeledContent("本机纪元成员数") { Text(verbatim: String(count)) }
            }
            if let leaf = value.leafIndex {
                LabeledContent("本机叶子索引") { Text(verbatim: String(leaf)) }
            }
            if let generation = value.generation {
                LabeledContent("本机当前发送代数") { Text(verbatim: String(generation)) }
            }
            if let importedAt = value.importedAt {
                LabeledContent("本机纪元导入时间") {
                    Text(Date(milliseconds: importedAt), format: .dateTime.year().month().day().hour().minute())
                }
            }
        } header: { Text("本机 MLS 会话") }
        footer: { Text("以上信息来自本机当前保存的纪元，不是服务器的实时成员列表。") }
    }

    @MainActor private func reloadGroup() async {
        let ticket = loadGate.begin()
        info = nil; loadError = nil
        guard scenePhase != .background, !ownerID.isEmpty, !groupID.isEmpty,
              let token = AuthTokenStore.shared.token, !token.isEmpty else {
            loadGate.finish(ticket)
            loadError = "账号或联系人信息尚未就绪，请返回聊天后重试。"
            return
        }
        let owner = ownerID
        do {
            let value = try await MLSGroupManager.shared.securityInfo(groupId: groupID, userId: owner)
            if Task.isCancelled { loadGate.finish(ticket); return }
            guard loadGate.finish(ticket) else { return }
            guard owner == ownerID, token == AuthTokenStore.shared.token, scenePhase != .background else {
                loadError = "账号或联系人信息尚未就绪，请返回聊天后重试。"; return
            }
            if info?.verification != value.verification || qrImage == nil {
                qrImage = value.verification.flatMap { QRCodeGenerator.makeImage(from: $0.qrPayload) }
            }
            if comparison?.code != value.verification { comparison = nil }
            info = value
        } catch {
            if Task.isCancelled { loadGate.finish(ticket); return }
            guard loadGate.finish(ticket) else { return }
            loadError = "暂时无法读取群安全信息，请解锁设备后点击刷新重试。"
        }
    }
}

/// Public identity metadata only. Opening never establishes/resets a session.
private struct ConversationEncryptionInfo: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("current_user_id") private var ownerID = ""
    let isGroup: Bool
    let peerID: String?
    let peerName: String
    @State private var info: E2EEPeerSecurityInfo?
    @State private var qrImage: UIImage?
    @State private var loadError: String?
    @State private var actionMessage: String?
    @State private var isSaving = false
    @State private var confirmingVerification = false
    @State private var verificationCandidate: String?
    @State private var showsQR = false
    @State private var isScanning = false
    @State private var scannedPayload: String?
    @State private var loadGate = SecurityInfoLoadGate()
    @State private var refreshNonce: UInt64 = 0

    private var refreshIdentity: String { "\(ownerID)|\(peerID ?? "")|\(scenePhase == .background)|\(refreshNonce)" }
    private var currentInfo: E2EEPeerSecurityInfo? {
        guard let info, info.ownerID == ownerID, info.peerID == peerID,
              scenePhase != .background, AuthTokenStore.shared.token?.isEmpty == false else { return nil }
        return info
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("端到端加密", systemImage: "lock.shield.fill")
                        .foregroundStyle(DoveTheme.ink)
                    LabeledContent("加密协议") {
                        Text(verbatim: isGroup ? "MLS" : "Signal Protocol")
                    }
                    AppLocalizedText(isGroup
                        ? "群聊使用 MLS。消息解密依赖参与设备持有的群密钥。"
                        : "私聊使用 Signal Protocol。消息解密依赖参与设备持有的会话密钥。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !isGroup {
                    if let value = currentInfo {
                        identitySections(value)
                    } else {
                        Section {
                            if let loadError { AppLocalizedText(loadError).foregroundStyle(.secondary) }
                            else if loadGate.isLoading { ProgressView("正在读取安全信息…") }
                            else { Text("暂无可显示的安全信息，请点击刷新。").foregroundStyle(.secondary) }
                        }
                    }
                }
                Section {
                    Text("安全码需要通过面对面或其他可信渠道核对。标记仅保存在这台设备，不会替对方完成验证，也不会显示、导出或重置私钥。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("加密说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("刷新") { refreshNonce &+= 1 }
                        .disabled(loadGate.isLoading || isSaving)
                        .accessibilityIdentifier("chat.security.refresh")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: refreshIdentity) {
            guard !isGroup else { return }
            if info?.ownerID != ownerID || info?.peerID != peerID {
                info = nil; qrImage = nil; actionMessage = nil; verificationCandidate = nil
            }
            await reload()
        }
        .task(id: loadGate.ticket) {
            let ticket = loadGate.ticket
            guard loadGate.isLoading else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard !Task.isCancelled else { return }
            expireRead(ticket)
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if !isGroup, scenePhase != .background, !loadGate.isLoading, !isSaving,
                   currentInfo != nil, loadError == nil, !confirmingVerification, !isScanning {
                    refreshNonce &+= 1
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { isScanning = false; confirmingVerification = false; verificationCandidate = nil }
        }
        .sheet(isPresented: $isScanning, onDismiss: checkScannedCode) {
            SecurityCodeScannerSheet { payload in
                scannedPayload = payload
                isScanning = false
            }
        }
        .confirmationDialog("已通过可信渠道核对双方安全码？", isPresented: $confirmingVerification, titleVisibility: .visible) {
            Button("一致，标记已验证") {
                let candidate = verificationCandidate
                Task { await setVerified(true, expectedBinding: candidate) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请确认你们看到的完整安全码一致。仅打开此页或显示二维码不代表已验证。")
        }
    }

    @ViewBuilder private func identitySections(_ value: E2EEPeerSecurityInfo) -> some View {
        Section {
            if value.identityChanged {
                Label("身份密钥已变化，旧验证已失效，请重新核对。", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
            LabeledContent("验证状态") {
                AppLocalizedText(value.verifiedAt == nil ? "未验证" : "已在本机验证")
                    .foregroundStyle(value.verifiedAt == nil ? .secondary : DoveTheme.green)
            }
            Text(verbatim: value.safetyNumber)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("chat.security.number")
            Button("复制安全码") { UIPasteboard.general.string = value.safetyNumber }
            DisclosureGroup("安全码二维码", isExpanded: $showsQR) {
                if let qrImage {
                    Image(uiImage: qrImage).interpolation(.none).resizable().scaledToFit()
                        .frame(maxWidth: 300).padding(12).background(.white)
                        .accessibilityLabel("安全码二维码")
                }
                Text("让对方扫描此码，或扫描对方的安全码二维码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("扫描对方安全码") { actionMessage = nil; isScanning = true }
                .accessibilityIdentifier("chat.security.scan")
            if let actionMessage { AppLocalizedText(actionMessage).font(.footnote).foregroundStyle(.secondary) }
            if value.verifiedAt != nil {
                Button("取消本机验证", role: .destructive) { Task { await setVerified(false, expectedBinding: value.binding) } }
            } else {
                Button("标记已验证") { verificationCandidate = value.binding; confirmingVerification = true }
                    .accessibilityIdentifier("chat.security.verify")
            }
        } header: { Text("安全码与身份验证") }
        footer: { Text("IMIM 520 位安全码，与现有网页版兼容；不是 Signal 官方 60 位安全码。") }
        .disabled(isSaving || loadGate.isLoading)

        Section {
            fingerprintRow("你的 Identity Key", value: value.localFingerprint)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: peerName).font(.subheadline)
                fingerprintRow("对方的 Identity Key", value: value.remoteFingerprint)
            }
        } header: { Text("身份公钥指纹") }

        Section {
            LabeledContent("会话状态") { Text("已建立") }
            LabeledContent("当前发送链计数") { Text(verbatim: String(value.sendCounter)) }
            LabeledContent("当前接收链计数") { Text(verbatim: String(value.receiveCounter)) }
            if let date = value.verifiedAt {
                LabeledContent("本机验证时间") { Text(date, format: .dateTime.year().month().day().hour().minute()) }
            }
        } header: { Text("本机会话") }
        footer: { Text("链计数会随密钥棘轮更新而重置，不是累计消息数。") }
    }

    private func fingerprintRow(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
        }
    }

    @MainActor private func expireRead(_ ticket: UInt64) {
        guard loadGate.finish(ticket) else { return }
        info = nil; qrImage = nil; confirmingVerification = false; verificationCandidate = nil
        loadError = "安全信息读取超时，请点击刷新重试。不会重置密钥或聊天记录。"
    }

    @MainActor private func reload() async {
        let ticket = loadGate.begin()
        loadError = nil
        guard scenePhase != .background, let peerID, !peerID.isEmpty,
              !ownerID.isEmpty, let token = AuthTokenStore.shared.token, !token.isEmpty else {
            loadGate.finish(ticket)
            info = nil; qrImage = nil
            loadError = "账号或联系人信息尚未就绪，请返回聊天后重试。"
            return
        }
        let owner = ownerID
        do {
            let value = try await E2EEManager.shared.peerSecurityInfo(ownerID: owner, peerID: peerID)
            if Task.isCancelled { loadGate.finish(ticket); return }
            guard loadGate.finish(ticket) else { return }
            guard owner == ownerID, token == AuthTokenStore.shared.token, scenePhase != .background else {
                info = nil; qrImage = nil; loadError = "账号或联系人信息尚未就绪，请返回聊天后重试。"; return
            }
            if info?.binding != value.binding {
                qrImage = QRCodeGenerator.makeImage(from: value.qrPayload)
                confirmingVerification = false; actionMessage = nil
            }
            info = value; loadError = nil
        } catch {
            if Task.isCancelled { loadGate.finish(ticket); return }
            guard loadGate.finish(ticket) else { return }
            guard owner == ownerID, token == AuthTokenStore.shared.token, scenePhase != .background else {
                info = nil; qrImage = nil; loadError = "账号或联系人信息尚未就绪，请返回聊天后重试。"; return
            }
            info = nil; qrImage = nil; confirmingVerification = false
            switch error as? E2EESecurityInfoError {
            case .identityChanged: loadError = "身份密钥已变化，旧验证已失效，请重新核对。"
            case .noSession: loadError = "本机尚无可核验的私聊会话。请先成功收发一条加密消息，再查看安全码。"
            default: loadError = "暂时无法读取安全信息，请稍后重试。"
            }
        }
    }

    @MainActor private func setVerified(_ verified: Bool, expectedBinding: String?) async {
        guard let value = currentInfo, value.binding == expectedBinding, !isSaving,
              let token = AuthTokenStore.shared.token else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await E2EEManager.shared.setPeerVerified(ownerID: value.ownerID, peerID: value.peerID,
                expectedBinding: value.binding, verified: verified)
            guard !Task.isCancelled, ownerID == value.ownerID, token == AuthTokenStore.shared.token else { return }
            await reload()
        } catch {
            guard ownerID == value.ownerID, token == AuthTokenStore.shared.token else { return }
            await reload()
            actionMessage = "验证未保存，密钥或账号可能已变化，请重新核对。"
        }
    }

    private func checkScannedCode() {
        guard let payload = scannedPayload else { return }
        scannedPayload = nil
        actionMessage = currentInfo?.matchesQR(payload) == true
            ? "二维码匹配。请确认对方身份后，点击标记已验证。"
            : "二维码不匹配。请确认这是对方当前会话的安全码，不要标记已验证。"
    }
}

private struct SecurityCodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onResult: (String) -> Void
    @State private var cameraReady = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if cameraReady, DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    SecurityCodeScanner(onResult: onResult) {
                        failure = "扫描不可用，请当面对比完整安全码。"
                        cameraReady = false
                    }
                } else if let failure {
                    AppLocalizedText(failure).padding()
                } else { ProgressView("正在打开相机…") }
            }
            .navigationTitle("扫描对方安全码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .task {
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard !Task.isCancelled else { return }
            cameraReady = allowed && DataScannerViewController.isSupported && DataScannerViewController.isAvailable
            if !cameraReady { failure = "相机不可用或未授权。可在系统设置允许相机，或当面对比完整安全码。" }
        }
    }
}

private struct SecurityCodeScanner: UIViewControllerRepresentable {
    let onResult: (String) -> Void
    let onFailure: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        DispatchQueue.main.async {
            do { try controller.startScanning() } catch { onFailure() }
        }
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onResult: (String) -> Void
        private var finished = false
        init(onResult: @escaping (String) -> Void) { self.onResult = onResult }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    finished = true; dataScanner.stopScanning(); onResult(payload); return
                }
            }
        }
    }
}

private struct AIConsentPanel: View {
    @Environment(\.dismiss) private var dismiss
    let kind: AIConsentKind
    let accept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("imim AI · DeepSeek", systemImage: kind == .text ? "sparkles" : "mic.fill")
                .font(.title3.bold())
            AppLocalizedText(kind == .text
                ? "本次消息及此 AI 会话的近期文字会发送给 DeepSeek 处理，不会上传你的其他私人聊天。"
                : "语音仅在本机识别。按住输入栏说话，松开发送，上滑取消；右侧声波按钮开启连续对话，停顿后自动发送。识别文字会交给 DeepSeek，回复由系统朗读，不上传录音或其他私人聊天。离开页面或进入后台会停止麦克风。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                accept()
                dismiss()
            } label: {
                AppLocalizedText(kind == .text ? "同意并发送" : "同意并继续")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(DoveTheme.green)
            Button(AppLocalization.string("取消"), role: .cancel) { dismiss() }
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// A narrow native touch surface keeps press/release/cancel ordering independent
// from SwiftUI GestureState reset, while the actual TextField stays mounted.
private struct AIInputTouchSurface: UIViewRepresentable {
    var isEnabled: Bool
    var onTap: () -> Void
    var onHoldBegan: () -> Void
    var onHoldMoved: (Bool) -> Void
    var onHoldEnded: (Bool) -> Void
    var exposesAccessibility = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> AIInputTouchView {
        let view = AIInputTouchView()
        view.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.25
        hold.allowableMovement = 30
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: hold)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(tap)
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: AIInputTouchView, context: Context) {
        context.coordinator.parent = self
        view.isAccessibilityElement = exposesAccessibility
        view.isUserInteractionEnabled = isEnabled
        view.activate = onTap
        view.accessibilityLabel = AppLocalization.string("发消息或按住说话…")
        view.accessibilityHint = AppLocalization.string("点按输入文字，按住说话，松开发送，上滑取消")
        view.accessibilityIdentifier = "ai.voice.holdToTalk"
    }
    static func dismantleUIView(_ view: AIInputTouchView, coordinator: Coordinator) { coordinator.finish(cancelled: true) }

    final class AIInputTouchView: UIView {
        var activate: (() -> Void)?
        override func accessibilityActivate() -> Bool { activate?(); return true }
    }
    @MainActor final class Coordinator: NSObject {
        var parent: AIInputTouchSurface
        var interaction = AIHoldInteraction()
        var startY: CGFloat = 0
        init(_ parent: AIInputTouchSurface) { self.parent = parent }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended, parent.isEnabled { parent.onTap() }
        }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard parent.isEnabled, interaction.begin() else { return }
                startY = gesture.location(in: nil).y
                parent.onHoldBegan()
            case .changed:
                interaction.move(vertical: Double(gesture.location(in: nil).y - startY))
                parent.onHoldMoved(interaction.isCancelling)
            case .ended:
                interaction.move(vertical: Double(gesture.location(in: nil).y - startY))
                finish(cancelled: false)
            case .cancelled, .failed: finish(cancelled: true)
            default: break
            }
        }
        func finish(cancelled: Bool) {
            guard let cancelled = interaction.finish(cancelled: cancelled) else { return }
            parent.onHoldMoved(false)
            parent.onHoldEnded(cancelled)
        }
    }
}

/// AI text keeps inline typography inside the shared conversation bubble.
/// Model-supplied links never acquire new interactive URL actions.
private enum AIAssistantTypography {
    static func formattedReply(_ content: String) -> AttributedString {
        var result = (try? AttributedString(markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
        // Only typography: do not add interactive model-supplied URL actions.
        result.link = nil
        return result
    }
}


private struct AIMessageComposer: View {
    @ObservedObject var voice: AIVoiceController
    let insertion: ComposerInsertion?
    let isSending: Bool
    @FocusState.Binding var isInputFocused: Bool
    let onSend: (String) -> Void
    let onStartConversation: () -> Void
    let onHoldBegan: () -> Void
    let onHoldEnded: (Bool) -> Void
    let onStop: () -> Void
    @State private var inputText = ""
    @State private var isCancellingHold = false
    @State private var isShowingEmojiPanel = false

    private var canSend: Bool { !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var audioBusy: Bool { voice.isPreparing || voice.isFinalizingHold || voice.isHoldingToTalk }

    private var holdHint: String {
        if voice.isFinalizingHold { return "正在转写…" }
        if voice.isPreparing { return "正在准备麦克风…" }
        if voice.isHoldingToTalk { return isCancellingHold ? "松开取消" : "松开发送，上滑取消" }
        return "发消息或按住说话…"
    }

    private var status: String? {
        if let error = voice.errorMessage { return error }
        if let hint = voice.hintMessage { return hint }
        if voice.isHoldingToTalk || voice.isFinalizingHold || voice.isPreparing { return holdHint }
        if voice.isListening { return "正在聆听，停顿后自动发送" }
        if voice.isPaused { return "朗读已暂停" }
        if voice.isSpeaking { return "正在朗读回复…" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status {
                HStack(spacing: 8) {
                    Image(systemName: voice.errorMessage != nil ? "exclamationmark.circle" : voice.isHoldingToTalk || voice.isListening ? "mic.fill" : "waveform")
                        .foregroundStyle(isCancellingHold ? Color.red : DoveTheme.green)
                    AppLocalizedText(status)
                        .foregroundStyle(voice.errorMessage == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if voice.isSpeaking {
                        Button { voice.togglePause() } label: {
                            Image(systemName: voice.isPaused ? "play.fill" : "pause.fill").frame(width: 36, height: 44)
                        }
                        .accessibilityLabel(AppLocalization.string(voice.isPaused ? "继续朗读" : "暂停朗读"))
                    }
                    if voice.isSpeaking || voice.conversationEnabled || isSending || audioBusy {
                        Button(action: onStop) {
                            Image(systemName: "stop.fill").frame(width: 36, height: 44)
                        }
                        .accessibilityLabel(AppLocalization.string(isSending ? "停止生成" : "结束语音"))
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if voice.isListening && !voice.transcript.isEmpty {
                Text(verbatim: voice.transcript)
                    .font(.body)
                    .lineLimit(4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DoveTheme.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }

            ConversationComposerLayout {
                Menu {
                    Toggle(isOn: $voice.autoReadReplies) {
                        Label(AppLocalization.string("朗读回复"), systemImage: "speaker.wave.2")
                    }
                    .accessibilityIdentifier("ai.voice.autoRead")
                    Button(action: onStartConversation) {
                        Label(AppLocalization.string("连续语音对话"), systemImage: "waveform")
                    }
                    .disabled(isSending || audioBusy)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DoveTheme.ink)
                        .frame(width: 40, height: 40)
                        .background(DoveTheme.warmGray.opacity(0.72), in: Circle())
                }
                .accessibilityLabel(AppLocalization.string("更多 AI 选项"))
            } field: {
                entry
            } accessory: {
                Button {
                    isInputFocused = false
                    isShowingEmojiPanel.toggle()
                } label: {
                    Image(systemName: isShowingEmojiPanel ? "keyboard.chevron.compact.down" : "face.smiling")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 40)
                }
                .accessibilityLabel(AppLocalization.string(isShowingEmojiPanel ? "关闭表情贴纸" : "打开表情贴纸"))
            } trailing: {
                if canSend || isSending {
                    Button {
                        if isSending { onStop() } else { submit() }
                    } label: {
                        Image(systemName: isSending ? "stop.fill" : "paperplane.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(DoveTheme.green, in: Circle())
                            .shadow(color: DoveTheme.green.opacity(0.24), radius: 10, y: 4)
                    }
                    .disabled(!isSending && (!canSend || audioBusy))
                    .accessibilityLabel(AppLocalization.string(isSending ? "停止生成" : "发送"))
                    .accessibilityIdentifier("ai.message.send")
                } else {
                    Button(action: toggleConversation) {
                        Image(systemName: voice.isHoldingToTalk || voice.conversationEnabled ? "waveform" : "mic.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(isCancellingHold ? Color.red : DoveTheme.green, in: Circle())
                            .shadow(color: DoveTheme.green.opacity(0.24), radius: 10, y: 4)
                    }
                    .disabled(voice.isFinalizingHold || (voice.isPreparing && !voice.isHoldingToTalk))
                    .accessibilityLabel(AppLocalization.string(voice.conversationEnabled ? "结束语音" : "连续语音对话"))
                    .accessibilityIdentifier("ai.voice.conversation")
                    .overlay {
                        AIInputTouchSurface(isEnabled: !isSending && !voice.isFinalizingHold && (!voice.isPreparing || voice.isHoldingToTalk),
                            onTap: toggleConversation, onHoldBegan: onHoldBegan,
                            onHoldMoved: { isCancellingHold = $0 }, onHoldEnded: onHoldEnded,
                            exposesAccessibility: false)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(DoveTheme.ink)
            if isShowingEmojiPanel {
                EmojiPickerPanel { emoji in
                    inputText += emoji
                    isShowingEmojiPanel = false
                    isInputFocused = true
                }
            }
        }
        .onChange(of: insertion?.id) { _, _ in
            guard let insertion else { return }
            inputText += insertion.text
        }
    }

    private var entry: some View {
        TextField(AppLocalization.string(holdHint), text: $inputText)
            .font(.system(size: 15))
            .lineLimit(1)
            .frame(height: 40)
            .focused($isInputFocused)
            .submitLabel(.send)
            .onSubmit(submit)
            .accessibilityIdentifier("ai.message.input")
            .overlay {
                if inputText.isEmpty && !isInputFocused {
                    AIInputTouchSurface(isEnabled: !isSending && !voice.isPreparing && !voice.isFinalizingHold, onTap: {
                        voice.stopAll()
                        isInputFocused = true
                    }, onHoldBegan: onHoldBegan, onHoldMoved: { isCancellingHold = $0 }, onHoldEnded: onHoldEnded)
                }
            }
    }

    private func toggleConversation() {
        isInputFocused = false
        isShowingEmojiPanel = false
        if voice.conversationEnabled && !voice.isSpeaking { onStop() }
        else { onStartConversation() }
    }

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !audioBusy else { return }
        inputText = ""
        onSend(text)
    }
}

private struct ComposerInsertion: Identifiable {
    let id = UUID()
    let text: String
}

private enum ChatComposerDraftPolicy {
    static func afterSubmission(current: String, submitted: String, accepted: Bool, cancelled: Bool) -> String {
        guard accepted, !cancelled, current == submitted else { return current }
        return ""
    }
}

/// One geometry/color authority for both peer and AI input rows.
private struct ConversationComposerLayout<Leading: View, Field: View, Accessory: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let field: () -> Field
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            leading()
            HStack(alignment: .center, spacing: 8) {
                field()
                accessory()
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
            trailing()
        }
    }
}

private struct ChatTextComposer: View {
    let insertion: ComposerInsertion?
    let placeholder: String
    let mediaEnabled: Bool
    let isSending: Bool
    let sendingStatus: String?
    @FocusState.Binding var isInputFocused: Bool
    @Binding var isShowingAttachmentPanel: Bool
    @Binding var isShowingMediaPanel: Bool
    let isRecording: Bool
    let canStartVoiceInput: Bool
    let onSend: @MainActor (String) async -> Bool
    let onVoiceTap: () -> Void
    let onVoiceChanged: (DragGesture.Value) -> Void
    let onVoiceEnded: (DragGesture.Value) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inputText = ""
    @State private var isSubmitting = false
    @State private var submissionTask: Task<Void, Never>?

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ConversationComposerLayout {
            if mediaEnabled {
            Button {
                isInputFocused = false
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
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
            .buttonStyle(ChatControlPressStyle())
            }

        } field: {
                TextField(placeholder, text: $inputText)
                    .font(.system(size: 15))
                    .focused($isInputFocused)
                    .lineLimit(1)
                    .submitLabel(.send)
                    .frame(height: 40)
                    .onTapGesture {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            isShowingMediaPanel = false
                            isShowingAttachmentPanel = false
                        }
                    }
                    .onSubmit {
                        submit()
                    }

        } accessory: {
                if mediaEnabled { Button {
                    let showPanel = !isShowingMediaPanel
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        isShowingAttachmentPanel = false
                        isShowingMediaPanel = showPanel
                    }
                    isInputFocused = !showPanel
                } label: {
                    Image(systemName: isShowingMediaPanel ? "keyboard.chevron.compact.down" : "face.smiling")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(ChatControlPressStyle())
                .accessibilityLabel(isShowingMediaPanel ? AppLocalization.text("关闭表情贴纸") : AppLocalization.text("打开表情贴纸"))
                }
        } trailing: {
            if canSend || !mediaEnabled || isSending || isSubmitting {
                Button {
                    submit()
                } label: {
                    Group {
                        if isSending || isSubmitting {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(DoveTheme.green, in: Circle())
                        .shadow(color: DoveTheme.green.opacity(0.24), radius: 10, y: 4)
                }
                .buttonStyle(ChatControlPressStyle())
                .disabled(!canSend || isSending || isSubmitting)
                .accessibilityLabel(AppLocalization.string(isSending || isSubmitting ? (sendingStatus ?? "正在发送…") : "发送消息"))
                .accessibilityIdentifier("chat.sendButton")
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
        .sensoryFeedback(.selection, trigger: (isShowingAttachmentPanel ? 1 : 0) + (isShowingMediaPanel ? 2 : 0))
        .onChange(of: insertion?.id) { _, _ in
            guard let insertion else { return }
            inputText += insertion.text
        }
        .onDisappear {
            submissionTask?.cancel()
            submissionTask = nil
            isSubmitting = false
        }
    }

    private func submit() {
        let content = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isSending, !isSubmitting else { return }
        let submittedDraft = inputText
        isSubmitting = true
        submissionTask = Task { @MainActor in
            defer { isSubmitting = false; submissionTask = nil }
            let accepted = await onSend(content)
            guard !Task.isCancelled else { return }
            // Keep unsent text and any new edits made while the request waited.
            inputText = ChatComposerDraftPolicy.afterSubmission(current: inputText, submitted: submittedDraft,
                accepted: accepted, cancelled: Task.isCancelled)
        }
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

                AppLocalizedText(title)
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
                            AppLocalizedText(item.rawValue)
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
    let peerUserId: String?
    let isCurrentUserAvatar: Bool
    let stickerViewport: StickerViewport
    let isForwardingRestricted: Bool
    let voiceRecorder: VoiceRecorderManager
    let onReply: () -> Void
    let onMention: () -> Void
    let onRecall: () -> Void
    let onRetry: () -> Void
    let onMediaRetry: () -> Void
    let onCall: (VideoCallType) -> Void
    var isAIConversation = false
    @AppStorage("chatTextScale") private var chatTextScale = 1.0
    @State private var imageRetryToken = UUID()
    @State private var videoPlayer: AVPlayer?
    @State private var isShowingVideo = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isOutgoing {
                Spacer(minLength: DoveTheme.Chat.avatarSize + 16)
            } else {
                DoveAvatar(name: peerName, url: peerAvatar, userId: peerUserId, size: DoveTheme.Chat.avatarSize)
                    .padding(.top, 4)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                bubbleContent
                    .contextMenu {
                        if message.type != "call" {
                        if !isForwardingRestricted {
                            Button {
                                UIPasteboard.general.string = message.content
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                        }

                        if !isAIConversation {
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
                        }
                    }

                HStack(spacing: 4) {
                    if message.isOutgoing && message.type != "call" {
                        deliveryStatusView
                    }
                    Text(message.createdAt.messageTimeText)
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.82))
                .padding(.horizontal, 4)
                if isAIConversation && !message.isOutgoing && message.status == "failed" && message.content != "AI 未完成回复，请重试" {
                    Label(AppLocalization.string("AI 未完成回复，请重试"), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.70, alignment: message.isOutgoing ? .trailing : .leading)

            if message.isOutgoing {
                DoveAvatar(name: peerName, url: peerAvatar, userId: peerUserId, size: DoveTheme.Chat.avatarSize,
                           allowsSourceUpdates: isCurrentUserAvatar)
                    .padding(.top, 4)
            } else {
                Spacer(minLength: DoveTheme.Chat.avatarSize + 16)
            }
        }
        .padding(.horizontal, DoveTheme.Chat.horizontalPadding)
        .padding(.vertical, 3)
        .sheet(isPresented: $isShowingVideo, onDismiss: {
            videoPlayer?.pause()
            videoPlayer = nil
        }) {
            NavigationStack {
                VideoPlayer(player: videoPlayer)
                    .onAppear { videoPlayer?.play() }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("关闭") { isShowingVideo = false }
                        }
                    }
            }
        }
    }

    private var bubbleContent: some View {
        Group {
            if message.type == "call" {
                callHistoryBubble
            } else if message.type == "voice" {
                ChatVoicePlaybackBubble(
                    message: message,
                    recorder: voiceRecorder
                ) {
                    if let url = CQIMMediaURL.resolve(message.voiceURL), url.isFileURL {
                        voiceRecorder.togglePlayback(messageId: message.messageId, urlString: url.absoluteString)
                    } else { onMediaRetry() }
                }
            } else if message.type == "sticker" || message.type == "gif" || message.type == "meme" {
                stickerBubble
            } else if message.stickerRenderSource != nil {
                stickerBubble
            } else if message.type == "image" {
                imageBubble
            } else if message.type == "video" {
                Button {
                    if let url = CQIMMediaURL.resolve(message.mediaURL), url.isFileURL {
                        videoPlayer = AVPlayer(url: url)
                        isShowingVideo = true
                    } else { onMediaRetry() }
                } label: { fileBubble }
                .buttonStyle(.plain)
            } else if message.type == "file" {
                fileBubble
            } else {
                textBubble
            }
        }
    }

    @ViewBuilder
    private var callHistoryBubble: some View {
        if let entry = CallHistoryEntry.decode(message) {
            Button { onCall(entry.mediaKind == "video" ? .video : .audio) } label: {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        AppLocalizedText(entry.titleKey)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DoveTheme.ink)
                        HStack(spacing: 5) {
                            Image(systemName: entry.isIncoming ? "arrow.down.left" : "arrow.up.right")
                                .foregroundStyle(entry.outcome == .completed ? Color.green : Color.red)
                                .accessibilityHidden(true)
                            if entry.connectedAt != nil {
                                Text(verbatim: entry.formattedDuration).monospacedDigit()
                            } else {
                                AppLocalizedText(entry.isIncoming ? "呼入" : "呼出")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Image(systemName: entry.mediaKind == "video" ? "video" : "phone")
                        .font(.title2)
                        .foregroundStyle(DoveTheme.accent)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(minWidth: 170, minHeight: 64, alignment: .leading)
                .background(bubbleBackground)
                .overlay(bubbleBorder)
                .clipShape(bubbleShape)
                .contentShape(bubbleShape)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("点击重新拨打"))
            .accessibilityIdentifier("chat.call.history")
        } else {
            // Never render malformed/local-to-another-account metadata as JSON.
            AppLocalizedText("通话记录不可用")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(12).background(bubbleBackground).clipShape(bubbleShape)
        }
    }

    @ViewBuilder
    private var textBubble: some View {
        if isAIConversation && message.content.isEmpty && message.status == "sending" {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                AppLocalizedText("AI 正在思考…").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DoveTheme.Chat.bubbleHPadding)
            .padding(.vertical, DoveTheme.Chat.bubbleVPadding)
            .background(bubbleBackground)
            .overlay(bubbleBorder)
            .clipShape(bubbleShape)
            .accessibilityIdentifier("ai.reply.thinking")
        } else if !isAIConversation && message.content.contains("等待密钥同步") {
            Button(action: onRetry) {
                Label(AppLocalization.string("消息暂无法解密，点按重试"), systemImage: "lock")
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
        messageText
            .tint(.blue)
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

    @ViewBuilder
    private var messageText: some View {
        if !isAIConversation {
            Text(ProxyMessageLinks.attributed(message.content))
        } else if message.isOutgoing {
            Text(verbatim: message.content)
        } else if message.status == "failed" && message.content == "AI 未完成回复，请重试" {
            AppLocalizedText(message.content)
        } else if message.senderId == "friend" && message.content == "你好，我是 imim AI，请直接告诉我你的问题。" {
            AppLocalizedText(message.content)
        } else {
            Text(AIAssistantTypography.formattedReply(message.content))
        }
    }

    private var imageBubble: some View {
        Group {
            if let url = CQIMMediaURL.resolve(message.mediaURL), url.isFileURL {
                AuthenticatedRemoteImage(url: url, contentMode: .fill) {
                    unavailableMediaView(title: "图片加载失败，点按重试", icon: "photo") {
                        imageRetryToken = UUID()
                        onMediaRetry()
                    }
                }
                .id(imageRetryToken)
                .frame(width: 190, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                unavailableMediaView(title: message.status == "sending" ? "正在发送图片..." : "图片未加载，点按重试", icon: "photo", retry: onMediaRetry)
            }
        }
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }

    private var stickerBubble: some View {
        VStack(spacing: 6) {
            if let source = message.stickerRenderSource {
                StickerAssetView(source: source, size: 176, viewport: stickerViewport)
            } else {
                stickerFallback
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
                AppLocalizedText(title)
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
        switch MessageDeliveryState.resolve(status: message.status, readAt: message.readAt) {
        case .sending:
            ProgressView()
                .scaleEffect(0.55)
        case .read:
            ZStack {
                Image(systemName: "checkmark").offset(x: -3)
                Image(systemName: "checkmark").offset(x: 3)
            }
            .frame(width: 18, height: 11)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.blue)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("已读"))
        case .sent:
            Image(systemName: "checkmark")
                .accessibilityLabel(Text("已发送"))
        case .failed:
            Text("发送失败")
                .foregroundStyle(DoveTheme.seal)
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
    var contentMode: SwiftUI.ContentMode = .fill
    var targetSize = CGSize(width: 190, height: 140)
    @ViewBuilder var failure: () -> Failure

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var didFail = false

    private struct DecodeRequest: Equatable {
        let url: URL
        let pixels: CGSize
        let fill: Bool
    }

    private var decodeRequest: DecodeRequest {
        DecodeRequest(url: url,
                      pixels: CGSize(width: targetSize.width * displayScale,
                                     height: targetSize.height * displayScale),
                      fill: contentMode == .fill)
    }

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
        .task(id: decodeRequest) {
            await load(decodeRequest)
        }
        .onDisappear { image = nil }
    }

    private func load(_ input: DecodeRequest) async {
        guard !Task.isCancelled else { return }
        image = nil
        didFail = false

        do {
            let thumbnail: CGImage
            if input.url.isFileURL {
                thumbnail = try await ChatImageDecoder.shared.decode(
                    fileURL: input.url, targetPixels: input.pixels, fill: input.fill)
            } else {
                var request = URLRequest(url: input.url)
                if let token = AuthTokenStore.shared.token, input.url.path.hasPrefix("/api/") {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw ChatImageDecoder.DecodeError.invalidImage
                }
                thumbnail = try await ChatImageDecoder.shared.decode(
                    data: data, targetPixels: input.pixels, fill: input.fill)
            }
            // A disappearing/reused view must never publish an obsolete result.
            try Task.checkCancellation()
            image = UIImage(cgImage: thumbnail, scale: max(1, displayScale), orientation: .up)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            didFail = true
        }
    }
}

// MARK: - Chat image decoder (isolated, no persistent plaintext cache)

/// Serial decoding bounds concurrent raster allocations and keeps file access
/// and ImageIO work off MainActor. Only the displayed thumbnail crosses back.
actor ChatImageDecoder {
    static let shared = ChatImageDecoder()
    enum DecodeError: Error { case invalidImage, invalidTarget }

    func decode(fileURL: URL, targetPixels: CGSize, fill: Bool) throws -> CGImage {
        try Task.checkCancellation()
        guard fileURL.isFileURL else { throw DecodeError.invalidImage }
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw DecodeError.invalidImage
            }
            return try thumbnail(source: source, targetPixels: targetPixels, fill: fill)
        }
    }

    func decode(data: Data, targetPixels: CGSize, fill: Bool) throws -> CGImage {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw DecodeError.invalidImage
            }
            return try thumbnail(source: source, targetPixels: targetPixels, fill: fill)
        }
    }

    private func thumbnail(source: CGImageSource, targetPixels: CGSize, fill: Bool) throws -> CGImage {
        #if CHAT_IMAGE_DECODER_TESTS
        precondition(!Thread.isMainThread, "Image decoding must leave the UI thread")
        #endif
        guard targetPixels.width.isFinite, targetPixels.height.isFinite,
              targetPixels.width > 0, targetPixels.height > 0 else { throw DecodeError.invalidTarget }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw DecodeError.invalidImage
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let width = rotated ? rawHeight.doubleValue : rawWidth.doubleValue
        let height = rotated ? rawWidth.doubleValue : rawHeight.doubleValue
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw DecodeError.invalidImage }
        let x = Double(targetPixels.width) / width
        let y = Double(targetPixels.height) / height
        // Retain aspect-fill detail, but cap extreme aspect ratios / oversized
        // targets to a 4096px edge and four-megapixel thumbnail raster budget.
        let scale = min(1, fill ? max(x, y) : min(x, y),
                        4096 / max(width, height), sqrt(4_000_000 / width / height))
        let maxPixelSize = max(1, Int(floor(max(width, height) * scale)))
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw DecodeError.invalidImage }
        try Task.checkCancellation()
        return image
    }
}

// MARK: - End chat image decoder

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
        let time = formatted(.dateTime.hour().minute().locale(AppLanguage.current.locale))
        if calendar.isDateInToday(self) {
            return AppLocalization.text("今天 \(time)")
        }
        if calendar.isDateInYesterday(self) {
            return AppLocalization.text("昨天 \(time)")
        }
        return formatted(.dateTime.month().day().hour().minute().locale(AppLanguage.current.locale))
    }
}

// MARK: - Bottom scroll policy (value-only, no messages or persistence)

/// Owned by ChatDetailView's UI state. A single deferred callback can serve a
/// burst of requests; obsolete callbacks cannot consume a newer request.
struct ChatBottomScrollPolicy {
    enum Reason: Int {
        case historyLoaded, incoming, outgoing, initial

        var requiresNearBottom: Bool { self == .historyLoaded || self == .incoming }
        var animated: Bool { self == .incoming || self == .outgoing }
    }

    private var generation: UInt64 = 0
    private var pending: (ticket: UInt64, reason: Reason)?

    mutating func request(_ reason: Reason, isNearBottom: Bool, isUserScrolling: Bool) -> UInt64? {
        guard !isUserScrolling, !reason.requiresNearBottom || isNearBottom else { return nil }
        if let current = pending {
            if reason.rawValue > current.reason.rawValue {
                pending = (current.ticket, reason)
            }
            return nil
        }
        generation &+= 1
        pending = (generation, reason)
        return generation
    }

    mutating func cancel() {
        pending = nil
    }

    /// nil = no scroll; false = immediate; true = animated. User intent is
    /// rechecked at delivery. Near-bottom eligibility belongs to admission:
    /// newly appended tall media can move the bottom out of range by itself.
    /// Never enqueue a replay after user drag.
    mutating func consume(_ ticket: UInt64, isUserScrolling: Bool, reduceMotion: Bool) -> Bool? {
        guard let current = pending, current.ticket == ticket else { return nil }
        pending = nil
        guard !isUserScrolling else { return nil }
        return current.reason.animated && !reduceMotion
    }
}

// MARK: - End bottom scroll policy

private struct ChatUserScrollTracking: ViewModifier {
    let changed: (Bool) -> Void
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                // Programmatic .animating is not a user gesture; include inertia
                // so incoming messages cannot interrupt a user's deceleration.
                changed(phase == .tracking || phase == .interacting || phase == .decelerating)
            }
        } else {
            // iOS 17 lacks scroll phases. Observe touch drag simultaneously;
            // GestureState also resets on cancellation. Do not replace scrolling.
            content
                .simultaneousGesture(DragGesture().updating($isDragging) { _, dragging, _ in
                    dragging = true
                })
                .onChange(of: isDragging) { _, dragging in changed(dragging) }
        }
    }
}

private struct MessageBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
