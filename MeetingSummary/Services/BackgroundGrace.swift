import UIKit

/// 맥에 보내는 요청 하나가 끝날 때까지, 앱이 뒤로 가도 잠깐(iOS가 주는 약 30초) 더 돌게 한다.
///
/// 작업 자체는 맥에서 계속되므로 앱이 멈춰도 일은 진행된다. 이 여유 시간은 "보낸 요청의 답"을 놓치지 않기 위한 것이다.
/// 그래도 놓친 답은 같은 메시지 번호로 다시 받는다 (`AskSession.converse`, `resumeMessage`).
@MainActor
enum BackgroundGrace {
    private final class Token {
        var id = UIBackgroundTaskIdentifier.invalid
    }

    static func run<T>(_ name: String, _ operation: () async throws -> T) async rethrows -> T {
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // 시간이 다 되면 바로 돌려준다 (돌려주지 않으면 iOS가 앱을 끝낸다)
            end(token)
        }
        defer { end(token) }
        return try await operation()
    }

    private static func end(_ token: Token) {
        guard token.id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token.id)
        token.id = .invalid
    }
}
