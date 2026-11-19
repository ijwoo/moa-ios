import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 메일 연결 ("네이버 메일 연결", D52): 맥이 사이트 로그인과 같은 형식으로 진행하지만 로그인이 아니다.
// 같은 화면(`SiteLoginSheet`)을 쓰되 정해 둔 말이 다르고, 연동 센터에서는 메일 계정 묶음에 둔다.
// 주소·비밀번호는 모두 가짜다.

@MainActor
@Suite("메일 연결 화면의 말")
struct MailSetupTests {
    private static let site = "naver_mail"
    private static let name = "네이버 메일 연결"

    /// 메일 연결도 해 주는 가짜 맥 (네이버에는 로그인되어 있고, 메일 계정은 아직 없다)
    private func agent(_ script: MockSites.MailSetup = .normal, loggedIn: Bool = true) -> MockAgentClient {
        var mail = MockMail(failure: "not_set")
        mail.noAddresses = true
        return MockAgentClient(v2: true, mail: mail, sites: MockSites(loggedIn: loggedIn, mailSetup: script))
    }

    private func flow(_ agent: any AgentProviding) -> SiteLoginFlow {
        SiteLoginFlow(site: Self.site, name: Self.name, agent: agent, pollInterval: .seconds(3600))
    }

    /// 주소를 묻는 첫 화면까지 연다
    private func opened(_ agent: any AgentProviding) async throws -> SiteLoginFlow {
        let flow = flow(agent)
        await flow.start()
        await flow.refresh()
        guard case .input(let login) = flow.screen else {
            Issue.record("주소를 묻는 화면이 나와야 한다: \(flow.screen)")
            throw AgentError.invalidResponse
        }
        #expect(login.fields.map(\.name) == ["id"])
        return flow
    }

    @Test func kindIsToldBySiteID() {
        #expect(SiteFlowKind.of("naver") == .login)
        #expect(SiteFlowKind.of("naver_mail") == .mailSetup)
        // 모르는 사이트는 로그인으로 본다
        #expect(SiteFlowKind.of("daum") == .login)
        // 맥이 이름을 주지 않아도 사이트 번호가 그대로 보이지 않는다
        #expect(SiteName.display("naver_mail") == "네이버 메일 연결")
        #expect(SiteLoginFlow(site: "naver_mail", agent: MockAgentClient(v2: true)).siteName == "네이버 메일 연결")
        #expect(SiteLoginFlow(site: "naver", name: "", agent: MockAgentClient(v2: true)).siteName == "네이버")
    }

    @Test func loginWordingIsUnchanged() throws {
        let copy = SiteLoginFlow(site: "naver", name: "네이버", agent: MockAgentClient(v2: true)).copy
        #expect(copy.kind == .login)
        #expect(copy.title == "네이버 로그인")
        #expect(copy.opening == "맥에서 네이버 로그인 화면을 열고 있어요")
        #expect(copy.doneTitle == "네이버에 로그인했어요")
        #expect(copy.doneDetail == "맥의 에이전트 브라우저에 로그인 상태만 남아 있어요. 아이디와 비밀번호는 맥에 저장하지 않았어요.")
        let input = SiteLogin(
            id: "l", site: "naver", method: "password", state: .needInput, step: 1, message: "",
            fields: [.init(name: "id", label: "", secret: false), .init(name: "password", label: "", secret: true)]
        )
        #expect(copy.submitTitle(for: input) == "로그인")
        #expect(copy.inputFooter(for: input).contains("맥에 남는 것은 로그인 상태뿐이에요"))
        // 사이트가 물어본 것은 사이트 화면의 글만 보인다
        var choice = input
        choice.state = .needChoice
        choice.message = "화면의 물음에 답해 주세요"
        choice.text = "이 브라우저를 자주 쓰는 기기로 등록할까요?"
        #expect(copy.choiceTexts(for: choice).headline == nil)
        #expect(copy.choiceTexts(for: choice).body == "이 브라우저를 자주 쓰는 기기로 등록할까요?")
        // 입력이 틀린 실패는 앱의 말로 한다 (맥이 준 글을 쓰지 않는다)
        var failed = input
        failed.state = .failed
        failed.reason = "wrong_input"
        failed.message = "맥이 준 글"
        #expect(copy.stopped(failed).title == "로그인하지 못했어요")
        #expect(!copy.stopped(failed).detail.contains("맥이 준 글"))
        // 막힌 까닭은 맥의 말에만 있다: 그 말을 보이고, 다시 시도는 내놓지 않는다 (D83)
        failed.reason = "blocked"
        #expect(copy.stopped(failed).title == "로그인이 막혔어요")
        #expect(copy.stopped(failed).detail == "맥이 준 글")
        #expect(!copy.stopped(failed).canRetry)
        failed.message = ""
        #expect(copy.stopped(failed).title == "네이버가 로그인을 막았어요")
        #expect(!copy.stopped(failed).canRetry)
    }

