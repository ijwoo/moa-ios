import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

/// 맥을 거친 답을 누가 썼는지 (`replies[].by`, D62): 읽기, 기록, "Claude 사용"을 붙이는 자리
@MainActor
@Suite("맥을 거친 답을 누가 썼나: Claude 사용 표시")
struct ReplyWriterTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func session(_ agent: MockAgentClient) -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        session.attach(context)
        return session
    }

    private func decode(_ json: String) throws -> AgentReply {
        try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200)
    }

    private func bubble(_ writer: ReplyWriter?, role: AskSession.Message.Role = .assistant, engine: AskSession.Engine = .local) -> AskSession.Message {
        AskSession.Message(role: role, text: "말", engine: engine, writer: writer)
    }

    private func marks(_ messages: [AskSession.Message]) -> [Int] {
        messages.indices.filter { AskSession.marksClaude(at: $0, in: messages) }
    }

    // MARK: - 읽기

    @Test func featureNameMatchesTheMac() {
        #expect(AgentFeature.replyBy == "reply_by")
        #expect(ReplyWriter.allNames == ["claude", "local", "mac"])
    }

    @Test func eachBubbleCarriesWhoWroteIt() throws {
        let reply = try decode("""
        {"conversation_id":"c_1","replies":[{"text":"서울은 맑아요.","by":"claude"},{"text":"겉옷을 챙기세요.","by":"claude"},
         {"text":"출처: 가상날씨","by":"mac"}],"action":{"type":"none"}}
        """)
        #expect(reply.writers == [.claude, .claude, .mac])
        #expect(reply.writer(at: 2) == .mac)
        #expect(reply.writer(at: 3) == nil)
    }

    /// 키가 없는 맥(지금까지의 서버)은 지금처럼: 표시할 것이 없다
    @Test func aMacThatDoesNotSayLeavesNothingToMark() throws {
        let reply = try decode(#"{"conversation_id":"c_1","replies":[{"text":"안녕하세요."}],"action":{"type":"none"}}"#)
        #expect(reply.replies == ["안녕하세요."])
        #expect(reply.writers.isEmpty)
        #expect(reply.writer(at: 0) == nil)
    }

    /// 모르는 값이나 글자가 아닌 값이 와도 답은 그대로 보여 주고, 그 말에는 표시를 붙이지 않는다
    @Test func unknownValuesAreReadAsNoMark() throws {
        let reply = try decode("""
        {"conversation_id":"c_1","replies":[{"text":"하나","by":"haiku"},{"text":"둘","by":7},{"text":"셋","by":"local"},{"text":"넷","by":null}],
         "action":{"type":"none"}}
        """)
        #expect(reply.replies == ["하나", "둘", "셋", "넷"])
        #expect(reply.writers == [nil, nil, .local, nil])
    }

    /// 빈 말풍선은 버린다. 남은 말과 쓴 곳의 차례가 어긋나지 않는다
    @Test func droppedEmptyBubblesDoNotShiftTheWriters() throws {
        let reply = try decode("""
        {"conversation_id":"c_1","replies":[{"text":"","by":"mac"},{"text":"네, 알겠어요.","by":"claude"}],"action":{"type":"none"}}
        """)
        #expect(reply.replies == ["네, 알겠어요."])
        #expect(reply.writers == [.claude])
    }

    // MARK: - 표시를 붙이는 자리

    @Test func theMarkGoesOnceUnderTheLastBubbleOfAClaudeAnswer() {
        // 웹 검색 답: 앞의 두 말은 Claude, 마지막 "출처" 줄은 맥이 붙였다 → 답 전체의 아래에 한 번
        #expect(marks([bubble(nil, role: .user), bubble(.claude), bubble(.claude), bubble(.mac)]) == [3])
        #expect(marks([bubble(nil, role: .user), bubble(.claude)]) == [1])
        // 응답마다 따로 본다
        #expect(marks([bubble(nil, role: .user), bubble(.claude), bubble(nil, role: .user), bubble(.claude), bubble(.claude)]) == [1, 4])
    }

    @Test func answersNotWrittenByClaudeGetNoMark() {
        #expect(marks([bubble(nil, role: .user), bubble(.local)]).isEmpty)
        #expect(marks([bubble(nil, role: .user), bubble(.mac), bubble(.local)]).isEmpty)
        // 맥이 알려 주지 않은 답 (예전 서버, 예전 기록)
        #expect(marks([bubble(nil, role: .user), bubble(nil), bubble(nil)]).isEmpty)
        // 앞 응답이 Claude였다고 다음 응답에 붙지 않는다
        #expect(marks([bubble(nil, role: .user), bubble(.claude), bubble(nil, role: .user), bubble(.local)]) == [1])
    }

    /// 회의 질문의 답(중계 서버 → Claude)은 이 규칙이 아니라 원래 표시(`engine == .cloud`)를 쓴다
    @Test func theMeetingAnswerPathIsLeftAlone() {
        #expect(marks([bubble(nil, role: .user, engine: .cloud), bubble(nil, engine: .cloud)]).isEmpty)
    }

    /// 로그인 완료 카드는 앱이 붙인 것이다: 응답에 넣지 않고, 표시도 그 위의 말에 붙는다
    @Test func theLoggedInCardIsNotPartOfAnAnswer() {
        var card = bubble(nil)
        card.siteLoggedIn = "naver"
        #expect(marks([bubble(nil, role: .user), bubble(.claude), card]) == [1])
        #expect(marks([card]).isEmpty)
        #expect(AskSession.marksClaude(at: 9, in: [card]) == false)
    }

    // MARK: - 대화에서

    @Test func aClaudeAnswerIsMarkedAndTheMarkSurvivesReopening() async throws {
        let agent = MockAgentClient(v2: true)
        await agent.script(AgentReply(
            conversationID: "", replies: ["서울은 맑아요.", "출처: 가상날씨"], action: .none, writers: [.claude, .mac]
        ))
        let session = session(agent)
        await session.send("오늘 서울 날씨 어때?", meetings: [])
        #expect(session.messages.map(\.writer) == [nil, .claude, .mac])
        #expect(marks(session.messages) == [2])
        try context.save()

        let reopened = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        reopened.attach(context)
        if reopened.messages.isEmpty, let conversation = session.conversation { reopened.open(conversation) }
        #expect(reopened.messages.map(\.writer) == [nil, .claude, .mac])
        #expect(marks(reopened.messages) == [2])
    }

    @Test func aBackQuestionKeepsItsWriter() async {
        let agent = MockAgentClient(v2: true)
        await agent.script(AgentReply(conversationID: "", replies: ["누구에게 보낼까요?"], action: .ask(choices: ["팀 전체"]), writers: [.claude]))
        let session = session(agent)
        await session.send("메일 써줘", meetings: [])
        #expect(session.messages.last?.writer == .claude)
        #expect(session.messages.last?.asksBack == true)
        #expect(marks(session.messages) == [1])
    }

    /// 로그인 안내는 맥에 정해 둔 문장이다: 표시가 붙지 않는다
    @Test func theLoginNoticeIsNotMarked() async {
        let agent = MockAgentClient(v2: true)
        await agent.script(AgentReply(conversationID: "", replies: ["네이버 로그인이 필요해요."], action: .siteLogin(site: "naver"), writers: [.mac]))
        let session = session(agent)
        await session.send("결제내역 알려줘", meetings: [])
        #expect(session.messages.last?.writer == .mac)
        #expect(session.messages.last?.siteLogin == "naver")
        #expect(marks(session.messages).isEmpty)
    }

    /// 일을 맡았다는 한 마디는 작업의 확인 문장이 된다. 누가 썼는지도 작업과 함께 남고, 진행 상태를 다시 받아도 이어진다
    @Test func theTaskAcknowledgementRemembersItsWriter() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: MockDialogCloud(marksWriter: true))
        let session = session(agent)
        await session.send("팀에게 주간 회의 안내 메일 초안 써줘", meetings: [])
        let state = try #require(session.messages.last?.agent)
        #expect(state.ack != nil)
        #expect(state.ackBy == "claude")
        #expect(state.phase == .awaitingApproval)

        // 저장했다 다시 읽어도 남는다
        let stored = try #require(session.conversation?.sortedRecords.last?.agentData)
        #expect(try JSONDecoder().decode(AgentTaskState.self, from: stored).ackBy == "claude")
    }

    @Test func aMacThatDoesNotSayLeavesTheAcknowledgementUnmarked() async throws {
        let session = session(MockAgentClient(v2: true))
        await session.send("팀에게 주간 회의 안내 메일 초안 써줘", meetings: [])
        let state = try #require(session.messages.last?.agent)
        #expect(state.ack != nil)
        #expect(state.ackBy == nil)
    }

    /// 예전에 저장한 작업 기록에는 이 값이 없다. 그래도 읽힌다
    @Test func olderTaskRecordsStillDecode() throws {
        let old = #"{"id":"T1","task":"메일 초안","steps":[],"phase":"done","isQueued":false,"approvedDrafts":[],"lastRevision":0,"ack":"네, 준비할게요."}"#
        let state = try JSONDecoder().decode(AgentTaskState.self, from: Data(old.utf8))
        #expect(state.ack == "네, 준비할게요.")
        #expect(state.ackBy == nil)
    }

    // MARK: - 가짜 맥

    @Test func theMockSaysWhoWroteOnlyWhenTurnedOn() async throws {
        let quiet = MockAgentClient(v2: true, dialogCloud: MockDialogCloud(webLookup: true))
        #expect(await quiet.supports(AgentFeature.replyBy) == false)
        #expect(try await quiet.message("오늘 서울 날씨 어때?", conversationID: nil, context: nil).writers.isEmpty)

        let telling = MockAgentClient(v2: true, dialogCloud: MockDialogCloud(webLookup: true, marksWriter: true))
        #expect(await telling.supports(AgentFeature.replyBy))
        let weather = try await telling.message("오늘 서울 날씨 어때?", conversationID: nil, context: nil)
        #expect(weather.replies.count == 3)
        #expect(weather.writers == [.claude, .claude, .mac])
        #expect(try await telling.message("안녕", conversationID: nil, context: nil).writers == [.claude])
        // 회의 질문으로 넘길 때는 말풍선이 없다
        #expect(try await telling.message("지난 회의 결론이 뭐였지", conversationID: nil, context: nil).writers.isEmpty)
    }
}
