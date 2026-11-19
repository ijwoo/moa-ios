import UIKit
import UserNotifications

/// 알림을 받는 자리 (D67). SwiftUI 앱에는 이 두 가지를 받을 곳이 따로 없어 앱 대리자를 둔다.
/// - Apple이 준 이 기기의 알림 주소
/// - 알림이 왔을 때(앱이 앞에 있을 때)와 알림을 눌렀을 때
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 앱이 꺼진 채로 알림을 눌러 켜진 경우에도 받으려면 켜지는 동안 정해 두어야 한다
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = PushToken.hex(deviceToken)
        Task { await PushCenter.shared.received(token: token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // 주소를 받지 못했다 (네트워크, 시뮬레이터). 다음에 앱을 열 때 다시 청한다
    }

    /// 앱이 앞에 있을 때 온 알림: 그 대화를 보고 있으면 배너를 띄우지 않는다 (화면이 이미 바뀐다). 아니면 띄운다
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let notice = PushNotice(userInfo: notification.request.content.userInfo)
        let shows = Self.onMain { PushCenter.shared.shouldPresent(notice) }
        completionHandler(shows ? [.banner, .list, .sound] : [])
    }

    /// 알림을 눌렀다: 그 대화로 간다 (화면이 `PushCenter.pending`을 보고 연다)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let notice = PushNotice(userInfo: response.notification.request.content.userInfo)
        Self.onMain { PushCenter.shared.opened(notice) }
        completionHandler()
    }

    /// 시스템은 이 두 가지를 주 스레드에서 부른다. 혹시 아니어도 멈추지 않게 주 스레드로 옮겨서 한다
    private nonisolated static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
