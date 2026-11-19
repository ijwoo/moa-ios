import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 예약해 둔 일 (D91). 예약도 결과도 모두 지어낸 것이다.

@Suite("예약: 맥이 준 것 읽기")
struct RoutineDecodingTests {
    private static let list = """
    {"routines":[
      {"id":"rt_a","title":"아침 브리핑","prompt":"오늘 온 메일 요약해줘","enabled":true,"schedule":{"kind":"daily","times":["07:30"]},
       "when_text":"매일 오전 7:30","next_run_at":"2026-11-17T07:30:00+09:00","last_run_at":null,"last_status":null,"done":false},
      {"id":"rt_b","title":"","prompt":"준비물 알려줘","enabled":true,"schedule":{"kind":"once","at":"2026-12-05T10:00"},
       "when_text":"12월 5일 오전 10:00","next_run_at":null,"last_run_at":"2026-12-05T10:00:03+09:00","last_status":"done","done":true},
      {"id":"../etc","title":"나쁜 번호","prompt":"x","enabled":true},
      {"title":"번호 없음"},
      "글자"
    ]}
    """

    @Test func routinesAreReadAndBadOnesAreDroppedOneByOne() throws {
        let routines = try RoutineDecoding.routines(data: Data(Self.list.utf8), status: 200)
        // 주소에 넣을 수 없는 번호, 번호가 없는 것, 꼴이 다른 것만 빠진다
        #expect(routines.map(\.id) == ["rt_a", "rt_b"])
        #expect(routines[0].title == "아침 브리핑")
        #expect(routines[0].whenText == "매일 오전 7:30")
        #expect(routines[0].nextRunAt != nil)
        #expect(routines[0].group == .repeating)
        // 이름이 비면 건넬 말이 이름이 된다
        #expect(routines[1].title == "준비물 알려줘")
        #expect(routines[1].group == .once)
        #expect(routines[1].done)
        #expect(!routines[1].canToggle)
    }

    @Test func errorsAreErrors() {
        let refused = Data(#"{"error":{"code":"too_many","message":"20개까지"}}"#.utf8)
        #expect(throws: AgentError.self) { _ = try RoutineDecoding.routines(data: refused, status: 409) }
        #expect(throws: AgentError.invalidResponse) { _ = try RoutineDecoding.routines(data: Data("{}".utf8), status: 200) }
    }

    @Test func runsCarryTheRepliesAndWhereToContinue() throws {
        let json = """
        {"runs":[
          {"id":"rr_1","routine_id":"rt_a","title":"아침 브리핑","status":"done","due_at":"2026-11-16T07:30:00+09:00",
           "ran_at":"2026-11-16T07:30:04+09:00","conversation_id":"c_abc","replies":[{"text":"메일은 3통이에요.","by":"claude"},{"text":""},7]},
          {"id":"rr_2","routine_id":"rt_b","title":"보내기","status":"task","ran_at":"2026-11-16T09:00:01+09:00","conversation_id":"c_def","task_id":"T1"},
          {"id":"rr_3","routine_id":"rt_a","title":"아침 브리핑","status":"missed","ran_at":"2026-11-15T09:10:00+09:00"}
        ]}
        """
        let runs = try RoutineDecoding.runs(data: Data(json.utf8), status: 200)
        #expect(runs.map(\.id) == ["rr_1", "rr_2", "rr_3"])
        // 빈 말과 꼴이 다른 말풍선은 빠진다
        #expect(runs[0].replies == [RoutineRun.Bubble(text: "메일은 3통이에요.", writer: .claude)])
        #expect(runs[0].conversationID == "c_abc")
        #expect(runs[0].canOpen)
        #expect(runs[1].taskID == "T1")
        #expect(runs[1].canOpen)
        // 놓친 실행에는 열어 볼 것이 없다
        #expect(!runs[2].canOpen)
    }

    @Test func aReplyMayCarryTheChangedList() throws {
        let with = """
        {"conversation_id":"c1","replies":[{"text":"네, 매일 오전 8:00에 해 둘게요."}],"action":{"type":"none"},
         "routines":[{"id":"rt_a","title":"메일 요약","prompt":"메일 요약해줘","enabled":true,"schedule":{"kind":"daily"},"when_text":"매일 오전 8:00"}]}
        """
        let reply = try AgentHTTPClient.decodeReply(data: Data(with.utf8), status: 200)
        #expect(reply.replies == ["네, 매일 오전 8:00에 해 둘게요."])
        #expect(reply.routines?.map(\.id) == ["rt_a"])
        // 붙어 오지 않으면 nil, 꼴이 어긋나도 답은 그대로 읽는다
        let without = #"{"conversation_id":"c1","replies":[{"text":"안녕하세요."}],"action":{"type":"none"}}"#
        #expect(try AgentHTTPClient.decodeReply(data: Data(without.utf8), status: 200).routines == nil)
        let odd = #"{"conversation_id":"c1","replies":[{"text":"안녕하세요."}],"action":{"type":"none"},"routines":"없음"}"#
        let read = try AgentHTTPClient.decodeReply(data: Data(odd.utf8), status: 200)
        #expect(read.replies == ["안녕하세요."])
        #expect(read.routines == nil)
    }
}

@Suite("예약: 화면에 쓰는 글")
struct RoutineTextTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func routine(enabled: Bool = true, kind: String = "daily", next: Date? = nil, status: String? = nil, done: Bool = false) -> AgentRoutine {
        AgentRoutine(id: "rt", title: "아침 브리핑", prompt: "메일 요약해줘", enabled: enabled, kind: kind, whenText: "매일 오전 7:30", nextRunAt: next, lastStatus: status, done: done)
    }

