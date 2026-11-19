import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 로그인 때문에 멈춘 작업에서 바로 로그인하기 (D57).
// 아이디·비밀번호·사이트 내용은 모두 지어낸 것이다.

private enum LoginStoppedFixture {
    /// 가짜 아이디·비밀번호 (실제 값이 아니다)
    static let id = "minsu_demo"
    static let password = "Kq7!가상-비밀번호"

    static func task(reason: String? = "login_expired", action: String? = #"{"type":"site_login","site":"naver"}"#) -> String {
        let reasonJSON = reason.map { #","reason":"\#($0)""# } ?? ""
        let actionJSON = action.map { #","action":\#($0)"# } ?? ""
        return """
        {"id":"t_read1","status":"failed","task":"결제내역 알려줘","title":"결제내역 확인",\
        "created_at":"2026-11-13T01:30:00+00:00","updated_at":"2026-11-13T01:30:28+00:00","steps":[],\
        "result":{"outcome":"needs_login","summary":"네이버 로그인이 풀렸어요. 다시 로그인해 주세요."\(reasonJSON)\(actionJSON),"approved_drafts":[],\
        "report":{"done":[],"blocked":["네이버 로그인이 풀렸어요. 다시 로그인해 주세요."],"sources":[]}}}
        """
    }

    static func decode(reason: String? = "login_expired", action: String? = #"{"type":"site_login","site":"naver"}"#) throws -> AgentTaskState {
        try AgentHTTPClient.decodeTask(data: Data(task(reason: reason, action: action).utf8), status: 200)
    }
}

@Suite("로그인 때문에 멈춘 작업: 받은 값 읽기")
struct LoginStoppedDecodingTests {
    @Test func expiredLoginNamesTheSiteToLogInTo() throws {
        let state = try LoginStoppedFixture.decode()
        #expect(state.phase == .failed)
        #expect(state.loginSite == "naver")
        #expect(state.loginExpired == true)
        #expect(state.needsSiteLogin)
        #expect(state.error == "네이버 로그인이 풀려서 멈췄어요.")
        // 메일 계정 문제가 아니다
        #expect(!state.needsMailAccount)
    }

    @Test func missingLoginIsNotCalledExpired() throws {
        let state = try LoginStoppedFixture.decode(reason: "login_missing")
        #expect(state.loginSite == "naver")
        #expect(state.loginExpired == false)
        #expect(state.error == "네이버 로그인이 필요해서 멈췄어요.")
    }

    @Test(arguments: [
        nil,
        #"{"type":"open_url","site":"naver"}"#,
        #"{"type":"site_login"}"#,
        #"{"type":"site_login","site":"../tasks"}"#,
        #"{"type":"site_login","site":7}"#,
        #""site_login""#,
        "[]",
    ])
    func taskWithoutAUsableSiteStillShowsWhy(action: String?) throws {
        // 어디에 로그인할지 모르면 버튼은 붙이지 않는다. 그래도 왜 멈췄는지는 읽힌다
        let state = try LoginStoppedFixture.decode(action: action)
        #expect(state.phase == .failed)
        #expect(state.loginSite == nil)
        #expect(!state.needsSiteLogin)
        #expect(state.error == "로그인이 풀려서 멈췄어요.")
        #expect(state.report?.blocked == ["네이버 로그인이 풀렸어요. 다시 로그인해 주세요."])
    }

    @Test func loginSiteSurvivesSavingAndOldRecordsStillOpen() throws {
        let state = try LoginStoppedFixture.decode()
        let saved = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(AgentTaskState.self, from: saved) == state)
        // 이 값이 없던 때 저장한 기록도 읽힌다
        var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        object["loginSite"] = nil
        object["loginExpired"] = nil
        let old = try JSONDecoder().decode(AgentTaskState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.loginSite == nil && !old.needsSiteLogin)
    }
}

@MainActor
@Suite("로그인 때문에 멈춘 작업: 대화에서 로그인하고 이어서 하기")
struct LoginStoppedChatTests {
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

