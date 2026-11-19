import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 내 주소로 메일 보내기(send_self)와 채팅에서 여는 메일 계정 연결(mail_connect).
// 응답 예시는 두 세션이 합의한 형식을 가상 데이터로 쓴 것이다 (주소는 모두 가짜).

private enum MailFixture {
    static let fields = ["보내는 사람": "me@naver.test", "받는 사람": "me@naver.test", "제목": "주간 회의 정리", "본문": "출시일은 12월 3일로 확정했습니다."]
    static let fieldsJSON = #"{"보내는 사람":"me@naver.test","받는 사람":"me@naver.test","제목":"주간 회의 정리","본문":"출시일은 12월 3일로 확정했습니다."}"#
    static let hash = AgentDraftHash.sha256(action: "보내기", fields: fields, kind: "send", url: "mailto:me@naver.test")
    static let head = #""id":"S7gk2Lw0","task":"회의 내용을 내 메일로 보내기","title":"회의 정리 메일 보내기","steps":[]"#

    static let approval = """
    {\(head),"status":"awaiting_approval","narration":[{"time":"2026-11-12T01:00:00+00:00","text":"메일을 보내도 될지 승인을 기다리고 있어요"}],\
    "approval":{"approval_id":"ap_1","draft_id":"d_1","action":"보내기","kind":"send","url":"mailto:me@naver.test","sha256":"\(hash)","fields":\(fieldsJSON)}}
    """
    /// 맥의 시계는 이 기기와 다를 수 있다 (여기서는 한참 과거). 남은 시간은 맥의 시계끼리 뺀 값이다
    static let pending = """
    {\(head),"status":"send_pending","send":{"draft_id":"d_1","sha256":"\(hash)","from":"me@naver.test","to":"me@naver.test","fields":\(fieldsJSON),\
    "send_at":"2020-01-01T00:00:10+00:00","cancel_until":"2020-01-01T00:00:10+00:00","now":"2020-01-01T00:00:00+00:00"}}
    """
    static func sent(verified: String, to: String = #""me@naver.test""#) -> String {
        """
        {\(head),"status":"completed","result":{"outcome":"completed","summary":"메일을 보냈습니다",\
        "approved_drafts":[{"draft_id":"d_1","sha256":"\(hash)","action":"보내기","kind":"send","url":"mailto:me@naver.test","fields":\(fieldsJSON)}],\
        "report":{"done":["내 주소로 회의 정리 메일을 보냄"],"blocked":[],"sources":[],\
        "sent":[{"draft_id":"d_1","sha256":"\(hash)","to":\(to),"message_id":"<m1@mail.test>","sent_at":"2026-11-12T01:00:12+00:00",\
        "verified":"\(verified)","detail":""}]}}}
        """
    }
    static func failed(_ reason: String?) -> String {
        let reasonJSON = reason.map { #","reason":"\#($0)""# } ?? ""
        return #"{\#(head),"status":"failed","result":{"outcome":"send_failed","summary":""\#(reasonJSON),"approved_drafts":[]}}"#
    }
    static let canceledWhileWaiting = """
    {\(head),"status":"cancelled","send":{"draft_id":"d_1","sha256":"\(hash)","cancel_until":"2020-01-01T00:00:10+00:00","now":"2020-01-01T00:00:03+00:00"},\
    "result":{"outcome":"cancelled","summary":""}}
    """

    static func decode(_ json: String) throws -> AgentTaskState {
        try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
    }
}

@Suite("메일 보내기 응답 해석")
struct MailSendDecodingTests {
    @Test func sendApprovalIsShownAsAMailToSend() throws {
        let state = try MailFixture.decode(MailFixture.approval)
        #expect(state.phase == .awaitingApproval)
        let draft = try #require(state.draft)
        #expect(draft.isSend)
        #expect(draft.action == "보내기")
        #expect(draft.fields.map(\.label) == ["보내는 사람", "받는 사람", "제목", "본문"])
        // 승인할 때는 화면에 보인 내용으로 계산한 해시를 보낸다 (맥이 고정한 것과 같아야 보낸다)
        #expect(draft.approvalHash == MailFixture.hash)
        #expect(state.currentStatus == "보낼 메일을 확인해 주세요")
    }

