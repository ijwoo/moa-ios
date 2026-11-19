import UserNotifications

/// 알림 확장 (D73): Apple을 거쳐 온 알림(정해진 문장과 번호)을 띄우기 전에, 그 번호로 맥에 직접 물어 실제 글로 바꾼다.
///
/// - 받지 못하면(맥에 닿지 않는다, 글이 지금은 없다, 시간이 넘었다) 정해진 문장을 그대로 띄운다
/// - 하는 일은 `PushTextDelivery`에 있다 (앱의 테스트가 확인한다). 이 확장은 아무것도 저장하지 않고 적어 두지 않는다
/// - 그 대화를 보고 있을 때 배너를 숨기는 것은 전처럼 앱이 한다 (`AppDelegate`)
final class NotificationService: UNNotificationServiceExtension {
    private var delivery: PushTextDelivery?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let delivery = PushTextDelivery(content: content, handler: contentHandler)
        self.delivery = delivery
        delivery.start()
    }

    override func serviceExtensionTimeWillExpire() {
        delivery?.expire()
    }
}
