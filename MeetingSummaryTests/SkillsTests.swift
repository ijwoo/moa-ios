import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 사이드바와 맡길 수 있는 일(skills, D53).
// 응답 예시는 맥 쪽 API 문서의 형식을 가상 데이터로 쓴 것이다.

private enum SkillFixture {
    static let list = """
    {"skills":[\
    {"id":"mail_briefing","title":"오늘 온 메일 브리핑","description":"오늘 받은 메일을 정리해 드려요.","category":"메일",\
    "prompt":"오늘 온 메일 요약해줘","status":"ready","available":false,\
    "needs":[{"kind":"mail_account","message":"메일 계정 연결이 필요해요","prompt":"네이버 메일 연결해줘"}]},\
    {"id":"mail_to_self","title":"회의 요약을 내 메일로 보내기","description":"보내기 전에 승인을 받아요.","category":"메일",\
    "prompt":"오늘 회의 내용 요약해서 나한테 메일로 보내줘","status":"beta","available":true,"needs":[]},\
    {"id":"naver_login","title":"네이버 로그인","description":"","category":"연결","prompt":"네이버 로그인해줘","status":"ready","available":true,"needs":[]},\
    {"id":"naver_mail_connect","title":"네이버 메일 연결","description":"네이버 메일을 연결해요.","category":"연결",\
    "prompt":"네이버 메일 연결해줘","status":"ready","available":false,\
    "needs":[{"kind":"site:naver","message":"네이버 로그인이 필요해요","prompt":"네이버 로그인해줘"}]}]}
    """

    static func decode(_ json: String, status: Int = 200) throws -> [AgentSkill] {
        try AgentHTTPClient.decodeSkills(data: Data(json.utf8), status: status)
    }
}

@Suite("맡길 수 있는 일 응답")
struct SkillsDecodingTests {
    @Test func decodesTheCardsInServerOrder() throws {
        let skills = try SkillFixture.decode(SkillFixture.list)
        #expect(skills.map(\.id) == ["mail_briefing", "mail_to_self", "naver_login", "naver_mail_connect"])
        let briefing = skills[0]
        #expect(briefing.title == "오늘 온 메일 브리핑")
        #expect(briefing.category == "메일")
        #expect(briefing.prompt == "오늘 온 메일 요약해줘")
        #expect(!briefing.isBeta)
        #expect(!briefing.isAvailable)
        #expect(briefing.blocker == AgentSkill.Need(kind: "mail_account", message: "메일 계정 연결이 필요해요", prompt: "네이버 메일 연결해줘"))
        // 시험 중인 일
        #expect(skills[1].isBeta)
        #expect(skills[1].isAvailable)
        #expect(skills[1].blocker == nil)
        #expect(skills[2].description.isEmpty)
    }

    @Test func groupsByCategoryKeepingServerOrder() throws {
        let groups = AgentSkill.grouped(try SkillFixture.decode(SkillFixture.list))
        #expect(groups.map(\.category) == ["메일", "연결"])
        #expect(groups[0].skills.map(\.id) == ["mail_briefing", "mail_to_self"])
        #expect(groups[1].skills.map(\.id) == ["naver_login", "naver_mail_connect"])
        // 떨어져 있어도 같은 묶음은 처음 나온 자리에 모인다
        let mixed = [
            AgentSkill(id: "a", title: "a", description: "", category: "메일", prompt: "a"),
            AgentSkill(id: "b", title: "b", description: "", category: "", prompt: "b"),
            AgentSkill(id: "c", title: "c", description: "", category: "메일", prompt: "c"),
        ]
        let regrouped = AgentSkill.grouped(mixed)
        #expect(regrouped.map(\.category) == ["메일", ""])
        #expect(regrouped[0].skills.map(\.id) == ["a", "c"])
        #expect(AgentSkill.grouped([]).isEmpty)
    }