    @Test func waitBeforeSendingUsesTheServerClock() throws {
        let state = try MailFixture.decode(MailFixture.pending)
        #expect(state.phase == .sendPending)
        #expect(state.draft == nil)
        // 맥의 시계가 이 기기와 달라도 남은 시간은 10초다
        let remaining = try #require(state.sendWait?.remaining())
        #expect((9...10).contains(remaining))
        #expect(state.sendWait?.sha256 == MailFixture.hash)
        // 기다리는 동안 보여 줄 메일은 승인한 것과 같은 내용이다
        #expect(state.outgoing?.isSend == true)
        #expect(state.outgoing?.title == "주간 회의 정리")
        #expect(state.statusLabel == "보내기 대기")
        #expect(!state.phase.isFinished)
    }

    @Test func passedDeadlineLeavesNoTimeButIsStillWaiting() throws {
        let wait = AgentSendWait(cancelUntil: "x", deadline: Date.now.addingTimeInterval(-5), sha256: nil)
        #expect(wait.remaining() == 0)
        #expect(AgentSendWait(cancelUntil: nil, deadline: nil, sha256: nil).remaining() == nil)
    }

    @Test func sentMailCarriesTheDeliveryCheck() throws {
        let state = try MailFixture.decode(MailFixture.sent(verified: "delivered"))
        #expect(state.phase == .done)
        #expect(state.sent == [AgentSent(to: ["me@naver.test"], sentAt: "2026-11-12T01:00:12+00:00", verified: .delivered, sha256: MailFixture.hash)])
        #expect(state.sentDrafts.count == 1)
        #expect(state.savedDrafts.isEmpty)
        #expect(state.currentStatus == "메일을 보냈고 도착을 확인했어요")
    }