    /// 로그인 화면이 하는 일: 열고, 입력을 보내고, 휴대폰 승인을 기다린다
    private func logIn(_ flow: SiteLoginFlow) async {
        await flow.start()
        await flow.refresh()
        await flow.submit(["id": LoginStoppedFixture.id, "password": LoginStoppedFixture.password])
        for _ in 0..<10 where flow.screen != .done { await flow.refresh() }
    }

    @Test func stoppedTaskOffersLoginAndRetriesAfterIt() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1), captures: MockCaptures(script: .blocked))
        let session = await session(agent)
        await session.send("결제내역 알려줘", meetings: [])

        let stopped = try #require(session.messages.last?.agent)
        #expect(stopped.needsSiteLogin)
        #expect(session.siteLoginTask == AskSession.SiteLoginTask(taskID: stopped.id, site: "naver"))
        // 맥이 답으로 연 로그인 카드가 아니다 (화면을 스스로 열지 않는다)
        #expect(session.siteLoginPrompt == nil)
        // 누르기 전에는 맥에 로그인을 시작하지 않는다
        #expect(await agent.loginStarts == 0)

        let flow = try #require(session.siteLoginFlow(for: "naver"))
        await logIn(flow)
        #expect(flow.screen == .done)
        // 작업 아래에 "로그인됐어요"가 붙고 로그인 안내는 사라진다
        #expect(session.messages.last?.siteLoggedIn == "naver")
        #expect(session.siteLoginTask == nil)

        await session.retryAfterSiteLogin(stopped.id, meetings: [])
        let retried = try #require(session.messages.last?.agent)
        #expect(retried.id != stopped.id)
        #expect(retried.phase == .done)
        #expect(retried.report?.done == [MockCaptures.answer])
        #expect(session.messages.filter { $0.role == .user && $0.text == "결제내역 알려줘" }.count == 2)
        // 다시 보낸 말은 새 메시지 번호로 간다. 같은 번호면 맥이 멈췄던 그 작업을 그대로 돌려준다 (D47)
        let sent = await agent.messageIDs.compactMap { $0 }
        #expect(sent.count == 2)
        #expect(Set(sent).count == 2)

        // 아이디·비밀번호는 대화 어디에도 남지 않는다: 메시지에도, 맥의 대화 담당에게 간 말에도, 저장된 기록에도
        let leaks = { (text: String) in text.contains(LoginStoppedFixture.password) || text.contains(LoginStoppedFixture.id) }
        #expect(session.messages.allSatisfy { !leaks($0.text) })
        #expect(await agent.received.allSatisfy { !leaks($0.text) && !leaks($0.context ?? "") })
        for record in try context.fetch(FetchDescriptor<ChatRecord>()) {
            #expect(!leaks(record.text))
            #expect(!leaks(String(decoding: record.agentData ?? Data(), as: UTF8.self)))
        }
    }

    @Test func retryHappensOnlyRightAfterLoggingInFromThatTask() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1), captures: MockCaptures(script: .blocked))
        let session = await session(agent)
        await session.send("결제내역 알려줘", meetings: [])
        let stopped = try #require(session.messages.last?.agent)

        // 로그인하지 않았으면 다시 맡기지 않는다
        let before = session.messages.count
        await session.retryAfterSiteLogin(stopped.id, meetings: [])
        #expect(session.messages.count == before)

        // 그 사이 다른 말이 오갔으면 안내도 사라지고, 나중에 로그인해도 옛 부탁을 다시 맡기지 않는다
        await session.send("안녕", meetings: [])
        #expect(session.siteLoginTask == nil)
        let count = session.messages.count
        session.siteLoggedIn("naver")
        await session.retryAfterSiteLogin(stopped.id, meetings: [])
        #expect(session.messages.count == count)
    }

    // MARK: 로그인이 없어서 작업을 만들지 못한 부탁 (D58)

    @Test func requestBlockedByMissingLoginIsSentAgainAfterLoggingIn() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1), captures: MockCaptures(script: .login))
        let session = await session(agent)
        await session.send("결제내역 알려줘", meetings: [])

        // 작업은 만들어지지 않고, 로그인 안내가 그 부탁을 기억한다
        let prompt = try #require(session.siteLoginPrompt)
        #expect(session.messages.last?.agent == nil)
        #expect(prompt.site == "naver")
        #expect(prompt.request == "결제내역 알려줘")

        let flow = try #require(session.siteLoginFlow(for: "naver"))
        await logIn(flow)
        #expect(session.messages.last?.siteLoggedIn == "naver")

        // 사용자가 "했어"라고 말하지 않아도 같은 부탁이 다시 간다
        await session.retryAfterSiteLoginPrompt(prompt.messageID, meetings: [])
        let done = try #require(session.messages.last?.agent)
        #expect(done.phase == .done)
        #expect(done.report?.done == [MockCaptures.answer])
        #expect(session.messages.filter { $0.role == .user && $0.text == "결제내역 알려줘" }.count == 2)
        // 새 메시지 번호로 간다 (같은 번호면 맥이 "로그인이 필요해요"를 그대로 돌려준다)
        let sent = await agent.messageIDs.compactMap { $0 }
        #expect(sent.count == 2 && Set(sent).count == 2)

        let leaks = { (text: String) in text.contains(LoginStoppedFixture.password) || text.contains(LoginStoppedFixture.id) }
        #expect(session.messages.allSatisfy { !leaks($0.text) })
        #expect(await agent.received.allSatisfy { !leaks($0.text) && !leaks($0.context ?? "") })
    }

    @Test func askingOnlyToLogInIsNotSentAgain() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1), captures: MockCaptures(script: .login))
        let session = await session(agent)
        await session.send("네이버 로그인해줘", meetings: [])

        let prompt = try #require(session.siteLoginPrompt)
        #expect(prompt.request == nil)
        let flow = try #require(session.siteLoginFlow(for: "naver"))
        await logIn(flow)
        let count = session.messages.count
        await session.retryAfterSiteLoginPrompt(prompt.messageID, meetings: [])
        #expect(session.messages.count == count)
        #expect(await agent.received.count == 1)
    }

    @Test func blockedRequestIsNotSentAgainOnceTheConversationMovedOn() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1), captures: MockCaptures(script: .login))
        let session = await session(agent)
        await session.send("결제내역 알려줘", meetings: [])
        let prompt = try #require(session.siteLoginPrompt)

        // 로그인하지 않았으면 다시 보내지 않는다
        var count = session.messages.count
        await session.retryAfterSiteLoginPrompt(prompt.messageID, meetings: [])
        #expect(session.messages.count == count)

        // 그 사이 다른 말이 오갔으면 안내가 사라지고, 옛 부탁을 다시 보내지 않는다
        await session.send("안녕", meetings: [])
        #expect(session.siteLoginPrompt == nil)
        count = session.messages.count
        await session.retryAfterSiteLoginPrompt(prompt.messageID, meetings: [])
        #expect(session.messages.count == count)
    }

    @Test(arguments: ["네이버 로그인해줘", "네이버 연결해 줘", "NAVER login", "네이버 메일 연동해줘"])
    func wordsThatOnlyAskToLogIn(_ text: String) {
        #expect(AskSession.isLoginOnlyRequest(text))
    }

    @Test(arguments: ["결제내역 알려줘", "네이버페이 결제내역에서 최근 3건을 알려줘", "이번 달에 얼마 썼어?"])
    func wordsThatAskForSomethingElse(_ text: String) {
        #expect(!AskSession.isLoginOnlyRequest(text))
    }

    @Test func macThatDoesNotNameASiteGetsNoLoginButton() async throws {
        // 로그인을 모르는 맥(사이트를 알려 주지 않는다): 예전처럼 이유와 멈춘 화면만 보여 준다
        let session = await session(MockAgentClient(v2: true, captures: MockCaptures(script: .blocked)))
        await session.send("결제내역 알려줘", meetings: [])
        let stopped = try #require(session.messages.last?.agent)
        #expect(stopped.phase == .failed && !stopped.needsSiteLogin)
        #expect(session.siteLoginTask == nil)
    }
}
