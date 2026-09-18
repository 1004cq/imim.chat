import UIKit
import UserNotifications

final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        CallManager.shared.start()
        VoIPPushManager.shared.start()
        PushNotificationManager.shared.configure(notificationDelegate: self)
        // Ask on first launch and immediately obtain an APNs token once allowed.
        PushNotificationManager.shared.requestAuthorizationAndRegister()
        return true
    }

    func requestNotificationAuthorization() {
        PushNotificationManager.shared.requestAuthorizationAndRegister()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotificationManager.shared.handleAPNsToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotificationManager.shared.handleRegistrationFailure(error)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        PushNotificationManager.shared.updatePresence(.background)
        SocketManager.shared.enterBackground()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        PushNotificationManager.shared.updatePresence(.foreground, activeChatId: NotificationRouter.shared.activeConversationId)
        SocketManager.shared.enterForeground()
        PushNotificationManager.shared.ensureRegistrationAndUpload()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        PushNotificationManager.shared.ensureRegistrationAndUpload()
        SocketManager.shared.enterForeground()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        PushNotificationManager.shared.updatePresence(.offline)
        SocketManager.shared.enterBackground()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        PushNotificationManager.shared.handleRemoteNotification(userInfo)
        completionHandler(.newData)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        let chatId = (userInfo["chatId"] as? String)
            ?? (userInfo["conversationId"] as? String)
            ?? ""
        if NotificationRouter.shared.activeConversationId == chatId {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        PushNotificationManager.shared.handleNotificationResponse(response)
        completionHandler()
    }
}