    @Test func wholeSetupNeverSaysLogin() async throws {
        let agent = agent()
        let flow = try await opened(agent)
        let copy = flow.copy
        #expect(copy.kind == .mailSetup)
        #expect(copy.title == "네이버 메일 연결")
        #expect(copy.opening == "맥에서 준비하고 있어요")

        // 1. 주소: 비밀번호가 아니므로 "저장하지 않아요"가 아니라 이 주소가 어떻게 되는지를 말한다
        guard case .input(let address) = flow.screen else { return }
        #expect(address.message == "연결할 네이버 메일 주소(또는 아이디)를 입력해 주세요")
        #expect(copy.submitTitle(for: address) == "다음")
        #expect(copy.inputFooter(for: address) == "연결이 끝나면 이 주소가 맥의 기본 메일 계정으로 등록돼요.")
        await flow.submit(["id": "me@naver.test"])
        #expect(flow.screen == .working("네이버 보안설정으로 가고 있어요"))
        await flow.refresh()

        // 2. 네이버가 비밀번호를 다시 묻는다
        guard case .input(let password) = flow.screen else {
            Issue.record("비밀번호를 묻는 화면이 나와야 한다: \(flow.screen)")
            return
        }
        #expect(password.fields.map(\.name) == ["password"])
        #expect(copy.submitTitle(for: password) == "확인")
        #expect(copy.inputFooter(for: password).hasPrefix("비밀번호는 맥의 브라우저에 한 번 입력하는 데만 써요."))
        await flow.submit(["password": "Kq7!가상-비밀번호"])
        await flow.refresh()

        // 3. 바꾸기 전에 묻는다: 물음은 굵게, 설명은 그 아래
        guard case .choice(let create) = flow.screen else {
            Issue.record("만들지 묻는 화면이 나와야 한다: \(flow.screen)")
            return
        }
        #expect(create.choices == ["만들기", "취소"])
        #expect(copy.choiceTexts(for: create).headline == "애플리케이션 비밀번호를 만들까요?")
        #expect(copy.choiceTexts(for: create).body == create.text)
        #expect(copy.choiceFooter == "에이전트가 설정을 바꾸기 전에 묻는 것이에요. 고른 대로 맥의 브라우저에서 눌러요.")
        await flow.choose("만들기")
        #expect(flow.screen == .working("만든 비밀번호로 메일 서버에 연결해 보고 있어요"))
        await flow.refresh()

        // 4. 끝: 남는 것은 로그인 상태가 아니라 맥에 보관한 앱 비밀번호다
        #expect(flow.screen == .done)
        #expect(copy.doneTitle == "메일 계정을 연결했어요")
        #expect(copy.doneDetail == "새로 만든 앱 비밀번호는 맥의 키체인에만 보관돼요. 계정 비밀번호는 저장하지 않았어요.")
        // 맥이 받은 것은 화면마다 그 칸 이름대로 한 번씩이다
        #expect(await agent.loginInputs.map(\.names) == [["id"], ["password"], ["choice"]])
        // 정해 둔 말 어디에도 "로그인"이 없다
        let fixed = [
            copy.title, copy.opening, copy.offline, copy.wrongInput, copy.approvalFallback, copy.approvalFooter, copy.choiceFooter ?? "",
            copy.doneTitle, copy.doneDetail, copy.startFailedTitle, copy.unsupportedDetail, copy.lostTitle,
            copy.inputFooter(for: address), copy.inputFooter(for: password), copy.submitTitle(for: address), copy.submitTitle(for: password),
        ]
        #expect(fixed.allSatisfy { !$0.contains("로그인") })
    }