    @Test func dropsCardsThatCannotBeAskedAndKeepsTheRest() throws {
        let json = """
        {"skills":[\
        {"id":"no_prompt","title":"보낼 말 없음","prompt":"  "},\
        {"id":"","title":"번호 없음","prompt":"해줘"},\
        {"id":"no_title","prompt":"해줘"},\
        {"id":"ok","title":" 남는 카드 ","prompt":" 이거 해줘 ","status":"something_new","extra":1}]}
        """
        let skills = try SkillFixture.decode(json)
        #expect(skills.map(\.id) == ["ok"])
        // 앞뒤 빈칸은 떼고, 모르는 상태는 시험 중이 아니다. 빠진 값은 빈 글
        #expect(skills[0].title == "남는 카드")
        #expect(skills[0].prompt == "이거 해줘")
        #expect(!skills[0].isBeta)
        #expect(skills[0].description.isEmpty)
        #expect(skills[0].category.isEmpty)
        #expect(skills[0].isAvailable)
    }

    @Test func availabilityFallsBackToWhetherNeedsRemain() throws {
        let json = """
        {"skills":[\
        {"id":"a","title":"a","prompt":"a","needs":[{"kind":"new_kind","message":"먼저 무엇이 필요해요","prompt":""}]},\
        {"id":"b","title":"b","prompt":"b","needs":[{"kind":"mail_account","message":"  "}]},\
        {"id":"c","title":"c","prompt":"c","available":false}]}
        """
        let skills = try SkillFixture.decode(json)
        // 맥이 말해 주지 않았고 준비가 남아 있으면 맡길 수 없다
        #expect(!skills[0].isAvailable)
        #expect(skills[0].blocker?.prompt.isEmpty == true)
        // 글이 없는 준비는 보여 줄 것이 없어 뺀다 → 남은 준비 없음
        #expect(skills[1].needs.isEmpty)
        #expect(skills[1].isAvailable)
        // 맡길 수 없다는데 까닭이 없으면 단추만 막힌다
        #expect(!skills[2].isAvailable)
        #expect(skills[2].blocker == nil)
    }

    @Test func needButtonSaysWhatToPrepare() {
        #expect(AgentSkill.Need(kind: "site:naver", message: "m", prompt: "p").buttonTitle == "로그인하기")
        #expect(AgentSkill.Need(kind: "mail_account", message: "m", prompt: "p").buttonTitle == "메일 연결하기")
        #expect(AgentSkill.Need(kind: "something_new", message: "m", prompt: "p").buttonTitle == "먼저 준비하기")
    }

    @Test func emptyListAndBadResponses() throws {
        let none = try SkillFixture.decode(#"{"skills":[]}"#)
        #expect(none.isEmpty)
        #expect(throws: AgentError.invalidResponse) { try SkillFixture.decode(#"{"cards":[]}"#) }
        #expect(throws: AgentError.invalidResponse) { try SkillFixture.decode("<html>") }
        #expect(throws: AgentError.unauthorized) {
            try SkillFixture.decode(#"{"error":{"code":"unauthorized","message":"m"}}"#, status: 401)
        }
    }
}

@MainActor
@Suite("맡길 수 있는 일 목록")
struct SkillsModelTests {
    /// 메일 계정이 아직 없는 맥 (네이버 로그인은 `loggedIn`에 따라)
    private func agent(loggedIn: Bool = false, mailReady: Bool = false, reachable: Bool = true, offers: Bool = true) -> MockAgentClient {
        var mail = MockMail()
        mail.noAddresses = !mailReady
        return MockAgentClient(
            reachable: reachable, v2: true, mail: mail, sites: MockSites(loggedIn: loggedIn, mailSetup: .normal), offersSkills: offers
        )
    }

    @Test func loadsTheCardsWithNeedsFromTheMacState() async {
        let model = SkillsModel(agent: agent())
        #expect(!model.hasLoaded)
        #expect(!model.isOffered)
        await model.load()
        #expect(model.hasLoaded)
        #expect(!model.loadFailed)
        #expect(model.isOffered)
        #expect(model.skills.map(\.id) == ["mail_briefing", "mail_to_self", "naver_login", "naver_mail_connect"])
        // 메일 계정도 네이버 로그인도 없다
        #expect(model.skills[0].blocker?.kind == "mail_account")
        #expect(model.skills[1].isBeta)
        #expect(model.skills[2].isAvailable)
        #expect(model.skills[3].blocker?.kind == "site:naver")
    }

