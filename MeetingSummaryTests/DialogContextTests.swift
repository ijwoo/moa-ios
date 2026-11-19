import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 대화 맥락을 위해 맥과 새로 주고받는 값 (D59): 로그인 뒤 이어서 하기 표시, 답장으로 가리킨 작업, 지금 시각.
// 아이디·비밀번호·사이트 내용은 모두 지어낸 것이다.

@Suite("대화 맥락: 맥에 보내는 값")
struct DialogContextRequestTests {
    private func object(_ body: AgentHTTPClient.MessageBody) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    private let noon = Date(timeIntervalSince1970: 1_794_547_200) // 2026-11-13 05:20:00 UTC

    @Test func newKeysGoOnlyToAMacThatKnowsThem() throws {
        // 모르는 키를 받은 맥은 요청을 거절한다. 기능 표시가 없으면 예전과 같은 요청이다
        let old = AgentHTTPClient.MessageBody(
            text: "이거 메일로 보내줘", conversationID: "c_1", context: nil, messageID: "m_1", replyTaskID: "t_read1",
            tone: "friendly", features: []
        )
        #expect(try Set(object(old).keys) == ["text", "conversation_id"])

        let new = AgentHTTPClient.MessageBody(
            text: "이거 메일로 보내줘", conversationID: "c_1", context: nil, messageID: "m_1", replyTaskID: "t_read1",
            tone: "friendly", features: [AgentFeature.replyTo, AgentFeature.clientTime],
            now: noon, timeZone: try #require(TimeZone(identifier: "Asia/Seoul"))
        )
        let sent = try object(new)
        #expect(Set(sent.keys) == ["text", "conversation_id", "reply_to", "client_time"])
        #expect(sent["reply_to"] as? [String: String] == ["task_id": "t_read1"])
        #expect(sent["client_time"] as? String == "2026-11-13T14:20:00+09:00")
    }

    @Test func replyKeyIsLeftOutWhenNothingWasQuoted() throws {
        let body = AgentHTTPClient.MessageBody(
            text: "안녕", conversationID: nil, context: nil, messageID: nil, replyTaskID: nil,
            tone: "formal", features: [AgentFeature.replyTo, AgentFeature.tone]
        )
        #expect(try Set(object(body).keys) == ["text", "tone"])
    }

    @Test func clientTimeAlwaysCarriesANumericOffset() throws {
        #expect(AgentHTTPClient.MessageBody.clientTime(noon, timeZone: try #require(TimeZone(identifier: "UTC"))) == "2026-11-13T05:20:00+00:00")
        #expect(
            AgentHTTPClient.MessageBody.clientTime(noon, timeZone: try #require(TimeZone(identifier: "America/Los_Angeles")))
                == "2026-11-12T21:20:00-08:00"
        )
    }
}

