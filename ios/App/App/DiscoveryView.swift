import AVFoundation
import AVKit
import CryptoKit
import Kingfisher
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Native Moments keeps the web feed's quiet, edge-to-edge timeline while
/// preserving native loading, publishing and media viewing behavior.
struct DiscoveryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var viewModel = MomentsFeedViewModel()
    @State private var isShowingComposer = false
    @State private var isShowingCoverActions = false
    @State private var selectedCoverSource: ImagePickerView.Source?
    @State private var coverPreview: UIImage?
    @State private var coverURL = ""
    @State private var profileName: String?
    @State private var profileAvatar: String?
    @State private var isUploadingCover = false
    @State private var coverUploadError: String?
    @State private var coverProfileError: String?
    @State private var coverReloadID = UUID()

    var body: some View {
        ZStack {
            MomentsPalette.pageBackground.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    profileCover
                    feed
                }
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                async let feed: Void = viewModel.refresh()
                async let profile: Void = refreshProfileCover()
                _ = await (feed, profile)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            loadSavedCover()
            async let feed: Void = viewModel.loadIfNeeded()
            async let profile: Void = refreshProfileCover()
            _ = await (feed, profile)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cqimProfileDidChange)) { _ in
            Task { await refreshProfileCover() }
        }
        .confirmationDialog("朋友圈", isPresented: $isShowingCoverActions, titleVisibility: .visible) {
            Button("发布动态") {
                isShowingComposer = true
            }
            Button("从相册更换封面") {
                selectedCoverSource = .photoLibrary
            }
            Button("拍照更换封面") {
                selectedCoverSource = .camera
            }
            if !coverURL.isEmpty || coverPreview != nil {
                Button("恢复默认封面", role: .destructive) {
                    resetCover()
                }
            }
        }
        .sheet(item: $selectedCoverSource) { source in
            if source == .camera {
                DualCameraView(allowsVideo: false) { result in
                    if case .photo(let data) = result, let image = UIImage(data: data) { updateCover(with: image) }
                }
            } else {
                ImagePickerView(source: source, allowsEditing: false) { image in
                    updateCover(with: image)
                }
            }
        }
        .sheet(isPresented: $isShowingComposer) {
            MomentComposerSheet { content, media in
                try await viewModel.publish(content: content, media: media)
            }
            .presentationDetents([.medium])
            .presentationBackground(MomentsPalette.pageBackground)
        }
        .alert("封面更新失败", isPresented: Binding(
            get: { coverUploadError != nil },
            set: { if !$0 { coverUploadError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(coverUploadError ?? AppLocalization.text("请稍后重试"))
        }
    }

    private var profileCover: some View {
        let name = profileName
            ?? nonBlank(UserDefaults.standard.string(forKey: "current_user_name"))
            ?? nonBlank(UserDefaults.standard.string(forKey: "current_user_account"))
            ?? "IMIM"
        let avatar = profileAvatar ?? UserDefaults.standard.string(forKey: "current_user_avatar")

        return ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                coverImage
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
                .frame(height: 226)
                .overlay {
                    LinearGradient(
                        colors: [Color.black.opacity(0.06), Color.black.opacity(0.40)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .overlay(alignment: .top) {
                    HStack {
                        Text("朋友圈")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.32), radius: 4, y: 2)

                        Spacer()

                        Button {
                            isShowingComposer = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 25, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("发布朋友圈")

                        Button {
                            isShowingCoverActions = true
                        } label: {
                            if isUploadingCover {
                                ProgressView().tint(.white)
                                    .frame(width: 42, height: 42)
                            } else {
                                Image(systemName: "camera")
                                    .font(.system(size: 21, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 42, height: 42)
                                    .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isUploadingCover)
                        .accessibilityLabel("更换朋友圈封面")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                }

            HStack(alignment: .bottom, spacing: 11) {
                Spacer(minLength: 8)

                Text(name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.48), radius: 3, y: 1)
                    .padding(.bottom, 8)

                MomentAvatar(name: name, url: avatar, userId: UserDefaults.standard.string(forKey: "current_user_id"),
                             size: 68, allowsSourceUpdates: true)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.white, lineWidth: 3)
                    }
                    .shadow(color: .black.opacity(0.24), radius: 8, y: 4)
                    .offset(y: 32)
            }
            .padding(.trailing, 18)
        }
        .frame(height: 226)
        .padding(.bottom, 46)
    }

    @ViewBuilder
    private var coverImage: some View {
        if let coverPreview {
            Image(uiImage: coverPreview)
                .resizable()
                .scaledToFill()
        } else if let url = momentURL(coverURL) {
            MomentCachedImage(url: url, pixels: 1536) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                case .failure:
                    coverFailure
                case .empty:
                    coverLoading
                @unknown default:
                    coverFailure
                }
            }
            .id(coverReloadID)
        } else {
            if coverProfileError != nil {
                coverFailure
            } else {
                defaultCover
            }
        }
    }

    private var coverLoading: some View {
        defaultCover
            .overlay {
                ProgressView()
                    .tint(.white.opacity(0.8))
                    .accessibilityLabel("正在加载封面")
            }
    }

    private var coverFailure: some View {
        defaultCover
            .overlay(alignment: .bottomLeading) {
                Button {
                    coverReloadID = UUID()
                    Task { await refreshProfileCover() }
                } label: {
                    Label("封面加载失败，点按重试", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.24), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 18)
                .padding(.bottom, 18)
            }
    }

    private var defaultCover: some View {
        ZStack {
            LinearGradient(
                colors: [MomentsPalette.coverSlate, MomentsPalette.coverCharcoal],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.18), .clear],
                center: .topLeading,
                startRadius: 4,
                endRadius: 240
            )

            RadialGradient(
                colors: [MomentsPalette.accent.opacity(0.13), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 260
            )

            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.12))
                .offset(x: 118, y: 42)
        }
    }

    private var coverDefaultsKey: String {
        let userID = UserDefaults.standard.string(forKey: "current_user_id") ?? "current"
        return "moments_profile_cover_url.\(userID)"
    }

    private func loadSavedCover() {
        coverURL = UserDefaults.standard.string(forKey: coverDefaultsKey) ?? ""
    }

    private func refreshProfileCover() async {
        guard !isUploadingCover else { return }
        do {
            let profile = try await APIClient.shared.fetchCurrentProfile()
            guard !Task.isCancelled, !isUploadingCover else { return }
            profileName = nonBlank(profile.nickname) ?? nonBlank(profile.name) ?? nonBlank(profile.id)
            profileAvatar = nonBlank(profile.avatar)
            AvatarImageLoader.shared.prefetch([.init(userId: profile.id, urlString: momentAvatarSource(profileAvatar))])
            if let profileName { UserDefaults.standard.set(profileName, forKey: "current_user_name") }
            if let profileAvatar { UserDefaults.standard.set(profileAvatar, forKey: "current_user_avatar") }
            coverProfileError = nil
            // Empty is authoritative too: a cover removed on Web must not
            // reappear from this installation's cached URL.
            coverURL = nonBlank(profile.backgroundUrl) ?? ""
            UserDefaults.standard.set(coverURL, forKey: coverDefaultsKey)
        } catch {
            guard !Task.isCancelled else { return }
            coverProfileError = error.localizedDescription
        }
    }

    private func updateCover(with image: UIImage) {
        coverPreview = image
        isUploadingCover = true

        Task {
            defer { isUploadingCover = false }
            do {
                guard let data = image.jpegData(compressionQuality: 0.86) else {
                    throw APIClientError.server("无法处理这张封面图片")
                }
                let uploaded = try await APIClient.shared.uploadMomentMedia(
                    data: data,
                    fileName: "moment-cover-\(UUID().uuidString).jpg",
                    mimeType: "image/jpeg",
                    type: "image"
                )
                try await APIClient.shared.updateMomentCover(backgroundURL: uploaded.url)
                coverURL = uploaded.url
                coverProfileError = nil
                UserDefaults.standard.set(uploaded.url, forKey: coverDefaultsKey)
                coverPreview = nil
                coverReloadID = UUID()
            } catch {
                coverUploadError = error.localizedDescription
            }
        }
    }

    private func resetCover() {
        coverPreview = nil
        coverURL = ""
        coverProfileError = nil
        coverReloadID = UUID()
        UserDefaults.standard.removeObject(forKey: coverDefaultsKey)
        Task {
            do {
                try await APIClient.shared.updateMomentCover(backgroundURL: "")
            } catch {
                coverUploadError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var feed: some View {
        let shouldReduceMotion = reduceMotion
        if viewModel.isLoading && viewModel.moments.isEmpty {
            loadingView
        } else if let errorMessage = viewModel.errorMessage, viewModel.moments.isEmpty {
            errorView(errorMessage)
        } else if viewModel.moments.isEmpty {
            emptyView
        } else {
            ForEach(viewModel.moments) { moment in
                MomentFeedRow(moment: moment, isLiking: viewModel.likingMomentIDs.contains(moment.id)) {
                    viewModel.toggleLike(moment.id)
                } onComment: { content in
                    try await viewModel.comment(on: moment.id, content: content)
                }
                .scrollTransition(.interactive, axis: .vertical) { content, phase in
                    content
                        .opacity(phase.isIdentity || shouldReduceMotion ? 1 : 0.90)
                        .scaleEffect(phase.isIdentity || shouldReduceMotion ? 1 : 0.985)
                }
            }

            if viewModel.hasMore {
                Button {
                    Task { await viewModel.loadMore() }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isLoadingMore {
                            ProgressView().tint(MomentsPalette.mint)
                        } else {
                            Text("加载更多")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(MomentsPalette.mint)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 20)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView().tint(MomentsPalette.mint)
            Text("正在加载朋友圈...")
                .foregroundStyle(MomentsPalette.secondaryText)
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private var emptyView: some View {
        VStack(spacing: 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(MomentsPalette.mint)
            Text("暂无朋友圈动态")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MomentsPalette.primaryText)
            Text("好友发布动态后会显示在这里。")
                .font(.system(size: 13))
                .foregroundStyle(MomentsPalette.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 58)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            AppLocalizedText(message)
                .font(.system(size: 14))
                .foregroundStyle(.red.opacity(0.9))
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await viewModel.refresh() }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(MomentsPalette.onAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(MomentsPalette.mint, in: Capsule())
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .padding(.horizontal, 24)
    }
}

@MainActor
private final class MomentsFeedViewModel: ObservableObject {
    @Published private(set) var moments: [MomentFeedItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published private(set) var hasMore = false
    @Published private(set) var likingMomentIDs: Set<String> = []

    private var nextCursor: String?
    private var refreshGeneration = UUID()
    private var paginationGeneration = UUID()

    func loadIfNeeded() async {
        guard moments.isEmpty else { return }
        await refresh()
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        let owner = MomentImagePipeline.owner
        refreshGeneration = generation
        // A refreshed first page supersedes any in-flight old cursor page.
        paginationGeneration = UUID()
        isLoadingMore = false
        isLoading = true
        errorMessage = nil
        defer { if refreshGeneration == generation { isLoading = false } }

        do {
            let response = try await APIClient.shared.fetchMomentsFeed()
            guard !Task.isCancelled, refreshGeneration == generation,
                  MomentImagePipeline.owner == owner else { return }
            var seen = Set<String>()
            moments = response.moments.filter { seen.insert($0.id).inserted }
            prefetchAvatars(moments)
            MomentImagePipeline.prefetch(moments)
            nextCursor = response.nextCursor
            hasMore = response.hasMore ?? false
        } catch {
            guard !Task.isCancelled, !Self.isCancellation(error), refreshGeneration == generation,
                  MomentImagePipeline.owner == owner else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !Task.isCancelled, !isLoading, !isLoadingMore, hasMore else { return }
        let generation = UUID()
        let refresh = refreshGeneration
        let owner = MomentImagePipeline.owner
        paginationGeneration = generation
        isLoadingMore = true
        defer { if paginationGeneration == generation { isLoadingMore = false } }

        do {
            let response = try await APIClient.shared.fetchMomentsFeed(cursor: nextCursor)
            guard !Task.isCancelled, paginationGeneration == generation,
                  refreshGeneration == refresh, MomentImagePipeline.owner == owner else { return }
            var existing = Set(moments.map(\.id))
            let additions = response.moments.filter { existing.insert($0.id).inserted }
            moments.append(contentsOf: additions)
            prefetchAvatars(additions)
            MomentImagePipeline.prefetch(additions)
            nextCursor = response.nextCursor
            hasMore = response.hasMore ?? false
        } catch {
            guard !Task.isCancelled, !Self.isCancellation(error), paginationGeneration == generation,
                  refreshGeneration == refresh, MomentImagePipeline.owner == owner else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    func toggleLike(_ momentId: String) {
        guard !likingMomentIDs.contains(momentId),
              let original = moments.first(where: { $0.id == momentId }) else { return }
        let owner = MomentImagePipeline.owner
        let generation = refreshGeneration
        likingMomentIDs.insert(momentId)
        let optimistic = original.updated(
            isLiked: !original.isLiked,
            likeCount: max(0, original.likeCount + (original.isLiked ? -1 : 1))
        )
        replace(optimistic)

        Task {
            defer { likingMomentIDs.remove(momentId) }
            guard !Task.isCancelled, MomentImagePipeline.owner == owner else { return }
            do {
                let result = try await APIClient.shared.toggleMomentLike(momentId: momentId)
                guard !Task.isCancelled, MomentImagePipeline.owner == owner,
                      refreshGeneration == generation,
                      let current = moments.first(where: { $0.id == momentId }) else { return }
                // Only merge like fields; never restore old content or comments.
                replace(current.updated(isLiked: result.liked, likeCount: result.likeCount))
            } catch {
                guard !Task.isCancelled, MomentImagePipeline.owner == owner,
                      refreshGeneration == generation,
                      let current = moments.first(where: { $0.id == momentId }) else { return }
                replace(current.updated(isLiked: original.isLiked, likeCount: original.likeCount))
                errorMessage = "点赞失败：\(error.localizedDescription)"
            }
        }
    }

    private func prefetchAvatars(_ items: [MomentFeedItem]) {
        AvatarImageLoader.shared.prefetch(items.map {
            .init(userId: $0.authorId, urlString: momentAvatarSource($0.authorAvatar))
        }, allowsSourceUpdates: false)
    }

    func publish(content: String, media: [MomentUploadSelection] = []) async throws {
        let owner = MomentImagePipeline.owner
        func checkOwner() throws {
            try Task.checkCancellation()
            guard MomentImagePipeline.owner == owner else { throw CancellationError() }
        }
        try checkOwner()
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !media.isEmpty else { throw MomentComposerError.emptyContent }

        var uploaded: [MomentCreateMedia] = []
        uploaded.reserveCapacity(media.count)
        for item in media {
            try checkOwner()
            uploaded.append(try await APIClient.shared.uploadMomentMedia(
                data: item.data,
                fileName: item.fileName,
                mimeType: item.mimeType,
                type: item.type
            ))
            try checkOwner()
        }
        try checkOwner()
        try await APIClient.shared.createMoment(content: normalized, media: uploaded)
        try checkOwner()
        await refresh()
    }

    func comment(on momentId: String, content: String) async throws {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw MomentComposerError.emptyContent }
        let owner = MomentImagePipeline.owner
        try Task.checkCancellation()
        try await APIClient.shared.createMomentComment(momentId: momentId, content: normalized)
        try Task.checkCancellation()
        guard MomentImagePipeline.owner == owner else { throw CancellationError() }
        await refresh()
    }

    private func replace(_ moment: MomentFeedItem) {
        guard let index = moments.firstIndex(where: { $0.id == moment.id }) else { return }
        moments[index] = moment
    }
}

private struct MomentFeedRow: View {
    let moment: MomentFeedItem
    let isLiking: Bool
    let onToggleLike: () -> Void
    let onComment: (String) async throws -> Void
    @State private var likePulse = false
    @State private var isComposingComment = false
    @State private var commentText = ""
    @State private var isSendingComment = false
    @State private var commentSendFailed = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MomentAvatar(name: moment.authorName, url: moment.authorAvatar, userId: moment.authorId, size: 40)

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(moment.authorName.isEmpty ? AppLocalization.text("IMIM 用户") : moment.authorName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(MomentsPalette.authorBlue)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }

                if !moment.content.isEmpty {
                    Text(moment.content)
                        .font(.system(size: 14))
                        .foregroundStyle(MomentsPalette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                MomentMediaGrid(media: moment.media)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()

                HStack(spacing: 10) {
                    Text(moment.createdAt.momentDateText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(MomentsPalette.tertiaryText)

                    Spacer(minLength: 8)

                    Menu {
                        Button(moment.isLiked ? AppLocalization.text("取消赞") : AppLocalization.text("赞"), action: onToggleLike)
                            .disabled(isLiking)
                        Button("评论") {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isComposingComment = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(MomentsPalette.authorBlue)
                            .frame(width: 36, height: 28)
                            .background(MomentsPalette.actionBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if moment.likeCount > 0 || moment.commentCount > 0 || !moment.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        Button {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.48)) {
                                likePulse = true
                            }
                            onToggleLike()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                withAnimation(.easeOut(duration: 0.16)) { likePulse = false }
                            }
                        } label: {
                            Label("\(moment.likeCount)", systemImage: moment.isLiked ? "heart.fill" : "heart")
                                .foregroundStyle(moment.isLiked ? MomentsPalette.like : MomentsPalette.authorBlue)
                                .scaleEffect(likePulse ? 1.15 : 1)
                                .contentTransition(.numericText())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLiking)

                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isComposingComment.toggle()
                            }
                        } label: {
                            Label("\(moment.commentCount)", systemImage: "bubble.left")
                                .foregroundStyle(MomentsPalette.authorBlue)
                                .contentTransition(.numericText())
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    if !moment.comments.isEmpty {
                        Divider().padding(.horizontal, 10)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(moment.comments) { comment in
                                commentTextView(comment)
                                    .font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    }
                    .background(MomentsPalette.actionBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                if isComposingComment {
                    HStack(spacing: 8) {
                        TextField("写下你的评论", text: $commentText)
                            .disabled(isSendingComment)
                            .font(.system(size: 14))
                            .foregroundStyle(MomentsPalette.primaryText)
                            .padding(.horizontal, 11)
                            .frame(height: 38)
                            .background(MomentsPalette.actionBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Button {
                            let content = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !content.isEmpty, !isSendingComment else { return }
                            isSendingComment = true
                            commentSendFailed = false
                            Task { @MainActor in
                                defer { isSendingComment = false }
                                do {
                                    try await onComment(content)
                                    commentText = ""
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        isComposingComment = false
                                    }
                                } catch {
                                    commentSendFailed = !(error is CancellationError)
                                }
                            }
                        } label: {
                            if isSendingComment { ProgressView().accessibilityLabel(Text("发送中")) }
                            else { Text("发送") }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MomentsPalette.authorBlue)
                        .buttonStyle(.plain)
                        .disabled(isSendingComment || commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if commentSendFailed {
                        Text("评论发送失败，请重试")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 17)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 64)
        }
    }

    private func commentTextView(_ comment: MomentComment) -> Text {
        let author = comment.userName.isEmpty ? "IMIM 用户" : comment.userName
        var line = Text(author).foregroundColor(MomentsPalette.authorBlue)
        if let replyName = nonBlank(comment.replyToUserName) {
            line = line + Text(" 回复 ").foregroundColor(MomentsPalette.primaryText)
                + Text(replyName).foregroundColor(MomentsPalette.authorBlue)
        }
        return line + Text(": " + (comment.isDeleted ? AppLocalization.text("该评论已删除") : comment.content))
            .foregroundColor(comment.isDeleted ? MomentsPalette.secondaryText : MomentsPalette.primaryText)
    }
}

private struct MomentMediaGrid: View {
    let media: [MomentMediaItem]
    @State private var selectedPhoto: MomentPhotoDestination?

    var body: some View {
        Group {
            if media.count == 1, let item = media.first {
                MomentMediaTile(item: item) {
                    selectedPhoto = MomentPhotoDestination(item: item)
                }
                .frame(maxWidth: 240, alignment: .leading)
            } else if !media.isEmpty {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: media.count == 2 || media.count == 4 ? 2 : 3),
                    spacing: 4
                ) {
                    ForEach(Array(media.prefix(9).enumerated()), id: \.offset) { _, item in
                        MomentMediaTile(item: item, isSquare: true) {
                            selectedPhoto = MomentPhotoDestination(item: item)
                        }
                    }
                }
                .frame(maxWidth: media.count == 2 || media.count == 4 ? 220 : 300, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .fullScreenCover(item: $selectedPhoto) { destination in
            MomentPhotoViewer(url: destination.url)
        }
    }
}

private struct MomentMediaTile: View {
    private struct ProbeRequest: Hashable { let item: MomentMediaItem; let retry: Int }
    let item: MomentMediaItem
    var isSquare = false
    let onOpen: () -> Void
    @State private var resolvedVideo: Bool?
    @State private var resolvedItem: MomentMediaItem?
    @State private var probeFailed = false
    @State private var probeRetry = 0

    private var currentResolution: Bool? { resolvedItem == item ? resolvedVideo : nil }

    var body: some View {
        Group {
            if item.isVideo || currentResolution == true {
                MomentVideoCard(item: item)
            } else if currentResolution == false || !MomentMediaPolicy.needsTypeProbe(momentURL(item.url)) {
                MomentMediaThumb(item: item, isSquare: isSquare, onOpen: onOpen)
            } else {
                Button { probeRetry += 1 } label: {
                    MomentsPalette.actionBackground
                        .aspectRatio(isSquare ? 1 : 4.0 / 3.0, contentMode: .fit)
                        .overlay {
                            if probeFailed {
                                Label("媒体识别失败，点按重试", systemImage: "arrow.clockwise")
                                    .font(.footnote)
                                    .foregroundStyle(MomentsPalette.secondaryText)
                                    .padding(12)
                            } else { ProgressView() }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!probeFailed)
            }
        }
        .task(id: ProbeRequest(item: item, retry: probeRetry)) {
            resolvedVideo = nil
            resolvedItem = item
            probeFailed = false
            guard !item.isVideo, MomentMediaPolicy.needsTypeProbe(momentURL(item.url)) else { return }
            let video = await MomentMediaTypeResolver.shared.isVideo(item.url)
            guard !Task.isCancelled else { return }
            resolvedVideo = video
            probeFailed = video == nil
        }
    }
}

private struct MomentVideoCard: View {
    private struct ThumbnailRequest: Hashable {
        let item: MomentMediaItem
        let owner: String
        let showingVideo: Bool
    }
    let item: MomentMediaItem
    @State private var isShowingVideo = false
    @StateObject private var thumbnail = MomentVideoThumbnailModel()
    @AppStorage("current_user_id") private var owner = "signed-out"

    private var playbackURL: URL? {
        momentURL(item.playbackURLString)
    }

    private var aspectRatio: CGFloat {
        guard let image = currentThumbnail, image.size.height > 0 else { return 16.0 / 9.0 }
        return image.size.width / image.size.height
    }

    private var currentThumbnail: UIImage? {
        guard MomentMediaPolicy.poster(item) == nil else { return nil }
        return thumbnail.currentImage(url: playbackURL, owner: owner)
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                ZStack {
                    if let image = currentThumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        MomentCachedImage(url: momentURL(MomentMediaPolicy.poster(item)), pixels: 720) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .clipped()
                            default:
                                LinearGradient(
                                    colors: [MomentsPalette.videoHighlight, MomentsPalette.videoBackground],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .overlay {
                                    Image(systemName: "video.fill")
                                        .font(.system(size: 26, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.30))
                                }
                            }
                        }
                    }

                    Color.black.opacity(0.10)

                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.26), in: Circle())
                        .overlay { Circle().stroke(.white.opacity(0.75), lineWidth: 1.25) }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                isShowingVideo = true
            }
            .fullScreenCover(isPresented: $isShowingVideo) {
                if let url = playbackURL {
                    MomentVideoPlayer(url: url)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView("视频地址无效", systemImage: "exclamationmark.triangle", description: Text("服务器没有返回可播放的视频地址。"))
                }
            }
            .task(id: ThumbnailRequest(item: item, owner: owner, showingVideo: isShowingVideo)) {
                thumbnail.reset()
                guard !isShowingVideo else { return }
                guard let playbackURL else { return }
                // Supplied posters are preferred. Never download an entire video
                // for a scrolling feed card; old clips reuse locally cached frames.
                if MomentMediaPolicy.poster(item) == nil {
                    await thumbnail.load(url: playbackURL)
                }
            }
            .onDisappear { thumbnail.reset() }
    }
}

private struct MomentMediaThumb: View {
    let item: MomentMediaItem
    var isSquare = false
    let onOpen: () -> Void
    @State private var retryID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MomentCachedImage(url: momentURL(MomentMediaPolicy.photo(item)), pixels: 720) { phase in
            switch phase {
            case .success(let image):
                mediaImage(image)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture(perform: onOpen)
                    .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.18)))
            case .failure:
                Button {
                    retryID = UUID()
                } label: {
                    unavailableMedia
                }
                .buttonStyle(.plain)
            default:
                loadingMedia
            }
        }
        .id(retryID)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: isSquare ? 4 : 6, style: .continuous))
    }

    @ViewBuilder
    private func mediaImage(_ image: Image) -> some View {
        if isSquare {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        image.resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                }
        } else {
            image.resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }

    private var loadingMedia: some View {
        ZStack {
            MomentsPalette.actionBackground
            ProgressView().tint(MomentsPalette.accent).scaleEffect(0.78)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(isSquare ? 1 : 4.0 / 3.0, contentMode: .fit)
    }

    private var unavailableMedia: some View {
        ZStack {
            MomentsPalette.actionBackground
            VStack(spacing: 7) {
                Image(systemName: "photo")
                    .font(.system(size: 22, weight: .medium))
                Text("加载失败，点按重试")
                    .font(.caption)
            }
            .foregroundStyle(MomentsPalette.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(isSquare ? 1 : 4.0 / 3.0, contentMode: .fit)
    }
}

private struct MomentPhotoDestination: Identifiable {
    let url: URL

    init?(item: MomentMediaItem) {
        let source = [item.url, item.mediumUrl, item.thumbUrl]
            .compactMap { value -> String? in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            .first
        guard let source, let url = momentURL(source) else { return nil }
        self.url = url
    }

    var id: String { url.absoluteString }
}

private struct MomentPhotoViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            MomentCachedImage(url: url, pixels: 2048) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 8)
                case .failure:
                    ContentUnavailableView("图片无法打开", systemImage: "photo.badge.exclamationmark", description: Text("请返回朋友圈后重新加载。"))
                        .foregroundStyle(.white)
                default:
                    ProgressView()
                        .tint(.white)
                }
            }

            Button(action: dismiss.callAsFunction) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 14)
            .padding(.trailing, 16)
            .accessibilityLabel("关闭图片预览")
        }
    }
}

private struct MomentAvatar: View {
    let name: String
    let url: String?
    var userId: String? = nil
    let size: CGFloat
    var allowsSourceUpdates = false

    var body: some View {
        DoveCachedAvatarImage(name: name, url: momentAvatarSource(url), userId: userId,
                              size: size, isGroup: false, allowsSourceUpdates: allowsSourceUpdates,
                              placeholderImage: placeholder)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.34), lineWidth: 1)
        }
    }

    private var placeholder: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            UIColor(MomentsPalette.avatarFallback).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let text = String(name.prefix(1)).uppercased() as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(14, size * 0.38), weight: .bold),
                .foregroundColor: UIColor(MomentsPalette.primaryText)
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2), withAttributes: attributes)
        }
    }
}