    @Test func everythingIsAvailableOnceConnected() async {
        let model = SkillsModel(agent: agent(loggedIn: true, mailReady: true))
        await model.load()
        #expect(model.skills.count == 4)
        #expect(model.skills.filter { !$0.isAvailable }.isEmpty)
        #expect(model.skills.compactMap(\.blocker).isEmpty)
    }

    @Test func aMacThatDoesNotOfferSkillsHidesTheEntry() async {
        let model = SkillsModel(agent: agent(offers: false))
        await model.load()
        #expect(model.hasLoaded)
        #expect(!model.loadFailed)
        #expect(!model.isOffered)
        // 맥 에이전트가 설정되지 않은 앱
        let none = SkillsModel(agent: nil)
        await none.load()
        #expect(!none.isOffered)
        #expect(!none.loadFailed)
    }

    @Test func anUnreachableMacFailsTheLoad() async {
        let model = SkillsModel(agent: agent(reachable: false))
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.loadFailed)
        #expect(!model.isOffered)
    }

    @Test func aBlipKeepsTheOldListButMarksItStale() async {
        // 첫 확인은 되고, 그다음 한 번만 끊긴다
        let model = SkillsModel(agent: FlakySkillsAgent(failOn: [2]))
        await model.load()
        #expect(model.skills.count == 1)
        #expect(!model.loadFailed)
        await model.load()
        #expect(model.skills.count == 1)
        #expect(model.loadFailed)
        await model.load()
        #expect(model.skills.count == 1)
        #expect(!model.loadFailed)
    }
}

/// 정해 둔 차례의 연결 확인에만 실패하는 맥
private actor FlakySkillsAgent: AgentProviding {
    private let failOn: Set<Int>
    private var checks = 0

    init(failOn: Set<Int>) { self.failOn = failOn }

    func isReachable() async -> Bool {
        checks += 1
        return !failOn.contains(checks)
    }
    func supports(_ feature: String) async -> Bool { feature == AgentFeature.skills }
    func skills() async throws -> [AgentSkill] {
        [AgentSkill(id: "a", title: "가상 일", description: "", category: "", prompt: "가상 일 해줘")]
    }
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply { throw AgentError.unreachable }
    func start(task: String, context: String?) async throws -> AgentTaskState { throw AgentError.unreachable }
    func state(of id: String) async throws -> AgentTaskState { throw AgentError.unreachable }
    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        throw AgentError.unreachable
    }
    func cancel(_ id: String) async throws -> AgentTaskState { throw AgentError.unreachable }
}

// "부탁하기"는 카드의 말을 내 말로 대화에 보내는 것이 전부다. 그리고 대화가 답을 기다리는 동안에는 맡길 수 없다.
@MainActor
@Suite("맡길 수 있는 일 부탁하기")
struct SkillsAskTests {
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

    @Test func askingTheBriefingCardSendsItsPromptAndShowsTheAnswer() async throws {
        let agent = MockAgentClient(v2: true, mail: MockMail(), sites: MockSites(loggedIn: true), offersSkills: true)
        let card = try #require(try await agent.skills().first)
        #expect(card.isAvailable)
        let session = await session(agent)
        await session.send(card.prompt, meetings: [meeting])

        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(session.messages[0].text == "오늘 온 메일 요약해줘")
        // 여러 줄 답이 한 말로 온다 (가상 메일)
        let answer = session.messages[1].text
        #expect(answer.hasPrefix("오늘 온 메일은 5통이에요."))
        #expect(answer.contains("\n- 14:20 가상상사 구매팀"))
        #expect(session.requestBlocker == nil)
        // 맥이 받은 말도 카드의 말 그대로다
        #expect(await agent.received.map(\.text) == ["오늘 온 메일 요약해줘"])
    }

