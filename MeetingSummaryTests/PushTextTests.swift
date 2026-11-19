import Foundation
import Testing
import UserNotifications
@testable import MeetingSummary

/// 알림에 띄울 실제 글 (D73): 알림 확장이 알림에 실려 온 번호로 맥에 직접 물어 받는다.
/// 여기의 글·주소·토큰은 모두 가상의 값이다
@Suite("알림의 글: 번호로 맥에 직접 묻고, 못 받으면 정해진 문장을 둔다")
struct PushTextTests {
    private let host = "mac.example.test"
    private let token = "virtual-token"

    private func info(type: String? = "task_done", task: Any? = "t_12", conversation: Any? = "c_3") -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = ["aps": ["alert": ["body": "부탁하신 일이 끝났어요"], "mutable-content": 1]]
        if let type { info["type"] = type }
        if let task { info["task_id"] = task }
        if let conversation { info["conversation_id"] = conversation }
        return info
    }

    private func decode(_ json: String, status: Int = 200, type: String = "task_done") -> PushText? {
        PushText.decode(data: Data(json.utf8), status: status, type: type)
    }

    // MARK: - 맥과 맞춘 값

    @Test func namesMatchTheMac() {
        #expect(AgentFeature.pushText == "push_text")
        // 글을 받을 수 있는 종류는 앱이 아는 알림의 종류와 같다
        // 로그인이 풀렸다는 알림(D122)만 빼고: 그 번호는 작업이 아니라(`site:<키>`) 맥에 글을 묻지 않는다
        #expect(PushText.kinds == Set(PushNotice.Kind.allCases.filter { $0 != .loginExpired }.map(\.rawValue)))
        #expect(PushText.bodyLimit == 300)
    }

    // MARK: - 알림에서 읽기

    @Test func theTargetComesFromTheNumbersInTheNotification() {
        #expect(PushText.target(userInfo: info()) == PushText.Target(taskID: "t_12", type: "task_done", conversationID: "c_3"))
        // 대화 번호는 없어도 된다 (묶지 않을 뿐이다)
        #expect(PushText.target(userInfo: info(conversation: nil)) == PushText.Target(taskID: "t_12", type: "task_done"))
        #expect(PushText.target(userInfo: info(conversation: "../c"))?.conversationID == nil)
        for kind in PushNotice.Kind.allCases where kind != .loginExpired {
            #expect(PushText.target(userInfo: info(type: kind.rawValue))?.type == kind.rawValue)
        }
        #expect(PushText.target(userInfo: info(type: "login_expired", task: "site:naver")) == nil)
    }

    @Test func oddNotificationsAreLeftAlone() {
        #expect(PushText.target(userInfo: info(type: "news")) == nil)
        #expect(PushText.target(userInfo: info(type: nil)) == nil)
        #expect(PushText.target(userInfo: info(task: nil)) == nil)
        #expect(PushText.target(userInfo: info(task: 12)) == nil)
        #expect(PushText.target(userInfo: info(task: "")) == nil)
        // 주소의 다른 곳으로 새는 번호는 받지 않는다
        #expect(PushText.target(userInfo: info(task: "../../v1/health")) == nil)
        #expect(PushText.target(userInfo: info(task: "t_1?x=1")) == nil)
        #expect(PushText.target(userInfo: info(task: "t 1")) == nil)
        #expect(PushText.target(userInfo: [:]) == nil)
    }

    @Test func pathRuleIsTheAppsRule() {
        let samples = ["t_12", "T-9", "", "a/b", "..", "t 1", "t?x", "한글", "t.1", "t%2F", String(repeating: "a", count: 80), String(repeating: "a", count: 81)]
        for sample in samples {
            #expect(PushText.isPathSafe(sample) == AgentHTTPClient.isPathSafe(sample), "\(sample)")
        }
    }

    // MARK: - 맥에 묻기

    @Test func theRequestAsksTheMacDirectly() throws {
        let target = PushText.Target(taskID: "t_12", type: "approval_needed", conversationID: "c_3")
        let request = try #require(PushText.request(for: target, host: host, token: token))
        #expect(request.url?.absoluteString == "https://mac.example.test/v1/tasks/t_12/notification?type=approval_needed")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-App-Token") == token)
        #expect(request.httpBody == nil)
        // 저장해 둔 답을 쓰지 않고, 확장에 주어진 시간보다 짧게 기다린다
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(request.timeoutInterval == PushText.timeout)
        #expect(PushText.timeout < 30)
        // 대화 번호는 보내지 않는다
        #expect(request.url?.absoluteString.contains("c_3") == false)
    }

    @Test func noRequestWithoutAHostOrToken() {
        let target = PushText.Target(taskID: "t_12", type: "task_done")
        #expect(PushText.request(for: target, host: nil, token: token) == nil)
        #expect(PushText.request(for: target, host: "", token: token) == nil)
        #expect(PushText.request(for: target, host: host, token: nil) == nil)
        #expect(PushText.request(for: target, host: host, token: "") == nil)
        // 번호나 종류가 이상하면 묻지 않는다
        #expect(PushText.request(for: PushText.Target(taskID: "a/b", type: "task_done"), host: host, token: token) == nil)
        #expect(PushText.request(for: PushText.Target(taskID: "t_12", type: "news"), host: host, token: token) == nil)
    }

    // MARK: - 답 읽기

    @Test func aTextReplacesTheFixedSentence() {
        let text = decode(#"{"type": "task_done", "title": "주간 회의록 정리", "body": "정리를 마쳤어요.\n결정 3건, 할 일 5건이에요.", "private": false}"#)
        #expect(text == PushText(title: "주간 회의록 정리", body: "정리를 마쳤어요.\n결정 3건, 할 일 5건이에요."))
        #expect(text?.isPrivate == false)
    }

    @Test func aPrivateTextIsShownToo() {
        // 사용자가 정했다: 로그인한 화면에서 읽은 결과도 알림에 보인다
        let text = decode(#"{"type": "task_done", "title": "가상 사이트 읽기", "body": "가상의 읽은 결과예요.", "private": true}"#)
        #expect(text?.body == "가상의 읽은 결과예요.")
        #expect(text?.isPrivate == true)
    }

    @Test func aTextWithoutATitleKeepsTheNotificationsTitle() {
        #expect(decode(#"{"type": "task_done", "body": "끝났어요."}"#) == PushText(title: nil, body: "끝났어요."))
        #expect(decode(#"{"body": "끝났어요.", "title": "  "}"#)?.title == nil)
        #expect(decode(#"{"body": "끝났어요.", "title": 3}"#)?.title == nil)
    }

    @Test func anythingElseKeepsTheFixedSentence() {
        let good = #"{"type": "task_done", "title": "일", "body": "끝났어요."}"#
        // 글이 지금은 없다 / 일을 모른다 / 예전 맥 / 토큰이 다르다 / 맥에 닿지 않는다
        for status in [404, 400, 401, 403, 500, 204, 0] { #expect(decode(good, status: status) == nil) }
        #expect(decode(#"{"error": {"code": "notification_gone"}}"#, status: 404) == nil)
        // 다른 종류의 글이다
        #expect(decode(good, type: "approval_needed") == nil)
        // 글이 없거나 꼴이 다르다
        #expect(decode(#"{"type": "task_done", "title": "일"}"#) == nil)
        #expect(decode(#"{"type": "task_done", "title": "일", "body": ""}"#) == nil)
        #expect(decode(#"{"type": "task_done", "title": "일", "body": " \n "}"#) == nil)
        #expect(decode(#"{"type": "task_done", "body": 3}"#) == nil)
        #expect(decode(#"["끝났어요."]"#) == nil)
        #expect(decode("끝났어요.") == nil)
        #expect(decode("") == nil)
    }

    @Test func textsAreTrimmedAndCut() throws {
        let long = String(repeating: "가", count: 400)
        let text = try #require(decode(#"{"title": "첫 줄\n둘째 줄", "body": "  \#(long)  "}"#))
        // 제목은 한 줄이다
        #expect(text.title == "첫 줄 둘째 줄")
        #expect(text.body.count == PushText.bodyLimit)
        #expect(text.body.hasSuffix("…"))
        let title = try #require(decode(#"{"title": "\#(long)", "body": "끝"}"#)?.title)
        #expect(title.count == PushText.titleLimit && title.hasSuffix("…"))
        // 맥이 자른 길이(300자)는 그대로 둔다. 줄바꿈도 그대로다
        let exact = String(repeating: "나", count: 300)
        #expect(decode(#"{"body": "\#(exact)"}"#)?.body == exact)
        #expect(decode(#"{"body": "한 줄\n두 줄"}"#)?.body == "한 줄\n두 줄")
    }

    // MARK: - 데이터 처리 방식의 설명

    @Test func theSetupKnowsWhetherTheMacGivesTheText() async {
        let plain = await DialogSetup(agent: MockAgentClient(v2: true, offersPush: true))
        #expect(plain.sendsPush && !plain.givesPushText)
        let local = await DialogSetup(agent: MockAgentClient(v2: true, offersPush: true, offersPushText: true))
        #expect(local.place == .local && local.sendsPush && local.givesPushText)
        let cloud = await DialogSetup(agent: MockAgentClient(v2: true, dialogCloud: MockDialogCloud(), offersPush: true, offersPushText: true))
        #expect(cloud.place == .cloud && cloud.givesPushText)
        // 알림을 보내지 않는 맥은 알림의 글도 주지 않는다
        let none = await DialogSetup(agent: MockAgentClient(v2: true, offersPushText: true))
        #expect(!none.sendsPush && !none.givesPushText)
        #expect(!DialogSetup(place: .local, givesPushText: true).givesPushText)
    }

    @Test func theSetupRemembersIt() {
        let setup = DialogSetup(place: .local, sendsPush: true, givesPushText: true)
        #expect(setup.stored == "v2 local push pushtext")
        #expect(DialogSetup(stored: "v2 local push pushtext") == setup)
        #expect(DialogSetup(stored: "v2 cloud context push items pushtext")?.givesPushText == true)
        // 예전에 적어 둔 값에는 없다
        #expect(DialogSetup(stored: "v2 local push")?.givesPushText == false)
        #expect(DialogSetup(stored: "v2 local pushtext")?.givesPushText == false)
    }

    @Test func thePrivacyRowSaysWhereTheTextComesFrom() {
        let without = MacAgentFacts(setup: DialogSetup(place: .cloud, sendsPush: true)).rows.first { $0.icon == .bell }
        #expect(without?.note?.contains("맥에서 직접 받아 바꿔 띄우고") == false)

        for place in [DialogPlace.local, .cloud] {
            let rows = MacAgentFacts(setup: DialogSetup(place: place, sendsPush: true, givesPushText: true)).rows
            let row = rows.first { $0.icon == .bell }
            // Apple을 거치는 것은 전과 같다
            #expect(row?.text.contains("Apple의 알림 서버") == true)
            #expect(row?.note?.contains("정해진 문장 하나") == true)
            #expect(row?.note?.contains("기기 토큰") == true)
            // 실제 글은 이 아이폰이 맥에서 직접 받는다
            #expect(row?.note?.contains("Apple을 거치지 않아요") == true)
            #expect(row?.note?.contains("맥에서 직접 받아 바꿔 띄우고, 받지 못하면 정해진 문장이 떠요") == true)
            #expect(row?.note?.contains("로그인한 화면에서 읽은 결과의 앞부분도 알림에 보일 수 있어요") == true)
            #expect(rows.last?.icon == .inbox)
        }
    }
}

// MARK: - 알림을 바꿔 넘기기

/// 이 파일만 쓰는 가짜 맥: 일의 번호마다 정해 둔 답을 준다 (묶음이 함께 돌아도 섞이지 않게 번호로 나눈다)
final class PushTextStubProtocol: URLProtocol, @unchecked Sendable {
    enum Answer: Sendable {
        case reply(Int, String)
        /// 답하지 않는다 (시간이 다 될 때까지)
        case silence
    }

    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var asked: [String: [URLRequest]] = [:]
    private static let lock = NSLock()

    static func set(_ answer: Answer, for taskID: String) { lock.withLock { answers[taskID] = answer } }
    static func requests(for taskID: String) -> [URLRequest] { lock.withLock { asked[taskID] ?? [] } }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushTextStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // 주소: /v1/tasks/<번호>/notification
        let parts = request.url?.pathComponents ?? []
        let taskID = parts.count > 3 ? parts[3] : ""
        let answer = Self.lock.withLock {
            Self.asked[taskID, default: []].append(request)
            return Self.answers[taskID] ?? .reply(404, #"{"error": {"code": "task_not_found"}}"#)
        }
        guard case .reply(let status, let text) = answer, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 넘겨받은 알림을 모아 두는 상자
private final class Delivered: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [UNNotificationContent] = []
    var all: [UNNotificationContent] { lock.withLock { contents } }
    func add(_ content: UNNotificationContent) { lock.withLock { contents.append(content) } }
}

@Suite("알림의 글: 받으면 바꾸고, 못 받으면 그대로, 꼭 한 번만 넘긴다")
struct PushTextDeliveryTests {
    private let fixed = "부탁하신 일이 끝났어요"

    private func content(task: String?, type: String = "task_done", conversation: String? = "c_3") -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.body = fixed
        var info: [AnyHashable: Any] = ["type": type]
        if let task { info["task_id"] = task }
        if let conversation { info["conversation_id"] = conversation }
        content.userInfo = info
        return content
    }

    private func request(_ target: PushText.Target) -> URLRequest? {
        PushText.request(for: target, host: "mac.example.test", token: "virtual-token")
    }

    /// 알림이 넘어올 때까지 기다린다 (2초 안에 오지 않으면 그만둔다)
    private func wait(_ box: Delivered, count: Int = 1) async {
        for _ in 0..<200 where box.all.count < count { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theTextFromTheMacReplacesTheFixedSentence() async {
        PushTextStubProtocol.set(.reply(200, #"{"type": "task_done", "title": "주간 회의록 정리", "body": "정리를 마쳤어요.\n결정 3건, 할 일 5건이에요."}"#), for: "t_ok")
        let box = Delivered()
        let delivery = PushTextDelivery(content: content(task: "t_ok")) { box.add($0) }
        delivery.start(session: PushTextStubProtocol.session, makeRequest: request)
        await wait(box)
        #expect(box.all.count == 1)
        #expect(box.all.first?.title == "주간 회의록 정리")
        #expect(box.all.first?.body == "정리를 마쳤어요.\n결정 3건, 할 일 5건이에요.")
        #expect(box.all.first?.threadIdentifier == "c_3")
        // 눌렀을 때 갈 곳을 아는 번호는 그대로다
        #expect(box.all.first?.userInfo["task_id"] as? String == "t_ok")
        // 맥에는 번호와 종류, 토큰만 갔다
        let asked = PushTextStubProtocol.requests(for: "t_ok")
        #expect(asked.count == 1)
        #expect(asked.first?.url?.absoluteString == "https://mac.example.test/v1/tasks/t_ok/notification?type=task_done")
        #expect(asked.first?.value(forHTTPHeaderField: "X-App-Token") == "virtual-token")
    }

    @Test func aGoneTextKeepsTheFixedSentence() async {
        PushTextStubProtocol.set(.reply(404, #"{"error": {"code": "notification_gone"}}"#), for: "t_gone")
        let box = Delivered()
        PushTextDelivery(content: content(task: "t_gone")) { box.add($0) }
            .start(session: PushTextStubProtocol.session, makeRequest: request)
        await wait(box)
        #expect(box.all.count == 1)
        #expect(box.all.first?.body == fixed)
        #expect(box.all.first?.title == "")
        // 글을 못 받아도 같은 대화의 알림과 묶인다
        #expect(box.all.first?.threadIdentifier == "c_3")
    }

    @Test func aRefusedOrOddAnswerKeepsTheFixedSentence() async {
        PushTextStubProtocol.set(.reply(401, #"{"error": {"code": "unauthorized"}}"#), for: "t_401")
        PushTextStubProtocol.set(.reply(200, "<html>가상의 다른 화면</html>"), for: "t_html")
        PushTextStubProtocol.set(.reply(200, #"{"type": "approval_needed", "title": "다른 일", "body": "다른 종류의 글"}"#), for: "t_other")
        for task in ["t_401", "t_html", "t_other"] {
            let box = Delivered()
            PushTextDelivery(content: content(task: task)) { box.add($0) }
                .start(session: PushTextStubProtocol.session, makeRequest: request)
            await wait(box)
            #expect(box.all.map(\.body) == [fixed], "\(task)")
        }
    }

    @Test func anUnknownNotificationIsPassedOnWithoutAsking() async {
        let box = Delivered()
        // 일의 번호가 없다
        PushTextDelivery(content: content(task: nil)) { box.add($0) }
            .start(session: PushTextStubProtocol.session, makeRequest: request)
        // 모르는 종류다
        PushTextDelivery(content: content(task: "t_news", type: "news")) { box.add($0) }
            .start(session: PushTextStubProtocol.session, makeRequest: request)
        // 바로(묻지 않고) 넘어온다
        #expect(box.all.map(\.body) == [fixed, fixed])
        #expect(box.all.map(\.threadIdentifier) == ["", ""])
        #expect(PushTextStubProtocol.requests(for: "t_news").isEmpty)
    }

    @Test func withoutAHostItIsPassedOnAtOnce() {
        let box = Delivered()
        PushTextDelivery(content: content(task: "t_nohost")) { box.add($0) }
            .start(session: PushTextStubProtocol.session) { PushText.request(for: $0, host: nil, token: nil) }
        #expect(box.all.map(\.body) == [fixed])
        #expect(PushTextStubProtocol.requests(for: "t_nohost").isEmpty)
    }

    @Test func whenTimeRunsOutTheFixedSentenceGoesOnce() async {
        PushTextStubProtocol.set(.silence, for: "t_slow")
        let box = Delivered()
        let delivery = PushTextDelivery(content: content(task: "t_slow")) { box.add($0) }
        delivery.start(session: PushTextStubProtocol.session, makeRequest: request)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(box.all.isEmpty)
        delivery.expire()
        #expect(box.all.map(\.body) == [fixed])
        // 그만둔 요청이 뒤늦게 끝나도, 또 시간이 다 됐다고 해도 다시 넘기지 않는다
        delivery.expire()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(box.all.count == 1)
    }

    @Test func anAnswerAfterTheTimeRanOutIsDropped() async {
        PushTextStubProtocol.set(.reply(200, #"{"type": "task_done", "title": "일", "body": "늦게 온 글"}"#), for: "t_late")
        let box = Delivered()
        let delivery = PushTextDelivery(content: content(task: "t_late")) { box.add($0) }
        // 시간이 먼저 다 됐다
        delivery.expire()
        delivery.start(session: PushTextStubProtocol.session, makeRequest: request)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(box.all.map(\.body) == [fixed])
    }
}
