import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 맥 에이전트 새 버전(API v2) 연동: 작업 담당의 질문과 답, 진행 설명, 한 일·못 한 일 보고, 같은 메시지 번호로 다시 받기.
// 응답 예시는 실제 서버 코드가 가상 데이터로 돌려준 것을 옮겼다 (이름·주소는 모두 가짜).

private enum Fixture {
    static let narrationHead = """
    {"time":"2026-11-11T16:02:35+00:00","text":"작업을 시작했어요"},{"time":"2026-11-11T16:02:35+00:00","text":"테스트 메일을 열었어요"},\
    {"time":"2026-11-11T16:02:35+00:00","text":"'메일 쓰기'를 눌렀어요"},{"time":"2026-11-11T16:02:35+00:00","text":"확인할 것이 있어 질문을 보냈어요"}
    """
    static let head = """
    "id":"AXpFhiRhOBBPSQy4","task":"팀에 매출 자료 요청 초안 써 줘","created_at":"2026-11-11T16:02:35+00:00","updated_at":"2026-11-11T16:02:35+00:00",\
    "title":"매출 자료 요청 초안"
    """
    static let steps = """
    {"n":1,"tool":"navigate","args":{"url":"http://mail.test/inbox"},"status":"ok","url":"http://mail.test/inbox"},\
    {"n":2,"tool":"click","args":{"ref":"e1"},"status":"ok","url":"http://mail.test/compose"}
    """
    static func asking(received: Bool) -> String {
        """
        {\(head),"status":"awaiting_input","steps":[\(steps)],"narration":[\(narrationHead)],\
        "question":{"question_id":"Z4gBmodrDlM","text":"어느 분기 자료를 요청할까요?","choices":["3분기","4분기"],\
        "asked_at":"2026-11-11T16:02:35+00:00","expires_in_s":1800\(received ? #","received":true"# : "")}}
        """
    }
    static let completed = """
    {\(head),"status":"completed","steps":[\(steps),\
    {"n":3,"tool":"type","args":{"ref":"e5","text":"(본문)"},"status":"ok","url":"http://mail.test/compose"},\
    {"n":4,"tool":"click","args":{"ref":"e6"},"status":"ok","url":"http://mail.test/drafts"}],\
    "narration":[\(narrationHead),{"time":"2026-11-11T16:02:36+00:00","text":"답을 받아 이어서 진행해요"},\
    {"time":"2026-11-11T16:02:37+00:00","text":"'본문' 칸을 채웠어요"},\
    {"time":"2026-11-11T16:02:38+00:00","text":"초안을 저장해도 될지 승인을 기다리고 있어요"},\
    {"time":"2026-11-11T16:02:39+00:00","text":"'임시 저장'을 눌렀어요"},{"time":"2026-11-11T16:02:40+00:00","text":"작업을 마쳤어요"}],\
    "result":{"outcome":"completed","summary":"3분기 매출 자료 요청 초안을 임시 저장했습니다",\
    "approved_drafts":[{"draft_id":"d_gX7dTVljrMFA","sha256":"582e9c26b80d85c94e503f4f1e81834ef696efd94b53ee197ee3e7618a022168",\
    "action":"임시 저장","url":"http://mail.test/compose","fields":{"받는 사람":"test-b@mail.test","제목":"3분기 매출 자료 요청","본문":"안녕하세요."}}],\
    "report":{"done":["test-b@mail.test에게 보낼 3분기 매출 자료 요청 초안을 임시 저장"],"blocked":["첨부할 자료 파일은 찾지 못함"],\
    "sources":["http://mail.test/inbox","http://mail.test/compose","http://mail.test/drafts"]}}}
    """
    static let verifyFailed = """
    {"id":"tWnH-70Eb6qlqHag","status":"failed","task":"초안 저장","created_at":"2026-11-11T16:02:35+00:00","updated_at":"2026-11-11T16:02:35+00:00",\
    "steps":[{"n":1,"tool":"navigate","args":{"url":"http://mail.test/inbox"},"status":"ok","url":"http://mail.test/inbox"}],"title":"초안 저장",\
    "narration":[{"time":"2026-11-11T16:02:35+00:00","text":"작업을 시작했어요"},{"time":"2026-11-11T16:02:35+00:00","text":"작업을 끝내지 못했어요"}],\
    "result":{"outcome":"verify_failed","summary":"초안을 임시 저장했습니다 [검증 실패: 저장 버튼을 누른 적이 없다]","approved_drafts":[],\
    "report":{"done":[],"blocked":["완료 보고가 검증을 통과하지 못함: 보고에는 저장했다고 했지만 이번 작업에서 저장 버튼을 누른 적이 없다"],\
    "sources":["http://mail.test/inbox"]}}}
    """

    static func decode(_ json: String) throws -> AgentTaskState {
        try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
    }
}

@Suite("맥 에이전트 v2 응답 해석")
struct AgentV2DecodeTests {
    @Test func questionIsReadAsAwaitingInput() throws {
        let state = try Fixture.decode(Fixture.asking(received: false))
        #expect(state.phase == .awaitingInput)
        #expect(!state.phase.isFinished)
        let question = try #require(state.openQuestion)
        #expect(question.id == "Z4gBmodrDlM")
        #expect(question.text == "어느 분기 자료를 요청할까요?")
        #expect(question.choices == ["3분기", "4분기"])
        #expect(state.statusLabel == "답변 필요")
        #expect(state.currentStatus == "질문에 답해 주세요")
        #expect(!state.isWorking)
    }

    @Test func answeredQuestionIsNotAskedAgain() throws {
        let state = try Fixture.decode(Fixture.asking(received: true))
        #expect(state.phase == .awaitingInput)
        #expect(state.openQuestion == nil)
        #expect(state.isWorking)
        #expect(state.currentStatus == "답을 받아 이어서 진행해요")
    }