    @Test func withoutAMailAccountTheBriefingSaysToConnectFirst() async throws {
        var mail = MockMail()
        mail.noAddresses = true
        let agent = MockAgentClient(v2: true, mail: mail, sites: MockSites(loggedIn: true), offersSkills: true)
        let card = try #require(try await agent.skills().first)
        #expect(card.blocker?.prompt == "네이버 메일 연결해줘")
        let session = await session(agent)
        await session.send(card.prompt, meetings: [meeting])
        #expect(session.messages.last?.text == "메일 계정이 아직 연결되지 않았어요. 먼저 연결해 주세요.")
    }

    @Test func nothingBlocksAFreshConversation() async {
        let session = await session(MockAgentClient())
        #expect(session.requestBlocker == nil)
        #expect(session.canSwitchConversation)
        await session.send("안녕", meetings: [meeting])
        #expect(session.requestBlocker == nil)
        // 답을 다 받았으면 다른 대화로 옮겨도 된다
        #expect(session.canSwitchConversation)
    }

    @Test func aPendingApprovalBlocksNewRequests() async {
        let session = await session(MockAgentClient())
        await session.send("할 일로 메일 초안 써줘", meetings: [meeting], engine: .local)
        #expect(session.hasPendingApproval)
        #expect(session.requestBlocker == "대화에 있는 승인 요청에 먼저 답해 주세요.")
    }

    @Test func anOpenQuestionBlocksNewRequests() async {
        // 맥이 되물었다 (고를 수 있는 선택지)
        let asked = await session(MockAgentClient())
        await asked.send("메일 초안 써줘", meetings: [meeting])
        #expect(!asked.pendingChoices.isEmpty)
        #expect(asked.requestBlocker == "대화에서 에이전트가 물어본 것에 먼저 답해 주세요.")

        // 작업 도중에 물었다 (v2)
        let working = await session(MockAgentClient(v2: true))
        await working.send("지난 회의 내용 팀에게 메일 초안 써줘. 참조도 넣어줘", meetings: [meeting])
        #expect(working.openQuestionTask != nil)
        #expect(working.requestBlocker == "대화에서 에이전트가 물어본 것에 먼저 답해 주세요.")
    }
}

@Suite("사이드바 글")
struct SidebarTextTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func dayIsRelativeForTodayAndYesterday() {
        let now = date(2026, 11, 12, 15, 30)
        #expect(SidebarText.day(date(2026, 11, 12, 0, 5), now: now, calendar: calendar) == "오늘")
        #expect(SidebarText.day(date(2026, 11, 11, 23, 59), now: now, calendar: calendar) == "어제")
        #expect(SidebarText.day(date(2026, 11, 10), now: now, calendar: calendar) == "11월 10일")
        #expect(SidebarText.day(date(2026, 1, 3), now: now, calendar: calendar) == "1월 3일")
        // 해가 다르면 해를 붙인다
        #expect(SidebarText.day(date(2025, 11, 10), now: now, calendar: calendar) == "2025년 11월 10일")
        // 달이 바뀌는 날의 어제
        #expect(SidebarText.day(date(2026, 10, 31), now: date(2026, 11, 1, 9), calendar: calendar) == "어제")
    }

    @Test func dayTimeAddsTheClock() {
        let now = date(2026, 11, 12, 15, 30)
        #expect(SidebarText.dayTime(date(2026, 11, 12, 9, 20), now: now, calendar: calendar) == "오늘 오전 9:20")
        #expect(SidebarText.dayTime(date(2026, 11, 11, 15, 42), now: now, calendar: calendar) == "어제 오후 3:42")
        #expect(SidebarText.dayTime(date(2026, 11, 10, 9, 5), now: now, calendar: calendar) == "11월 10일 오전 9:05")
    }

    @Test func subtitleMarksConversationsThatUsedTheMac() {
        let now = date(2026, 11, 12, 15, 30)
        #expect(SidebarText.subtitle(for: date(2026, 11, 12, 9), usesAgent: true, now: now, calendar: calendar) == "오늘 · 맥 에이전트")
        #expect(SidebarText.subtitle(for: date(2026, 11, 10), usesAgent: false, now: now, calendar: calendar) == "11월 10일")
    }
}