private struct MomentVideoPlayer: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var localURL: URL?
    @State private var errorMessage: String?
    @State private var retryID = 0
    @State private var forceDownload = false
    @State private var cacheInvalidation: Task<Void, Never>?
    @State private var loadGeneration = UUID()
    @AppStorage("current_user_id") private var owner = "signed-out"

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let localURL {
                let generation = loadGeneration
                let playbackOwner = owner
                NativeFullscreenVideoPlayer(url: localURL) {
                    handlePlaybackFailure(localURL, generation: generation, owner: playbackOwner)
                }
                    .ignoresSafeArea()
            } else if let errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                    Text("视频加载失败")
                    AppLocalizedText(errorMessage).font(.footnote).multilineTextAlignment(.center)
                    Button("重新加载") { retryID += 1 }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("正在加载视频…").foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel("关闭视频")
            .padding(16)
        }
        .task(id: "\(owner)|\(retryID)") { await loadVideo() }
        .onChange(of: owner) { _, _ in loadGeneration = UUID(); removeLocalVideo(); dismiss() }
        .onDisappear { loadGeneration = UUID(); removeLocalVideo() }
        .onReceive(NotificationCenter.default.publisher(for: .imimProxySessionDidChange)) { _ in
            // Stop any direct AVPlayer asset before applying changed Proxy rules.
            loadGeneration = UUID()
            removeLocalVideo()
            retryID += 1
        }
    }

    @MainActor
    private func loadVideo() async {
        let generation = UUID()
        loadGeneration = generation
        let owner = MomentImagePipeline.owner
        errorMessage = nil
        #if DEBUG
        MomentVideoDiagnostics.record("loadBegin opaqueMedia=\(MomentMediaPolicy.needsTypeProbe(url))")
        #endif
        do {
            await cacheInvalidation?.value
            try Task.checkCancellation()
            guard loadGeneration == generation, MomentImagePipeline.owner == owner else { return }
            if !forceDownload, !ProxyStore.shared.isChanging, ProxyStore.shared.active == nil {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 2
                let probeRequest = request
                let probe = try? await MomentMediaDeadline.run(after: .seconds(4), operation: {
                    try await MomentMediaRequests.shared.fetch(probeRequest, owner: owner)
                })
                #if DEBUG
                MomentVideoDiagnostics.record("probe http=\(probe?.status ?? 0) video=\(probe?.mime?.lowercased().hasPrefix("video/") == true) ranges=\(probe?.ranges?.lowercased() == "bytes")")
                #endif
                if let response = probe,
                   MomentMediaPolicy.mayStream(url: url, proxyEnabled: ProxyStore.shared.active != nil || ProxyStore.shared.isChanging,
                                               status: response.status, mime: response.mime, ranges: response.ranges) {
                    guard !Task.isCancelled, loadGeneration == generation, MomentImagePipeline.owner == owner else { return }
                    localURL = url
                    return
                }
            }
            try Task.checkCancellation()
            guard loadGeneration == generation, MomentImagePipeline.owner == owner else { return }
            let downloaded = try await MomentVideoAssetCache.shared.playerFile(for: url, owner: owner)
            if Task.isCancelled || loadGeneration != generation || MomentImagePipeline.owner != owner {
                try? FileManager.default.removeItem(at: downloaded)
                return
            }
            localURL = downloaded
            #if DEBUG
            MomentVideoDiagnostics.record("localFileReady")
            #endif
            await MomentVideoThumbnailModel.warm(url: url, owner: owner)
        } catch {
            guard !Task.isCancelled, loadGeneration == generation, MomentImagePipeline.owner == owner else { return }
            if (error as? URLError)?.code == .timedOut {
                errorMessage = "视频加载超时，请检查网络后重试。"
            } else if let mediaError = error as? MomentVideoLoadError {
                switch mediaError {
                case .http(401), .http(403): errorMessage = "无权访问此视频，请重新登录后重试。"
                case .http(404), .http(410): errorMessage = "视频文件不存在或已失效。"
                case .http: errorMessage = "视频服务暂时不可用，请稍后重试。"
                case .unsupportedContent: errorMessage = "服务器返回的内容不是可播放视频。"
                }
            } else {
                errorMessage = "请检查网络后重试；若仍失败，该视频文件可能不可用。"
            }
        }
    }

    private func removeLocalVideo() {
        guard let localURL else { return }
        if localURL.isFileURL { try? FileManager.default.removeItem(at: localURL) }
        self.localURL = nil
    }

    @MainActor
    private func handlePlaybackFailure(_ failedURL: URL, generation: UUID, owner: String) {
        guard localURL == failedURL, loadGeneration == generation,
              MomentImagePipeline.owner == owner else { return }
        loadGeneration = UUID()
        forceDownload = true
        #if DEBUG
        MomentVideoDiagnostics.record("playbackFailed localFile=\(failedURL.isFileURL)")
        #endif
        if !failedURL.isFileURL {
            removeLocalVideo()
            retryID += 1 // Streaming gets one full-download fallback.
        } else {
            // Do not leave a failed local player on a black screen, or reuse the
            // same broken cached bytes on the next explicit retry.
            localURL = nil
            errorMessage = "请检查网络后重试；若仍失败，该视频文件可能不可用。"
            let source = url
            cacheInvalidation = Task { @concurrent in
                await MomentVideoAssetCache.shared.invalidate(source, owner: owner, failedFile: failedURL)
                try? FileManager.default.removeItem(at: failedURL)
            }
        }
    }
}