    @Test func questionStatusWithoutQuestionStaysRunning() throws {
        // 질문이 빠진 응답이면 물어볼 수 없다. 실패로 만들지 않고 다음 조회를 기다린다
        let json = #"{"id":"t1","status":"awaiting_input","task":"초안","steps":[]}"#
        let state = try Fixture.decode(json)
        #expect(state.phase == .running)
        #expect(state.openQuestion == nil)
    }

    @Test func narrationBecomesTheTimelineWithTimes() throws {
        let state = try Fixture.decode(Fixture.completed)
        let timeline = state.timeline
        #expect(timeline.count == 9)
        #expect(timeline.allSatisfy { $0.kind == .narration && $0.time != nil })
        #expect(timeline.first?.text == "작업을 시작했어요")
        #expect(timeline.last?.text == "작업을 마쳤어요")
        // 입력한 내용은 기록에 나오지 않는다 (단계 기록의 "입력 · …" 대신 칸 이름만)
        #expect(!timeline.contains { $0.text.contains("(본문)") })
    }

    @Test func runningTaskShowsTheLastNarrationOnTheCard() throws {
        let json = """
        {"id":"t1","status":"running","task":"초안","steps":[{"n":1,"tool":"navigate","args":{"url":"http://mail.test/inbox"},"status":"ok"}],\
        "narration":[{"time":"2026-11-11T16:02:35+00:00","text":"작업을 시작했어요"},{"time":"2026-11-11T16:02:36+00:00","text":"테스트 메일을 열었어요"}]}
        """
        #expect(try Fixture.decode(json).currentStatus == "테스트 메일을 열었어요")
    }

    @Test func reportSplitsDoneAndBlocked() throws {
        let state = try Fixture.decode(Fixture.completed)
        #expect(state.phase == .done)
        let report = try #require(state.report)
        #expect(report.done == ["test-b@mail.test에게 보낼 3분기 매출 자료 요청 초안을 임시 저장"])
        #expect(report.blocked == ["첨부할 자료 파일은 찾지 못함"])
        #expect(report.sources.count == 3)
        #expect(state.approvedDrafts.count == 1)
        // 테스트·내부 주소는 링크로 만들지 않는다
        #expect(report.sources.compactMap(AgentLink.openable).isEmpty)
    }

    @Test func verifyFailedExplainsAndKeepsTheReason() throws {
        let state = try Fixture.decode(Fixture.verifyFailed)
        #expect(state.phase == .failed)
        #expect(state.error == "맥의 완료 보고가 실제로 한 일과 맞지 않아 작업을 끝냈어요.")
        #expect(state.report?.done.isEmpty == true)
        #expect(state.report?.blocked.first?.hasPrefix("완료 보고가 검증을 통과하지 못함") == true)
    }

    @Test func internalErrorHasItsOwnSentence() throws {
        let json = #"{"id":"t1","status":"failed","task":"초안","steps":[],"result":{"outcome":"internal_error","summary":""}}"#
        #expect(try Fixture.decode(json).error == "맥 에이전트 안에서 오류가 나 작업을 끝내지 못했어요.")
    }

    @Test func oldTaskWithoutNewFieldsKeepsStepTimeline() throws {
        let json = """
        {"id":"t1","status":"awaiting_approval","task":"초안","steps":[{"n":1,"tool":"navigate","args":{"url":"http://mail.test/inbox"},"status":"ok"},\
        {"n":2,"tool":"click","args":{"ref":"e6"},"status":"needs_approval"}],\
        "approval":{"approval_id":"ap1","action":"임시 저장","fields":{"제목":"공유"}}}
        """
        let state = try Fixture.decode(json)
        #expect(state.narration == nil && state.report == nil && state.pendingQuestion == nil)
        #expect(state.timeline.map(\.kind) == [.action, .milestone])
    }

    @Test func savedStateWithQuestionSurvivesEncoding() throws {
        var state = try Fixture.decode(Fixture.asking(received: false))
        state.answered = [AgentAnswered(question: "어느 분기 자료를 요청할까요?", answer: "3분기")]
        let restored = try JSONDecoder().decode(AgentTaskState.self, from: JSONEncoder().encode(state))
        #expect(restored == state)
    }

