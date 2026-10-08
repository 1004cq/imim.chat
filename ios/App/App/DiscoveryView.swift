import AVFoundation
import AVKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Native Moments keeps the web feed's quiet, edge-to-edge timeline while
/// preserving native loading, publishing and media viewing behavior.
struct DiscoveryView: View {
    @AppStorage("isDarkMode") private var isDarkMode = false
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
            ImagePickerView(source: source, allowsEditing: false) { image in
                updateCover(with: image)
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
        .preferredColorScheme(isDarkMode ? .dark : .light)
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
            AsyncImage(
                url: url,
                transaction: Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.28))
            ) { phase in
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
                MomentFeedRow(moment: moment) {
                    viewModel.toggleLike(moment.id)
                } onComment: { content in
                    Task {
                        try? await viewModel.comment(on: moment.id, content: content)
                    }
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

    private var nextCursor: String?

    func loadIfNeeded() async {
        guard moments.isEmpty else { return }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await APIClient.shared.fetchMomentsFeed()
            moments = response.moments
            prefetchAvatars(response.moments)
            nextCursor = response.nextCursor
            hasMore = response.hasMore ?? false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let response = try await APIClient.shared.fetchMomentsFeed(cursor: nextCursor)
            let existing = Set(moments.map(\.id))
            moments.append(contentsOf: response.moments.filter { !existing.contains($0.id) })
            prefetchAvatars(response.moments)
            nextCursor = response.nextCursor
            hasMore = response.hasMore ?? false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleLike(_ momentId: String) {
        guard let original = moments.first(where: { $0.id == momentId }) else { return }
        let optimistic = original.updated(
            isLiked: !original.isLiked,
            likeCount: max(0, original.likeCount + (original.isLiked ? -1 : 1))
        )
        replace(optimistic)

        Task {
            do {
                let result = try await APIClient.shared.toggleMomentLike(momentId: momentId)
                replace(optimistic.updated(isLiked: result.liked, likeCount: result.likeCount))
            } catch {
                // Keep the feed truthful: an unsuccessful optimistic like is restored.
                replace(original)
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
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !media.isEmpty else { throw MomentComposerError.emptyContent }

        var uploaded: [MomentCreateMedia] = []
        uploaded.reserveCapacity(media.count)
        for item in media {
            uploaded.append(try await APIClient.shared.uploadMomentMedia(
                data: item.data,
                fileName: item.fileName,
                mimeType: item.mimeType,
                type: item.type
            ))
        }
        try await APIClient.shared.createMoment(content: normalized, media: uploaded)
        await refresh()
    }

    func comment(on momentId: String, content: String) async throws {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw MomentComposerError.emptyContent }
        try await APIClient.shared.createMomentComment(momentId: momentId, content: normalized)
        await refresh()
    }

    private func replace(_ moment: MomentFeedItem) {
        guard let index = moments.firstIndex(where: { $0.id == moment.id }) else { return }
        moments[index] = moment
    }
}

private struct MomentFeedRow: View {
    let moment: MomentFeedItem
    let onToggleLike: () -> Void
    let onComment: (String) -> Void
    @State private var likePulse = false
    @State private var isComposingComment = false
    @State private var commentText = ""

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
                            .font(.system(size: 14))
                            .foregroundStyle(MomentsPalette.primaryText)
                            .padding(.horizontal, 11)
                            .frame(height: 38)
                            .background(MomentsPalette.actionBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Button("发送") {
                            let content = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !content.isEmpty else { return }
                            onComment(content)
                            commentText = ""
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isComposingComment = false
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MomentsPalette.authorBlue)
                        .buttonStyle(.plain)
                        .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                if item.isVideo {
                    MomentVideoCard(item: item)
                        .frame(maxWidth: 240, alignment: .leading)
                } else {
                    MomentMediaThumb(item: item) {
                        selectedPhoto = MomentPhotoDestination(item: item)
                    }
                    .frame(maxWidth: 240, alignment: .leading)
                }
            } else if !media.isEmpty {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: media.count == 2 || media.count == 4 ? 2 : 3),
                    spacing: 4
                ) {
                    ForEach(Array(media.prefix(9).enumerated()), id: \.offset) { _, item in
                        if item.isVideo {
                            MomentVideoCard(item: item)
                        } else {
                            MomentMediaThumb(item: item, isSquare: true) {
                                selectedPhoto = MomentPhotoDestination(item: item)
                            }
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

private struct MomentVideoCard: View {
    let item: MomentMediaItem
    @State private var isShowingVideo = false
    @StateObject private var thumbnail = MomentVideoThumbnailModel()

    private var playbackURL: URL? {
        momentURL(item.playbackURLString)
    }

    private var aspectRatio: CGFloat {
        guard let image = thumbnail.image, image.size.height > 0 else { return 16.0 / 9.0 }
        return image.size.width / image.size.height
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                ZStack {
                    if let image = thumbnail.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        AsyncImage(url: momentURL(item.previewURLString)) { phase in
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
            .task(id: playbackURL) {
                guard let playbackURL else { return }
                await thumbnail.load(url: playbackURL)
            }
    }
}

private struct MomentMediaThumb: View {
    let item: MomentMediaItem
    var isSquare = false
    let onOpen: () -> Void
    @State private var retryID = UUID()

    var body: some View {
        AsyncImage(url: momentURL(item.mediumUrl ?? item.thumbUrl ?? item.url)) { phase in
            switch phase {
            case .success(let image):
                mediaImage(image)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture(perform: onOpen)
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
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

            AsyncImage(url: url) { phase in
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let localURL {
                NativeFullscreenVideoPlayer(url: localURL)
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
        .task(id: retryID) { await loadVideo() }
        .onDisappear { removeLocalVideo() }
    }

    @MainActor
    private func loadVideo() async {
        errorMessage = nil
        do {
            // The legacy /api/media/{id} endpoint ignores HTTP Range. A local
            // file gives AVPlayer reliable seeking without changing that server.
            let downloaded = try await downloadVideo(url)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: downloaded)
                return
            }
            localURL = downloaded
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "请检查网络后重试；若仍失败，该视频文件可能不可用。"
        }
    }

    private func downloadVideo(_ source: URL) async throws -> URL {
        let cachedURL = try await MomentVideoAssetCache.shared.file(for: source)
        try Task.checkCancellation()
        let fileExtension = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("imim-moment-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        // The player owns its copy; closing it must not delete the thumbnail cache.
        try FileManager.default.copyItem(at: cachedURL, to: destination)
        return destination
    }

    private func removeLocalVideo() {
        guard let localURL else { return }
        try? FileManager.default.removeItem(at: localURL)
        self.localURL = nil
    }
}

private struct NativeFullscreenVideoPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        guard (uiViewController.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        uiViewController.player?.pause()
        uiViewController.player = AVPlayer(url: url)
        uiViewController.player?.play()
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player?.pause()
        uiViewController.player = nil
    }
}

@MainActor
private final class MomentVideoThumbnailModel: ObservableObject {
    private static let cache = NSCache<NSURL, UIImage>()
    @Published private(set) var image: UIImage?

    func load(url: URL) async {
        let key = url as NSURL
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }

        image = nil
        do {
            // Extensionless legacy media cannot serve Range requests. Generate
            // its cover from the cached local file, also reused when tapped.
            let source: URL
            if url.path.hasPrefix("/api/media/"), url.pathExtension.isEmpty {
                source = try await MomentVideoAssetCache.shared.file(for: url)
            } else {
                source = url
            }
            try Task.checkCancellation()
            let asset = AVURLAsset(url: source)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            let frame = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
            try Task.checkCancellation()
            let thumbnail = UIImage(cgImage: frame.image)
            Self.cache.setObject(thumbnail, forKey: key)
            image = thumbnail
        } catch {
            // Keep the playable video card if a thumbnail cannot be generated.
        }
    }
}

private actor MomentVideoAssetCache {
    static let shared = MomentVideoAssetCache()
    private var files: [URL: URL] = [:]
    private var downloads: [URL: Task<URL, Error>] = [:]

    func file(for source: URL) async throws -> URL {
        if let file = files[source], FileManager.default.fileExists(atPath: file.path) {
            return file
        }
        if let download = downloads[source] { return try await download.value }
        // Service-owned: thumbnail and player share one transfer. Leaving a row
        // must not cancel a download that an open player is also waiting for.
        let download = Task { try await Self.download(source) }
        downloads[source] = download
        defer { downloads[source] = nil }
        let file = try await download.value
        if files.count >= 8, let oldest = files.first {
            try? FileManager.default.removeItem(at: oldest.value)
            files[oldest.key] = nil
        }
        files[source] = file
        return file
    }

    private static func download(_ source: URL) async throws -> URL {
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 180
        // Public or pre-signed media only; don't forward bearer tokens to COS.
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              http.mimeType?.hasPrefix("video/") == true
                || http.mimeType == "application/octet-stream" else {
            throw URLError(.badServerResponse)
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("imim-video-cache-\(UUID().uuidString).mp4")
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
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("此刻想分享什么？")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MomentsPalette.primaryText)

                TextEditor(text: $content)
                    .font(.system(size: 16))
                    .foregroundStyle(MomentsPalette.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 140)
                    .background(MomentsPalette.actionBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: 9,
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
                    Button("取消") { dismiss() }
                        .foregroundStyle(MomentsPalette.secondaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? AppLocalization.text("发布中") : AppLocalization.text("发布")) {
                        submit()
                    }
                    .disabled(isSubmitting || (content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedItems.isEmpty))
                    .foregroundStyle(MomentsPalette.mint)
                }
            }
        }
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await onSubmit(content, try await uploadSelections())
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }

    private func uploadSelections() async throws -> [MomentUploadSelection] {
        var result: [MomentUploadSelection] = []
        result.reserveCapacity(selectedItems.count)

        for (index, item) in selectedItems.enumerated() {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw APIClientError.server("第 \(index + 1) 个媒体读取失败")
            }
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