private struct NativeFullscreenVideoPlayer: UIViewControllerRepresentable {
    let url: URL
    var onFailure: (() -> Void)? = nil

    @MainActor
    final class Coordinator {
        var observation: NSKeyValueObservation?
        var failedURL: URL?
        var generation = UUID()
        func observe(_ item: AVPlayerItem, url: URL, onFailure: (() -> Void)?) {
            reset()
            let generation = generation
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, self.failedURL != url else { return }
                    self.failedURL = url
                    onFailure?()
                }
            }
        }
        func reset() {
            generation = UUID()
            observation?.invalidate()
            observation = nil
            failedURL = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let item = AVPlayerItem(url: url)
        context.coordinator.observe(item, url: url, onFailure: onFailure)
        controller.player = AVPlayer(playerItem: item)
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        guard (uiViewController.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        uiViewController.player?.pause()
        let item = AVPlayerItem(url: url)
        context.coordinator.observe(item, url: url, onFailure: onFailure)
        uiViewController.player = AVPlayer(playerItem: item)
        uiViewController.player?.play()
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.reset()
        uiViewController.player?.pause()
        uiViewController.player = nil
    }
}

// MARK: - Moments media policy and scheduler

enum MomentVideoLoadError: Error { case http(Int), unsupportedContent }