    @Test func featuresAreReadFromHealth() {
        let new = Data(#"{"status":"ok","features":["messages","client_message_id","task_questions"]}"#.utf8)
        #expect(AgentHTTPClient.decodeFeatures(new) == ["messages", "client_message_id", "task_questions"])
        // 이전 서버: 목록이 없으면 새 기능을 켜지 않는다
        #expect(AgentHTTPClient.decodeFeatures(Data(#"{"status":"ok"}"#.utf8)).isEmpty)
        #expect(AgentHTTPClient.decodeFeatures(Data()).isEmpty)
    }

    @Test func timelineIconsFollowTheSentence() {
        func symbol(_ text: String, _ kind: AgentEvent.Kind = .narration) -> String {
            AgentTaskDetailView.symbol(for: AgentEvent(id: 0, kind: kind, text: text))
        }
        #expect(symbol("테스트 메일을 열었어요") == "globe")
        #expect(symbol("'임시 저장'을 눌렀어요") == "hand.tap")
        #expect(symbol("'본문' 칸을 채웠어요") == "square.and.pencil")
        #expect(symbol("처음 보는 문장") == "circle.fill")
        #expect(symbol("승인 요청", .milestone) == "hand.raised")
        #expect(symbol("입력 · 회의 공유", .action) == "square.and.pencil")
    }
}

/// 요청을 가로채 기록하고 정해 둔 응답을 돌려준다
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let path: String
        let headers: [String: String]
        let body: String
    }

    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var respond: @Sendable (String) -> (Int, String) = { _ in (200, "{}") }
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let path = request.url?.path() ?? ""
        let (status, text) = Self.lock.withLock {
            Self.seen.append(Seen(path: path, headers: request.allHTTPHeaderFields ?? [:], body: String(decoding: body, as: UTF8.self)))
            return Self.respond(path)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("맥 에이전트 v2 요청", .serialized)
struct AgentV2RequestTests {
    private static let reply = #"{"conversation_id":"c_1","replies":[{"text":"안녕하세요."}],"action":{"type":"none"}}"#
    private static let accounts = """
    {"accounts":[{"provider":"naver","address":"me@naver.test","status":"ready","default":true,"checked_at":"2026-11-12T01:00:00+00:00"},\
    {"provider":"gmail","address":"me@gmail.test","status":"auth_failed","default":false,"checked_at":null},\
    {"provider":"other","address":"me@mail.test","status":"something_new"}]}
    """

    private func client(features: String) -> AgentHTTPClient {
        StubProtocol.lock.withLock {
            StubProtocol.seen = []
            StubProtocol.respond = { path in
                if path.hasSuffix("/health") { return (200, #"{"status":"ok"\#(features)}"#) }
                if path.hasSuffix("/answer") { return (200, Fixture.asking(received: true)) }
                if path.contains("/v1/mail/accounts") { return (200, Self.accounts) }
                return (200, Self.reply)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return AgentHTTPClient(baseURL: URL(string: "http://mac.test:8765")!, token: "t", session: URLSession(configuration: configuration))
    }

    private func seen(_ suffix: String) -> StubProtocol.Seen? {
        StubProtocol.lock.withLock { StubProtocol.seen.last { $0.path.hasSuffix(suffix) } }
    }

    @Test func newServerGetsVersionHeaderAndMessageID() async throws {
        let client = client(features: #","features":["messages","client_message_id","task_questions"]"#)
        #expect(await client.isReachable())
        #expect(await client.supports(AgentFeature.messageReplay))
        _ = try await client.message("안녕", conversationID: nil, context: nil, messageID: "0B3F6E1A-AAAA-BBBB-CCCC-000000000001")
        let request = try #require(seen("/v1/messages"))
        #expect(request.headers["X-Api-Version"] == "2")
        #expect(request.body.contains(#""client_message_id":"0B3F6E1A-AAAA-BBBB-CCCC-000000000001""#))
    }

    @Test func oldServerGetsNeitherHeaderNorMessageID() async throws {
        let client = client(features: "")
        #expect(await client.isReachable())
        #expect(await client.supports(AgentFeature.messageReplay) == false)
        _ = try await client.message("안녕", conversationID: nil, context: nil, messageID: "0B3F6E1A-AAAA-BBBB-CCCC-000000000001")
        let request = try #require(seen("/v1/messages"))
        #expect(request.headers["X-Api-Version"] == nil)
        #expect(!request.body.contains("client_message_id"))
    }

    @Test func toneGoesOnlyToServersThatKnowIt() async throws {
        var client = client(features: #","features":["messages","tone"]"#)
        client.tone = { .formal }
        #expect(await client.isReachable())
        _ = try await client.message("안녕", conversationID: nil, context: nil, messageID: nil)
        #expect(try #require(seen("/v1/messages")).body.contains(#""tone":"formal""#))

        client.tone = { .friendly }
        _ = try await client.message("안녕", conversationID: nil, context: nil, messageID: nil)
        #expect(try #require(seen("/v1/messages")).body.contains(#""tone":"friendly""#))
    }

    @Test func serverWithoutToneGetsNoToneField() async throws {
        var client = client(features: #","features":["messages","client_message_id","task_questions"]"#)
        client.tone = { .formal }
        #expect(await client.isReachable())
        _ = try await client.message("안녕", conversationID: nil, context: nil, messageID: nil)
        // 모르는 값을 받으면 거절하는 서버가 있을 수 있어, 지원한다고 알린 서버에만 보낸다
        #expect(!(try #require(seen("/v1/messages")).body.contains("tone")))
    }

    @Test func answerGoesToTheTaskWithItsQuestionID() async throws {
        let client = client(features: #","features":["task_questions"]"#)
        let state = try await client.answer("AXpFhiRhOBBPSQy4", questionID: "Z4gBmodrDlM", answer: "3분기")
        let request = try #require(seen("/answer"))
        #expect(request.path == "/v1/tasks/AXpFhiRhOBBPSQy4/answer")
        #expect(request.body.contains(#""question_id":"Z4gBmodrDlM""#))
        #expect(request.body.contains(#""answer":"3분기""#))
        // 답만 보내는 요청에는 버전 헤더가 필요 없다 (작업을 만드는 요청에만 붙인다)
        #expect(request.headers["X-Api-Version"] == nil)
        #expect(state.pendingQuestion?.received == true)
    }

    // MARK: 메일 보내기 (send_self)·계정 연결 (mail_connect)

    @Test func sendingServerGetsVersionThree() async throws {
        let client = client(features: #","features":["messages","client_message_id","task_questions","send_self"]"#)
        #expect(await client.isReachable())
        #expect(await client.supports(AgentFeature.sendSelf))
        _ = try await client.message("안녕", conversationID: nil, context: nil, messageID: nil)
        // 3을 붙인 요청에만 보내기 작업이 만들어진다 (보내기 화면을 모르는 이전 앱에는 그 상태가 가지 않는다)
        #expect(try #require(seen("/v1/messages")).headers["X-Api-Version"] == "3")
    }

    @Test func serverWithoutSendingKeepsVersionTwo() async throws {
        let client = client(features: #","features":["messages","task_questions","mail_connect"]"#)
        #expect(await client.isReachable())
        #expect(await client.supports(AgentFeature.sendSelf) == false)
        _ = try await client.message("안녕", conversationID: nil, context: nil, messageID: nil)
        #expect(try #require(seen("/v1/messages")).headers["X-Api-Version"] == "2")
    }

    @Test func mailAccountsAreReadWithTheirStatus() async throws {
        let client = client(features: #","features":["send_self"]"#)
        let accounts = try await client.mailAccounts(check: false)
        #expect(try #require(seen("/v1/mail/accounts")).path == "/v1/mail/accounts")
        #expect(accounts.map(\.address) == ["me@naver.test", "me@gmail.test", "me@mail.test"])
        #expect(accounts.map(\.status) == [.ready, .authFailed, .unknown])
        #expect(accounts.map(\.isDefault) == [true, false, false])
        #expect(accounts[0].checkedAt != nil)
        #expect(accounts[1].checkedAt == nil)
        #expect(accounts[0].providerName == "네이버 메일")
        #expect(accounts[1].providerName == "Gmail")

        _ = try await client.mailAccounts(check: true)
        #expect(seen("/check")?.path == "/v1/mail/accounts/check")
    }

    @Test func appPasswordGoesOnlyToTheConnectEndpoint() async throws {
        let client = client(features: #","features":["send_self","mail_connect"]"#)
        #expect(await client.isReachable())
        let accounts = try await client.connectMail(provider: "naver", address: "me@naver.test", password: "abcdabcdabcdabcd")
        let request = try #require(seen("/connect"))
        #expect(request.path == "/v1/mail/accounts/connect")
        #expect(request.body.contains(#""provider":"naver""#))
        #expect(request.body.contains(#""address":"me@naver.test""#))
        #expect(request.body.contains(#""app_password":"abcdabcdabcdabcd""#))
        // 돌아오는 것은 계정 목록뿐이다
        #expect(accounts.first?.status == .ready)
        // 다른 요청에는 어디에도 실리지 않는다
        let others = StubProtocol.lock.withLock { StubProtocol.seen.filter { !$0.path.hasSuffix("/connect") } }
        #expect(others.allSatisfy { !$0.body.contains("abcdabcd") && !$0.headers.values.contains { $0.contains("abcdabcd") } })
    }

    @Test func appPasswordIsNotSentToAServerThatDoesNotKnowConnect() async throws {
        let client = client(features: #","features":["send_self"]"#)
        #expect(await client.isReachable())
        await #expect(throws: AgentError.conflict) {
            _ = try await client.connectMail(provider: "naver", address: "me@naver.test", password: "abcdabcdabcdabcd")
        }
        #expect(seen("/connect") == nil)
        #expect(StubProtocol.lock.withLock { StubProtocol.seen.allSatisfy { !$0.body.contains("abcdabcd") } })
    }
}

/// 처음 `losses`번은 맥이 메시지를 처리했는데 앱이 답을 받지 못한다 (늦음·연결 끊김)
actor LostReplyAgent: AgentProviding {
    let inner = MockAgentClient(v2: true)
    let replays: Bool
    let error: AgentError
    var losses: Int
    init(losses: Int = 1, replays: Bool = true, error: AgentError = .slow) {
        self.losses = losses
        self.replays = replays
        self.error = error
    }
    func isReachable() async -> Bool { true }
    func supports(_ feature: String) async -> Bool { replays }
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        try await message(text, conversationID: conversationID, context: context, messageID: nil)
    }
    func message(_ text: String, conversationID: String?, context: String?, messageID: String?) async throws -> AgentReply {
        // 번호를 모르는 서버는 같은 메시지를 새 메시지로 처리한다
        let reply = try await inner.message(text, conversationID: conversationID, context: context, messageID: replays ? messageID : nil)
        if losses > 0 {
            losses -= 1
            throw error
        }
        return reply
    }
    func answer(_ id: String, questionID: String, answer: String) async throws -> AgentTaskState {
        try await inner.answer(id, questionID: questionID, answer: answer)
    }
    func start(task: String, context: String?) async throws -> AgentTaskState { try await inner.start(task: task, context: context) }
    func state(of id: String) async throws -> AgentTaskState { try await inner.state(of: id) }
    func cancel(_ id: String) async throws -> AgentTaskState { try await inner.cancel(id) }
    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        try await inner.decide(id, approvalID: approvalID, approve: approve, reason: reason, sha256: sha256)
    }
}

/// 질문 시간이 지난 뒤에 답을 받는 맥: 답은 거절(409)하고 작업은 이미 다음으로 넘어가 있다
actor ExpiredQuestionAgent: AgentProviding {
    let inner = MockAgentClient(v2: true)
    func isReachable() async -> Bool { true }
    func supports(_ feature: String) async -> Bool { true }
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        try await inner.message(text, conversationID: conversationID, context: context)
    }
    func answer(_ id: String, questionID: String, answer: String) async throws -> AgentTaskState {
        // 맥은 답 없이 진행했다 (가짜 맥에서는 답을 넣어 다음으로 넘긴다)
        _ = try await inner.answer(id, questionID: questionID, answer: "넣지 않기")
        _ = try await inner.state(of: id)
        throw AgentError.conflict
    }
    func start(task: String, context: String?) async throws -> AgentTaskState { try await inner.start(task: task, context: context) }
    func state(of id: String) async throws -> AgentTaskState { try await inner.state(of: id) }
    func cancel(_ id: String) async throws -> AgentTaskState { try await inner.cancel(id) }
    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        try await inner.decide(id, approvalID: approvalID, approve: approve, reason: reason, sha256: sha256)
    }
}

@MainActor
@Suite("맥 에이전트 v2 흐름")
struct AgentV2FlowTests {
    let context: ModelContext
    let meeting: Meeting
    private static let request = "지난 회의 내용 팀에게 메일 초안 써줘. 참조도 넣어줘"

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        meeting = Meeting(title: "주간 회의")
        context.insert(meeting)
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
    }

    private func session(_ agent: any AgentProviding, maxResends: Int = 3) -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero, maxResends: maxResends)
        session.attach(context)
        return session
    }

    @Test func questionIsAnsweredOnTheSameTask() async throws {
        let agent = MockAgentClient(v2: true)
        let session = session(agent)
        await session.send(Self.request, meetings: [meeting])

        // 작업 담당이 묻고 멈춘다: 승인 대기처럼 기다리는 표시는 꺼지고, 답이 필요하다고 알린다
        let asking = try #require(session.openQuestionTask)
        #expect(asking.openQuestion?.choices == ["넣지 않기", "팀 전체"])
        #expect(session.status == .needsAnswer)
        #expect(!session.isLoading)
        let messagesBefore = session.messages.count

        // 입력창에 쓴 글은 새 메시지가 아니라 그 질문의 답으로 간다
        await session.send("넣지 않기", meetings: [meeting])
        #expect(await agent.received.count == 1)
        #expect(await agent.answers.map(\.answer) == ["넣지 않기"])
        #expect(await agent.answers.first?.questionID == asking.openQuestion?.id)
        #expect(session.messages.count == messagesBefore)

        // 같은 작업이 이어져 승인 대기까지 간다. 질문과 답은 작업에 남는다
        let state = try #require(session.messages.last?.agent)
        #expect(state.id == asking.id)
        #expect(state.phase == .awaitingApproval)
        #expect(state.answered == [AgentAnswered(question: "참조에는 누구를 넣을까요?", answer: "넣지 않기")])
        #expect(state.timeline.contains { $0.text == "답을 받아 이어서 진행해요" })

        await session.decide(state.id, approve: true)
        let done = try #require(session.messages.last?.agent)
        #expect(done.phase == .done)
        #expect(done.report?.done.isEmpty == false)
        #expect(done.answered?.count == 1)
        #expect(done.timeline.last?.text == "작업을 마쳤어요")
    }

    @Test func openQuestionSurvivesRelaunch() async throws {
        let agent = MockAgentClient(v2: true)
        await session(agent).send(Self.request, meetings: [meeting])

        let reopened = session(agent)
        await reopened.resumeAgent()
        let asking = try #require(reopened.openQuestionTask)
        await reopened.answer(asking.id, with: "팀 전체")
        #expect(reopened.messages.last?.agent?.phase == .awaitingApproval)
        #expect(reopened.messages.last?.agent?.answered?.first?.answer == "팀 전체")
    }

    @Test func lateAnswerIsMarkedUndeliveredAndTheTaskGoesOn() async throws {
        let session = session(ExpiredQuestionAgent())
        await session.send(Self.request, meetings: [meeting])
        let asking = try #require(session.openQuestionTask)

        await session.answer(asking.id, with: "팀 전체")
        let state = try #require(session.messages.last?.agent)
        #expect(state.answered == [AgentAnswered(question: "참조에는 누구를 넣을까요?", answer: "팀 전체", delivered: false)])
        // 오류로 끝내지 않고 지금 상태부터 따라간다
        #expect(state.phase == .awaitingApproval)
        #expect(session.messages.last?.role == .agent)
    }

    @Test func taskCanBeStoppedWhileItAsks() async throws {
        let session = session(MockAgentClient(v2: true))
        await session.send(Self.request, meetings: [meeting])
        let asking = try #require(session.openQuestionTask)

        await session.cancelAgent(asking.id)
        #expect(session.messages.last?.agent?.phase == .canceled)
        #expect(session.openQuestionTask == nil)
        #expect(session.status == nil)
    }

    @Test func lostReplyIsFetchedAgainWithTheSameMessageID() async throws {
        // 맥은 작업을 만들었는데 앱이 답을 받지 못했다 → 같은 번호로 다시 받는다. 작업은 하나뿐이다
        let agent = LostReplyAgent(losses: 2)
        let session = session(agent)
        await session.send("지난 회의 내용 팀에게 메일 초안 써줘", meetings: [meeting])

        let ids = await agent.inner.messageIDs
        #expect(ids.count == 3)
        #expect(ids[0] != nil && Set(ids).count == 1)
        #expect(await agent.inner.received.count == 1)
        #expect(!session.messages.contains { $0.role == .error })
        #expect(session.messages.filter { $0.role == .agent }.count == 1)
        #expect(session.messages.last?.agent?.id == "task-1")
        #expect(session.messages.last?.agent?.phase == .awaitingApproval)
    }

    @Test func lostConnectionIsAlsoFetchedAgain() async throws {
        let agent = LostReplyAgent(error: .unreachable)
        let session = session(agent)
        await session.send("지난 회의 내용 팀에게 메일 초안 써줘", meetings: [meeting])
        #expect(await agent.inner.received.count == 1)
        #expect(session.messages.last?.agent?.id == "task-1")
    }

    @Test func resendingStopsAfterTheLimit() async throws {
        let agent = LostReplyAgent(losses: 10)
        let session = session(agent, maxResends: 2)
        await session.send("지난 회의 내용 팀에게 메일 초안 써줘", meetings: [meeting])
        #expect(await agent.inner.messageIDs.count == 3)
        #expect(session.messages.last?.role == .error)
        #expect(session.messages.last?.retryQuestion == "지난 회의 내용 팀에게 메일 초안 써줘")
    }

    @Test func oldServerIsNotResentAutomatically() async throws {
        // 번호를 모르는 맥에 자동으로 다시 보내면 작업이 두 개 생긴다 → 오류로 알리고 사용자가 정한다
        let agent = LostReplyAgent(replays: false)
        let session = session(agent)
        await session.send("지난 회의 내용 팀에게 메일 초안 써줘", meetings: [meeting])
        #expect(await agent.inner.received.count == 1)
        #expect(session.messages.last?.role == .error)
    }

    @Test func unansweredMessageIsPickedUpAfterRelaunch() async throws {
        // 답을 기다리다 앱이 꺼졌다: 맥은 이미 작업을 만들었다
        let agent = LostReplyAgent(losses: 1)
        let first = session(agent, maxResends: 0)
        await first.send("지난 회의 내용 팀에게 메일 초안 써줘", meetings: [meeting])
        #expect(first.messages.last?.role == .error)

        let reopened = session(agent)
        #expect(reopened.messages.last?.role == .user)
        await reopened.resumeMessage(meetings: [meeting])
        #expect(await agent.inner.received.count == 1)
        #expect(Set(await agent.inner.messageIDs).count == 1)
        #expect(reopened.messages.last?.agent?.id == "task-1")
        #expect(reopened.messages.filter { $0.role == .user }.count == 1)
    }

    @Test func oldUnansweredMessageIsNotResentAutomatically() async throws {
        let agent = LostReplyAgent(losses: 1)
        let first = session(agent, maxResends: 0)
        await first.send("지난 회의 내용 팀에게 메일 초안 써줘", meetings: [meeting])
        // 하루 전에 보낸 메시지로 만든다: 맥이 번호를 잊었을 수 있어 새 작업이 생길 수 있다
        let record = try #require(first.conversation?.sortedRecords.last)
        record.createdAt = .now.addingTimeInterval(-86_400)

        let reopened = session(agent)
        await reopened.resumeMessage(meetings: [meeting])
        #expect(await agent.inner.messageIDs.count == 1)
        #expect(reopened.messages.last?.role == .error)
        #expect(reopened.messages.last?.retryQuestion == "지난 회의 내용 팀에게 메일 초안 써줘")
        // 다시 불러도 안내가 겹치지 않는다
        await reopened.resumeMessage(meetings: [meeting])
        #expect(reopened.messages.filter { $0.role == .error }.count == 1)
    }

    @Test func answeredMessageIsLeftAlone() async throws {
        let agent = MockAgentClient(v2: true)
        let session = session(agent)
        await session.send("안녕", meetings: [meeting])
        await session.resumeMessage(meetings: [meeting])
        #expect(await agent.received.count == 1)
        #expect(session.messages.count == 2)
    }
}

@Suite("보고의 '○○ 열기' 줄 (D81)")
struct ReportSourceLineTests {
    private func links(_ urls: [String]) -> [AgentLink] {
        AgentLink.onePerSite(urls.compactMap(AgentLink.openable))
    }

    @Test("같은 사이트의 페이지가 여럿이면 한 줄만 두고, 마지막으로 연 페이지를 연다")
    func sameSiteIsOneLine() {
        let result = links(["https://www.example.com/", "https://www.example.com/timetable?day=mon"])
        #expect(result.map(\.title) == ["www.example.com"])
        #expect(result.first?.url.absoluteString == "https://www.example.com/timetable?day=mon")
    }

    @Test("다른 사이트는 따로 두고, 사이트가 처음 나온 차례를 지킨다")
    func differentSitesKeepOrder() {
        let result = links([
            "https://www.example.com/a", "https://news.example.org/1", "https://www.example.com/b"
        ])
        #expect(result.map(\.title) == ["www.example.com", "news.example.org"])
        #expect(result.map(\.url.path) == ["/b", "/1"])
    }

    @Test("앞의 www.만 다른 주소는 같은 사이트로 본다")
    func wwwIsSameSite() {
        let result = links(["https://example.com/a", "https://www.example.com/b"])
        #expect(result.count == 1)
        #expect(result.first?.title == "www.example.com")
    }

    @Test("하나뿐이거나 없으면 그대로다")
    func singleAndEmpty() {
        #expect(links(["https://www.example.com/a"]).map(\.url.path) == ["/a"])
        #expect(links([]).isEmpty)
        #expect(links(["http://www.example.com/a", "https://mac.internal/x"]).isEmpty)
    }
}

@Suite("대화의 작업 줄과 답 말풍선 (D82)")
struct TaskLineTests {
    private func state(_ phase: AgentTaskState.Phase) -> AgentTaskState {
        AgentTaskState(id: "t_1", task: "가상 작업", steps: [], phase: phase)
    }

    // MARK: 작업 줄

    @Test("끝난 작업은 한 줄만 남는다: 완료는 상태 이름도 붙이지 않는다")
    func finishedTaskIsOneLine() {
        let done = state(.done)
        #expect(done.isSettled)
        #expect(done.lineStatus == nil)
        #expect(done.lineActivity == nil)
    }

    @Test("취소·실패는 상태 이름만 붙고, 지금 하는 일은 없다")
    func stoppedTaskNamesItsState() {
        #expect(state(.canceled).lineStatus == "취소됨")
        #expect(state(.failed).lineStatus == "실패")
        #expect(state(.canceled).isSettled)
        #expect(state(.failed).isSettled)
        #expect(state(.canceled).lineActivity == nil)
        #expect(state(.failed).lineActivity == nil)
    }

    @Test("일하는 동안에만 지금 하는 일 한 문장이 붙는다")
    func workingTaskShowsWhatItIsDoing() {
        var running = state(.running)
        #expect(!running.isSettled)
        #expect(running.lineStatus == nil)
        #expect(running.lineActivity == "작업을 준비하고 있어요")
        running.activity = "가상할일의 목록을 여는 중이에요"
        #expect(running.lineActivity == "가상할일의 목록을 여는 중이에요")
        running.isQueued = true
        #expect(running.lineActivity == "앞 작업이 끝나기를 기다리고 있어요")
    }

    @Test("내가 정할 차례면 상태 이름이 붙고, 지금 하는 일은 없다 (바로 아래 카드가 말한다)")
    func waitingForMeNamesItsState() {
        let approval = state(.awaitingApproval)
        #expect(approval.lineStatus == "승인 필요")
        #expect(approval.lineActivity == nil)
        #expect(!approval.isSettled)
        let question = state(.awaitingInput)
        #expect(question.lineStatus == "답변 필요")
        #expect(question.lineActivity == nil)
    }

    // MARK: 멈춘 까닭

    @Test("끝내지 못한 까닭은 한 번만 말한다")
    func theReasonIsSaidOnce() {
        var denied = state(.canceled)
        denied.error = AgentTaskState.deniedText
        #expect(denied.stopReason(showsLoginCard: false) == "승인하지 않아 작업을 끝냈어요.")
        // 못 한 일 보고가 같은 말을 하면 "끝냈어요"만 하는 문장은 뺀다
        denied.report = AgentReport(blocked: ["승인하지 않으셔서 누르지 않았어요"])
        #expect(denied.stopReason(showsLoginCard: false) == nil)
        // 한 일만 있는 보고는 왜 멈췄는지 말해 주지 않으므로 까닭을 남긴다
        denied.report = AgentReport(done: ["목록을 열었어요"])
        #expect(denied.stopReason(showsLoginCard: false) == "승인하지 않아 작업을 끝냈어요.")
    }

    @Test("까닭이 따로 있는 문장은 보고가 있어도 말한다")
    func aSpecificReasonIsKept() {
        var failed = state(.failed)
        failed.error = "시간이 너무 오래 걸려서 멈췄어요."
        failed.report = AgentReport(blocked: ["목록을 끝까지 읽지 못했어요"])
        #expect(failed.stopReason(showsLoginCard: false) == "시간이 너무 오래 걸려서 멈췄어요.")
    }

    @Test("까닭을 받지 못했으면 멈췄다는 것만 말한다")
    func withoutAReasonItOnlySaysItStopped() {
        #expect(state(.failed).stopReason(showsLoginCard: false) == AgentTaskState.unfinishedText)
        #expect(state(.canceled).stopReason(showsLoginCard: false) == AgentTaskState.canceledText)
    }

    @Test("로그인 카드가 붙으면 카드가 말하므로 하지 않는다")
    func theLoginCardSpeaksInstead() {
        var failed = state(.failed)
        failed.error = AgentTaskState.loginFailureText(site: "todo.test", expired: true)
        #expect(failed.stopReason(showsLoginCard: true) == nil)
        #expect(failed.stopReason(showsLoginCard: false) != nil)
    }

    @Test("끝나지 않았거나 잘 끝난 작업에는 멈춘 까닭이 없다")
    func noReasonUnlessStopped() {
        #expect(state(.done).stopReason(showsLoginCard: false) == nil)
        #expect(state(.running).stopReason(showsLoginCard: false) == nil)
        #expect(state(.awaitingApproval).stopReason(showsLoginCard: false) == nil)
    }

    // MARK: "○○ 열기" 줄

    private let stayed = AgentLink.openable("https://www.example.com/last")

    @Test("맥이 근거 주소를 비워 보내면 열기 줄을 두지 않는다 (마지막으로 머문 페이지로 되돌아가지 않는다)")
    func emptySourcesMeanNoLine() throws {
        var done = state(.done)
        done.links = [try #require(stayed)]
        done.report = AgentReport(done: ["검색해서 알아낸 답이에요."])
        #expect(done.openLinks.isEmpty)
    }

    @Test("근거 주소가 있으면 사이트마다 한 줄")
    func sourcesBecomeOneLinePerSite() throws {
        var done = state(.done)
        done.links = [try #require(stayed)]
        done.report = AgentReport(done: ["답"], sources: ["https://shop.example.org/a", "https://shop.example.org/b", "https://todo.test/list"])
        #expect(done.openLinks.map(\.url.absoluteString) == ["https://shop.example.org/b"])
    }

    @Test("보고가 없는 작업은 지금처럼 마지막으로 머문 페이지를 연다")
    func withoutAReportTheLastPageIsKept() throws {
        var done = state(.done)
        #expect(done.openLinks.isEmpty)
        done.links = [try #require(stayed)]
        #expect(done.openLinks.map(\.url.path) == ["/last"])
    }

    // MARK: 답의 글

    @Test("맥이 '- '로 쓴 짧은 줄은 목록으로 나눈다")
    func dashLinesBecomeAList() {
        let lines = AnswerText.lines("지금 워크스페이스의 할 일은 2건이에요.\n- 회의록 정리\n- 장보기")
        #expect(lines == [.text("지금 워크스페이스의 할 일은 2건이에요."), .bullet("회의록 정리"), .bullet("장보기")])
    }

    @Test("목록 줄이 없는 글은 나누지 않는다")
    func plainTextIsLeftAlone() {
        #expect(AnswerText.lines("할 일을 추가했어요.") == nil)
        #expect(AnswerText.lines("첫 줄이에요.\n둘째 줄이에요.") == nil)
        #expect(AnswerText.lines("") == nil)
    }

    @Test("빼기 표시로 시작해도 띄어 쓰지 않았으면 목록이 아니다")
    func aMinusSignIsNotABullet() {
        #expect(AnswerText.lines("-3도까지 내려가요.") == nil)
        #expect(AnswerText.lines("오늘은 추워요.\n-3도까지 내려가요.") == nil)
        // 표시만 있고 글이 없는 줄도 목록이 아니다
        #expect(AnswerText.lines("가\n- ") == nil)
    }

    @Test("이어진 보통 줄은 한 문단으로 묶고, 빈 줄은 문단을 가른다")
    func plainLinesAreJoined() {
        let lines = AnswerText.lines("첫 줄\n둘째 줄\n\n- 하나\n\n끝맺는 말")
        #expect(lines == [.text("첫 줄\n둘째 줄"), .bullet("하나"), .text("끝맺는 말")])
    }

    @Test("가운뎃점·둥근 점으로 쓴 줄도 목록이다. 글자는 그대로 둔다")
    func otherBulletMarksWork() {
        let lines = AnswerText.lines("• 하나\n· 둘 - 셋\n  - 넷")
        #expect(lines == [.bullet("하나"), .bullet("둘 - 셋"), .bullet("넷")])
    }

    // MARK: 답을 말풍선으로 나누기, 굵은 글씨 (D84)

    @Test("빈 줄로 갈린 문단마다 말풍선 하나다. 문단이 하나면 그대로 하나다")
    func paragraphsBecomeBubbles() {
        #expect(AnswerText.bubbles("결론이에요.\n- 하나\n- 둘\n\n풀어 쓴 문단이에요.\n\n더 볼까요?")
            == ["결론이에요.\n- 하나\n- 둘", "풀어 쓴 문단이에요.", "더 볼까요?"])
        #expect(AnswerText.bubbles("할 일을 추가했어요.") == ["할 일을 추가했어요."])
        #expect(AnswerText.bubbles("첫 줄\n둘째 줄") == ["첫 줄\n둘째 줄"])
        // 빈 줄이 여러 개여도, 줄에 빈칸만 있어도 문단을 한 번 가를 뿐이다
        #expect(AnswerText.bubbles("가\n\n\n  \n나") == ["가", "나"])
        #expect(AnswerText.bubbles("") == [""])
    }

    @Test("목록만 든 문단은 앞 말풍선에 붙인다")
    func aListAloneJoinsTheBubbleBefore() {
        #expect(AnswerText.bubbles("결론이에요.\n\n- 하나\n- 둘\n\n끝맺는 말") == ["결론이에요.\n- 하나\n- 둘", "끝맺는 말"])
        // 앞에 아무것도 없으면 그 목록이 첫 말풍선이다
        #expect(AnswerText.bubbles("- 하나\n- 둘\n\n끝") == ["- 하나\n- 둘", "끝"])
    }

    @Test("말풍선은 정해 둔 수까지만 나누고, 남은 문단은 마지막에 붙인다")
    func bubblesAreLimited() {
        let text = (1...7).map { "문단 \($0)" }.joined(separator: "\n\n")
        let parts = AnswerText.bubbles(text)
        #expect(parts.count == 5)
        #expect(parts.last == "문단 5\n\n문단 6\n\n문단 7")
        #expect(AnswerText.bubbles("가\n\n나\n\n다", limit: 2) == ["가", "나\n\n다"])
    }

    private func strong(_ text: String) -> [String] {
        AnswerText.emphasized(text).runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(AnswerText.emphasized(text)[$0.range].characters) }
    }

    @Test("별표 두 개로 감싼 낱말만 굵게 그리고, 별표는 지운다")
    func doubleStarsBecomeBold() {
        let text = "이번 달은 **4건, 62,800원**이에요. 아직 **배송 중**이에요."
        #expect(String(AnswerText.emphasized(text).characters) == "이번 달은 4건, 62,800원이에요. 아직 배송 중이에요.")
        #expect(strong(text) == ["4건, 62,800원", "배송 중"])
        #expect(strong("**처음**부터") == ["처음"])
    }

    @Test("짝이 맞지 않거나 애매한 별표는 글자 그대로 둔다")
    func oddStarsAreLeftAlone() {
        for text in ["별 **하나만 열렸어요", "곱하기는 2 ** 3 ** 4", "빈 것 **** 은 그대로", "줄을 **넘는\n굵은** 글", "**a*b**", "별 없는 글"] {
            #expect(String(AnswerText.emphasized(text).characters) == text)
            #expect(strong(text).isEmpty)
        }
    }

    @Test("답의 글에서는 굵은 글씨 말고는 아무것도 만들지 않는다: 주소도 링크가 되지 않는다")
    func answerTextNeverMakesLinks() {
        let text = "[여기](https://shop.test/a)를 **꼭** 보세요. `코드` _기울임_ https://shop.test/b"
        let drawn = AnswerText.emphasized(text)
        #expect(String(drawn.characters) == "[여기](https://shop.test/a)를 꼭 보세요. `코드` _기울임_ https://shop.test/b")
        #expect(drawn.runs.allSatisfy { $0.link == nil })
        #expect(strong(text) == ["꼭"])
    }

    // MARK: "Claude 사용" 표시 (D83)

    private var claude: String { ReplyWriter.claude.rawValue }

    @Test("맡았다는 말과 답을 모두 Claude가 썼으면 표시는 답 아래 한 번뿐이다")
    func claudeIsMarkedOncePerTurn() {
        var done = state(.done)
        done.ack = "네, 찾아볼게요."
        done.ackBy = claude
        done.report = AgentReport(done: ["찾은 답이에요."], by: claude)
        #expect(done.marksClaudeOnResult)
        #expect(!done.marksClaudeOnAck)
    }

    @Test("일하는 동안이나 답을 Claude가 쓰지 않았을 때는 맡았다는 말 아래에 남는다")
    func ackKeepsTheMarkUntilTheAnswerCarriesIt() {
        var running = state(.running)
        running.ack = "네, 찾아볼게요."
        running.ackBy = claude
        #expect(running.marksClaudeOnAck)
        #expect(!running.marksClaudeOnResult)

        var done = running
        done.phase = .done
        done.report = AgentReport(done: ["맥이 읽어 온 값이에요."])
        #expect(done.marksClaudeOnAck)
        #expect(!done.marksClaudeOnResult)

        // 답 없이 끝난 작업(못 한 일만 있는 보고)에도 답 아래 표시는 없다
        var stopped = running
        stopped.phase = .failed
        stopped.report = AgentReport(done: ["하다 만 일"], blocked: ["로그인이 풀렸어요"], by: claude)
        #expect(stopped.marksClaudeOnAck)
        #expect(!stopped.marksClaudeOnResult)
    }

    @Test("Claude가 쓰지 않은 말에는 어디에도 붙지 않는다")
    func nothingIsMarkedWithoutClaude() {
        var done = state(.done)
        done.ack = "네, 확인할게요."
        done.report = AgentReport(done: ["맥이 읽어 온 값이에요."])
        #expect(!done.marksClaudeOnAck)
        #expect(!done.marksClaudeOnResult)
        // 맡았다는 말이 없으면 그 자리의 표시도 없다
        done.ackBy = claude
        done.ack = nil
        #expect(!done.marksClaudeOnAck)
    }

    @Test("초안이 본문인 결과에서는 보고가 덧말이라 답 아래 표시가 없다 — 맡았다는 말 아래에 남는다")
    func draftResultsKeepTheMarkOnTheAck() {
        var done = state(.done)
        done.ack = "네, 초안을 써 둘게요."
        done.ackBy = claude
        done.report = AgentReport(done: ["초안을 저장했어요."], by: claude)
        done.approvedDrafts = [AgentDraft(approvalID: nil, action: "임시 저장", fields: [])]
        #expect(done.reportFollowsDrafts)
        #expect(!done.marksClaudeOnResult)
        #expect(done.marksClaudeOnAck)
        // 못 한 일이 있으면 보고가 먼저다
        done.report = AgentReport(done: ["초안을 저장했어요."], blocked: ["첨부는 붙이지 못했어요"], by: claude)
        #expect(!done.reportFollowsDrafts)
        #expect(done.marksClaudeOnResult)
        #expect(!done.marksClaudeOnAck)
    }
}
