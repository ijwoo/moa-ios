import Foundation

/// 알림에 띄울 실제 글 (D73).
///
/// Apple을 거쳐 오는 알림에는 정해진 문장과 번호만 실린다 (D67). 알림 확장이 그 번호로 맥에 직접 물어
/// (`GET /v1/tasks/{task_id}/notification?type=…`, 기능 이름 `push_text`) 받은 글로 바꿔 띄운다.
/// 받지 못하면 정해진 문장을 그대로 둔다.
///
/// 이 파일은 앱과 알림 확장에 함께 들어간다: 다른 파일에 기대지 않는다 (받아서 넘기는 일은 `PushTextDelivery`)
struct PushText: Equatable, Sendable {
    /// 일의 제목 (없으면 알림에 제목을 달지 않는다)
    var title: String?
    /// 띄울 글
    let body: String
    /// 로그인한 화면에서 읽은 개인 내용이 든 글인지. 사용자가 잠금 화면에 보여도 된다고 정해 가리지 않는다 (D73)
    var isPrivate = false

    /// 글을 받을 수 있는 알림의 종류 (맥과 맞춘 이름, `PushNotice.Kind`와 같다)
    static let kinds: Set<String> = ["approval_needed", "input_needed", "task_done", "task_failed", "needs_login", "routine_result"]
    static let titleLimit = 80
    static let bodyLimit = 300
    /// 예약이 돈 알림: 번호가 작업이 아니라 실행 기록(`rr_…`)이라, 묻는 곳이 다르다 (D93)
    static let routineKind = "routine_result"
    /// 확장에 주어지는 시간(30초쯤)보다 넉넉히 짧게 기다린다. 넘으면 정해진 문장이 뜬다
    static let timeout: TimeInterval = 8

    /// 알림에 실려 온 값에서 읽은 것: 어느 일의 어떤 알림인지
    struct Target: Equatable, Sendable {
        let taskID: String
        let type: String
        /// 같은 대화의 알림을 묶는 데 쓴다
        var conversationID: String?
    }

    /// 종류를 모르거나 일의 번호가 없으면 nil (그런 알림은 정해진 문장 그대로 둔다).
    /// 번호는 주소에 넣어도 되는 꼴일 때만 받는다
    static func target(userInfo: [AnyHashable: Any]) -> Target? {
        guard let type = userInfo["type"] as? String, kinds.contains(type),
              let taskID = userInfo["task_id"] as? String, isPathSafe(taskID) else { return nil }
        let conversation = (userInfo["conversation_id"] as? String).flatMap { isPathSafe($0) ? $0 : nil }
        return Target(taskID: taskID, type: type, conversationID: conversation)
    }

    /// 주소에 넣는 번호는 글자·숫자·밑줄·붙임표만 받는다 (다른 경로로 새지 않게)
    static func isPathSafe(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// 맥에 글을 묻는 요청. 주소·토큰은 앱과 같은 값이다 (빌드 때 넣는다). 없으면 nil.
    /// 저장하지 않고(캐시 없이) 받는다
    static func request(for target: Target, host: String?, token: String?) -> URLRequest? {
        guard let host, !host.isEmpty, let token, !token.isEmpty, isPathSafe(target.taskID), kinds.contains(target.type),
              var parts = URLComponents(string: "https://\(host)") else { return nil }
        if target.type == routineKind {
            // 예약이 돈 결과는 그 실행 기록에서 읽는다 (`GET /v1/routines/runs/{rr_…}`)
            parts.path = "/v1/routines/runs/\(target.taskID)"
        } else {
            parts.path = "/v1/tasks/\(target.taskID)/notification"
            parts.queryItems = [URLQueryItem(name: "type", value: target.type)]
        }
        guard let url = parts.url, url.host != nil else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-App-Token")
        return request
    }

    static func request(for target: Target, bundle: Bundle = .main) -> URLRequest? {
        request(
            for: target, host: bundle.object(forInfoDictionaryKey: "MSAgentHost") as? String,
            token: bundle.object(forInfoDictionaryKey: "MSAgentToken") as? String
        )
    }

    /// 맥의 답을 읽는다. 200이 아니거나(글이 지금은 없다, 일을 모른다, 예전 맥), 꼴이 다르거나, 다른 종류의 글이거나,
    /// 글이 비어 있으면 nil — 정해진 문장을 그대로 둔다
    static func decode(data: Data, status: Int, type: String) -> PushText? {
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if type == routineKind { return routineText(object) }
        if let answered = object["type"] as? String, answered != type { return nil }
        guard let body = clean(object["body"] as? String, limit: bodyLimit, keepsLines: true) else { return nil }
        return PushText(
            title: clean(object["title"] as? String, limit: titleLimit, keepsLines: false), body: body,
            isPrivate: object["private"] as? Bool ?? false
        )
    }

    /// 예약이 돈 기록(`{"run": {"title", "replies": [{"text"}]}}`)에서 알림의 글을 만든다: 제목은 예약의 이름, 글은 그때의 답.
    /// 답이 없으면(작업이 됐거나 놓친 실행) nil — 정해진 문장을 그대로 둔다. 굵게 표시(`**`)는 알림에서 그릴 수 없어 뗀다
    private static func routineText(_ object: [String: Any]) -> PushText? {
        guard let run = object["run"] as? [String: Any] else { return nil }
        let replies = (run["replies"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["text"] as? String }
        let joined = replies.map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard let body = clean(joined, limit: bodyLimit, keepsLines: true) else { return nil }
        return PushText(title: clean(run["title"] as? String, limit: titleLimit, keepsLines: false), body: body, isPrivate: true)
    }

    /// 앞뒤 빈칸을 떼고 길이를 자른다. 제목은 한 줄로 만든다. 비면 nil
    private static func clean(_ text: String?, limit: Int, keepsLines: Bool) -> String? {
        guard var text else { return nil }
        if !keepsLines { text = text.split(whereSeparator: \.isNewline).joined(separator: " ") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > limit ? text.prefix(limit - 1).trimmingCharacters(in: .whitespacesAndNewlines) + "…" : text
    }
}