/// Bound the whole cooperative transfer, including admission wait. URLRequest's
/// timeoutInterval only bounds idle time, not the total duration of a download.
enum MomentMediaDeadline {
    static func run<Value: Sendable>(after duration: Duration,
                                     operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}

enum MomentMediaPolicy {
    static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func photo(_ item: MomentMediaItem) -> String? {
        nonBlank(item.thumbUrl) ?? nonBlank(item.mediumUrl) ?? nonBlank(item.url)
    }

    static func poster(_ item: MomentMediaItem) -> String? {
        // `url` is frequently the video itself, NOT an image preview.
        [item.posterUrl, item.thumbUrl, item.mediumUrl].compactMap(nonBlank).first {
            $0 != item.playbackURLString && !["mp4", "mov", "m4v", "m3u8", "webm", "mkv"]
                .contains(URL(string: $0)?.pathExtension.lowercased() ?? "")
        }
    }

    static func needsTypeProbe(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.path.hasPrefix("/api/media/") && url.pathExtension.isEmpty
    }

    static func key(url: URL, owner: String) -> String {
        // Keep query/revision/signature: different source URLs must not alias.
        // Hash both so signed links/identifiers don't become file names or logs.
        let value = owner + "\u{0}" + url.absoluteString
        return "moments-v1-" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func mayStream(url: URL, proxyEnabled: Bool, status: Int, mime: String?, ranges: String?) -> Bool {
        guard !proxyEnabled, url.scheme == "https", status == 200 else { return false }
        if url.pathExtension.lowercased() == "m3u8" {
            return mime?.lowercased().contains("mpegurl") == true
        }
        return mime?.lowercased().hasPrefix("video/") == true
            && ranges?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "bytes"
    }
}

/// Cancellation-aware admission; no semaphore/thread blocking. Visible requests
/// precede queued speculative prefetch. A cancelled waiter never consumes a slot.
actor MomentTransferGate {
    private let limit: Int
    private var running = 0
    private struct Waiter {
        let id: UUID
        let speculative: Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    init(limit: Int) { self.limit = max(1, limit) }

    func run<T: Sendable>(speculative: Bool = false, operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        if running < limit { running += 1 }
        else {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiters.append(Waiter(id: id, speculative: speculative, continuation: continuation)) }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        guard !waiters.isEmpty else { running -= 1; return }
        let index = waiters.firstIndex(where: { !$0.speculative }) ?? 0
        waiters.remove(at: index).continuation.resume()
    }
}

struct MomentMediaResponse: Sendable {
    let data: Data
    let status: Int
    let mime: String?
    let ranges: String?
}

/// One transfer per account+full URL+method. Individual row cancellation releases
/// its lease; cancel the underlying task only when its last consumer disappears.
actor MomentMediaRequests {
    static let shared = MomentMediaRequests { request in
        let (data, response) = try await ProxySession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return MomentMediaResponse(data: data, status: http.statusCode, mime: http.mimeType,
                                   ranges: http.value(forHTTPHeaderField: "Accept-Ranges"))
    }
    private struct Job {
        let token: UUID
        let task: Task<MomentMediaResponse, Error>
        var consumers: Set<UUID>
    }
    private var jobs: [String: Job] = [:]
    private let gate: MomentTransferGate
    private let transport: @Sendable (URLRequest) async throws -> MomentMediaResponse
    init(limit: Int = 4, transport: @escaping @Sendable (URLRequest) async throws -> MomentMediaResponse) {
        gate = MomentTransferGate(limit: limit)
        self.transport = transport
    }
    func fetch(_ request: URLRequest, owner: String, speculative: Bool = false) async throws -> MomentMediaResponse {
        try Task.checkCancellation()
        guard let url = request.url else { throw URLError(.badURL) }
        let key = MomentMediaPolicy.key(url: url, owner: owner) + (request.httpMethod ?? "GET")
        let consumer = UUID()
        let job: Job
        if var existing = jobs[key] {
            existing.consumers.insert(consumer)
            jobs[key] = existing
            job = existing
        } else {
            let gate = gate, transport = transport
            let task = Task { @concurrent in
                try await gate.run(speculative: speculative) { try await transport(request) }
            }
            job = Job(token: UUID(), task: task, consumers: [consumer])
            jobs[key] = job
        }
        defer { release(key, token: job.token, consumer: consumer) }
        return try await withTaskCancellationHandler {
            let result = try await job.task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.release(key, token: job.token, consumer: consumer) }
        }
    }
    private func release(_ key: String, token: UUID, consumer: UUID) {
        guard var job = jobs[key], job.token == token else { return }
        job.consumers.remove(consumer)
        if job.consumers.isEmpty {
            job.task.cancel()
            jobs[key] = nil
        } else { jobs[key] = job }
    }
}

// MARK: - End Moments media policy and scheduler

private struct MomentImageProvider: ImageDataProvider {
    let url: URL
    let owner: String
    var speculative = false
    var cacheKey: String { MomentMediaPolicy.key(url: url, owner: owner) }
    var contentURL: URL? { url }
    func data() async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
        request.timeoutInterval = 25
        let result = try await MomentMediaRequests.shared.fetch(request, owner: owner, speculative: speculative)
        try Task.checkCancellation()
        guard (200...299).contains(result.status), !result.data.isEmpty,
              result.mime?.hasPrefix("video/") != true else { throw URLError(.badServerResponse) }
        return result.data
    }
}

@MainActor
private enum MomentImagePipeline {
    static let cache: ImageCache = {
#if MOMENTS_MEDIA_TESTS
        let cache = ImageCache(name: "IMIMMomentsFixture-" + CommandLine.arguments[1])
#else
        let cache = ImageCache(name: "IMIMMomentsImages-v1")
#endif
        cache.memoryStorage.config.totalCostLimit = 48 * 1024 * 1024
        cache.memoryStorage.config.countLimit = 120
        cache.diskStorage.config.sizeLimit = 160 * 1024 * 1024
        cache.diskStorage.config.expiration = .days(14)
        return cache
    }()
    static var owner: String {
#if MOMENTS_MEDIA_TESTS
        MomentFixtureOwner.value
#else
        UserDefaults.standard.string(forKey: "current_user_id") ?? "signed-out"
#endif
    }
    private static var prefetchTask: Task<Void, Never>?
    static func options(pixels: Int) -> KingfisherOptionsInfo {
        [.targetCache(cache), .processor(DownsamplingImageProcessor(size: CGSize(width: pixels, height: pixels))),
         .scaleFactor(1), .backgroundDecode, .waitForCache]
    }
    static func prefetch(_ feed: [MomentFeedItem]) {
        prefetchTask?.cancel()
        let owner = owner
        // Only six small, explicitly supplied images; never preload a video or
        // fall back to an original photo just to warm a below-the-fold cell.
        var seen = Set<URL>()
        let urls = feed.prefix(4).flatMap(\.media).compactMap { item -> URL? in
            let source = item.isVideo ? MomentMediaPolicy.poster(item)
                : MomentMediaPolicy.nonBlank(item.thumbUrl) ?? MomentMediaPolicy.nonBlank(item.mediumUrl)
            guard let url = momentURL(source), seen.insert(url).inserted else { return nil }
            return url
        }.prefix(6)
        prefetchTask = Task(priority: .utility) {
            for url in urls {
                guard !Task.isCancelled, self.owner == owner else { return }
                _ = try? await KingfisherManager.shared.retrieveImage(
                    with: .provider(MomentImageProvider(url: url, owner: owner, speculative: true)),
                    options: options(pixels: 720))
            }
        }
    }
}

@MainActor
private final class MomentImageModel: ObservableObject {
    @Published private(set) var phase: AsyncImagePhase = .empty
    private var identity = ""
    private var generation = UUID()
    static func identity(url: URL?, owner: String, pixels: Int) -> String {
        "\(owner)|\(url?.absoluteString ?? "")|\(pixels)"
    }
    func currentPhase(url: URL?, owner: String, pixels: Int) -> AsyncImagePhase {
        identity == Self.identity(url: url, owner: owner, pixels: pixels) ? phase : .empty
    }
    func reset() {
        generation = UUID()
        identity = ""
        phase = .empty
    }
    func load(url: URL?, owner: String, pixels: Int) async {
        let generation = UUID()
        self.generation = generation
        identity = Self.identity(url: url, owner: owner, pixels: pixels)
        phase = .empty
        guard let url, !Task.isCancelled, MomentImagePipeline.owner == owner else { return }
        let options = MomentImagePipeline.options(pixels: pixels)
        let provider = MomentImageProvider(url: url, owner: owner)
        if let image = MomentImagePipeline.cache.retrieveImageInMemoryCache(forKey: provider.cacheKey, options: options) {
            phase = .success(Image(uiImage: image))
            return
        }
        do {
            let result = try await KingfisherManager.shared.retrieveImage(with: .provider(provider), options: options)
            guard !Task.isCancelled, self.generation == generation, MomentImagePipeline.owner == owner else { return }
            phase = .success(Image(uiImage: result.image))
        } catch {
            guard !Task.isCancelled, self.generation == generation, MomentImagePipeline.owner == owner else { return }
            phase = .failure(error)
        }
    }
}

private struct MomentCachedImage<Content: View>: View {
    let url: URL?
    let pixels: Int
    @ViewBuilder let content: (AsyncImagePhase) -> Content
    @AppStorage("current_user_id") private var owner = "signed-out"
    @StateObject private var model = MomentImageModel()
    var body: some View {
        content(model.currentPhase(url: url, owner: owner, pixels: pixels))
            .task(id: MomentImageModel.identity(url: url, owner: owner, pixels: pixels)) {
                await model.load(url: url, owner: owner, pixels: pixels)
            }
            .onDisappear { model.reset() }
    }
}

@MainActor
private final class MomentVideoThumbnailModel: ObservableObject {
    @Published private(set) var image: UIImage?
    private var generation = UUID()
    private var identity: String?