    @Test func acceptedOnlyIsNotCalledDelivered() throws {
        let state = try MailFixture.decode(MailFixture.sent(verified: "accepted_only", to: #"["me@naver.test"]"#))
        #expect(state.sent.first?.verified == .acceptedOnly)
        #expect(state.sent.first?.to == ["me@naver.test"])
        #expect(state.currentStatus == "메일을 보냈어요. 도착은 확인하지 못했어요")
    }

    @Test func unknownCheckValueIsTreatedAsNotConfirmed() throws {
        // 모르는 값을 "도착했다"로 읽지 않는다
        let state = try MailFixture.decode(MailFixture.sent(verified: "something_new"))
        #expect(state.sent.first?.verified == .acceptedOnly)
    }

    @Test(arguments: [
        ("auth_failed", true, "메일 계정에 로그인하지 못해 보내지 못했어요. 메일 계정을 다시 연결해 주세요. 보낸 메일은 없어요."),
        ("not_set", true, "메일 계정이 연결되어 있지 않아 보내지 못했어요. 보낸 메일은 없어요."),
        ("unreachable", false, "메일 서버에 연결하지 못해 보내지 못했어요. 보낸 메일은 없어요."),
        ("rate_limited", false, "보내기 한도를 넘어 보내지 못했어요. 보낸 메일은 없어요."),
        ("not_allowed", false, "내 주소가 아닌 곳으로는 보낼 수 없어요. 보낸 메일은 없어요."),
        ("rejected", false, "메일 서버가 받아 주지 않아 보내지 못했어요. 보낸 메일은 없어요."),
        ("invented_date", false, "맥이 쓴 초안에 원문에 없는 연도가 들어가 있어 보내지 않았어요. 보낸 메일은 없어요."),
        ("something_new", false, "메일을 보내지 못했어요. 보낸 메일은 없어요."),
    ])
    func sendFailureExplainsTheReason(reason: String, needsAccount: Bool, text: String) throws {
        let state = try MailFixture.decode(MailFixture.failed(reason))
        #expect(state.phase == .failed)
        #expect(state.error == text)
        #expect(state.sendFailure == reason)
        // 계정을 연결하면 풀리는 실패에만 연결 안내를 붙인다
        #expect(state.needsMailAccount == needsAccount)
        #expect(state.sent.isEmpty)
    }

    @Test func sendFailureWithoutAReasonStillSaysNothingWasSent() throws {
        let state = try MailFixture.decode(MailFixture.failed(nil))
        #expect(state.error == "메일을 보내지 못했어요. 보낸 메일은 없어요.")
        #expect(!state.needsMailAccount)
    }

    @Test func cancelDuringTheWaitSaysNoMailWasSent() throws {
        let state = try MailFixture.decode(MailFixture.canceledWhileWaiting)
        #expect(state.phase == .canceled)
        #expect(state.error == AgentTaskState.sendCanceledText)
        #expect(state.sent.isEmpty)
    }

    @Test func waitingStateSurvivesSaving() throws {
        var state = try MailFixture.decode(MailFixture.pending)
        state.cancelMissed = true
        let restored = try JSONDecoder().decode(AgentTaskState.self, from: JSONEncoder().encode(state))
        #expect(restored == state)
    }

    @Test func statesSavedBeforeMailSendingStillOpen() throws {
        // 이전 빌드가 저장한 작업에는 보내기 관련 값이 없다
        let old = AgentTaskState(id: "t1", task: "초안 써 줘", steps: ["입력 · 회의 공유"], phase: .done)
        let json = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(!json.contains("sendWait") && !json.contains("outgoing") && !json.contains("sendFailure"))
        let restored = try JSONDecoder().decode(AgentTaskState.self, from: Data(json.utf8))
        #expect(restored.sent.isEmpty)
        #expect(!restored.needsMailAccount)

        let report = try JSONDecoder().decode(AgentReport.self, from: Data(#"{"done":["초안 저장"],"blocked":[],"sources":[]}"#.utf8))
        #expect(report.sent == nil)
        let draft = try JSONDecoder().decode(
            AgentDraft.self, from: Data(#"{"approvalID":"ap","action":"임시 저장","fields":[],"revision":1}"#.utf8)
        )
        #expect(!draft.isSend)
    }
}

/// 메일 보내기는 알지만 앱에서 계정을 연결하는 기능은 없는 맥
actor SendOnlyAgent: AgentProviding {
    let inner: MockAgentClient
    init(mail: MockMail) { inner = MockAgentClient(v2: true, mail: mail) }
    func isReachable() async -> Bool { true }
    func supports(_ feature: String) async -> Bool { feature != AgentFeature.mailConnect }
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        try await inner.message(text, conversationID: conversationID, context: context)
    }
    func message(_ text: String, conversationID: String?, context: String?, messageID: String?) async throws -> AgentReply {
        try await inner.message(text, conversationID: conversationID, context: context, messageID: messageID)
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
    func mailAccounts(check: Bool) async throws -> [MailAccount] { try await inner.mailAccounts(check: check) }
}

@MainActor
@Suite("메일 보내기 흐름")
struct MailSendFlowTests {
    let context: ModelContext
    let meeting: Meeting
    private static let request = "지난 회의 내용 나한테 메일로 보내줘"
    /// 가짜 앱 비밀번호 (실제 값이 아니다)
    private static let password = "abcd efgh ijkl mnop"

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

    private func session(_ agent: any AgentProviding) async -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        session.attach(context)
        await session.checkAgent()
        return session
    }

    /// 조건이 될 때까지 잠깐씩 기다린다 (다른 일이 진행되게 자리를 비켜 준다)
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<5000 where !condition() { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }

    @Test func approvedMailIsSentAfterTheWaitAndChecked() async throws {
        let agent = MockAgentClient(v2: true, mail: MockMail())
        let session = await session(agent)
        await session.send(Self.request, meetings: [meeting])

        // 보내기 전에 반드시 승인을 받는다. 보내는 곳과 받는 곳은 기본 계정(네이버)이다
        let asking = try #require(session.messages.last?.agent)
        #expect(asking.phase == .awaitingApproval)
        let draft = try #require(asking.draft)
        #expect(draft.isSend)
        #expect(draft.fields.first { $0.label == "보내는 사람" }?.value == "me@naver.test")
        #expect(draft.fields.first { $0.label == "받는 사람" }?.value == "me@naver.test")
        #expect(session.status == .needsApproval)

        await session.decide(asking.id, approve: true)
        let done = try #require(session.messages.last?.agent)
        #expect(done.id == asking.id)
        #expect(done.phase == .done)
        #expect(done.sent.map(\.to) == [["me@naver.test"]])
        #expect(done.sent.first?.verified == .delivered)
        // 보낸 메일은 승인한 내용 그대로다
        #expect(done.sentDrafts.first?.sha256 == draft.sha256)
        #expect(done.savedDrafts.isEmpty)
        #expect(done.timeline.contains { $0.text == "메일을 보냈어요" })
        #expect(done.outgoing == nil && done.sendWait == nil)
        #expect(session.status == nil)
        #expect(!session.isLoading)
    }

    @Test func namedServiceChoosesThatAccount() async throws {
        let session = await session(MockAgentClient(v2: true, mail: MockMail()))
        await session.send("지난 회의 내용 지메일로 나한테 메일 보내줘", meetings: [meeting])
        let draft = try #require(session.messages.last?.agent?.draft)
        #expect(draft.fields.first { $0.label == "받는 사람" }?.value == "me@gmail.test")
    }

    @Test func unconfirmedDeliveryIsReportedAsItIs() async throws {
        let session = await session(MockAgentClient(v2: true, mail: MockMail(verified: .acceptedOnly)))
        await session.send(Self.request, meetings: [meeting])
        let asking = try #require(session.messages.last?.agent)
        await session.decide(asking.id, approve: true)
        let done = try #require(session.messages.last?.agent)
        #expect(done.phase == .done)
        #expect(done.sent.first?.verified == .acceptedOnly)
        #expect(done.currentStatus == "메일을 보냈어요. 도착은 확인하지 못했어요")
    }

    @Test func refusingTheApprovalSendsNothing() async throws {
        let session = await session(MockAgentClient(v2: true, mail: MockMail()))
        await session.send(Self.request, meetings: [meeting])
        let asking = try #require(session.messages.last?.agent)
        await session.decide(asking.id, approve: false)
        let state = try #require(session.messages.last?.agent)
        #expect(state.phase == .canceled)
        #expect(state.sent.isEmpty && state.sentDrafts.isEmpty)
    }

    @Test func sendCanBeCanceledDuringTheWait() async throws {
        let agent = MockAgentClient(v2: true, mail: MockMail(waitPolls: 1_000_000))
        let session = await session(agent)
        await session.send(Self.request, meetings: [meeting])
        let asking = try #require(session.messages.last?.agent)

        let deciding = Task { await session.decide(asking.id, approve: true) }
        try await wait { session.messages.last?.agent?.phase == .sendPending }
        // 기다리는 동안에는 보낼 메일과 남은 시간이 보이고, 위쪽 상태 줄은 "보내기 대기"다
        let waiting = try #require(session.messages.last?.agent)
        #expect(waiting.outgoing?.sha256 == asking.draft?.sha256)
        #expect(waiting.sendWait?.remaining() != nil)
        #expect(session.status == .sending)

        await session.cancelAgent(asking.id)
        await deciding.value
        let state = try #require(session.messages.last?.agent)
        #expect(state.phase == .canceled)
        #expect(state.error == AgentTaskState.sendCanceledText)
        #expect(state.sent.isEmpty)
        #expect(state.cancelMissed != true)
        #expect(try await agent.state(of: asking.id).phase == .canceled)
        #expect(!session.isLoading)
    }

    @Test func lateCancelSaysTheMailWasAlreadySent() async throws {
        let agent = MockAgentClient(v2: true, mail: MockMail(waitPolls: 1_000_000, lateCancel: true))
        let session = await session(agent)
        await session.send(Self.request, meetings: [meeting])
        let asking = try #require(session.messages.last?.agent)

        let deciding = Task { await session.decide(asking.id, approve: true) }
        try await wait { session.messages.last?.agent?.phase == .sendPending }
        await session.cancelAgent(asking.id)
        await deciding.value

        // 취소됐다고 말하지 않는다: 메일은 나갔고, 그 사실과 도착 확인 결과를 보여 준다
        let state = try #require(session.messages.last?.agent)
        #expect(state.phase == .done)
        #expect(state.cancelMissed == true)
        #expect(state.sent.count == 1)
        #expect(state.sentDrafts.count == 1)
        #expect(session.messages.last?.role == .agent)
    }

    @Test func connectSheetIsPrefilledWithTheAccountThatNeedsConnecting() async throws {
        let session = await session(MockAgentClient(v2: true, mail: MockMail(failure: "auth_failed")))
        await session.send(Self.request, meetings: [meeting])
        #expect(session.mailConnectTaskID != nil)
        #expect(session.mailConnectSuggestion == nil)   // 목록을 받기 전

        await session.loadMailAccounts()
        #expect(session.mailConnectSuggestion?.address == "me@naver.test")
        #expect(!session.mailNeedsAddressSetup)

        // 연결되면 더 채울 계정이 없다
        _ = try await session.connectMail(provider: "naver", address: "me@naver.test", password: "abcdabcdabcdabcd")
        #expect(session.mailConnectSuggestion == nil)
    }

    @Test func serverWithoutAnyAddressAsksToSetTheAddressFirst() async {
        var mail = MockMail(failure: "not_set")
        mail.noAddresses = true
        let session = await session(MockAgentClient(v2: true, mail: mail))
        await session.send(Self.request, meetings: [meeting])
        #expect(session.messages.last?.agent?.needsMailAccount == true)
        #expect(!session.mailNeedsAddressSetup)   // 목록을 받기 전에는 단정하지 않는다

        await session.loadMailAccounts()
        #expect(session.mailNeedsAddressSetup)
        #expect(session.mailConnectSuggestion == nil)
    }

    @Test func accountProblemOffersConnectInChatAndRetriesAfterIt() async throws {
        let agent = MockAgentClient(v2: true, mail: MockMail(failure: "auth_failed"))
        let session = await session(agent)
        await session.send(Self.request, meetings: [meeting])

        // 승인을 받기 전에 끝난다. 보낸 메일은 없고, 계정 연결 안내가 그 작업에 붙는다
        let failed = try #require(session.messages.last?.agent)
        #expect(failed.phase == .failed)
        #expect(failed.needsMailAccount)
        #expect(failed.sent.isEmpty)
        #expect(session.mailConnectTaskID == failed.id)

        // 틀린 앱 비밀번호: 연결되지 않고 안내는 그대로다
        #expect(try await session.connectMail(provider: "naver", address: "me@naver.test", password: "wrong wrong") == .authFailed)
        #expect(session.mailConnectTaskID == failed.id)

        // 맞는 앱 비밀번호: 연결되고, 보내지 못했던 부탁을 다시 맡긴다
        let before = session.messages.count
        #expect(try await session.connectMail(provider: "naver", address: "ME@naver.test", password: Self.password) == .ready)
        #expect(await agent.connects == 2)
        #expect(session.messages.count == before)
        await session.retryAfterMailConnect(failed.id, meetings: [meeting])

        let retried = try #require(session.messages.last?.agent)
        #expect(retried.id != failed.id)
        #expect(retried.phase == .awaitingApproval)
        #expect(retried.draft?.isSend == true)
        #expect(session.mailConnectTaskID == nil)
        #expect(session.messages.filter { $0.role == .user && $0.text == Self.request }.count == 2)

        // 앱 비밀번호는 대화 어디에도 남지 않는다: 메시지에도, 맥의 대화 담당에게 간 말에도, 저장된 기록에도
        let secret = Self.password.replacingOccurrences(of: " ", with: "")
        let leaks = { (text: String) in text.replacingOccurrences(of: " ", with: "").contains(secret) || text.contains("wrong wrong") }
        #expect(session.messages.allSatisfy { !leaks($0.text) })
        #expect(await agent.received.allSatisfy { !leaks($0.text) && !leaks($0.context ?? "") })
        for record in try context.fetch(FetchDescriptor<ChatRecord>()) {
            #expect(!leaks(record.text))
            #expect(!leaks(String(decoding: record.agentData ?? Data(), as: UTF8.self)))
        }
    }

    @Test func notConnectedAccountAlsoOffersConnect() async throws {
        let session = await session(MockAgentClient(v2: true, mail: MockMail(failure: "not_set")))
        await session.send(Self.request, meetings: [meeting])
        let failed = try #require(session.messages.last?.agent)
        #expect(failed.sendFailure == "not_set")
        #expect(session.mailConnectTaskID == failed.id)
    }

    @Test func mailServerOutageDoesNotAskForThePassword() async throws {
        // 계정 문제가 아닌 실패에 비밀번호를 다시 넣으라고 하지 않는다
        let session = await session(MockAgentClient(v2: true, mail: MockMail(failure: "unreachable")))
        await session.send(Self.request, meetings: [meeting])
        let failed = try #require(session.messages.last?.agent)
        #expect(failed.phase == .failed)
        #expect(failed.error == AgentTaskState.sendFailureText("unreachable"))
        #expect(session.mailConnectTaskID == nil)
    }

    @Test func connectIsNotOfferedWhenTheServerCannotTakeIt() async throws {
        let session = await session(SendOnlyAgent(mail: MockMail(failure: "auth_failed")))
        await session.send(Self.request, meetings: [meeting])
        #expect(session.messages.last?.agent?.needsMailAccount == true)
        #expect(session.mailConnectTaskID == nil)
        await #expect(throws: AgentError.conflict) {
            _ = try await session.connectMail(provider: "naver", address: "me@naver.test", password: Self.password)
        }
    }

    @Test func connectPromptGoesAwayOnceTheTalkMovesOn() async throws {
        let session = await session(MockAgentClient(v2: true, mail: MockMail(failure: "auth_failed")))
        await session.send(Self.request, meetings: [meeting])
        #expect(session.mailConnectTaskID != nil)
        await session.send("안녕", meetings: [meeting])
        #expect(session.mailConnectTaskID == nil)
    }

    @Test func serverWithoutMailSendingKeepsSavingDrafts() async throws {
        // 보내기를 모르는 맥에서는 같은 말이 지금처럼 처리된다 (보내기 작업이 만들어지지 않는다)
        let session = await session(MockAgentClient(v2: true))
        await session.send(Self.request, meetings: [meeting])
        #expect(session.messages.allSatisfy { $0.agent?.draft?.isSend != true && $0.agent?.phase != .sendPending })
        #expect(session.mailConnectTaskID == nil)
    }
}

@MainActor
@Suite("메일 계정")
struct MailAccountTests {
    @Test func providerIsGuessedFromTheAddress() {
        #expect(MailProvider.guess(from: "me@naver.test") == .naver)
        #expect(MailProvider.guess(from: "Me@Gmail.test") == .gmail)
        #expect(MailProvider.guess(from: "me@mail.test") == nil)
        #expect(MailProvider.guess(from: "") == nil)
    }

    @Test func accountsCardListsBothServicesWithNaverAsDefault() async {
        let model = MailAccountsModel(agent: MockAgentClient(v2: true, mail: MockMail()))
        await model.load()
        #expect(model.isSupported && model.canConnect)
        #expect(model.accounts.map(\.provider) == ["naver", "gmail"])
        #expect(model.accounts.first(where: \.isDefault)?.provider == "naver")
        #expect(!model.loadFailed)
    }

    @Test func accountsCardStaysHiddenOnAServerWithoutMailSending() async {
        let model = MailAccountsModel(agent: MockAgentClient(v2: true))
        await model.load()
        #expect(!model.isSupported)
        #expect(model.accounts.isEmpty)
    }

    @Test func connectingFromTheProfileUpdatesTheStatus() async throws {
        let model = MailAccountsModel(agent: MockAgentClient(v2: true, mail: MockMail(failure: "auth_failed")))
        await model.load()
        #expect(model.accounts.first?.status == .authFailed)
        #expect(model.accounts.first?.status.needsConnect == true)

        #expect(try await model.connect(provider: "naver", address: "me@naver.test", password: "wrong") == .authFailed)
        #expect(try await model.connect(provider: "naver", address: "me@naver.test", password: "abcdabcdabcdabcd") == .ready)
        #expect(model.accounts.first?.status == .ready)
        #expect(model.accounts.first?.status.needsConnect == false)
    }

    @Test func addressOutsideMyListIsRefusedAndNothingIsAdded() async {
        let model = MailAccountsModel(agent: MockAgentClient(v2: true, mail: MockMail()))
        await model.load()
        await #expect(throws: AgentError.notAllowed) {
            _ = try await model.connect(provider: "naver", address: "other@naver.test", password: "abcdabcdabcdabcd")
        }
        #expect(model.accounts.map(\.address) == ["me@naver.test", "me@gmail.test"])
    }

    @Test func connectRefusalsAreReadFromTheServerAnswer() {
        let refused = Data(#"{"error":{"code":"not_allowed","message":"x"}}"#.utf8)
        #expect(throws: AgentError.notAllowed) { _ = try AgentHTTPClient.decodeAccounts(data: refused, status: 403) }
        let tooMany = Data(#"{"error":{"code":"rate_limited","message":"x"}}"#.utf8)
        #expect(throws: AgentError.rateLimited) { _ = try AgentHTTPClient.decodeAccounts(data: tooMany, status: 429) }
        // 다른 작업으로 바쁜 것(429 busy)과 헷갈리지 않는다
        #expect(AgentHTTPClient.decodeError(data: Data(#"{"error":{"code":"busy"}}"#.utf8), status: 429) == .busy)
    }

    @Test func connectRefusalsAreExplainedWithoutEchoingTheServerText() {
        let notAllowed = MailConnectSheet.problem(for: AgentError.notAllowed)
        #expect(notAllowed.contains("등록되지 않은 주소") && notAllowed.contains("보관하지 않았어요"))
        #expect(MailConnectSheet.problem(for: AgentError.rateLimited).contains("10분"))
        // 서버가 준 글은 그대로 보여 주지 않는다
        #expect(!MailConnectSheet.problem(for: AgentError.server("535 5.7.8 raw")).contains("535"))
    }

    @Test func serverWithoutAnyAddressShowsNoAccountsToConnect() async {
        var mail = MockMail(failure: "not_set")
        mail.noAddresses = true
        let model = MailAccountsModel(agent: MockAgentClient(v2: true, mail: mail))
        await model.load()
        #expect(model.isSupported && model.accounts.isEmpty && !model.loadFailed)
    }

    @Test func checkAgainRefreshesTheCheckTime() async {
        let model = MailAccountsModel(agent: MockAgentClient(v2: true, mail: MockMail()))
        await model.load(check: true)
        #expect(model.accounts.allSatisfy { $0.checkedAt != nil })
        #expect(!model.isChecking)
    }
}