    @Test func connectedAccountBecomesTheDefaultMailAccount() async throws {
        let agent = agent()
        let model = SiteAccountsModel(agent: agent)
        await model.load()
        // 브라우저 로그인 묶음에는 네이버만, 메일 연결은 메일 계정 묶음의 줄로
        #expect(model.sites.map(\.site) == ["naver", "naver_mail"])
        #expect(model.loginSites.map(\.site) == ["naver"])
        #expect(model.mailSetups.map(\.name) == ["네이버 메일 연결"])
        #expect(try await agent.mailAccounts(check: false).isEmpty)

        let flow = try #require(model.flow(for: "naver_mail"))
        // 화면 제목은 맥이 알려 준 이름이다
        #expect(flow.copy.title == "네이버 메일 연결")
        await flow.start()
        await flow.refresh()
        await flow.submit(["id": "me@naver.test"])
        await flow.refresh()
        await flow.submit(["password": "Kq7!가상-비밀번호"])
        await flow.refresh()
        await flow.choose("만들기")
        await flow.refresh()
        #expect(flow.screen == .done)

        let accounts = try await agent.mailAccounts(check: false)
        #expect(accounts.map(\.address) == ["me@naver.test"])
        #expect(accounts.first?.isDefault == true)
        #expect(accounts.first?.status == .ready)
        // 연결된 뒤에는 "연결" 줄이 사라지고 메일 계정 줄이 그 자리를 대신한다
        await model.load()
        #expect(model.mailSetups.isEmpty)
        #expect(model.loginSites.map(\.site) == ["naver"])
    }

    @Test func decliningEndsWithWhatTheMacSaid() async throws {
        let flow = try await opened(agent(.imap))
        await flow.submit(["id": "me@naver.test"])
        await flow.refresh()
        guard case .choice(let imap) = flow.screen else {
            Issue.record("IMAP을 켤지 묻는 화면이 나와야 한다: \(flow.screen)")
            return
        }
        #expect(flow.copy.choiceTexts(for: imap).headline == "IMAP/SMTP 사용을 켤까요?")
        await flow.choose("취소")
        await flow.refresh()
        #expect(flow.screen == .stopped(title: "연결을 취소했어요", detail: "IMAP/SMTP 설정을 바꾸지 않고 끝냈어요", canRetry: true))
    }

    @Test func failureShowsWhatTheMacSaidToCleanUp() async throws {
        let flow = try await opened(agent(.failed))
        await flow.submit(["id": "me@naver.test"])
        await flow.refresh()
        await flow.submit(["password": "Kq7!가상-비밀번호"])
        await flow.refresh()
        await flow.choose("만들기")
        await flow.refresh()
        guard case .stopped(let title, let detail, let canRetry) = flow.screen else {
            Issue.record("멈춰야 한다: \(flow.screen)")
            return
        }
        // 무엇을 지워야 하는지는 맥이 준 글에만 있다
        #expect(title == "메일을 연결하지 못했어요")
        #expect(detail.contains("네이버 보안설정에서 'AIagent' 비밀번호를 지운 뒤 다시 해 주세요"))
        #expect(canRetry)
        #expect(flow.stoppedAt != nil)
    }