    func currentImage(url: URL?, owner: String) -> UIImage? {
        guard let url, identity == MomentMediaPolicy.key(url: url, owner: owner) else { return nil }
        return image
    }
    func reset() {
        generation = UUID()
        identity = nil
        image = nil
    }

    static func warm(url: URL, owner: String) async {
        _ = try? await KingfisherManager.shared.retrieveImage(
            with: .provider(MomentVideoPosterProvider(url: url, owner: owner)),
            options: MomentImagePipeline.options(pixels: 720))
    }

    func load(url: URL) async {
        let owner = MomentImagePipeline.owner
        let generation = UUID()
        self.generation = generation
        identity = MomentMediaPolicy.key(url: url, owner: owner)
        let provider = MomentVideoPosterProvider(url: url, owner: owner)
        let options = MomentImagePipeline.options(pixels: 720)
        if let cached = MomentImagePipeline.cache.retrieveImageInMemoryCache(forKey: provider.cacheKey, options: options) {
            image = cached
            return
        }

        image = nil
        do {
            let result = try await KingfisherManager.shared.retrieveImage(with: .provider(provider), options: options)
            guard !Task.isCancelled, self.generation == generation, MomentImagePipeline.owner == owner else { return }
            image = result.image
        } catch {
            // Keep the playable video card if a thumbnail cannot be generated.
        }
    }
}

private struct MomentVideoPosterProvider: ImageDataProvider {
    let url: URL
    let owner: String
    var cacheKey: String { MomentMediaPolicy.key(url: url, owner: owner) + "-poster" }
    func data() async throws -> Data {
        guard let local = await MomentVideoAssetCache.shared.cachedFile(for: url, owner: owner) else {
            throw URLError(.resourceUnavailable)
        }
        return try await MomentVideoFrameDecoder.shared.frame(local)
    }
}

/// Local frame generation/encoding stays off the UI actor and is limited to one
/// decoder. Remote videos are never opened here just to show a feed thumbnail.
private actor MomentVideoFrameDecoder {
    static let shared = MomentVideoFrameDecoder()
    private let gate = MomentTransferGate(limit: 1)
    func frame(_ source: URL) async throws -> Data {
        try await gate.run {
            try Task.checkCancellation()
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            let frame = try await withTaskCancellationHandler {
                try await generator.image(at: CMTime(seconds: 0, preferredTimescale: 600))
            } onCancel: { generator.cancelAllCGImageGeneration() }
            try Task.checkCancellation()
            guard let data = UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.82) else {
                throw URLError(.cannotDecodeContentData)
            }
            return data
        }
    }
}