@MainActor
@Suite("에이전트 작업 목록")
struct AgentTaskEntryTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func record(_ role: String, task: String? = nil, phase: AgentTaskState.Phase = .done, at seconds: TimeInterval,
                        in conversation: Conversation) throws -> ChatRecord {
        let data = try task.map { try JSONEncoder().encode(AgentTaskState(id: "t-\($0)", task: $0, steps: ["입력 · 본문"], phase: phase)) }
        let record = ChatRecord(role: role, text: task ?? "말", agentData: data, createdAt: Date(timeIntervalSince1970: seconds))
        context.insert(record)
        record.conversation = conversation
        return record
    }

    @Test func collectsTasksNewestFirstWithTheirConversation() throws {
        let first = Conversation(title: "첫 대화")
        let second = Conversation(title: "둘째 대화")
        context.insert(first)
        context.insert(second)
        let old = try record("agent", task: "회의 공유 초안", at: 100, in: first)
        _ = try record("user", at: 150, in: first)
        _ = try record("assistant", at: 160, in: first)
        let new = try record("agent", task: "나에게 요약 메일", phase: .awaitingApproval, at: 300, in: second)
        let middle = try record("agent", task: "일정 확인", phase: .failed, at: 200, in: first)
        // 읽을 수 없는 작업 기록과, 작업 내용이 없는 줄은 뺀다
        let broken = ChatRecord(role: "agent", text: "깨짐", agentData: Data("{".utf8), createdAt: Date(timeIntervalSince1970: 400))
        let empty = ChatRecord(role: "agent", text: "없음", createdAt: Date(timeIntervalSince1970: 500))
        context.insert(broken)
        context.insert(empty)

        let records = try context.fetch(FetchDescriptor<ChatRecord>())
        let entries = AgentTaskEntry.entries(from: records)
        #expect(entries.map(\.id) == [new.id, middle.id, old.id])
        #expect(entries.map(\.state.task) == ["나에게 요약 메일", "일정 확인", "회의 공유 초안"])
        #expect(entries.map(\.state.phase) == [.awaitingApproval, .failed, .done])
        #expect(entries.map(\.conversation?.id) == [second.id, first.id, first.id])
        #expect(entries[0].date == Date(timeIntervalSince1970: 300))
        #expect(AgentTaskEntry.entries(from: []).isEmpty)
        // 끝났거나 내 답을 기다리는 일은 저장된 상태 그대로 보여 준다
        #expect(entries.map(\.isUnconfirmed) == [false, false, false])
        #expect(entries.map(\.statusLabel) == entries.map(\.state.statusLabel))
    }

    @Test func aTaskLastSeenRunningIsNotShownAsRunning() throws {
        let conversation = Conversation(title: "대화")
        context.insert(conversation)
        let running = try record("agent", task: "하던 일", phase: .running, at: 100, in: conversation)
        let sending = try record("agent", task: "보내던 일", phase: .sendPending, at: 200, in: conversation)
        let records = try context.fetch(FetchDescriptor<ChatRecord>())

        // 다른 대화를 보고 있으면 그 뒤를 모른다: "진행 중" 대신 열어서 확인하라고 한다
        let stale = AgentTaskEntry.entries(from: records)
        #expect(stale.map(\.id) == [sending.id, running.id])
        #expect(stale.map(\.isUnconfirmed) == [true, true])
        #expect(stale.map(\.statusLabel) == ["열어서 확인", "열어서 확인"])

        // 지금 열려 있는 대화의 일은 화면의 상태가 맞다 (저장된 것보다 새것)
        let done = AgentTaskState(id: "t-하던 일", task: "하던 일", steps: ["입력 · 본문", "마무리"], phase: .done)
        let live = AgentTaskEntry.entries(from: records, live: [running.id: done, sending.id: try #require(AgentTaskEntry.entries(from: records).first?.state)])
        #expect(live.map(\.isUnconfirmed) == [false, false])
        #expect(live[1].state.phase == .done)
        #expect(live[0].state.phase == .sendPending)
        #expect(live[0].statusLabel == live[0].state.statusLabel)
    }
}