@Suite("대화 맥락: 로그인 뒤 이어서 하기 표시 읽기")
struct LoginResumeDecodingTests {
    private func reply(_ action: String, resumeFlag: Bool) throws -> AgentReply {
        let json = #"{"conversation_id":"c_1","replies":[{"text":"네이버 로그인이 필요해요."}],"action":\#(action)}"#
        return try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200, resumeFlag: resumeFlag)
    }

    @Test func flagIsReadFromAMacThatSendsIt() throws {
        #expect(try reply(#"{"type":"site_login","site":"naver","resume":true}"#, resumeFlag: true).loginResume == true)
        #expect(try reply(#"{"type":"site_login","site":"naver","resume":false}"#, resumeFlag: true).loginResume == false)
        // 표시를 주는 맥이 키를 뺐으면 "이어서 할 부탁이 없다"는 뜻이다
        #expect(try reply(#"{"type":"site_login","site":"naver"}"#, resumeFlag: true).loginResume == false)
    }

    @Test func macThatDoesNotSendTheFlagLeavesItUnknown() throws {
        // 표시를 모르는 맥: 앱이 말로 가린다 (D58)
        #expect(try reply(#"{"type":"site_login","site":"naver"}"#, resumeFlag: false).loginResume == nil)
        #expect(try reply(#"{"type":"site_login","site":"naver","resume":true}"#, resumeFlag: false).loginResume == nil)
    }

    @Test(arguments: [#""yes""#, "1", "null", "[]", "{}"])
    func oddFlagValueDoesNotBreakTheReply(value: String) throws {
        let reply = try reply(#"{"type":"site_login","site":"naver","resume":\#(value)}"#, resumeFlag: true)
        #expect(reply.replies == ["네이버 로그인이 필요해요."])
        // 참이 아니면 다시 보내지 않는다 (잘못 다시 보내는 것보다 안 보내는 쪽이 낫다)
        #expect(reply.loginResume == false)
        guard case .siteLogin(let site) = reply.action else {
            Issue.record("로그인 카드는 그대로 붙어야 한다")
            return
        }
        #expect(site == "naver")
    }

    @Test func flagOnOtherActionsIsIgnored() throws {
        #expect(try reply(#"{"type":"none","resume":true}"#, resumeFlag: true).loginResume == nil)
    }
}

@MainActor
@Suite("대화 맥락: 대화에서")
struct DialogContextChatTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func session(_ agent: MockAgentClient) async -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        session.attach(context)
        await session.checkAgent()
        return session
    }

    /// 로그인 화면이 하는 일: 열고, 가짜 값을 보내고, 휴대폰 승인을 기다린다
    private func logIn(_ flow: SiteLoginFlow) async {
        await flow.start()
        await flow.refresh()
        await flow.submit(["id": "minsu_demo", "password": "Kq7!가상-비밀번호"])
        for _ in 0..<10 where flow.screen != .done { await flow.refresh() }
    }

    private func loginNotice(resume: Bool?) -> AgentReply {
        AgentReply(conversationID: "", replies: ["네이버 로그인이 필요해요. 먼저 로그인해 주세요."], action: .siteLogin(site: "naver"), loginResume: resume)
    }

    // MARK: - 로그인 뒤 이어서 하기

    @Test func macSaysResumeEvenWhenTheWordsLookLikeALoginRequest() async throws {
        // "로그인"이 든 말은 앱이 혼자서는 다시 보내지 않는다 (D58). 맥이 "하지 못한 부탁"이라고 알려 주면 다시 보낸다
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1), captures: MockCaptures(script: .login))
        let session = await session(agent)
        await agent.script(loginNotice(resume: true))
        await session.send("로그인해서 결제내역 알려줘", meetings: [])

        let prompt = try #require(session.siteLoginPrompt)
        #expect(prompt.request == "로그인해서 결제내역 알려줘")

        await logIn(try #require(session.siteLoginFlow(for: "naver")))
        await session.retryAfterSiteLoginPrompt(prompt.messageID, meetings: [])
        let task = try #require(session.messages.last?.agent)
        #expect(task.phase == .done)
        #expect(session.messages.filter { $0.role == .user && $0.text == "로그인해서 결제내역 알려줘" }.count == 2)
        // 다시 보낸 말은 새 메시지 번호로 간다
        #expect(Set(await agent.messageIDs.compactMap { $0 }).count == 2)
    }

    @Test func macSaysNoResumeEvenWhenTheWordsLookLikeARequest() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1), captures: MockCaptures(script: .login))
        let session = await session(agent)
        await agent.script(loginNotice(resume: false))
        await session.send("결제내역 알려줘", meetings: [])

        let prompt = try #require(session.siteLoginPrompt)
        #expect(prompt.request == nil)

        await logIn(try #require(session.siteLoginFlow(for: "naver")))
        await session.retryAfterSiteLoginPrompt(prompt.messageID, meetings: [])
        // 다시 보내지 않는다: 대화는 "로그인됐어요"에서 끝난다
        #expect(session.messages.last?.siteLoggedIn == "naver")
        #expect(await agent.messageIDs.count == 1)
    }

    @Test func macThatSaysNothingFallsBackToTheWords() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1), captures: MockCaptures(script: .login))
        let session = await session(agent)
        await agent.script(loginNotice(resume: nil))
        await session.send("로그인해서 결제내역 알려줘", meetings: [])
        #expect(try #require(session.siteLoginPrompt).request == nil)

        let other = await self.session(MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1), captures: MockCaptures(script: .login)))
        await other.send("결제내역 알려줘", meetings: [])
        #expect(try #require(other.siteLoginPrompt).request == "결제내역 알려줘")
    }

    // MARK: - 맡긴 일에 답장

    @Test func replyingToATaskSendsOnlyItsNumber() async throws {
        let agent = MockAgentClient(v2: true, captures: MockCaptures(script: .open))
        let session = await session(agent)
        await session.send("결제내역 알려줘", meetings: [])
        let run = try #require(session.messages.last { $0.role == .agent })
        let state = try #require(run.agent)
        #expect(state.phase == .done)

        let quote = try #require(session.quote(for: run.id))
        // 인용에는 제목만 있다. 맥이 읽어 온 답은 들어가지 않는다
        #expect(quote.text == state.title)
        #expect(!quote.text.contains(MockCaptures.answer))

        await session.send("이거 뭐였지", meetings: [], replyTo: quote)
        #expect(await agent.replyTaskIDs == [nil, state.id])
        // 말에는 인용을 붙이지 않는다 (맥에는 번호만 간다)
        #expect(await agent.received.last?.text == "이거 뭐였지")
        #expect(session.messages.contains { $0.replyTo == quote })
    }

    @Test func replyingToAnAnswerSendsNoTaskNumber() async throws {
        let agent = MockAgentClient(v2: true)
        let session = await session(agent)
        await session.send("안녕", meetings: [])
        let answer = try #require(session.messages.last)
        await session.send("피곤하다", meetings: [], replyTo: session.quote(for: answer.id))
        #expect(await agent.replyTaskIDs == [nil, nil])
    }

    @Test func taskQuoteSurvivesRelaunchAndOldQuotesStillLoad() async throws {
        let agent = MockAgentClient(v2: true, captures: MockCaptures(script: .open))
        let session = await session(agent)
        await session.send("결제내역 알려줘", meetings: [])
        let run = try #require(session.messages.last { $0.role == .agent })
        let quote = try #require(session.quote(for: run.id))
        await session.send("안녕", meetings: [], replyTo: quote)

        let reopened = AskSession(provider: FakeAskProvider([]), agent: nil)
        reopened.attach(context)
        #expect(reopened.messages.first { $0.replyTo != nil }?.replyTo == quote)

        // 이 값이 없던 때 저장한 인용도 읽힌다
        let old = #"{"messageID":"\#(UUID().uuidString)","fromUser":false,"text":"12월 3일입니다."}"#
        let decoded = try JSONDecoder().decode(AskSession.Quote.self, from: Data(old.utf8))
        #expect(decoded.isTask == nil)
        #expect(decoded.label == "받은 답")
    }

    @Test func taskQuoteNeverGoesToClaude() async throws {
        let cloud = FakeAskProvider([.success(.init(answer: "기록에 없습니다.", found: false, citations: []))])
        let agent = MockAgentClient(v2: true, captures: MockCaptures(script: .open))
        let session = AskSession(provider: cloud, agent: agent, pollInterval: .zero)
        session.attach(context)
        await session.checkAgent()
        await session.send("결제내역 알려줘", meetings: [])
        let run = try #require(session.messages.last { $0.role == .agent })
        let quote = try #require(session.quote(for: run.id))

        let meeting = Meeting(title: "주간 회의")
        context.insert(meeting)
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
        await session.send("출시일은?", meetings: [meeting], engine: .cloud, replyTo: quote)
        // 말풍선에는 인용이 붙지만 Claude로는 질문만 간다 (작업 제목도 가지 않는다)
        #expect(session.messages.contains { $0.replyTo == quote })
        #expect(cloud.requests.last?.question == "출시일은?")
    }
}