#if DEBUG
private enum MomentVideoDiagnostics {
    static func record(_ event: String) {
        // Bypass stdio buffering so USB captures see these bounded safe fields
        // immediately; never add a URL, response body or credential here.
        try? FileHandle.standardOutput.write(contentsOf: Data(("[MomentsVideo] " + event + "\n").utf8))
    }
}

/// Task-local diagnostic state; never log URLs, identifiers, tokens or content.
private actor MomentVideoTransferTrace {
    private var bucket = -1
    func progress(bytes: Int64, expected: Int64, status: Int?, video: Bool) {
        let next = expected > 0 ? min(10, Int(Double(bytes) / Double(expected) * 10)) : 0
        guard bucket != next else { return }
        bucket = next
        MomentVideoDiagnostics.record("bytes=\(bytes) expected=\(expected) http=\(status ?? 0) video=\(video)")
    }
    func finished(code: Int) { MomentVideoDiagnostics.record("transferFinished errorCode=\(code)") }
}

private final class MomentVideoDownloadObserver: NSObject, URLSessionDownloadDelegate {
    private let trace = MomentVideoTransferTrace()
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
        let video = downloadTask.response?.mimeType?.lowercased().hasPrefix("video/") == true
        let trace = trace
        Task { @concurrent in
            await trace.progress(bytes: totalBytesWritten, expected: totalBytesExpectedToWrite, status: status, video: video)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let trace = trace, code = (error as NSError?)?.code ?? 0
        Task { @concurrent in await trace.finished(code: code) }
    }
}
#endif

