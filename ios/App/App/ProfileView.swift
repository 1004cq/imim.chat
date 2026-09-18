import SwiftUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject private var authSession: AuthSession
    @State private var nickname = ""
    @State private var bio = ""
    @State private var selectedImageSource: ImagePickerView.Source?
    @State private var isShowingAvatarOptions = false
    @State private var isSavingAvatar = false
    @State private var uploadProgress: Double?
    @State private var avatarStatusMessage: String?
    @State private var avatarErrorMessage: String?

    private var currentUser: CurrentUser? {
        authSession.currentUser
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Button {
                        isShowingAvatarOptions = true
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            DoveAvatar(
                                name: currentUser?.nickname ?? "我",
                                url: currentUser?.avatar,
                                size: 72
                            )

                            Image(systemName: "camera.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(DoveTheme.green, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("修改头像")

                    VStack(alignment: .leading, spacing: 6) {
                        Text(currentUser?.nickname ?? "未登录")
                            .font(.title3.bold())
                        Text(currentUser?.account ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if isSavingAvatar {
                            ProgressView(avatarStatusMessage ?? "正在处理头像...")
                                .font(.caption)
                        }

                        if let uploadProgress {
                            ProgressView(value: uploadProgress)
                                .tint(DoveTheme.green)
                            Text("上传头像 \(Int(uploadProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let avatarStatusMessage {
                            Text(avatarStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 8)
            } footer: {
                Text("头像会自动裁剪为正方形并压缩保存；上传失败时会保留本地头像并提示同步状态。")
            }

            Section("资料") {
                TextField("昵称", text: $nickname)
                TextField("签名", text: $bio, axis: .vertical)
                    .lineLimit(2...4)
                Button("保存资料") {
                    Task {
                        await authSession.updateProfile(nickname: nickname, bio: bio)
                    }
                }
                .disabled(authSession.isLoading)
            }

            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("编辑资料")
        .confirmationDialog("设置头像", isPresented: $isShowingAvatarOptions, titleVisibility: .visible) {
            Button("拍照") {
                selectedImageSource = .camera
            }
            Button("从相册选择") {
                selectedImageSource = .photoLibrary
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $selectedImageSource) { source in
            ImagePickerView(source: source, allowsEditing: true) { image in
                saveAvatar(image)
            }
        }
        .alert("头像保存失败", isPresented: Binding(
            get: { avatarErrorMessage != nil },
            set: { if !$0 { avatarErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(avatarErrorMessage ?? "")
        }
        .onAppear {
            nickname = currentUser?.nickname ?? ""
            bio = currentUser?.bio ?? ""
        }
    }

    private func saveAvatar(_ image: UIImage) {
        guard let user = currentUser else { return }
        isSavingAvatar = true
        avatarErrorMessage = nil

        do {
            avatarStatusMessage = "正在裁剪并压缩头像..."
            let path = try AvatarStore.saveAvatar(image, userId: user.id, replacing: user.avatar)
            authSession.updateAvatar(path: path)
            isSavingAvatar = false
            avatarStatusMessage = "头像已保存，正在同步服务器..."

            Task {
                await uploadAvatarIfPossible(localPath: path)
            }
        } catch {
            isSavingAvatar = false
            avatarErrorMessage = error.localizedDescription
        }
    }

    private func uploadAvatarIfPossible(localPath: String) async {
        do {
            let fileURL = URL(fileURLWithPath: localPath)
            let data = try Data(contentsOf: fileURL)
            uploadProgress = 0
            let remoteURL = try await APIClient.shared.uploadAvatar(
                imageData: data,
                fileName: fileURL.lastPathComponent
            ) { value in
                uploadProgress = value
            }
            authSession.updateAvatar(path: remoteURL.absoluteString)
            uploadProgress = nil
            avatarStatusMessage = "头像已同步"
        } catch {
            uploadProgress = nil
            avatarStatusMessage = "头像已保存本地，服务器同步稍后重试"
        }
    }
}