    @Test func setupNeedsTheNaverLoginFirst() async throws {
        let flow = flow(agent(loggedIn: false))
        await flow.start()
        await flow.refresh()
        #expect(flow.screen == .stopped(title: "메일을 연결하지 못했어요", detail: "먼저 네이버 로그인을 해 주세요", canRetry: true))
    }

    @Test func wrongAddressAsksAgainAndThenStops() async throws {
        let flow = try await opened(agent())
        await flow.submit(["id": "wrong"])
        await flow.refresh()
        guard case .input(let again) = flow.screen else {
            Issue.record("다시 물어야 한다: \(flow.screen)")
            return
        }
        #expect(again.wasWrongInput)
        #expect(again.message == "네이버 메일 주소 형식이 아니에요. 다시 입력해 주세요")
        #expect(flow.copy.wrongInput == "입력한 내용이 맞지 않아요. 다시 입력해 주세요. 여러 번 틀리면 연결을 멈춰요.")
        for _ in 0..<2 {
            await flow.submit(["id": "wrong"])
            await flow.refresh()
        }
        #expect(flow.screen == .stopped(title: "메일을 연결하지 못했어요", detail: "주소를 확인하지 못했어요", canRetry: true))
    }

    @Test func stoppedWordingWithoutAMessage() {
        let copy = SiteLoginCopy(kind: .mailSetup, name: Self.name)
        var login = SiteLogin(id: "l", site: Self.site, method: "password", state: .failed, step: 2, message: "")
        #expect(copy.stopped(login).detail == "메일은 연결되지 않았어요. 잠시 뒤에 다시 시도해 주세요.")
        // 사이트가 막았으면 다시 해 보라고 하지 않는다
        login.reason = "blocked"
        #expect(!copy.stopped(login).canRetry)
        login.state = .expired
        #expect(copy.stopped(login).title == "시간이 지나 끝났어요")
        login.state = .cancelled
        #expect(copy.stopped(login).detail == "메일은 연결되지 않았어요.")
        // 시작하지 못한 까닭
        #expect(copy.startProblem(for: AgentError.rateLimited) == "짧은 시간에 여러 번 시작했어요. 10분쯤 뒤에 다시 해 주세요.")
        #expect(copy.startProblem(for: AgentError.unknownSite) == "지금 연결된 맥에서는 이 기능을 아직 쓸 수 없어요.")
        #expect(copy.startProblem(for: AgentError.unreachable) == SiteLoginFlow.startProblem(for: AgentError.unreachable))
    }

    @Test func mailSetupIsNotCountedAsABrowserLogin() async throws {
        let naver = SiteStatus(site: "naver", name: "네이버", status: .loggedIn, checkedAt: nil, methods: ["password"])
        let mail = SiteStatus(site: "naver_mail", name: "네이버 메일 연결", status: .loggedIn, checkedAt: nil, methods: ["password"])
        #expect(ConnectionSummary.browser(supported: true, sites: [naver, mail]) == "네이버")
        #expect(ConnectionSummary.browser(supported: true, sites: [mail]) == "로그인 안 됨")
        // 메일 연결을 모르는 맥은 목록에 넣지 않는다
        let old = MockAgentClient(v2: true, sites: MockSites())
        #expect(try await old.sites().map(\.site) == ["naver"])
        // 메일 계정이 없을 때의 말: 맥이 대신 연결해 줄 수 있으면 "주소를 먼저 넣어야 해요"라고 하지 않는다
        #expect(IntegrationsView.emptyMailTitle(loadFailed: false, canSetUp: true) == "연결된 메일 계정이 아직 없어요")
        #expect(IntegrationsView.emptyMailTitle(loadFailed: false, canSetUp: false) == "보낼 수 있는 내 주소가 아직 없어요")
        #expect(IntegrationsView.emptyMailTitle(loadFailed: true, canSetUp: true) == "계정 목록을 받지 못했어요")
    }
}

