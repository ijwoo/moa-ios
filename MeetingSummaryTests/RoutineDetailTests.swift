import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import MeetingSummary

// 예약의 지침과 날짜별 기록, 알림의 결과 글, 승인·질문 카드의 화면 (D93). 모두 지어낸 것이다.

@Suite("예약 상세: 맥이 준 것 읽기")
struct RoutineDetailDecodingTests {
    @Test func notesAreReadAndMissingNotesAreEmpty() throws {
        let json = """
        {"routines":[
          {"id":"rt_a","title":"아침 브리핑","prompt":"메일 요약해줘","notes":"  - 보안 메일을 맨 위에\\n- 광고는 수만  ","enabled":true},
          {"id":"rt_b","title":"저녁 뉴스","prompt":"뉴스 알려줘","enabled":true},
          {"id":"rt_c","title":"꼴이 다른 지침","prompt":"x","notes":7,"enabled":true}
        ]}
        """
        let routines = try RoutineDecoding.routines(data: Data(json.utf8), status: 200)
        // 지침의 꼴이 다른 예약은 그것만 빠진다
        #expect(routines.map(\.id) == ["rt_a", "rt_b"])
        #expect(routines[0].notes == "- 보안 메일을 맨 위에\n- 광고는 수만")
        #expect(routines[1].notes.isEmpty)
    }

    @Test func aFinishedTaskLeavesItsResultInTheRun() throws {
        let json = """
        {"runs":[
          {"id":"rr_1","routine_id":"rt_a","title":"보내기","status":"task","ran_at":"2026-11-13T09:00:01+09:00","task_id":"T1",
           "task_status":"completed","task_result":["정리를 내 주소로 보냈어요.","",3]},
          {"id":"rr_2","routine_id":"rt_a","title":"보내기","status":"task","ran_at":"2026-11-12T09:00:01+09:00","task_id":"T0","task_status":"failed"}
        ]}
        """
        let runs = try RoutineDecoding.runs(data: Data(json.utf8), status: 200)
        #expect(runs[0].taskResult == ["정리를 내 주소로 보냈어요."])
        #expect(runs[0].statusText == "작업을 마쳤어요")
        #expect(runs[1].statusText == "작업을 끝내지 못했어요")
        // 작업이 끝나기 전에는 실행의 결과를 말한다
        #expect(RoutineRun(id: "rr_3", title: "x", status: "task").statusText == "작업으로 진행했어요")
    }

    @Test func oneRunIsReadAndAMissingOneIsNil() throws {
        let json = #"{"run":{"id":"rr_1","routine_id":"rt_a","title":"아침 브리핑","status":"done","replies":[{"text":"메일은 3통이에요."}]}}"#
        #expect(try RoutineDecoding.run(data: Data(json.utf8), status: 200)?.replies.first?.text == "메일은 3통이에요.")
        #expect(try RoutineDecoding.run(data: Data(#"{"error":{"code":"not_found"}}"#.utf8), status: 404) == nil)
        #expect(throws: AgentError.invalidResponse) { _ = try RoutineDecoding.run(data: Data("{}".utf8), status: 200) }
    }

    @Test func runsAreGroupedByDayNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12)))
        func at(_ day: Int, _ hour: Int, year: Int = 2026, month: Int = 11) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 30))
        }
        let runs = [
            RoutineRun(id: "rr_1", title: "x", status: "done", ranAt: at(16, 11)),
            RoutineRun(id: "rr_2", title: "x", status: "done", ranAt: at(16, 7)),
            RoutineRun(id: "rr_3", title: "x", status: "missed", ranAt: at(15, 7)),
            RoutineRun(id: "rr_4", title: "x", status: "done", ranAt: at(3, 7)),
            RoutineRun(id: "rr_5", title: "x", status: "done", ranAt: at(30, 7, year: 2025, month: 12)),
            RoutineRun(id: "rr_6", title: "x", status: "done"),
        ]
        let groups = RoutineRun.byDay(runs, now: now, calendar: calendar)
        #expect(groups.map(\.day) == ["오늘", "어제", "11월 3일", "2025년 12월 30일", "때를 알 수 없음"])
        #expect(groups[0].runs.map(\.id) == ["rr_1", "rr_2"])
        #expect(RoutineRun.timeText(try #require(at(16, 7)), calendar: calendar) == "오전 7:30")
    }
}

@MainActor
@Suite("예약 상세: 지침과 기록")
struct RoutineDetailModelTests {
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

