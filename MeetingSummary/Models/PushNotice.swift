import Foundation

/// 맥이 보내는 알림 하나 (D67).
///
/// 알림은 Apple의 알림 서버를 지나므로, 맥은 정해진 문장 하나와 번호(종류·작업·대화)만 싣는다.
/// 작업 제목, 초안, 받는 사람, 사이트 이름, 읽은 결과는 실리지 않는다. 내용은 앱을 연 뒤 맥에서 직접 받는다 (`GET /v1/tasks/{id}`)
struct PushNotice: Equatable, Sendable {
    /// 알림의 종류. 문장은 맥이 그대로 보낸다 (local-ai-agent `docs/design/push.md`). 모르는 종류는 읽지 않는다
    enum Kind: String, CaseIterable, Sendable {
        case approvalNeeded = "approval_needed"
        case inputNeeded = "input_needed"
        case taskDone = "task_done"
        case taskFailed = "task_failed"
        case needsLogin = "needs_login"
        case routineResult = "routine_result"
        /// 맥이 6시간마다 로그인을 확인하다 풀린 사이트를 찾았다 (D122). 번호는 작업이 아니라 `site:<키>`라, 실제 글을 묻지 않는다
        case loginExpired = "login_expired"

        /// 두 쪽이 맞춘 문장 (맥이 보내는 것과 같아야 한다. 앱은 화면 설명과 가짜 알림에 쓴다)
        var body: String {
            switch self {
            case .approvalNeeded: "승인이 필요한 일이 있어요"
            case .inputNeeded: "확인이 필요한 질문이 있어요"
            case .taskDone: "맡긴 일이 끝났어요"
            case .taskFailed: "맡긴 일을 끝내지 못했어요"
            case .needsLogin: "로그인이 필요해서 멈췄어요"
            case .routineResult: "루틴 결과가 도착했어요"
            case .loginExpired: "로그인이 풀린 사이트가 있어요"
            }
        }
    }

    let kind: Kind
    /// 없으면 앱만 연다
    var taskID: String?
    var conversationID: String?
    /// 로그인이 풀린 사이트의 키 (`login_expired`만)
    var site: String?

    init(kind: Kind, taskID: String? = nil, conversationID: String? = nil, site: String? = nil) {
        self.kind = kind
        self.taskID = taskID
        self.conversationID = conversationID
        self.site = site
    }

    /// 알림에 실려 온 값에서 읽는다. 종류를 모르면 nil (그런 알림은 눌러도 앱만 열린다).
    /// 번호는 주소에 넣어도 되는 꼴일 때만 받는다
    init?(userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String, let kind = Kind(rawValue: type) else { return nil }
        self.kind = kind
        taskID = (userInfo["task_id"] as? String).flatMap { AgentHTTPClient.isPathSafe($0) ? $0 : nil }
        conversationID = (userInfo["conversation_id"] as? String).flatMap { AgentHTTPClient.isPathSafe($0) ? $0 : nil }
        site = kind == .loginExpired ? (userInfo["site"] as? String).flatMap { AgentHTTPClient.isPathSafe($0) ? $0 : nil } : nil
    }
}

/// 이 기기의 알림 주소 (Apple이 준 기기 토큰). 맥에는 16진수 글자로 보낸다
enum PushToken {
    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// 맥이 받는 꼴: 16진수 64~200자
    static func isValid(_ hex: String) -> Bool {
        (64...200).contains(hex.utf8.count) && hex.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}