// 대화에서 "네이버 메일 연결해줘"라고 해도 같은 화면이 열린다 (맥이 `site_login` · `naver_mail`로 답한다).
// 대화에 붙는 카드와 남는 한 줄도 로그인이 아니라 메일 연결의 말이어야 한다.
@MainActor
@Suite("메일 연결 대화")
struct MailSetupChatTests {
    let context: ModelContext
    let meeting: Meeting

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        meeting = Meeting(title: "주간 회의")
        context.insert(meeting)
    }

    private func session(_ agent: any AgentProviding) async -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        session.attach(context)
        await session.checkAgent()
        return session
    }

    private func agent() -> MockAgentClient {
        var mail = MockMail(failure: "not_set")
        mail.noAddresses = true
        return MockAgentClient(v2: true, mail: mail, sites: MockSites(loggedIn: true, mailSetup: .normal))
    }

    @Test func askingInChatOpensTheMailSetupNotTheLogin() async throws {
        let agent = agent()
        let session = await session(agent)
        await session.send("네이버 메일 연결해줘", meetings: [meeting])
        let last = try #require(session.messages.last)
        #expect(last.text == "네이버 메일 연결을 시작할게요.")
        #expect(session.siteLoginPrompt == AskSession.SiteLoginPrompt(messageID: last.id, site: "naver_mail"))
        // "네이버 로그인해줘"는 여전히 로그인이다
        await session.send("네이버 로그인해줘", meetings: [meeting])
        #expect(session.siteLoginPrompt?.site == "naver")

        // 카드의 글: 로그인이 필요하다고 하지 않는다
        let card = SiteLoginCopy(site: "naver_mail")
        #expect(card.cardTitle == "네이버 메일 연결")
        #expect(card.cardButton == "연결 화면 열기")
        #expect([card.cardTitle, card.cardBody, card.cardButton, card.cardButtonHint, card.cardFooter, card.doneCardTitle, card.chatDone, card.chatOpening]
            .allSatisfy { !$0.contains("로그인") })
        // 로그인 카드의 글은 그대로다
        let login = SiteLoginCopy(site: "naver")
        #expect(login.cardTitle == "네이버 로그인이 필요해요")
        #expect(login.cardButton == "네이버 로그인")
        #expect(login.doneCardTitle == "네이버 로그인 완료")
        #expect(login.chatOpening == "네이버 로그인 화면을 열게요.")
    }

    @Test func finishingLeavesOneLineAboutTheMailAccount() async throws {
        let agent = agent()
        let session = await session(agent)
        await session.send("네이버 메일 연결해줘", meetings: [meeting])
        let prompt = try #require(session.siteLoginPrompt)
        let flow = try #require(session.siteLoginFlow(for: prompt.site))
        #expect(flow.copy.title == "네이버 메일 연결")
        await flow.start()
        await flow.refresh()
        await flow.submit(["id": "me@naver.test"])
        await flow.refresh()
        await flow.submit(["password": "Kq7!가상-비밀번호"])
        await flow.refresh()
        await flow.choose("만들기")
        await flow.refresh()
        #expect(flow.screen == .done)

        // 대화에는 결과 한 줄만 남고 (완료 카드로 그린다), 카드는 사라진다
        #expect(session.siteLoginPrompt == nil)
        let done = try #require(session.messages.last)
        #expect(done.siteLoggedIn == "naver_mail")
        #expect(done.text == "메일 계정을 연결했어요. 새로 만든 앱 비밀번호는 맥의 키체인에만 보관돼요. 계정 비밀번호는 저장하지 않았어요.")
        // 넣은 주소와 비밀번호는 대화 어디에도 없다
        #expect(session.messages.allSatisfy { !$0.text.contains("Kq7!") && !$0.text.contains("me@naver.test") })
    }
}