    @Test func groupsFollowTheReferenceOrder() {
        let all = [
            routine(enabled: false), routine(kind: "once"), routine(kind: "weekly"), routine(kind: "daily"),
            // 꺼 둔 한 번짜리도 일시 중지다. 모르는 종류는 반복으로 본다
            routine(enabled: false, kind: "once"), routine(kind: "monthly"),
        ]
        let grouped = AgentRoutine.grouped(all)
        #expect(grouped.map(\.group) == [.repeating, .once, .paused])
        #expect(grouped.map(\.routines.count) == [3, 1, 2])
        // 빈 묶음은 빠진다
        #expect(AgentRoutine.grouped([routine(kind: "once")]).map(\.group) == [.once])
    }

    @Test func theSmallLineSaysWhenItRunsNextOrHowItWent() {
        let now = date(16, 15, 0)
        #expect(routine(next: date(16, 18, 0)).detail(now: now, calendar: calendar) == "다음 오늘 오후 6:00")
        #expect(routine(next: date(17, 7, 30)).detail(now: now, calendar: calendar) == "다음 내일 오전 7:30")
        #expect(routine(next: date(20, 9, 0)).detail(now: now, calendar: calendar) == "다음 11월 20일 오전 9:00")
        // 꺼 둔 것은 지난번 결과를, 없으면 아무것도
        #expect(routine(enabled: false, status: "missed").detail(now: now, calendar: calendar) == "지난번: 맥이 꺼져 있어 놓쳤어요")
        #expect(routine(enabled: false).detail(now: now, calendar: calendar) == nil)
        #expect(routine(kind: "once", status: "done", done: true).detail(now: now, calendar: calendar) == "끝났어요 · 답이 왔어요")
        // 모르는 결과 값은 지어내지 않는다
        #expect(AgentRoutine.statusText("새값") == nil)
    }
}

@MainActor
@Suite("예약: 목록")
struct RoutinesModelTests {
    @Test func theScreenIsOfferedOnlyByAMacThatKnowsRoutines() async {
        let with = RoutinesModel(agent: MockAgentClient(v2: true, routines: .demo()))
        await with.load()
        #expect(with.isOffered)
        #expect(with.routines.count == 4)
        #expect(with.runs.count == 5)

        let agent = MockAgentClient(v2: true)
        let without = RoutinesModel(agent: agent)
        await without.load()
        #expect(!without.isOffered)
        #expect(without.routines.isEmpty)
        // 모르는 맥에는 묻지도 않는다
        #expect(await agent.routineListCalls == 0)
    }

    @Test func turningOffMovesItToPausedAndDeletingRemovesIt() async {
        let model = RoutinesModel(agent: MockAgentClient(v2: true, routines: .demo()))
        await model.load()
        await model.setEnabled(false, id: "rt_briefing")
        #expect(model.routine(id: "rt_briefing")?.group == .paused)
        await model.setEnabled(true, id: "rt_news")
        #expect(model.routine(id: "rt_news")?.group == .repeating)
        await model.delete(id: "rt_workshop")
        #expect(model.routine(id: "rt_workshop") == nil)
        #expect(model.notice == nil)
    }

    @Test func aChangeTheMacDidNotTakeLeavesTheListAsItWas() async {
        let agent = MockAgentClient(v2: true, routines: .demo())
        let model = RoutinesModel(agent: agent)
        await model.load()
        await agent.setReachable(false)
        await model.setEnabled(false, id: "rt_briefing")
        // 맥이 받아들이지 않았으면 켜진 채다
        #expect(model.routine(id: "rt_briefing")?.enabled == true)
        #expect(model.notice == "맥에 연결되지 않아 끄지 못했어요.")
        await model.delete(id: "rt_briefing")
        #expect(model.routine(id: "rt_briefing") != nil)
    }
}

@MainActor
@Suite("예약: 대화")
struct RoutineChatTests {
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

