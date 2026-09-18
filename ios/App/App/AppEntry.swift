import LocalAuthentication
import SwiftData
import SwiftUI

@main
struct imimchatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("isDarkMode") private var isDarkMode = false
    @StateObject private var authSession = AuthSession()
    @StateObject private var pushManager = PushNotificationManager.shared

    // 配置 SwiftData 存储容器。持久化存储失败时使用内存容器兜底，避免启动闪退。
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            User.self,
            Chat.self,
            Message.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // 数据库打开失败属于可恢复错误；断言会让 Debug 构建在进入兜底前退出。
            NSLog("[Storage] 无法创建持久化 ModelContainer，正在尝试内存存储: %@", String(describing: error))
            let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            if let fallbackContainer = try? ModelContainer(for: schema, configurations: [inMemoryConfig]) {
                return fallbackContainer
            }
            preconditionFailure("无法创建 SwiftData 内存容器，请检查模型定义。")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(sharedModelContainer)
                .environmentObject(authSession)
                .environmentObject(pushManager)
                .preferredColorScheme(isDarkMode ? .dark : .light)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var authSession: AuthSession
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("privacy_biometric_lock") private var biometricLockEnabled = false
    @ObservedObject private var appLock = AppLockManager.shared

    var body: some View {
        ZStack {
            Group {
                if authSession.isAuthenticated {
                    MainTabView()
                } else {
                    LoginView()
                }
            }

            if authSession.isAuthenticated && appLock.isLocked {
                AppLockView(unlock: appLock.unlock)
            }
        }
        .onAppear {
            appLock.syncProtectionState(isEnabled: biometricLockEnabled)
        }
        .onChange(of: biometricLockEnabled) { _, isEnabled in
            appLock.syncProtectionState(isEnabled: isEnabled)
        }
        .onChange(of: scenePhase) { _, phase in
            appLock.handle(scenePhase: phase, isEnabled: biometricLockEnabled)
            switch phase {
            case .active:
                PushNotificationManager.shared.updatePresence(.foreground, activeChatId: NotificationRouter.shared.activeConversationId)
            case .background:
                PushNotificationManager.shared.updatePresence(.background)
            default:
                break
            }
        }
    }
}

@MainActor
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    @Published private(set) var isLocked = false

    private var needsAuthentication = false
    private var isAuthenticating = false

    private init() {}

    func syncProtectionState(isEnabled: Bool) {
        guard isEnabled else {
            needsAuthentication = false
            isLocked = false
            return
        }
    }

    func handle(scenePhase: ScenePhase, isEnabled: Bool) {
        guard isEnabled else {
            syncProtectionState(isEnabled: false)
            return
        }

        switch scenePhase {
        case .background:
            needsAuthentication = true
            isLocked = true
        case .active where needsAuthentication:
            unlock()
        default:
            break
        }
    }

    func unlock() {
        guard !isAuthenticating else { return }
        guard UserDefaults.standard.bool(forKey: "privacy_biometric_lock") else {
            syncProtectionState(isEnabled: false)
            return
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            isLocked = true
            return
        }

        isAuthenticating = true
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "使用 Face ID 解锁 IMIM Chat"
        ) { [weak self] success, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.needsAuthentication = false
                    self.isLocked = false
                }
            }
        }
    }
}

private struct AppLockView: View {
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                Text("IMIM Chat 已锁定")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("使用 Face ID 继续")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                Button(action: unlock) {
                    Label("使用 Face ID 解锁", systemImage: "faceid")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityAddTraits(.isModal)
    }
}