private actor MomentVideoAssetCache {
    typealias Transport = @Sendable (URLRequest) async throws -> (URL, URLResponse)
    static let shared = MomentVideoAssetCache()
    private let gate = MomentTransferGate(limit: 1)
    private var downloads: [String: Task<URL, Error>] = [:]
    private var consumers: [String: Set<UUID>] = [:]
    private let directory: URL
    private let transport: Transport
    private let timeout: Duration

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IMIMMomentsVideos-v1", isDirectory: true),
         timeout: Duration = .seconds(180),
         transport: @escaping Transport = {
             #if DEBUG
             return try await ProxySession.shared.download(for: $0, delegate: MomentVideoDownloadObserver())
             #else
             return try await ProxySession.shared.download(for: $0)
             #endif
         }) {
        self.directory = directory
        self.transport = transport
        self.timeout = timeout
    }

    func invalidate(_ source: URL, owner: String, failedFile: URL) {
        let cached = directory.appendingPathComponent(MomentMediaPolicy.key(url: source, owner: owner) + ".mp4")
        guard let original = try? FileManager.default.attributesOfItem(atPath: cached.path),
              let failed = try? FileManager.default.attributesOfItem(atPath: failedFile.path),
              let originalDevice = original[.systemNumber] as? NSNumber,
              let failedDevice = failed[.systemNumber] as? NSNumber,
              let originalInode = original[.systemFileNumber] as? NSNumber,
              let failedInode = failed[.systemFileNumber] as? NSNumber,
              let originalSize = original[.size] as? NSNumber, let failedSize = failed[.size] as? NSNumber,
              let originalDate = original[.modificationDate] as? Date,
              let failedDate = failed[.modificationDate] as? Date else { return }
        let sameInode = originalDevice == failedDevice && originalInode == failedInode
        let sameCopy = originalSize == failedSize && originalDate == failedDate
        // A late failure from an old player must not evict a replacement file.
        guard sameInode || sameCopy else { return }
        try? FileManager.default.removeItem(at: cached)
    }

    func cachedFile(for source: URL, owner: String) -> URL? {
        let file = directory.appendingPathComponent(MomentMediaPolicy.key(url: source, owner: owner) + ".mp4")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return file
    }

    func playerFile(for source: URL, owner: String) async throws -> URL {
        let cached = try await file(for: source, owner: owner)
        try Task.checkCancellation()
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("imim-moment-\(UUID().uuidString).mp4")
        // Hard link avoids a second full-video copy on MainActor; the inode stays
        // alive even if the bounded cache removes its own name during playback.
        do { try FileManager.default.linkItem(at: cached, to: owned) }
        catch { try FileManager.default.copyItem(at: cached, to: owned) }
        return owned
    }

    private func file(for source: URL, owner: String) async throws -> URL {
        try Task.checkCancellation()
        if let cached = cachedFile(for: source, owner: owner) { return cached }
        let key = MomentMediaPolicy.key(url: source, owner: owner)
        let consumer = UUID()
        let task: Task<URL, Error>
        if let existing = downloads[key] { task = existing }
        else {
            let gate = gate, directory = directory, transport = transport, timeout = timeout
            task = Task { @concurrent in
                try await MomentMediaDeadline.run(after: timeout) {
                    try await gate.run { try await Self.download(source, directory: directory, key: key, transport: transport) }
                }
            }
            downloads[key] = task
        }
        consumers[key, default: []].insert(consumer)
        defer { release(key, consumer: consumer) }
        let file = try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { Task { await self.release(key, consumer: consumer) } }
        prune(keeping: file)
        return file
    }
    private func release(_ key: String, consumer: UUID) {
        // Membership guard stops old completions from clearing a replacement job.
        guard consumers[key]?.remove(consumer) != nil else { return }
        if consumers[key]?.isEmpty == true {
            downloads.removeValue(forKey: key)?.cancel()
            consumers[key] = nil
        }
    }
    private func prune(keeping file: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard url.pathExtension == "mp4", let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var count = entries.count, bytes = entries.reduce(0) { $0 + $1.1 }
        for entry in entries where entry.0 != file {
            guard count > 8 || bytes > 250 * 1024 * 1024 else { break }
            if (try? FileManager.default.removeItem(at: entry.0)) != nil {
                count -= 1; bytes -= entry.1
            }
        }
    }
    private static func download(_ source: URL, directory: URL, key: String, transport: Transport) async throws -> URL {
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 180
        // Public or pre-signed media only; don't forward account bearer tokens.
        let (temporaryURL, response) = try await transport(request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw MomentVideoLoadError.http(http.statusCode) }
        let mime = http.mimeType?.lowercased()
        guard mime?.hasPrefix("video/") == true || mime == "application/octet-stream" else {
            throw MomentVideoLoadError.unsupportedContent
        }
        try Task.checkCancellation()
        let size = (try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= 250 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(key + ".mp4")
        // Completed files only, no partially-written cache hits after failure.
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try FileManager.default.moveItem(at: temporaryURL, to: file)
        return file
    }
}

private struct MomentUploadSelection {
    let data: Data
    let fileName: String
    let mimeType: String
    let type: String
}