    @Test func notesAreSavedOnTheMacAndCanBeCleared() async {
        let model = RoutinesModel(agent: MockAgentClient(v2: true, routines: .demo()))
        await model.load()
        #expect(model.routine(id: "rt_briefing")?.notes.contains("보안 관련 메일") == true)
        #expect(await model.setNotes("- 회의 초대를 먼저 말해 줘", id: "rt_news"))
        #expect(model.routine(id: "rt_news")?.notes == "- 회의 초대를 먼저 말해 줘")
        // 비우고 저장하면 지운다
        #expect(await model.setNotes("", id: "rt_news"))
        #expect(model.routine(id: "rt_news")?.notes.isEmpty == true)
    }

    @Test func notesTheMacDidNotTakeStayAsTheyWere() async {
        let agent = MockAgentClient(v2: true, routines: .demo())
        let model = RoutinesModel(agent: agent)
        await model.load()
        await agent.setReachable(false)
        #expect(await model.setNotes("바꾼 지침", id: "rt_briefing") == false)
        #expect(model.routine(id: "rt_briefing")?.notes.contains("보안 관련 메일") == true)
        #expect(model.notice == "맥에 연결되지 않아 지침을 저장하지 못했어요.")
    }

    @Test func historyHoldsOnlyThatRoutinesRuns() async {
        let model = RoutinesModel(agent: MockAgentClient(v2: true, routines: .demo()))
        await model.load()
        await model.loadHistory(id: "rt_briefing")
        #expect(model.history["rt_briefing"]?.map(\.id) == [MockRoutines.briefingRunID, "rr_demo_briefing_1", "rr_demo_briefing_2", "rr_demo_briefing_3"])
        await model.loadHistory(id: "rt_news")
        #expect(model.history["rt_news"]?.isEmpty == true)
        // 예약을 지우면 그 기록도 버린다 (맥도 지운다)
        await model.delete(id: "rt_briefing")
        #expect(model.history["rt_briefing"] == nil)
    }

    @Test func aRunWhoseTaskIsGoneShowsTheResultKeptInTheRecord() async throws {
        let agent = MockAgentClient(v2: true, routines: .demo())
        let session = await session(agent)
        await session.routines.load()
        await session.routines.loadHistory(id: "rt_weekly")
        let run = try #require(session.routines.history["rt_weekly"]?.first)
        // 작업은 맥에 없지만(다시 켜졌다) 기록에 남은 결과 글로 대화가 열린다
        #expect(await session.open(run) == .opened)
        #expect(session.messages.map(\.text) == ["지난 회의 내용 나한테 메일로 보내줘", "주간 회의 정리를 내 주소로 보냈어요."])
        #expect(session.messages.allSatisfy { $0.agent == nil })
    }

    @Test func aNotificationAsksForThatOneRun() async {
        let agent = MockAgentClient(v2: true, routines: .demo())
        let session = await session(agent)
        #expect(await session.openRoutineRun(id: "rr_demo_briefing_3") == .opened)
        #expect(await agent.runLookups == 1)
        #expect(session.messages.last?.text.contains("온 메일이 없어요") == true)
    }
}

@Suite("예약 알림: 결과의 앞부분을 띄운다")
struct RoutinePushTextTests {
    private let target = PushText.Target(taskID: "rr_abc12345", type: "routine_result", conversationID: "c_9")

    @Test func theRunIsAskedForInsteadOfATask() throws {
        let request = try #require(PushText.request(for: target, host: "mac.example.test", token: "virtual-token"))
        #expect(request.url?.absoluteString == "https://mac.example.test/v1/routines/runs/rr_abc12345")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-App-Token") == "virtual-token")
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test func theTitleIsTheRoutineAndTheBodyIsItsAnswer() {
        let json = #"{"run":{"id":"rr_abc12345","title":"아침 브리핑","status":"done","replies":[{"text":"메일은 **3통**이에요."},{"text":"날씨는 맑아요."},7]}}"#
        let text = PushText.decode(data: Data(json.utf8), status: 200, type: "routine_result")
        #expect(text?.title == "아침 브리핑")
        // 굵게 표시는 뗀다 (알림은 그리지 못한다)
        #expect(text?.body == "메일은 3통이에요.\n날씨는 맑아요.")
    }

    @Test func longAnswersAreCut() {
        let long = String(repeating: "가", count: 500)
        let json = #"{"run":{"title":"아침 브리핑","replies":[{"text":"\#(long)"}]}}"#
        let text = PushText.decode(data: Data(json.utf8), status: 200, type: "routine_result")
        #expect(text?.body.count == PushText.bodyLimit)
        #expect(text?.body.hasSuffix("…") == true)
    }

    @Test func aRunWithoutAnAnswerKeepsTheFixedSentence() {
        let none = #"{"run":{"id":"rr_abc12345","title":"주간 회의 정리","status":"task","task_id":"T1"}}"#
        #expect(PushText.decode(data: Data(none.utf8), status: 200, type: "routine_result") == nil)
        #expect(PushText.decode(data: Data(#"{"error":{"code":"not_found"}}"#.utf8), status: 404, type: "routine_result") == nil)
        #expect(PushText.decode(data: Data(#"{"body":"다른 꼴"}"#.utf8), status: 200, type: "routine_result") == nil)
        // 작업 알림은 전과 같이 읽는다
        #expect(PushText.decode(data: Data(#"{"type":"task_done","body":"마쳤어요."}"#.utf8), status: 200, type: "task_done")?.body == "마쳤어요.")
    }
}

@Suite("승인·질문 카드: 그때의 화면")
struct CardCaptureTests {
    private static let head = #""id":"S7gk2Lw0","task":"후기 고치기","title":"후기 고치기""#
    private static let capture = """
    {"id":"p1","type":"screenshot","mime":"image/jpeg","width":1280,"height":800,"bytes":120000,"page_host":"todo.test",\
    "caption":"'수정' 단추가 있는 화면","sensitive":true,"expires_at":"2099-01-01T00:00:00+00:00","path":"/v1/tasks/S7gk2Lw0/attachments/p1"}
    """

