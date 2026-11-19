import Foundation
import UserNotifications

/// 알림 하나를 실제 글로 바꿔 넘기는 일 (D73). 알림 확장(`NotificationService`)이 쓴다.
///
/// - 알림에 실려 온 번호로 맥에 직접 묻는다 (`PushText`). 받으면 제목과 글을 바꾸고, 못 받으면 온 그대로(정해진 문장) 넘긴다
/// - 알림은 꼭 한 번만 넘긴다 (답이 온 것과 시간이 다 된 것이 겹쳐도)
/// - 받은 글은 알림에만 넣는다: 저장하지 않고 적어 두지 않는다
///
/// 이 파일도 앱과 알림 확장에 함께 들어간다. 앱은 쓰지 않고, 테스트가 앱 쪽에서 이 동작을 확인한다
/// (시뮬레이터의 가상 알림은 알림 확장을 거치지 않아서다)
final class PushTextDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let content: UNMutableNotificationContent
    private var handler: ((UNNotificationContent) -> Void)?
    private var task: URLSessionDataTask?

    init(content: UNMutableNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.content = content
        self.handler = handler
    }

    /// 맥에 묻기 시작한다. `makeRequest`는 테스트가 가상의 주소로 바꿔 끼운다
    func start(
        session: URLSession = URLSession(configuration: .ephemeral),
        makeRequest: (PushText.Target) -> URLRequest? = { PushText.request(for: $0) }
    ) {
        guard let target = PushText.target(userInfo: content.userInfo) else { return finish(with: nil) }
        // 같은 대화의 알림은 한데 묶인다 (글을 못 받아도)
        if let conversation = target.conversationID { content.threadIdentifier = conversation }
        guard let request = makeRequest(target) else { return finish(with: nil) }
        let type = target.type
        let task = session.dataTask(with: request) { [self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            finish(with: data.flatMap { PushText.decode(data: $0, status: status, type: type) })
        }
        lock.withLock { self.task = task }
        task.resume()
    }

    /// 확장에 주어진 시간이 다 됐다: 묻기를 그만두고 정해진 문장으로 넘긴다
    func expire() {
        lock.withLock { task }?.cancel()
        finish(with: nil)
    }

    /// `text`가 없으면 온 그대로 넘긴다
    private func finish(with text: PushText?) {
        let handler = lock.withLock {
            let handler = self.handler
            self.handler = nil
            return handler
        }
        guard let handler else { return }
        if let text {
            if let title = text.title { content.title = title }
            content.body = text.body
        }
        handler(content)
    }
}