private struct MomentComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSubmit: (String, [MomentUploadSelection]) async throws -> Void
    @State private var content = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var cameraCaptures: [CameraCaptureResult] = []
    @State private var isCameraPresented = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var submissionTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("此刻想分享什么？")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MomentsPalette.primaryText)

                TextEditor(text: $content)
                    .disabled(isSubmitting)
                    .font(.system(size: 16))
                    .foregroundStyle(MomentsPalette.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 140)
                    .background(MomentsPalette.actionBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: max(1, 9 - cameraCaptures.count),
                    matching: .any(of: [.images, .videos])
                ) {
                    Label(
                        selectedItems.isEmpty ? AppLocalization.string("添加图片或视频") : AppLocalization.text("已选择 \(selectedItems.count) 个媒体"),
                        systemImage: "photo.on.rectangle.angled"
                    )
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MomentsPalette.mint)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting || cameraCaptures.count >= 9)

                HStack {
                    Button { isCameraPresented = true } label: {
                        Label(AppLocalization.string("拍摄"), systemImage: "camera.on.rectangle")
                    }
                    .disabled(isSubmitting || selectedItems.count + cameraCaptures.count >= 9)
                    if !cameraCaptures.isEmpty {
                        Text(AppLocalization.text("已拍摄 \(cameraCaptures.count) 个媒体"))
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(AppLocalization.string("移除")) {
                            cameraCaptures.forEach { $0.discard() }; cameraCaptures.removeAll()
                        }.disabled(isSubmitting)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MomentsPalette.mint)

                if let errorMessage {
                    AppLocalizedText(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red.opacity(0.9))
                }

                Text("图片和视频会先上传到朋友圈媒体库，再与 Web 使用同一条动态接口发布。单个视频最大 200 MB。")
                    .font(.system(size: 12))
                    .foregroundStyle(MomentsPalette.tertiaryText)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(MomentsPalette.pageBackground)
            .navigationTitle("发布朋友圈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { submissionTask?.cancel(); dismiss() }
                        .foregroundStyle(MomentsPalette.secondaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? AppLocalization.text("发布中") : AppLocalization.text("发布")) {
                        submit()
                    }
                    .disabled(isSubmitting || (content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedItems.isEmpty && cameraCaptures.isEmpty))
                    .foregroundStyle(MomentsPalette.mint)
                }
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            DualCameraView(allowsVideo: true) { cameraCaptures.append($0) }
        }
        .onDisappear {
            // Presenting the camera is not dismissal of the draft.
            if !isCameraPresented {
                submissionTask?.cancel()
                cameraCaptures.forEach { $0.discard() }
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        let draft = content
        let selections = selectedItems
        let captures = cameraCaptures
        let owner = MomentImagePipeline.owner
        isSubmitting = true
        errorMessage = nil
        submissionTask = Task {
            defer { isSubmitting = false; submissionTask = nil }
            do {
                var media = try await uploadSelections(selections)
                for (index, capture) in captures.enumerated() {
                    try Task.checkCancellation()
                    switch capture {
                    case .photo(let data):
                        media.append(MomentUploadSelection(data: data, fileName: "camera_\(index).jpg", mimeType: "image/jpeg", type: "image"))
                    case .video(let url):
                        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                        media.append(MomentUploadSelection(data: data, fileName: "camera_\(index).mp4", mimeType: "video/mp4", type: "video"))
                    }
                }
                guard media.count <= 9 else { throw APIClientError.server(AppLocalization.string("最多选择 9 个媒体")) }
                try Task.checkCancellation()
                guard MomentImagePipeline.owner == owner else { throw CancellationError() }
                try await onSubmit(draft, media)
                try Task.checkCancellation()
                dismiss()
            } catch {
                guard !Task.isCancelled, MomentImagePipeline.owner == owner else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func uploadSelections(_ selections: [PhotosPickerItem]) async throws -> [MomentUploadSelection] {
        var result: [MomentUploadSelection] = []
        result.reserveCapacity(selections.count)

        for (index, item) in selections.enumerated() {
            try Task.checkCancellation()
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw APIClientError.server("第 \(index + 1) 个媒体读取失败")
            }
            try Task.checkCancellation()
            let contentTypes = item.supportedContentTypes
            let contentType = contentTypes.first
            let isVideo = contentTypes.contains { $0.conforms(to: .movie) }
            let type = isVideo ? "video" : "image"
            let mimeType = contentType?.preferredMIMEType ?? (isVideo ? "video/mp4" : "image/jpeg")
            let ext = contentType?.preferredFilenameExtension ?? (isVideo ? "mp4" : "jpg")
            result.append(MomentUploadSelection(
                data: data,
                fileName: "moment_\(Int(Date().timeIntervalSince1970))_\(index).\(ext)",
                mimeType: mimeType,
                type: type
            ))
        }
        return result
    }
}

private struct MomentCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let authorName: String
    let onSubmit: (String) async throws -> Void
    @State private var content = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("评论 \(authorName.isEmpty ? AppLocalization.string("这条动态") : authorName + AppLocalization.string(" 的动态"))")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(MomentsPalette.primaryText)

            TextField("写下你的评论", text: $content, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 16))
                .foregroundStyle(MomentsPalette.primaryText)
                .padding(12)
                .background(MomentsPalette.actionBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let errorMessage {
                AppLocalizedText(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.9))
            }

            HStack {
                Button("取消") { dismiss() }
                    .foregroundStyle(MomentsPalette.secondaryText)
                Spacer()
                Button(isSubmitting ? AppLocalization.text("发送中") : AppLocalization.text("发送")) {
                    submit()
                }
                .fontWeight(.semibold)
                .foregroundStyle(MomentsPalette.mint)
                .disabled(isSubmitting || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .background(MomentsPalette.pageBackground)
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await onSubmit(content)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

private enum MomentComposerError: LocalizedError {
    case emptyContent

    var errorDescription: String? {
        "请输入内容后再发布。"
    }
}

private struct MomentGlassCircle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.22), lineWidth: 0.7)
                }
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.22), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        }
    }
}

private enum MomentsPalette {
    private static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    static let pageBackground = dynamic(dark: .black, light: .white)
    static let primaryText = dynamic(dark: .white, light: .black)
    static let secondaryText = dynamic(dark: UIColor(white: 0.6, alpha: 1), light: .secondaryLabel)
    static let tertiaryText = dynamic(dark: UIColor(white: 0.45, alpha: 1), light: .tertiaryLabel)
    static let cardSurface = dynamic(dark: UIColor(white: 0.095, alpha: 1), light: .white)
    static let cardStroke = dynamic(dark: UIColor(white: 0.20, alpha: 1), light: UIColor(white: 0.88, alpha: 1))
    static let accent = DoveTheme.accent
    static let onAccent = dynamic(dark: .white, light: .white)
    static let mint = accent
    static let coverSlate = dynamic(
        dark: UIColor(red: 0.16, green: 0.18, blue: 0.19, alpha: 1),
        light: UIColor(red: 0.30, green: 0.34, blue: 0.35, alpha: 1)
    )
    static let coverCharcoal = dynamic(
        dark: UIColor(red: 0.045, green: 0.055, blue: 0.06, alpha: 1),
        light: UIColor(red: 0.09, green: 0.11, blue: 0.12, alpha: 1)
    )
    static let authorBlue = dynamic(
        dark: UIColor(red: 0.60, green: 0.70, blue: 0.90, alpha: 1),
        light: UIColor(red: 0.31, green: 0.40, blue: 0.58, alpha: 1)
    )
    static let like = Color(red: 1.0, green: 0.42, blue: 0.45)
    static let divider = dynamic(dark: UIColor(white: 0.15, alpha: 1), light: .separator)
    static let actionBackground = dynamic(dark: UIColor(white: 0.14, alpha: 1), light: UIColor(white: 0.93, alpha: 1))
    static let videoHighlight = dynamic(dark: UIColor(white: 0.18, alpha: 1), light: UIColor(white: 0.85, alpha: 1))
    static let videoBackground = dynamic(dark: UIColor(white: 0.08, alpha: 1), light: UIColor(white: 0.76, alpha: 1))
    static let avatarFallback = dynamic(
        dark: UIColor(red: 0.20, green: 0.27, blue: 0.39, alpha: 1),
        light: UIColor(red: 0.85, green: 0.92, blue: 0.87, alpha: 1)
    )
}

private func momentAvatarSource(_ value: String?) -> String? {
    guard let value = nonBlank(value) else { return nil }
    if value.hasPrefix("asset://") || value.hasPrefix("file://")
        || (value.hasPrefix("/") && FileManager.default.fileExists(atPath: value)) {
        return value
    }
    return momentURL(value)?.absoluteString
}

private func momentURL(_ value: String?) -> URL? {
    guard var value, !value.isEmpty else { return nil }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("http://") || value.hasPrefix("https://") {
        return URL(string: value) ?? URL(string: value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
    }
    if value.hasPrefix("/") {
        return URL(string: "\(AppServer.origin)\(value)")
    }
    return URL(string: "\(AppServer.origin)/\(value)")
}

private func nonBlank(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private extension MomentFeedItem {
    func updated(isLiked: Bool, likeCount: Int) -> MomentFeedItem {
        MomentFeedItem(
            id: id,
            authorId: authorId,
            authorName: authorName,
            authorAvatar: authorAvatar,
            content: content,
            media: media,
            location: location,
            likeCount: likeCount,
            commentCount: commentCount,
            comments: comments,
            isLiked: isLiked,
            createdAt: createdAt
        )
    }
}

private extension MomentFeedItem {
    init(
        id: String,
        authorId: String,
        authorName: String,
        authorAvatar: String?,
        content: String,
        media: [MomentMediaItem],
        location: String?,
        likeCount: Int,
        commentCount: Int,
        comments: [MomentComment],
        isLiked: Bool,
        createdAt: Int64
    ) {
        self.id = id
        self.authorId = authorId
        self.authorName = authorName
        self.authorAvatar = authorAvatar
        self.content = content
        self.media = media
        self.location = location
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.comments = comments
        self.isLiked = isLiked
        self.createdAt = createdAt
    }
}

private extension Int64 {
    var momentDateText: String {
        guard self > 0 else { return "刚刚" }
        let date = Date(milliseconds: self)
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d"
        return formatter.string(from: date)
    }
}
