import AVFoundation
import AVKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The native Moments feed deliberately follows the dark web layout while using the same API data.
struct DiscoveryView: View {
    @AppStorage("isDarkMode") private var isDarkMode = false
    @StateObject private var viewModel = MomentsFeedViewModel()
    @State private var isShowingComposer = false
    @State private var isShowingCoverActions = false
    @State private var selectedCoverSource: ImagePickerView.Source?
    @State private var coverPreview: UIImage?
    @State private var coverURL = ""
    @State private var profileSignature: String?
    @State private var isUploadingCover = false
    @State private var coverUploadError: String?

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
            .refreshable {
                await viewModel.refresh()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            loadSavedCover()
            async let feed: Void = viewModel.loadIfNeeded()
            async let profile: Void = refreshProfileCover()
            _ = await (feed, profile)
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
            Text(coverUploadError ?? "请稍后重试")
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }

    private var profileCover: some View {
        let name = nonBlank(UserDefaults.standard.string(forKey: "current_user_name")) ?? "IMIM"
        let avatar = UserDefaults.standard.string(forKey: "current_user_avatar")
        let signature = profileSignature
            ?? nonBlank(UserDefaults.standard.string(forKey: "current_user_bio"))
            ?? "记录此刻的心情"

        return ZStack(alignment: .bottomTrailing) {
            coverImage
                .frame(height: 290)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.76)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                )

            HStack {
                Text("朋友圈")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)

                Spacer()