    private func decode(_ json: String) throws -> AgentTaskState {
        try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
    }

    @Test func anApprovalCardCarriesTheScreenItIsAbout() throws {
        let state = try decode("""
        {\(Self.head),"status":"awaiting_approval","approval":{"approval_id":"ap_1","action":"수정","kind":"action",\
        "url":"https://todo.test/list","sha256":"ab","fields":{"후기":"좋아요"},"attachment":\(Self.capture)}}
        """)
        let capture = try #require(state.draft?.attachment)
        #expect(capture.id == "p1")
        #expect(capture.pageHost == "todo.test")
        #expect(capture.caption == "'수정' 단추가 있는 화면")
        #expect(capture.isSensitive)
    }

    @Test func aQuestionCardCarriesItToo() throws {
        let state = try decode("""
        {\(Self.head),"status":"awaiting_input","question":{"question_id":"q_1","text":"어느 후기를 고칠까요?","choices":["첫째","둘째"],\
        "attachment":\(Self.capture)}}
        """)
        #expect(state.openQuestion?.attachment?.id == "p1")
    }

    @Test func aCardWithoutOneOrWithAnOddOneIsStillRead() throws {
        let plain = try decode("""
        {\(Self.head),"status":"awaiting_approval","approval":{"approval_id":"ap_1","action":"수정","kind":"action",\
        "url":"https://todo.test/list","sha256":"ab","fields":{"후기":"좋아요"}}}
        """)
        #expect(plain.draft != nil)
        #expect(plain.draft?.attachment == nil)
        // 꼴이 다르거나, 주소에 넣을 수 없는 번호이거나, 그림이 아닌 것은 없는 것으로 본다 — 카드는 그대로다
        for odd in ["7", #""글자""#, #"{"id":"../x","type":"screenshot","mime":"image/jpeg"}"#, #"{"id":"p1","type":"file","mime":"text/html"}"#] {
            let state = try decode("""
            {\(Self.head),"status":"awaiting_approval","approval":{"approval_id":"ap_1","action":"수정","kind":"action",\
            "url":"https://todo.test/list","sha256":"ab","fields":{"후기":"좋아요"},"attachment":\(odd)}}
            """)
            #expect(state.draft?.approvalID == "ap_1")
            #expect(state.draft?.attachment == nil)
        }
    }

    @Test func oldRecordsWithoutTheScreenStillOpen() throws {
        let old = #"{"approvalID":"ap_1","action":"수정","fields":[{"label":"후기","value":"좋아요"}],"revision":1}"#
        let draft = try JSONDecoder().decode(AgentDraft.self, from: Data(old.utf8))
        #expect(draft.attachment == nil)
        let question = try JSONDecoder().decode(AgentQuestion.self, from: Data(#"{"id":"q_1","text":"어느 것?","choices":[]}"#.utf8))
        #expect(question.attachment == nil)
    }

    @Test func theFakeMacGivesThePictureForTheCard() async throws {
        let draft = MockSiteDo.approval(id: "ap_1", revised: false)
        #expect(draft.attachment?.id == "p1")
        // 화면은 확인 번호에 들지 않는다: 승인한 내용(단추와 값)이 같으면 같은 번호다
        #expect(draft.sha256 == draft.shownSHA256)
    }
}