    @Test func thePlusButtonStartsAConversationAndTheNewRoutineShowsUp() async {
        let session = await session(MockAgentClient(v2: true, routines: MockRoutines()))
        await session.send(RoutinesModel.newPrompt, meetings: [])
        #expect(session.messages.last?.text == "어떤 걸 예약해 둘까요? 할 일이랑 날짜나 주기만 알려 주세요.")
        #expect(session.routines.routines.isEmpty)
        await session.send("매일 아침 8시에 메일 요약해줘", meetings: [])
        // 응답에 붙어 온 바뀐 뒤의 목록으로 예약 화면이 따라온다 (따로 다시 묻지 않는다)
        #expect(session.routines.routines.map(\.whenText) == ["매일 오전 8:00"])
        #expect(session.routines.isOffered)
    }

    @Test func aRunOpensAsAConversationThatCanGoOn() async throws {
        let agent = MockAgentClient(v2: true, routines: .demo())
        let session = await session(agent)
        await session.routines.load()
        await session.send("안녕", meetings: [])

        #expect(await session.openRoutineRun(id: MockRoutines.briefingRunID) == .opened)
        // 그때 맥이 내 말로 건넨 것과 받은 답이 그대로 온다
        #expect(session.messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(session.messages.first?.text == "오늘 온 메일이랑 날씨 요약해줘")
        #expect(session.messages.last?.text.hasPrefix("날씨는 맑고") == true)
        #expect(session.agentConversationID == "conv-routine-1")
        // 이어서 말하면 그 대화 번호로 간다
        await session.send("안녕", meetings: [])
        #expect(await agent.received.last?.conversationID == "conv-routine-1")

        // 다시 열어도 같은 답이 두 번 생기지 않는다: 이 기기에 남은 그 대화로 간다
        session.reset()
        #expect(await session.openRoutineRun(id: MockRoutines.briefingRunID) == .opened)
        #expect(session.messages.filter { $0.text.hasPrefix("날씨는 맑고") }.count == 1)
        let stored = try context.fetch(FetchDescriptor<Conversation>()).filter { $0.agentConversationID == "conv-routine-1" }
        #expect(stored.count == 1)
    }

    @Test func aPushedTaskFromAConversationNotOnThisPhoneOpensWithItsCard() async throws {
        // 맥이 직접 만든 대화의 작업 (D112): 예약 실행도 아니다. 작업을 받아 새 대화에 놓는다
        let agent = MockAgentClient(v2: true, routines: .demo())
        let session = await session(agent)
        let started = try await agent.start(task: "가상 보고서 만들어줘", context: nil)
        #expect(await session.openRoutineRun(taskID: started.id) == .notFound)
        #expect(await session.openTask(id: started.id, conversationID: "conv-mac-1") == .opened)
        #expect(session.messages.first?.role == .user)
        #expect(session.messages.first?.text == "가상 보고서 만들어줘")
        #expect(session.messages.contains { $0.agent?.id == started.id })
        #expect(session.agentConversationID == "conv-mac-1")
        // 맥에 없는 작업이면 대화를 만들지 않는다
        session.reset()
        #expect(await session.openTask(id: "task-none", conversationID: nil) == .notFound)
        #expect(session.messages.isEmpty)
    }

    @Test func aRunTheMacForgotOrThatHasNothingSaysSo() async {
        let agent = MockAgentClient(v2: true, routines: .demo())
        let session = await session(agent)
        #expect(await session.openRoutineRun(id: "rr_gone") == .notFound)
        await agent.addRun(RoutineRun(id: "rr_missed", routineID: "rt_news", title: "저녁 뉴스", status: "missed"))
        #expect(await session.openRoutineRun(id: "rr_missed") == .nothingToShow)
        // 아무 대화도 만들지 않았다
        #expect(session.messages.isEmpty)
        await agent.setReachable(false)
        #expect(await session.openRoutineRun(id: MockRoutines.briefingRunID) == .unreachable)
        #expect(AskSession.RoutineOpening.notFound.notice?.contains("맥에 남아 있지 않아요") == true)
        #expect(AskSession.RoutineOpening.opened.notice == nil)
    }

    @Test func aRunThatBecameATaskOpensWithItsCard() async throws {
        let agent = MockAgentClient(v2: true, routines: .demo())
        let session = await session(agent)
        // 맥에서 예약이 돌며 생긴 작업 (이 기기의 대화에는 없다)
        let task = try await agent.start(task: "가상 작업", context: nil)
        await agent.addRun(RoutineRun(
            id: "rr_task", routineID: "rt_weekly", title: "주간 회의 정리", status: "task", conversationID: "conv-routine-2", taskID: task.id
        ))
        await session.routines.load()
        // 그 작업의 알림에는 작업 번호가 온다
        #expect(await session.openRoutineRun(taskID: task.id) == .opened)
        #expect(session.messages.first?.text == "지난 회의 내용 나한테 메일로 보내줘")
        #expect(session.messages.contains { $0.agent?.id == task.id })
        #expect(session.agentConversationID == "conv-routine-2")
        #expect(await session.openRoutineRun(taskID: "없는 작업") == .notFound)
    }
}