                Button {
                    isShowingCoverActions = true
                } label: {
                    ZStack {
                        Circle().fill(.black.opacity(0.24))
                        if isUploadingCover {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .disabled(isUploadingCover)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 18)
            .padding(.top, 18)

            VStack(alignment: .trailing, spacing: 4) {
                Text(name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 4, y: 2)
                Text(signature)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
            .padding(.trailing, 116)
            .padding(.bottom, 18)

            MomentAvatar(name: name, url: avatar, size: 86)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.55), radius: 9, y: 4)
                .padding(.trailing, 18)
                .offset(y: 38)
        }
        .frame(height: 290)
        .padding(.bottom, 48)
    }

    @ViewBuilder
    private var coverImage: some View {
        if let coverPreview {
            Image(uiImage: coverPreview)
                .resizable()
                .scaledToFill()
        } else if let url = momentURL(coverURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    defaultCover
                }
            }
        } else {
            defaultCover
        }
    }

    private var defaultCover: some View {
        LinearGradient(
            colors: [MomentsPalette.coverGreen, Color.black.opacity(0.92)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .bottomLeading) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.white.opacity(0.14))
                .padding(24)
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
        guard let profile = try? await APIClient.shared.fetchCurrentProfile() else { return }
        profileSignature = nonBlank(profile.bio)
        guard let backgroundURL = nonBlank(profile.backgroundUrl) else { return }
        coverURL = backgroundURL
        UserDefaults.standard.set(backgroundURL, forKey: coverDefaultsKey)
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
                UserDefaults.standard.set(uploaded.url, forKey: coverDefaultsKey)
                coverPreview = nil
            } catch {
                coverUploadError = error.localizedDescription
            }
        }
    }

    private func resetCover() {
        coverPreview = nil
        coverURL = ""
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
                Divider()
                    .overlay(MomentsPalette.divider)
                    .padding(.leading, 74)
                    .padding(.trailing, 18)
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
            Text(message)
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
        HStack(alignment: .top, spacing: 12) {
            MomentAvatar(name: moment.authorName, url: moment.authorAvatar, size: 42)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(moment.authorName.isEmpty ? "IMIM 用户" : moment.authorName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(MomentsPalette.authorBlue)

                    Spacer(minLength: 8)

                    Text(moment.createdAt.darkMomentTimeText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MomentsPalette.tertiaryText)
                }

                if !moment.content.isEmpty {
                    Text(moment.content)
                        .font(.system(size: 15))
                        .foregroundStyle(MomentsPalette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                MomentMediaGrid(media: moment.media)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()

                HStack {
                    HStack(spacing: 16) {
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
                                .foregroundStyle(moment.isLiked ? MomentsPalette.like : MomentsPalette.secondaryText)
                                .scaleEffect(likePulse ? 1.25 : 1)
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isComposingComment.toggle()
                            }
                        } label: {
                            Label("\(moment.commentCount)", systemImage: "bubble.left")
                                .foregroundStyle(MomentsPalette.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 8)

                    Menu {
                        Button(moment.isLiked ? "取消赞" : "赞", action: onToggleLike)
                        Button("评论") {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isComposingComment = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(MomentsPalette.secondaryText)
                            .frame(width: 38, height: 28)
                            .background(MomentsPalette.actionBackground, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 13, weight: .medium))

                if isComposingComment {
                    HStack(spacing: 8) {
                        TextField("写下你的评论", text: $commentText)
                            .font(.system(size: 14))
                            .foregroundStyle(MomentsPalette.primaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(MomentsPalette.actionBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

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
                        .foregroundStyle(MomentsPalette.mint)
                        .buttonStyle(.plain)
                        .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 17)
        .background(MomentsPalette.pageBackground)
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
                } else {
                    MomentMediaThumb(item: item, height: nil) {
                        selectedPhoto = MomentPhotoDestination(item: item)
                    }
                }
            } else if !media.isEmpty {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(media.count, 3)),
                    spacing: 6
                ) {
                    ForEach(Array(media.prefix(9).enumerated()), id: \.offset) { _, item in
                        if item.isVideo {
                            MomentVideoCard(item: item)
                        } else {
                            MomentMediaThumb(item: item, height: 105) {
                                selectedPhoto = MomentPhotoDestination(item: item)
                            }
                        }
                    }
                }
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

                    Color.black.opacity(0.30)

                    Image(systemName: "play.fill")
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(.black.opacity(0.82))
                        .frame(width: 62, height: 62)
                        .background(.white.opacity(0.94), in: Circle())
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
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
                thumbnail.load(url: playbackURL)
            }
    }
}

private struct MomentMediaThumb: View {
    let item: MomentMediaItem
    let height: CGFloat?
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
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func mediaImage(_ image: Image) -> some View {
        if let height {
            image.resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
        } else {
            image.resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }

    private var loadingMedia: some View {
        MomentsPalette.actionBackground
            .aspectRatio(height == nil ? 4.0 / 3.0 : nil, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(ProgressView().tint(MomentsPalette.accent).scaleEffect(0.78))
    }

    private var unavailableMedia: some View {
        VStack(spacing: 7) {
            Image(systemName: "photo")
                .font(.system(size: 22, weight: .medium))
            Text("加载失败，点按重试")
                .font(.caption)
        }
        .foregroundStyle(MomentsPalette.tertiaryText)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(MomentsPalette.actionBackground)
        .aspectRatio(height == nil ? 4.0 / 3.0 : nil, contentMode: .fit)
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
    let size: CGFloat

    var body: some View {
        AsyncImage(url: momentURL(url)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: max(14, size * 0.38), weight: .bold))
                    .foregroundStyle(MomentsPalette.primaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MomentsPalette.avatarFallback)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.26), lineWidth: 1))
    }
}

private struct MomentVideoPlayer: View {
    let url: URL

    var body: some View {
        NativeFullscreenVideoPlayer(url: url)
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
}

@MainActor
private final class MomentVideoThumbnailModel: ObservableObject {
    private static let cache = NSCache<NSURL, UIImage>()
    @Published private(set) var image: UIImage?

    func load(url: URL) {
        let key = url as NSURL
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }

        image = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 720)
            let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil)
            let thumbnail = cgImage.map(UIImage.init(cgImage:))
            if let thumbnail {
                Self.cache.setObject(thumbnail, forKey: key)
            }
            DispatchQueue.main.async {
                self?.image = thumbnail
            }
        }
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
                        selectedItems.isEmpty ? "添加图片或视频" : "已选择 \(selectedItems.count) 个媒体",
                        systemImage: "photo.on.rectangle.angled"
                    )
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MomentsPalette.mint)
                }
                .buttonStyle(.plain)

                if let errorMessage {
                    Text(errorMessage)
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
                    Button(isSubmitting ? "发布中" : "发布") {
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
            Text("评论 \(authorName.isEmpty ? "这条动态" : authorName + " 的动态")")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(MomentsPalette.primaryText)

            TextField("写下你的评论", text: $content, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 16))
                .foregroundStyle(MomentsPalette.primaryText)
                .padding(12)
                .background(MomentsPalette.actionBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.9))
            }

            HStack {
                Button("取消") { dismiss() }
                    .foregroundStyle(MomentsPalette.secondaryText)
                Spacer()
                Button(isSubmitting ? "发送中" : "发送") {
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
    static let accent = DoveTheme.accent
    static let onAccent = dynamic(dark: .white, light: .white)
    static let mint = accent
    static let coverGreen = dynamic(
        dark: UIColor(red: 0.15, green: 0.46, blue: 0.30, alpha: 1),
        light: UIColor(red: 0.35, green: 0.70, blue: 0.48, alpha: 1)
    )
    static let authorBlue = accent
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

private func momentURL(_ value: String?) -> URL? {
    guard var value, !value.isEmpty else { return nil }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("http://") || value.hasPrefix("https://") {
        return URL(string: value) ?? URL(string: value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
    }
    if value.hasPrefix("/") {
        return URL(string: "https://wed.imim.chat\(value)")
    }
    return URL(string: "https://wed.imim.chat/\(value)")
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
        self.isLiked = isLiked
        self.createdAt = createdAt
    }
}

private extension Int64 {
    var darkMomentTimeText: String {
        guard self > 0 else { return "刚刚" }
        let date = Date(milliseconds: self)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
