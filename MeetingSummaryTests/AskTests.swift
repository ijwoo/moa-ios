import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

private typealias Source = AskContextBuilder.Source

private func source(_ title: String, daysAgo: Double, lines: [String], summary: String? = nil) -> Source {
    Source(
        id: UUID(), title: title, date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
        topic: summary, summary: summary,
        lines: lines.enumerated().map { .init(id: UUID(), start: Double($0.offset) * 5, text: $0.element) }
    )
}

struct AskContextBuilderTests {
    @Test func keywordsDropParticlesAndQuestionWords() {
        #expect(AskContextBuilder.keywords(from: "디자인 최종본은 누가 언제까지 전달하기로 했지?") == ["디자인", "최종본", "전달하기"]) // 조사 "로"를 뗀 형태로도 원문에 포함된다
        #expect(AskContextBuilder.keywords(from: "지난 회의에서 결제 방식은?") == ["결제", "방식"])
        #expect(AskContextBuilder.keywords(from: "PG를 쓸지") == ["pg", "쓸지"])
    }

    @Test func picksMatchingMeetingsAndListsTheRest() {
        let launch = source("출시 점검", daysAgo: 3, lines: ["결제는 외부 PG를 쓸지 정하지 못했습니다."])
        let review = source("1:1 면담", daysAgo: 1, lines: ["이번 분기 평가 얘기를 했습니다."])
        let context = AskContextBuilder.build(question: "결제 방식 정했어?", history: [], sources: [review, launch])

        #expect(context.request.meetings.map(\.title) == ["출시 점검"])
        #expect(context.request.otherMeetings.map(\.title) == ["1:1 면담"])
        let ref = try! #require(context.request.meetings.first?.utterances.first?.ref)
        #expect(ref == "m1-u1")
        #expect(context.references[ref]?.meetingID == launch.id)
        #expect(context.references[ref]?.utteranceID == launch.lines[0].id)
    }

    @Test func noMatchFallsBackToRecentMeetings() {
        let old = source("예전 회의", daysAgo: 30, lines: ["오래된 이야기"])
        let recent = source("최근 회의", daysAgo: 1, lines: ["최근 이야기"])
        let context = AskContextBuilder.build(question: "정리해줘", history: [], sources: [old, recent])
        #expect(context.request.meetings.map(\.title) == ["최근 회의", "예전 회의"])
    }

    @Test func budgetLimitsIncludedMeetings() {
        // 각 300자: 첫 회의를 담고 나면 남은 한도(100자)가 너무 작아 두 번째는 목록으로만 보낸다
        let a = source("A 결제", daysAgo: 1, lines: [String(repeating: "결제 ", count: 100)])
        let b = source("B 결제", daysAgo: 2, lines: [String(repeating: "결제 ", count: 100)])
        let context = AskContextBuilder.build(question: "결제", history: [], sources: [a, b], budget: 400)
        #expect(context.request.meetings.count == 1)
        #expect(context.request.otherMeetings.count == 1)
    }

    @Test func longMeetingSendsMatchingLinesWithNeighbours() {
        var lines = (0..<40).map { "잡담 \($0) " + String(repeating: "가", count: 30) }
        lines[20] = "법무 검토는 출시 전에 반드시 받아야 합니다."
        let meeting = source("긴 회의", daysAgo: 1, lines: lines)
        let context = AskContextBuilder.build(question: "법무 검토 언제?", history: [], sources: [meeting], budget: 300)
        let refs = context.request.meetings.first?.utterances.map(\.ref) ?? []
        // 원래 번호를 유지한다 (u21이 해당 줄)
        #expect(refs.contains("m1-u21"))
        #expect(refs.first == "m1-u19")
        #expect(context.references["m1-u21"]?.text.hasPrefix("법무 검토") == true)
    }

    // MARK: 회의한 날을 가리키는 말 (D44)

    /// `source(daysAgo:)`의 기준 시각 = 2027년 1월 15일 (금) 오후 5시 (서울)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let seoul: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    private func reference(_ text: String) -> AskContextBuilder.DayReference? {
        AskContextBuilder.dayReference(in: text, now: Self.now, calendar: Self.seoul)
    }

    @Test func dayWordsRightBeforeAMeetingWordAreRead() throws {
        #expect(reference("오늘 회의 내용 요약좀해서 나한테 메일로 보내줘")?.label == "오늘(1월 15일)")
        #expect(reference("오늘회의 요약해줘")?.label == "오늘(1월 15일)")
        #expect(reference("오늘 오전 회의에서 뭐 정했지?")?.label == "오늘(1월 15일)")
        #expect(reference("어제 한 주간 회의 정리해줘")?.label == "어제(1월 14일)")
        #expect(reference("그저께 미팅 결정 사항 알려줘")?.label == "그저께(1월 13일)")
        #expect(reference("1월 13일 회의 요약")?.label == "1월 13일")
        #expect(reference("이번 주 회의 정리해줘")?.label == "이번 주(1월 11일~1월 17일)")
        #expect(reference("지난주 회의에서 정한 것")?.label == "지난주(1월 4일~1월 10일)")

        // 오늘보다 뒤의 날짜는 지난해로 본다. 없는 날짜는 읽지 않는다
        let lastYear = try #require(reference("12월 3일 회의 요약해줘"))
        #expect(Self.seoul.component(.year, from: lastYear.interval.start) == 2026)
        #expect(reference("2월 30일 회의") == nil)

        // 하루는 그 날 0시부터 다음 날 0시 전까지
        let today = try #require(reference("오늘 회의"))
        #expect(today.interval.contains(Self.now))
        #expect(!today.interval.contains(Self.now.addingTimeInterval(-86_400)))
    }

    @Test func dayWithoutAMonthIsTheLatestSuchDay() throws {
        // 기준: 1월 15일. 이번 달에 이미 지난 날이면 이번 달, 아직 오지 않은 날이면 지난달
        #expect(reference("10일 회의로 보내 줘")?.label == "1월 10일")
        #expect(reference("그럼 15일자 회의 내용으로")?.label == "1월 15일")
        let lastMonth = try #require(reference("20일 회의로 보내 줘"))
        #expect(lastMonth.label == "12월 20일")
        #expect(Self.seoul.component(.year, from: lastMonth.interval.start) == 2026)
        // 달을 말했으면 그 달을 따른다 (없는 날짜를 다른 달로 바꿔 읽지 않는다)
        #expect(reference("1월 13일 회의 요약")?.label == "1월 13일")
        #expect(reference("2월 30일 회의") == nil)
        // 날짜가 아닌 말
        #expect(reference("3일 동안 회의만 했어") == nil)
        #expect(reference("110일 회의") == nil)
        #expect(reference("32일 회의") == nil)
        #expect(reference("0일 회의") == nil)
        #expect(reference("10일까지 회의록 보내기로 했지?") == nil)
    }

    @Test func dayWordsAboutSomethingElseAreNotRead() {
        // 회의한 날이 아니라 기한·할 일을 말하는 "오늘"
        #expect(reference("오늘까지 할 일 뭐였지?") == nil)
        #expect(reference("오늘까지 회의록 보내기로 했지?") == nil)
        #expect(reference("오늘 할 일 회의에서 뭐라고 했지?") == nil)
        #expect(reference("출시일이 12월 3일로 정해졌어?") == nil)
        #expect(reference("회의 요약해줘") == nil)
        // 날짜 말은 내용 찾기 낱말로 쓰지 않는다
        #expect(AskContextBuilder.keywords(from: "오늘은 뭐 하기로 했지") == ["하기"])
    }

    @Test func todaysMeetingIsChosenOverAnOlderOneThatSaysTodayMoreOften() {
        // 실기기 사례: "오늘 회의"라고 했는데, 내용에 "오늘"·"메일"이 많이 나오는 이틀 전 회의가 뽑혔다
        let old = source("주간 회의", daysAgo: 2, lines: ["오늘 회의에서는 출시 일정을 정합니다.", "오늘 안에 요약을 메일로 보내 주세요."])
        let today = source("준비 회의", daysAgo: 0, lines: ["시나리오 준비는 각자 맡기로 했습니다."])
        let context = AskContextBuilder.build(
            question: "오늘 회의 내용 요약해서 나한테 메일로 보내줘", history: [], sources: [old, today],
            now: Self.now, calendar: Self.seoul
        )
        #expect(context.request.meetings.map(\.title) == ["준비 회의"])
        #expect(context.request.otherMeetings.map(\.title) == ["주간 회의"])
        #expect(context.request.today == "1월 15일 (금)")
        #expect(context.request.day == .init(label: "오늘(1월 15일)", found: true))
        #expect(context.references["m1-u1"]?.meetingID == today.id)
    }

    @Test func noMeetingOnThatDayIsSaidInsteadOfSilentlyUsingAnotherDay() {
        let old = source("주간 회의", daysAgo: 2, lines: ["오늘 회의에서는 출시 일정을 정합니다."])
        let older = source("면담", daysAgo: 9, lines: ["평가 이야기를 했습니다."])
        let context = AskContextBuilder.build(
            question: "오늘 회의 내용 요약해줘", history: [], sources: [older, old], now: Self.now, calendar: Self.seoul
        )
        // 고르는 방식은 평소대로(최근 회의부터)이고, 그 날 회의가 없다는 사실을 함께 보낸다
        #expect(context.request.meetings.map(\.title) == ["주간 회의", "면담"])
        #expect(context.request.day == .init(label: "오늘(1월 15일)", found: false))
    }

    @Test func questionWithoutADayKeepsTheOldSelection() {
        let launch = source("출시 점검", daysAgo: 3, lines: ["결제는 외부 PG를 쓸지 정하지 못했습니다."])
        let today = source("1:1 면담", daysAgo: 0, lines: ["이번 분기 평가 얘기를 했습니다."])
        let context = AskContextBuilder.build(
            question: "결제 방식 정했어?", history: [], sources: [today, launch], now: Self.now, calendar: Self.seoul
        )
        #expect(context.request.meetings.map(\.title) == ["출시 점검"])
        #expect(context.request.day == nil)
        #expect(context.request.today == "1월 15일 (금)")
    }

    @Test func dayCanComeFromTheFirstRequestWhenTheMacAskedBack() {
        let old = source("주간 회의", daysAgo: 2, lines: ["나에게만 보내도 됩니다."])
        let today = source("준비 회의", daysAgo: 0, lines: ["시나리오 준비는 각자 맡기로 했습니다."])
        let context = AskContextBuilder.build(
            question: "나에게만", history: [], sources: [old, today],
            dayText: "오늘 회의 메일 초안 써줘\n나에게만", now: Self.now, calendar: Self.seoul
        )
        #expect(context.request.meetings.map(\.title) == ["준비 회의"])
    }

    @Test func requestCarriesTodayAndTheAskedDay() throws {
        var request = AskRequest(question: "q", history: [], meetings: [], otherMeetings: [])
        #expect(!String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains("today"))
        request.today = "1월 15일 (금)"
        request.day = .init(label: "오늘(1월 15일)", found: false)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(json.contains(#""today":"1월 15일 (금)""#))
        #expect(json.contains(#""found":false"#))
    }

    @Test func legacyTranscriptHasNoUtteranceID() {
        let legacy = Source(id: UUID(), title: "예전", date: .now, topic: nil, summary: nil,
                            lines: [.init(id: nil, start: 0, text: "구간 방식 원문")])
        let context = AskContextBuilder.build(question: "원문", history: [], sources: [legacy])
        #expect(context.references["m1-u1"]?.utteranceID == nil)
        #expect(context.references["m1-u1"]?.start == nil)
    }
}

final class FakeAskProvider: AskProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<AskAnswerDTO, SummaryAPIError>]
    private(set) var requests: [AskRequest] = []

    init(_ results: [Result<AskAnswerDTO, SummaryAPIError>]) { self.results = results }

    func ask(_ request: AskRequest) async throws -> AskAnswerDTO {
        try lock.withLock {
            requests.append(request)
            return try results.removeFirst().get()
        }
    }
}

@MainActor
struct AskSessionTests {
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
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
        meeting.appendUtterance(Utterance(start: 16, end: 20, text: "디자인 최종본은 김지원 님이 금요일까지 전달합니다."))
    }

    @Test func answerResolvesCitationsAndIgnoresUnknownRefs() async {
        let provider = FakeAskProvider([.success(.init(answer: "김지원 님이 금요일까지 전달합니다.", found: true, citations: ["m1-u2", "m3-u9"]))])
        let session = AskSession(provider: provider, agent: nil)
        await session.send("디자인 최종본은 누가?", meetings: [meeting])

        #expect(session.messages.map(\.role) == [.user, .assistant])
        let citations = session.messages[1].citations
        #expect(citations.count == 1)
        #expect(citations[0].meetingTitle == "주간 회의")
        #expect(citations[0].utteranceID == meeting.sortedUtterances[1].id)
        #expect(citations[0].start == 16)
    }

    @Test func historyIsSentWithFollowUp() async {
        let provider = FakeAskProvider([
            .success(.init(answer: "12월 3일입니다.", found: true, citations: ["m1-u1"])),
            .success(.init(answer: "김지원 님입니다.", found: true, citations: ["m1-u2"])),
        ])
        let session = AskSession(provider: provider, agent: nil)
        await session.send("출시일은?", meetings: [meeting])
        await session.send("디자인은 누가 해?", meetings: [meeting])
        let second = provider.requests[1]
        #expect(second.history == [.init(role: .user, text: "출시일은?"), .init(role: .assistant, text: "12월 3일입니다.")])
        #expect(second.question == "디자인은 누가 해?")
    }

    @Test func formatErrorRetriedOnceThenErrorMessageWithRetry() async {
        let provider = FakeAskProvider([.failure(.invalidResponse), .failure(.invalidResponse), .success(.init(answer: "답", found: true, citations: []))])
        let session = AskSession(provider: provider, agent: nil)
        await session.send("출시일은?", meetings: [meeting])
        #expect(provider.requests.count == 2)
        #expect(session.messages.last?.role == .error)
        #expect(session.messages.last?.retryQuestion == "출시일은?")

        // 다시 시도: 오류 메시지는 지워지고 질문이 중복되지 않는다
        await session.send("출시일은?", meetings: [meeting])
        #expect(session.messages.map(\.role) == [.user, .assistant])
    }

    @Test func noMeetingsAnswersWithoutCallingServer() async {
        let provider = FakeAskProvider([])
        let session = AskSession(provider: provider, agent: nil)
        await session.send("출시일은?", meetings: [])
        #expect(provider.requests.isEmpty)
        #expect(session.messages.last?.found == false)
    }

    @Test func decodeAnswerEnvelope() throws {
        let json = #"{"answer":{"answer":"답","found":true,"citations":["m1-u1"]}}"#
        #expect(try SummaryAPI.decodeAnswer(data: Data(json.utf8), status: 200) == .init(answer: "답", found: true, citations: ["m1-u1"]))
        #expect(throws: SummaryAPIError.server(code: "rate_limited", message: "많음", retryable: true)) {
            try SummaryAPI.decodeAnswer(data: Data(#"{"error":{"code":"rate_limited","message":"많음","retryable":true}}"#.utf8), status: 429)
        }
    }

    @Test func requestEncodesSnakeCase() throws {
        let request = AskRequest(question: "q", history: [], meetings: [], otherMeetings: [.init(ref: "m1", title: "t", date: "d", topic: nil)])
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(json.contains("\"other_meetings\""))
    }

    @Test func conversationIsSavedAndRestoredAfterRelaunch() async throws {
        let provider = FakeAskProvider([.success(.init(answer: "김지원 님이 금요일까지 전달합니다.", found: true, citations: ["m1-u2"]))])
        let session = AskSession(provider: provider, agent: nil)
        session.attach(context)
        await session.send("디자인 최종본은 누가?", meetings: [meeting])
        try context.save()

        // 앱을 다시 연 것처럼 새 세션을 붙인다
        let reopened = AskSession(provider: provider, agent: nil)
        reopened.attach(context)
        #expect(reopened.messages.map(\.role) == [.user, .assistant])
        #expect(reopened.messages[1].citations.first?.utteranceID == meeting.sortedUtterances[1].id)
        #expect(reopened.conversation?.title == "디자인 최종본은 누가?")
    }

    @Test func newChatKeepsHistoryAndDeleteRemoves() async throws {
        let provider = FakeAskProvider([
            .success(.init(answer: "첫 답", found: true, citations: [])),
            .success(.init(answer: "두 번째 답", found: true, citations: [])),
        ])
        let session = AskSession(provider: provider, agent: nil)
        session.attach(context)
        await session.send("첫 질문", meetings: [meeting])
        let first = try #require(session.conversation)
        session.reset()
        #expect(session.messages.isEmpty)
        await session.send("두 번째 질문", meetings: [meeting])
        #expect(try context.fetchCount(FetchDescriptor<Conversation>()) == 2)
        // 새 대화는 이전 대화 기록을 보내지 않는다
        #expect(provider.requests[1].history.isEmpty)

        session.open(first)
        #expect(session.messages.first?.text == "첫 질문")
        session.delete(first)
        #expect(session.messages.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Conversation>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ChatRecord>()) == 2)
    }

    @Test("긴 대화를 열면 최근 것만 그리고, 달라고 하면 이전 말을 더 그린다 (D69)")
    func longConversationShowsLatestPage() async throws {
        let turns = 40
        let answers = (1...turns).map { Result<AskAnswerDTO, SummaryAPIError>.success(.init(answer: "답 \($0)", found: true, citations: [])) }
        let session = AskSession(provider: FakeAskProvider(answers), agent: nil)
        session.attach(context)
        for turn in 1...turns { await session.send("질문 \(turn)", meetings: [meeting]) }
        // 주고받는 동안 온 말은 모두 그린다
        #expect(session.messages.count == 80)
        #expect(session.earlierCount == 0)

        // 다시 열면 최근 60개만 그린다
        let reopened = AskSession(provider: FakeAskProvider([.success(.init(answer: "새 답", found: true, citations: []))]), agent: nil)
        reopened.attach(context)
        #expect(reopened.messages.count == 80)
        #expect(reopened.earlierCount == 20)
        // 새로 오는 말은 언제나 그린다 (가려 둔 수는 그대로다)
        await reopened.send("새 질문", meetings: [meeting])
        #expect(reopened.messages.count == 82)
        #expect(reopened.earlierCount == 20)

        // 이미 그린 말이나 모르는 말로는 범위가 바뀌지 않는다
        #expect(!reopened.reveal(reopened.messages[20].id))
        #expect(!reopened.reveal(UUID()))
        #expect(reopened.earlierCount == 20)
        // 가려 둔 말로 가면 그 말과 앞의 몇 마디까지 그린다
        #expect(reopened.reveal(reopened.messages[15].id))
        #expect(reopened.earlierCount == 5)
        #expect(reopened.reveal(reopened.messages[3].id))
        #expect(reopened.earlierCount == 0)

        // "이전 대화 보기"는 한 묶음씩 더 그린다
        let conversation = try #require(reopened.conversation)
        reopened.open(conversation)
        #expect(reopened.earlierCount == 22)
        reopened.showEarlier()
        #expect(reopened.earlierCount == 0)
        // 새 대화에는 가려 둔 말이 없다
        reopened.open(conversation)
        reopened.reset()
        #expect(reopened.earlierCount == 0)
    }

    @Test func errorsAreNotSaved() async throws {
        let provider = FakeAskProvider([.failure(.offline)])
        let session = AskSession(provider: provider, agent: nil)
        session.attach(context)
        await session.send("질문", meetings: [meeting])
        #expect(session.messages.last?.role == .error)
        #expect(try context.fetchCount(FetchDescriptor<ChatRecord>()) == 1) // 질문만
    }
}

@MainActor
struct AgentSessionTests {
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
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
    }

    private func session(cloud: FakeAskProvider = FakeAskProvider([]), reachable: Bool = true) -> AskSession {
        let session = AskSession(provider: cloud, agent: MockAgentClient(reachable: reachable), pollInterval: .zero)
        session.attach(context)
        return session
    }

    @Test func agentRunsUntilApprovalAndBlocksNewQuestions() async {
        let cloud = FakeAskProvider([])
        let session = session(cloud: cloud)
        await session.send("할 일로 메일 초안 써줘", meetings: [meeting], engine: .local)

        #expect(session.messages.map(\.role) == [.user, .agent])
        let state = session.messages[1].agent
        #expect(state?.phase == .awaitingApproval)
        #expect(state?.steps.last == "승인 요청")
        #expect(state?.draft?.revision == 1)
        #expect(session.hasPendingApproval)
        // 작업 카드: 맡기자마자 보여 줄 확인 문장, 제목, 상태. 위쪽 상태 줄은 "승인 필요"
        #expect(state?.ack == "네, 바로 준비할게요.")
        #expect(state?.title == "할 일로 메일 초안 써줘")
        #expect(state?.statusLabel == "승인 필요")
        #expect(session.status == .needsApproval)
        #expect(cloud.requests.isEmpty)

        // 승인 대기 중에는 새 질문을 받지 않는다
        await session.send("다른 질문", meetings: [meeting])
        #expect(session.messages.count == 2)
        // 진행 중인 작업도 저장한다 (앱이 꺼져도 다시 열면 이어서 확인)
        #expect(session.conversation?.records.count == 2)
    }

    @Test func rejectWithReasonRevisesDraft() async throws {
        let session = session()
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        let id = try #require(session.messages.last?.agent?.id)
        await session.decide(id, approve: false, reason: "더 짧게")

        let state = session.messages.last?.agent
        #expect(state?.phase == .awaitingApproval)
        #expect(state?.draft?.revision == 2)
        #expect(state?.draft?.body?.contains("더 짧게") == true)
        #expect(state?.draft?.approvalID != nil)
        #expect(session.messages.filter { $0.role == .agent }.count == 1)
    }

    @Test func rejectWithoutReasonCancelsAndSaves() async throws {
        let session = session()
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        let id = try #require(session.messages.last?.agent?.id)
        await session.decide(id, approve: false, reason: "  ")
        #expect(session.messages.last?.agent?.phase == .canceled)
        #expect(!session.hasPendingApproval)
        #expect(session.conversation?.records.count == 2)
    }

    @Test func approveFinishesAndRestoresFromStore() async throws {
        let session = session()
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        let id = try #require(session.messages.last?.agent?.id)
        await session.decide(id, approve: true)
        #expect(session.messages.last?.agent?.phase == .done)

        let conversation = try #require(session.conversation)
        #expect(conversation.usesAgent)
        let reopened = AskSession(provider: nil, agent: nil)
        reopened.open(conversation)
        #expect(reopened.messages.map(\.role) == [.user, .agent])
        #expect(reopened.messages[0].engine == .local)
        #expect(reopened.messages[1].agent?.phase == .done)
        #expect(reopened.messages[1].agent?.approvedDrafts.first?.title?.contains("주간 회의") == true)
    }

    @Test func cloudHistoryExcludesAgentTurns() async throws {
        let cloud = FakeAskProvider([.success(.init(answer: "12월 3일입니다.", found: true, citations: []))])
        let session = session(cloud: cloud)
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        let id = try #require(session.messages.last?.agent?.id)
        await session.decide(id, approve: true)
        await session.send("출시일은?", meetings: [meeting])
        // 맥에서 처리한 부탁과 결과는 Claude로 보내지 않는다
        #expect(cloud.requests.first?.history.isEmpty == true)
    }

    @Test func unreachableShowsRetryableError() async {
        let session = session(reachable: false)
        await session.checkAgent()
        #expect(session.agentReachable == false)
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        #expect(session.messages.last?.role == .error)
        #expect(session.messages.last?.engine == .local)
        #expect(session.messages.last?.retryQuestion == "메일 초안 써줘")
    }
}


@MainActor
struct AgentFlowTests {
    let meeting: Meeting

    init() {
        meeting = Meeting(title: "주간 회의")
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
    }

    @Test func needsInputAnswerStartsNewTaskWithOriginalRequest() async throws {
        let agent = MockAgentClient()
        let session = AskSession(provider: nil, agent: agent, pollInterval: .zero)
        // 회의가 없으면 자료(context)가 없어 가짜 에이전트가 되묻는다
        await session.send("그 회의 언제였지?", meetings: [], engine: .local)
        let asked = try #require(session.messages.last?.agent)
        #expect(asked.phase == .needsInput)
        #expect(session.pendingAgentQuestion?.id == asked.id)

        await session.send("주간 회의", meetings: [meeting], engine: .local)
        let next = try #require(session.messages.last?.agent)
        #expect(next.id != asked.id)
        #expect(next.task.contains("그 회의 언제였지?"))
        #expect(next.task.contains("답: 주간 회의"))
    }

    @Test func cancelStopsRunningTask() async throws {
        let agent = MockAgentClient()
        let session = AskSession(provider: nil, agent: agent, pollInterval: .zero)
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        let id = try #require(session.messages.last?.agent?.id)
        await session.decide(id, approve: false, reason: "더 짧게")
        // 승인 대기 상태에서는 멈추기가 아니라 거부로 끝낸다. 진행 중 취소는 가짜 서버에서 직접 확인
        let canceled = try await agent.cancel(id)
        #expect(canceled.phase == .canceled)
    }
}

struct AgentHTTPDecodeTests {
    @Test func taskCardTextComesFromStepsAndPhase() throws {
        let running = """
        {"id":"T1","status":"running","task":"지난 회의 할 일을 정리해서 팀에 공유하는 메일 초안을 써줘\\n자세히",
         "steps":[{"n":1,"tool":"navigate","args":{"url":"http://mail.test/compose"},"status":"ok"},
                  {"n":2,"tool":"type","args":{"text":"안녕하세요"},"status":"ok"}]}
        """
        let state = try AgentHTTPClient.decodeTask(data: Data(running.utf8), status: 200)
        #expect(state.title == "지난 회의 할 일을 정리해서 팀에 공유하는 메일…")
        #expect(state.statusLabel == "진행 중")
        #expect(state.currentStatus == "내용을 입력하고 있어요")
        #expect(state.timeline.map(\.kind) == [.action, .action])

        let queued = #"{"id":"T2","status":"queued","task":"t","steps":[]}"#
        let waiting = try AgentHTTPClient.decodeTask(data: Data(queued.utf8), status: 200)
        #expect(waiting.statusLabel == "대기 중")
        #expect(waiting.currentStatus.contains("기다리고"))
    }

    @Test func timelineMarksApprovalAsMilestone() throws {
        let state = AgentTaskState(id: "T", task: "t", steps: ["열기 · mail.test", "승인 요청", "거부 사유 반영", "입력 · 본문"], phase: .running)
        #expect(state.timeline.map(\.kind) == [.action, .milestone, .milestone, .action])
    }

    @Test func linkOnlyForRealHttpsPages() throws {
        #expect(AgentLink.openable("https://mail.example.org/drafts/1")?.title == "mail.example.org")
        // 테스트·내부 주소, http, 숫자 주소는 링크로 만들지 않는다
        for blocked in ["http://mail.example.org/a", "https://mail.test/compose", "https://localhost/a",
                        "https://127.0.0.1/a", "https://mac.tailnet.ts.net/a", "about:blank", nil] {
            #expect(AgentLink.openable(blocked) == nil)
        }
        let done = """
        {"id":"T1","status":"completed","task":"t",
         "steps":[{"n":1,"tool":"navigate","args":{},"status":"ok","url":"https://mail.example.org/drafts"},
                  {"n":2,"tool":"finish","args":{},"status":"ok"}],
         "result":{"outcome":"completed","summary":"끝"}}
        """
        let state = try AgentHTTPClient.decodeTask(data: Data(done.utf8), status: 200)
        #expect(state.links?.map(\.url.absoluteString) == ["https://mail.example.org/drafts"])
    }

    @Test func typedWithoutSavingIsFlagged() throws {
        var state = AgentTaskState(id: "T", task: "t", steps: ["입력 · 본문", "마무리"], phase: .done)
        #expect(state.typedWithoutSaving)
        state.approvedDrafts = [AgentDraft(approvalID: nil, action: "임시 저장", fields: [])]
        #expect(!state.typedWithoutSaving)
    }

    @Test func oldSavedTaskStillDecodes() throws {
        // 새 값(ack·activity·links)이 없던 때 저장한 기록
        let old = #"{"id":"T","task":"t","steps":["누르기"],"phase":"done","isQueued":false,"approvedDrafts":[],"lastRevision":0}"#
        let state = try JSONDecoder().decode(AgentTaskState.self, from: Data(old.utf8))
        #expect(state.ack == nil)
        #expect(state.links == nil)
        #expect(state.title == "t")
    }

    @Test func awaitingApprovalMapsFieldsInReadableOrder() throws {
        let json = """
        {"id":"T1","status":"awaiting_approval","task":"메일 초안",
         "steps":[{"n":1,"tool":"navigate","args":{"url":"http://mail.test/compose"},"status":"ok","url":"http://mail.test/compose"},
                  {"n":2,"tool":"type","args":{"ref":"e3","text":"test-b@mail.test","submit":false},"status":"ok"},
                  {"n":3,"tool":"click","args":{"ref":"e9"},"status":"needs_approval"}],
         "approval":{"approval_id":"A1","kind":"draft","action":"임시 저장","url":"http://mail.test/compose",
                     "fields":{"본문":"내용","제목":"확인 요청","받는 사람":"test-b@mail.test"},"expires_in_s":1800}}
        """
        let state = try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
        #expect(state.phase == .awaitingApproval)
        #expect(state.steps == ["열기 · mail.test/compose", "입력 · test-b@mail.test", "승인 요청"])
        #expect(state.draft?.approvalID == "A1")
        #expect(state.draft?.fields.map(\.label) == ["받는 사람", "제목", "본문"])
    }

    @Test func completedUsesApprovedDraftsNotSummary() throws {
        let json = """
        {"id":"T1","status":"completed","task":"t","steps":[],
         "result":{"outcome":"completed","summary":"감사합니다를 덧붙였습니다",
                   "approved_drafts":[{"action":"임시 저장","url":"u","fields":{"제목":"확인","본문":"감사합니다."}}]}}
        """
        let state = try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
        #expect(state.phase == .done)
        #expect(state.approvedDrafts.first?.body == "감사합니다.")
    }

    @Test func failureOutcomesAndErrors() throws {
        let denied = """
        {"id":"T1","status":"failed","task":"t","steps":[],"result":{"outcome":"approval_denied","summary":""}}
        """
        #expect(try AgentHTTPClient.decodeTask(data: Data(denied.utf8), status: 200).phase == .canceled)
        let mismatch = """
        {"id":"T1","status":"failed","task":"t","steps":[],"result":{"outcome":"approval_mismatch"}}
        """
        let failed = try AgentHTTPClient.decodeTask(data: Data(mismatch.utf8), status: 200)
        #expect(failed.phase == .failed)
        #expect(failed.error?.contains("달라") == true)

        let lost = Data(#"{"error":{"code":"task_not_found","message":"없음"}}"#.utf8)
        #expect(AgentHTTPClient.decodeError(data: lost, status: 404) == .taskLost)
        let busy = Data(#"{"error":{"code":"busy","message":"바쁨"}}"#.utf8)
        #expect(AgentHTTPClient.decodeError(data: busy, status: 429) == .busy)
        #expect(AgentHTTPClient.decodeError(data: Data(), status: 401) == .unauthorized)
    }

    @Test func contextStartsWithTodayAndTheAskedDay() {
        var request = AskRequest(question: "q", history: [],
                                 meetings: [.init(ref: "m1", title: "준비 회의", date: "1월 15일 (금) 오전 10:00", summary: nil,
                                                  utterances: [.init(ref: "m1-u1", start: 0, text: "시나리오 준비는 각자 맡기로 했습니다.")])],
                                 otherMeetings: [])
        request.today = "1월 15일 (금)"
        #expect(AgentContext.text(from: request)?.hasPrefix("오늘 날짜: 1월 15일 (금)\n\n## 준비 회의") == true)

        request.day = .init(label: "오늘(1월 15일)", found: true)
        #expect(AgentContext.text(from: request)?.contains("부탁이 가리키는 날: 오늘(1월 15일). 그 날 녹음한 회의만 아래에 담았습니다.") == true)
        request.day = .init(label: "오늘(1월 15일)", found: false)
        // 맥이 이 글자를 읽고 "그 날 녹음한 회의가 없어요"라고 되묻는다 (맥 세션과의 약속). 바꾸려면 먼저 맥 쪽에 알린다
        #expect(AgentContext.text(from: request)?.contains("그 날 녹음한 회의는 없습니다. 아래는 다른 날 회의입니다.") == true)
    }

    @Test func contextIsCutAtLineBoundaryWithinLimit() {
        let long = (0..<400).map { AskRequest.Utterance(ref: "m1-u\($0)", start: Double($0), text: String(repeating: "가", count: 40)) }
        let request = AskRequest(question: "q", history: [],
                                 meetings: [.init(ref: "m1", title: "주간 회의", date: "11월 10일", summary: nil, utterances: long)],
                                 otherMeetings: [])
        let text = AgentContext.text(from: request) ?? ""
        #expect(text.count <= AgentContext.limit)
        #expect(text.hasPrefix("## 주간 회의"))
        #expect(text.hasSuffix(String(repeating: "가", count: 40)))
    }
}


/// 실제 서버처럼 승인 직후 같은 승인 대기 상태를 돌려주는 에이전트 (실기기 확인에서 발견)
actor StaleApprovalAgent: AgentProviding {
    let inner = MockAgentClient()
    func isReachable() async -> Bool { true }
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        try await inner.message(text, conversationID: conversationID, context: context)
    }
    func start(task: String, context: String?) async throws -> AgentTaskState { try await inner.start(task: task, context: context) }
    func state(of id: String) async throws -> AgentTaskState { try await inner.state(of: id) }
    func cancel(_ id: String) async throws -> AgentTaskState { try await inner.cancel(id) }
    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        var stale = try await inner.state(of: id)
        _ = try await inner.decide(id, approvalID: approvalID, approve: approve, reason: reason, sha256: sha256)
        stale.phase = .awaitingApproval
        return stale
    }
}

@MainActor
struct StaleApprovalTests {
    @Test func keepsPollingUntilApprovalIsProcessed() async throws {
        let meeting = Meeting(title: "주간 회의")
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
        let session = AskSession(provider: nil, agent: StaleApprovalAgent(), pollInterval: .zero)
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        let id = try #require(session.messages.last?.agent?.id)
        await session.decide(id, approve: true)
        #expect(session.messages.last?.agent?.phase == .done)
        #expect(session.messages.last?.agent?.approvedDrafts.count == 1)
    }
}

/// 화면에 보인 내용이 맥에 고정된 초안과 다른 상황: 앱이 계산한 해시가 서버 해시와 다르다
actor TamperedDraftAgent: AgentProviding {
    let inner = MockAgentClient()
    func isReachable() async -> Bool { true }
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        try await inner.message(text, conversationID: conversationID, context: context)
    }
    func start(task: String, context: String?) async throws -> AgentTaskState { try await inner.start(task: task, context: context) }
    func state(of id: String) async throws -> AgentTaskState {
        var state = try await inner.state(of: id)
        state.draft?.shownSHA256 = String(repeating: "0", count: 64)
        return state
    }
    func cancel(_ id: String) async throws -> AgentTaskState { try await inner.cancel(id) }
    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        try await inner.decide(id, approvalID: approvalID, approve: approve, reason: reason, sha256: sha256)
    }
}

@MainActor
struct HashApprovalTests {
    /// 서버(Python `json.dumps(ensure_ascii=False, sort_keys=True, separators=(",", ":"))`)로 계산한 값과 같아야 한다
    @Test func hashMatchesServerFormula() {
        let hash = AgentDraftHash.sha256(
            action: "임시 저장",
            fields: ["본문": "안녕\n\"따옴표\" \\ 탭\t끝", "받는 사람": "a@mail.test", "제목": "[공유] 정리"],
            kind: "draft", url: "http://mail.test/compose")
        #expect(hash == "12f2896cab2e61fef66763fbea57e4cbc14df2660981d2ce62cfebf7ac28c43b")
    }

    @Test func approvalCarriesHashAndReceivedState() throws {
        let fields = ["제목": "공유", "본문": "첫 줄\n둘째 줄"]
        let hash = AgentDraftHash.sha256(action: "임시 저장", fields: fields, kind: "draft", url: "http://mail.test/compose")
        let json = """
        {"id":"T1","status":"needs_approval","task":"t","steps":[],
         "approval":{"approval_id":"A1","kind":"draft","action":"임시 저장","url":"http://mail.test/compose",
                     "draft_id":"D1","sha256":"\(hash)","fields":{"제목":"공유","본문":"첫 줄\\n둘째 줄"},"received":"approve"}}
        """
        let draft = try #require(try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200).draft)
        #expect(draft.sha256 == hash)
        #expect(draft.approvalHash == hash)
        #expect(draft.shortHash == String(hash.prefix(8)))
        #expect(draft.received == "approve")
        #expect(draft.fields.first { $0.label == "본문" }?.value == "첫 줄\n둘째 줄")

        // 받은 내용이 서버 해시와 다르면, 승인할 때는 받은 내용으로 계산한 값을 보낸다 (서버가 거절한다)
        let other = json.replacingOccurrences(of: "둘째 줄", with: "바뀐 줄")
        let changed = try #require(try AgentHTTPClient.decodeTask(data: Data(other.utf8), status: 200).draft)
        #expect(changed.sha256 == hash)
        #expect(changed.approvalHash != hash)

        // 해시가 없는 예전 서버: 그대로 동작한다
        let old = #"{"id":"T2","status":"needs_approval","task":"t","steps":[],"approval":{"approval_id":"A2","action":"저장","fields":{"제목":"공유"}}}"#
        let plain = try #require(try AgentHTTPClient.decodeTask(data: Data(old.utf8), status: 200).draft)
        #expect(plain.approvalHash == nil)
        #expect(plain.shortHash == nil)
    }

    @Test func hashMismatchIsItsOwnError() {
        let body = Data(#"{"error":{"code":"hash_mismatch","message":"x"}}"#.utf8)
        #expect(throws: AgentError.hashMismatch) { try AgentHTTPClient.decodeTask(data: body, status: 409) }
    }

    @Test func approvedDraftKeepsTheApprovedHash() async throws {
        let meeting = Meeting(title: "주간 회의")
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
        let session = AskSession(provider: nil, agent: MockAgentClient(), pollInterval: .zero)
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        let state = try #require(session.messages.last?.agent)
        let hash = try #require(state.draft?.sha256)
        await session.decide(state.id, approve: true)
        #expect(session.messages.last?.agent?.phase == .done)
        #expect(session.messages.last?.agent?.approvedDrafts.first?.sha256 == hash)
    }

    @Test func mismatchedDraftIsNotApproved() async throws {
        let meeting = Meeting(title: "주간 회의")
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
        let session = AskSession(provider: nil, agent: TamperedDraftAgent(), pollInterval: .zero)
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        let id = try #require(session.messages.last?.agent?.id)
        await session.decide(id, approve: true)
        #expect(session.messages.last?.role == .error)
        #expect(session.messages.last?.text.contains("달라서 승인하지 않았어요") == true)
        let task = session.messages.last { $0.agent?.id == id }?.agent
        #expect(task?.phase == .awaitingApproval)
        #expect(task?.approvedDrafts.isEmpty == true)
    }
}

/// 연결이 끊겼다 돌아오는 맥: `failures`번은 상태 조회가 실패한다
actor FlakyAgent: AgentProviding {
    let inner = MockAgentClient()
    var failures: Int
    init(failures: Int) { self.failures = failures }
    func recover() { failures = 0 }
    func isReachable() async -> Bool { failures == 0 }
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        try await inner.message(text, conversationID: conversationID, context: context)
    }
    func start(task: String, context: String?) async throws -> AgentTaskState { try await inner.start(task: task, context: context) }
    func state(of id: String) async throws -> AgentTaskState {
        if failures > 0 {
            failures -= 1
            throw AgentError.unreachable
        }
        return try await inner.state(of: id)
    }
    func cancel(_ id: String) async throws -> AgentTaskState { try await inner.cancel(id) }
    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        try await inner.decide(id, approvalID: approvalID, approve: approve, reason: reason, sha256: sha256)
    }
}

/// 앱이 멈추거나 꺼졌다가 돌아왔을 때 작업을 이어서 확인하는지
@MainActor
struct AgentResumeTests {
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
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
    }

    @Test func pendingApprovalSurvivesRelaunch() async throws {
        let agent = MockAgentClient()
        let session = AskSession(provider: nil, agent: agent, pollInterval: .zero)
        session.attach(context)
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        #expect(session.messages.last?.agent?.phase == .awaitingApproval)

        // 앱을 다시 연 것처럼 새 세션을 붙인다 (맥은 그대로)
        let reopened = AskSession(provider: nil, agent: agent, pollInterval: .zero)
        reopened.attach(context)
        let restored = try #require(reopened.messages.last?.agent)
        #expect(restored.phase == .awaitingApproval)
        #expect(restored.ack == "네, 바로 준비할게요.")
        await reopened.resumeAgent()
        #expect(reopened.hasPendingApproval)

        await reopened.decide(restored.id, approve: true)
        #expect(reopened.messages.last?.agent?.phase == .done)
        // 같은 작업은 기록 하나를 고쳐 쓴다 (질문 1 + 작업 1)
        #expect(reopened.conversation?.records.count == 2)

        let third = AskSession(provider: nil, agent: agent, pollInterval: .zero)
        third.attach(context)
        #expect(third.messages.last?.agent?.phase == .done)
        #expect(third.messages.last?.agent?.approvedDrafts.count == 1)
    }

    @Test func shortDisconnectIsRetriedQuietly() async throws {
        let session = AskSession(provider: nil, agent: FlakyAgent(failures: 2), pollInterval: .zero)
        session.attach(context)
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        #expect(session.messages.last?.agent?.phase == .awaitingApproval)
        #expect(!session.messages.contains { $0.role == .error })
    }

    @Test func lostConnectionKeepsTheTaskAndResumesLater() async throws {
        let agent = FlakyAgent(failures: 10)
        let session = AskSession(provider: nil, agent: agent, pollInterval: .zero)
        session.attach(context)
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        // 카드는 진행 중으로 남고, 같은 부탁을 다시 보내는 버튼은 없다
        let error = try #require(session.messages.last)
        #expect(error.role == .error)
        #expect(error.retryQuestion == nil)
        #expect(error.resumeTaskID != nil)
        #expect(session.messages.dropLast().last?.agent?.phase == .running)

        // 여전히 끊겨 있으면 안내는 하나만 남는다
        await session.resumeAgent()
        #expect(session.messages.filter { $0.role == .error }.count == 1)

        // 다시 연결되면 이어서 받는다
        await agent.recover()
        await session.resumeAgent()
        #expect(session.messages.last?.agent?.phase == .awaitingApproval)
        #expect(!session.messages.contains { $0.role == .error })
    }

    @Test func taskGoneAfterMacRestartEndsAsFailed() async throws {
        let session = AskSession(provider: nil, agent: MockAgentClient(), pollInterval: .zero)
        session.attach(context)
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)

        // 맥 에이전트가 다시 시작되어 작업 기록이 없다
        let reopened = AskSession(provider: nil, agent: MockAgentClient(), pollInterval: .zero)
        reopened.attach(context)
        await reopened.resumeAgent()
        #expect(reopened.messages.last?.agent?.phase == .failed)
        #expect(!reopened.hasPendingApproval)
    }
}


/// 대화 요청이 실패하는 맥: 처음 `failures`번은 답이 늦다
actor SlowMainAgent: AgentProviding {
    let inner = MockAgentClient()
    var failures: Int
    private(set) var attempts = 0
    init(failures: Int) { self.failures = failures }
    func isReachable() async -> Bool { true }
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        attempts += 1
        if failures > 0 {
            failures -= 1
            throw AgentError.slow
        }
        return try await inner.message(text, conversationID: conversationID, context: context)
    }
    func start(task: String, context: String?) async throws -> AgentTaskState { try await inner.start(task: task, context: context) }
    func state(of id: String) async throws -> AgentTaskState { try await inner.state(of: id) }
    func cancel(_ id: String) async throws -> AgentTaskState { try await inner.cancel(id) }
    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        try await inner.decide(id, approvalID: approvalID, approve: approve, reason: reason, sha256: sha256)
    }
}

/// 메일 부탁에 두 번 되묻고, 세 번째 메시지에서 작업을 만드는 맥 (실기기에서 나온 순서)
actor AskingTwiceAgent: AgentProviding {
    let inner = MockAgentClient()
    let repliesPerAsk: Int
    private var request: String?
    private var asks = 0
    private(set) var received: [(text: String, conversationID: String?, context: String?)] = []
    init(repliesPerAsk: Int = 1) { self.repliesPerAsk = repliesPerAsk }
    func isReachable() async -> Bool { true }
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        received.append((text, conversationID, context))
        guard let request else {
            guard text.contains("초안") else {
                return try await inner.message(text, conversationID: conversationID, context: context)
            }
            self.request = text
            return ask(conversationID)
        }
        if asks < 2 { return ask(conversationID) }
        // 가짜 맥은 한 번 되물은 뒤 답을 받으면 작업을 만든다
        _ = try await inner.message(request, conversationID: conversationID, context: context)
        return try await inner.message(text, conversationID: conversationID, context: context)
    }
    private func ask(_ conversationID: String?) -> AgentReply {
        asks += 1
        let replies = (1...repliesPerAsk).map { "되물음 \(asks)-\($0)" }
        return AgentReply(conversationID: conversationID ?? "conv-1", replies: replies, action: .ask(choices: []))
    }
    func start(task: String, context: String?) async throws -> AgentTaskState { try await inner.start(task: task, context: context) }
    func state(of id: String) async throws -> AgentTaskState { try await inner.state(of: id) }
    func cancel(_ id: String) async throws -> AgentTaskState { try await inner.cancel(id) }
    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        try await inner.decide(id, approvalID: approvalID, approve: approve, reason: reason, sha256: sha256)
    }
}

/// 입력창 하나: 모든 메시지를 맥의 대화 담당이 먼저 받고, 답·되묻기·작업·Claude 중 하나로 정한다 (D34)
@MainActor
struct MainAgentTests {
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
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
    }

    private static let answer = AskAnswerDTO(answer: "12월 3일입니다.", found: true, citations: [])

    private func session(cloud: FakeAskProvider = FakeAskProvider([]), agent: any AgentProviding = MockAgentClient()) -> AskSession {
        let session = AskSession(provider: cloud, agent: agent, pollInterval: .zero)
        session.attach(context)
        return session
    }

    @Test func greetingIsAnsweredByTheMac() async {
        let cloud = FakeAskProvider([])
        let session = session(cloud: cloud)
        await session.send("안녕", meetings: [meeting])

        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(session.messages.map(\.engine) == [.local, .local])
        #expect(session.pendingChoices.isEmpty)
        #expect(session.agentReachable == true)
        #expect(cloud.requests.isEmpty)
        #expect(session.conversation?.records.count == 2)
    }

    @Test func greetingGoesToTheMacWithoutMeetingContext() async {
        let agent = MockAgentClient()
        let session = session(agent: agent)
        await session.send("안녕하세요!", meetings: [meeting])
        await session.send("지난 회의 결정 사항 메일로 팀에게 공유해줘", meetings: [meeting])

        let received = await agent.received
        #expect(received.first?.context == nil)
        #expect(received.last?.context?.isEmpty == false)
    }

    @Test func meetingQuestionIsRoutedToClaudeAndMarked() async throws {
        let cloud = FakeAskProvider([.success(Self.answer)])
        let session = session(cloud: cloud)
        await session.send("출시일은?", meetings: [meeting])

        #expect(cloud.requests.count == 1)
        #expect(session.messages.map(\.role) == [.user, .assistant])
        // 맥이 넘긴 질문과 Claude의 답은 Claude가 처리한 것으로 남는다 (화면에 "Claude 사용")
        #expect(session.messages.map(\.engine) == [.cloud, .cloud])
        let conversation = try #require(session.conversation)
        #expect(conversation.sortedRecords.map(\.engineRaw) == [nil, nil])
        #expect(!conversation.usesAgent)
    }

    @Test func macRepliesAreNotSentToClaude() async {
        let cloud = FakeAskProvider([.success(Self.answer)])
        let session = session(cloud: cloud)
        await session.send("안녕", meetings: [meeting])
        await session.send("출시일은?", meetings: [meeting])
        #expect(cloud.requests.first?.history.isEmpty == true)
    }

    @Test func askOffersChoicesAndTheAnswerCreatesTask() async throws {
        let agent = MockAgentClient()
        let session = session(agent: agent)
        await session.send("메일 초안 써줘", meetings: [meeting])

        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(session.pendingChoices == ["팀 전체", "나에게만"])
        #expect(session.messages.last?.asksBack == true)

        // 고른 값은 같은 대화 번호로 다음 메시지로 간다
        await session.send("나에게만", meetings: [meeting])
        let received = await agent.received
        #expect(received.map(\.conversationID) == [nil, "conv-1"])
        #expect(session.pendingChoices.isEmpty)
        // 되물음에 대한 답은 짧아도 회의 자료와 함께 간다 (그 답으로 작업이 만들어진다)
        #expect(received.last?.context?.isEmpty == false)

        let state = try #require(session.messages.last?.agent)
        #expect(state.phase == .awaitingApproval)
        #expect(state.title == "회의 공유 메일 초안")
        #expect(state.ack == "네, 회의 공유 메일 초안 준비할게요.")
        #expect(state.brief?.targets == ["me@mail.test"])
        #expect(state.draft?.fields.first { $0.label == "받는 사람" }?.value == "me@mail.test")
        // 작업 상세의 "부탁한 내용"은 처음 부탁과 답을 함께 보여 준다
        #expect(state.request == "메일 초안 써줘\n나에게만")
    }

    @Test func todaysMeetingStaysChosenWhileTheMacAsksBack() async throws {
        // 이틀 전 회의에는 답("나에게만")과 같은 말이 나온다. 그래도 처음 부탁의 "오늘 회의"를 따른다
        let old = Meeting(title: "지난 회의", date: .now.addingTimeInterval(-2 * 86_400))
        context.insert(old)
        old.appendUtterance(Utterance(start: 1, end: 4, text: "오늘 메일은 나에게만 보내도 됩니다."))
        let agent = MockAgentClient()
        let session = session(agent: agent)

        await session.send("오늘 회의 메일 초안 써줘", meetings: [old, meeting])
        #expect(session.messages.last?.asksBack == true)
        await session.send("나에게만", meetings: [old, meeting])

        for message in await agent.received {
            let text = try #require(message.context)
            #expect(text.contains("부탁이 가리키는 날: 오늘("))
            #expect(text.contains("그 날 녹음한 회의만 아래에 담았습니다."))
            #expect(text.contains("출시일은 12월 3일로 확정했습니다."))
            #expect(!text.contains("나에게만 보내도 됩니다."))
        }
    }

    @Test func aDayNamedInTheAnswerReplacesTheDayOfTheFirstRequest() async throws {
        // 맥이 "그 날 회의가 없다, 어느 회의로 보낼까"처럼 되물었을 때, 답에서 말한 날의 회의만 간다
        let old = Meeting(title: "지난 회의", date: .now.addingTimeInterval(-2 * 86_400))
        context.insert(old)
        old.appendUtterance(Utterance(start: 1, end: 4, text: "예산은 다음 주에 다시 봅니다."))
        let agent = MockAgentClient()
        let session = session(agent: agent)

        await session.send("오늘 회의 메일 초안 써줘", meetings: [old, meeting])
        #expect(session.messages.last?.asksBack == true)
        await session.send("그저께 회의로 나에게만 보내 줘", meetings: [old, meeting])

        let received = await agent.received
        let first = try #require(received.first?.context)
        #expect(first.contains("부탁이 가리키는 날: 오늘("))
        let second = try #require(received.last?.context)
        #expect(second.contains("부탁이 가리키는 날: 그저께("))
        #expect(second.contains("예산은 다음 주에 다시 봅니다."))
        #expect(!second.contains("출시일은 12월 3일로 확정했습니다."))
    }

    @Test func taskKeepsTitleAndBriefThroughApprovalAndRelaunch() async throws {
        let session = session()
        await session.send("팀 공유 메일 초안 써줘", meetings: [meeting])
        let id = try #require(session.messages.last?.agent?.id)
        #expect(session.messages.map(\.role) == [.user, .agent])
        await session.decide(id, approve: true)

        let done = try #require(session.messages.last?.agent)
        #expect(done.phase == .done)
        #expect(done.title == "회의 공유 메일 초안")
        #expect(done.brief?.purpose?.isEmpty == false)
        #expect(done.request == "팀 공유 메일 초안 써줘")

        let reopened = AskSession(provider: nil, agent: nil)
        reopened.open(try #require(session.conversation))
        #expect(reopened.messages.last?.agent?.brief == done.brief)
        #expect(reopened.messages.last?.agent?.request == done.request)
    }

    @Test func offlineMacFallsBackToClaude() async {
        let cloud = FakeAskProvider([.success(Self.answer)])
        let session = session(cloud: cloud, agent: MockAgentClient(reachable: false))
        await session.send("출시일은?", meetings: [meeting])

        #expect(session.agentReachable == false)
        #expect(cloud.requests.count == 1)
        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(session.messages.map(\.engine) == [.cloud, .cloud])
    }

    @Test func brieflyLostMacStillGetsTheMessage() async {
        // 방금까지 연결되던 맥이 연결 확인 한 번에 실패해도 부탁을 Claude로 넘기지 않는다
        let cloud = FakeAskProvider([])
        let agent = MockAgentClient(failingChecks: 1)
        let session = session(cloud: cloud, agent: agent)
        await session.send("안녕", meetings: [meeting])

        #expect(cloud.requests.isEmpty)
        #expect(session.agentReachable == true)
        #expect(await agent.received.map(\.text) == ["안녕"])
        #expect(session.messages.map(\.engine) == [.local, .local])
    }

    @Test func macLostForLongerFallsBackAndCanBeResent() async throws {
        let ask = "회의 요약해서 팀에게 메일로 보내줘"
        let cloud = FakeAskProvider([.success(Self.answer)])
        let agent = MockAgentClient(failingChecks: 3)
        let session = session(cloud: cloud, agent: agent)
        await session.send(ask, meetings: [meeting])

        // 세 번 모두 실패해야 Claude가 대신 답한다. 답에 표시가 남고, 연결이 돌아온 것을 바로 안다
        #expect(cloud.requests.count == 1)
        #expect(await agent.received.isEmpty)
        let answer = try #require(session.messages.last)
        #expect(answer.role == .assistant)
        #expect(answer.offlineQuestion == ask)
        #expect(session.agentReachable == true)
        #expect(session.resendableMessageID == answer.id)

        // 답 아래 버튼: 같은 글이 맥으로 가서 작업이 된다. 같은 답에서 두 번 보낼 수는 없다
        await session.resendToAgent(answer.id, meetings: [meeting])
        #expect(await agent.received.map(\.text) == [ask])
        #expect(cloud.requests.count == 1)
        #expect(session.messages.last?.role == .agent)
        #expect(session.resendableMessageID == nil)
        #expect(session.messages.first(where: { $0.id == answer.id })?.offlineQuestion == nil)
    }

    @Test func macKnownToBeOffIsCheckedOnlyOnce() async {
        // 이미 끊긴 것으로 알고 있으면 질문마다 여러 번 확인하며 기다리지 않는다
        let cloud = FakeAskProvider([.success(Self.answer)])
        let agent = MockAgentClient(failingChecks: 2)
        let session = session(cloud: cloud, agent: agent)
        await session.checkAgent()
        #expect(session.agentReachable == false)
        await session.send("출시일은?", meetings: [meeting])

        // 확인 한 번(두 번째 실패)으로 Claude에 넘겼다. 세 번 확인했다면 세 번째에 연결되어 맥으로 갔을 것이다
        #expect(cloud.requests.count == 1)
        #expect(await agent.received.isEmpty)
        #expect(session.messages.last?.offlineQuestion == "출시일은?")
    }

    @Test func answerTheMacRoutedToClaudeHasNoResendMark() async {
        let cloud = FakeAskProvider([.success(Self.answer)])
        let session = session(cloud: cloud)
        await session.send("출시일은?", meetings: [meeting])

        #expect(cloud.requests.count == 1)
        #expect(session.messages.last?.offlineQuestion == nil)
        #expect(session.resendableMessageID == nil)
    }

    @Test func conversationIDIsKeptAcrossMessagesAndRelaunch() async throws {
        let agent = MockAgentClient()
        let session = session(agent: agent)
        await session.send("안녕", meetings: [meeting])
        await session.send("고마워", meetings: [meeting])
        #expect(session.agentConversationID == "conv-1")
        #expect(await agent.received.map(\.conversationID) == [nil, "conv-1"])

        let reopened = AskSession(provider: nil, agent: agent, pollInterval: .zero)
        reopened.attach(context)
        #expect(reopened.agentConversationID == "conv-1")
        // 새 대화는 번호 없이 시작한다
        reopened.reset()
        #expect(reopened.agentConversationID == nil)
        await reopened.send("안녕", meetings: [meeting])
        #expect(reopened.agentConversationID == "conv-2")
    }

    /// 인사·감사에는 회의 자료를 붙이지 않는다 (맥이 자료가 붙은 일상 대화를 훨씬 느리게 처리한다).
    /// 부탁일 수 있는 말은 짧아도 자료를 붙인다.
    @Test func smallTalkIsOnlyWholeGreetingsOrThanks() {
        for text in ["안녕", "안녕하세요!", "고마워~", "감사합니다.", " ㅎㅎ ", "Thanks"] {
            #expect(AskSession.isSmallTalk(text), "\(text)")
        }
        for text in ["응", "좋아", "감사 메일 써줘", "메일 써줘", "안녕, 지난 회의 요약해줘", "나에게만", ""] {
            #expect(!AskSession.isSmallTalk(text), "\(text)")
        }
    }

    @Test func claudeAnswerGoesToTheMacWithTheNextRequest() async throws {
        let cloud = FakeAskProvider([.success(Self.answer)])
        let agent = MockAgentClient()
        let session = session(cloud: cloud, agent: agent)
        await session.send("출시일은?", meetings: [meeting])
        await session.send("팀에 그 내용으로 메일 초안 써줘", meetings: [meeting])

        // 맥은 Claude의 답을 보지 못했으므로, 방금 나눈 질문·답을 자료 앞에 붙여 보낸다
        let sent = try #require(await agent.received.last?.context)
        #expect(sent.contains("질문: 출시일은?"))
        #expect(sent.contains("답: 12월 3일입니다."))
        #expect(sent.contains("## 주간 회의"))
        // 부탁은 Claude로 가지 않는다
        #expect(cloud.requests.count == 1)
        #expect(session.messages.last?.agent?.phase == .awaitingApproval)
    }

    /// 실기기에서 나온 순서: 회의 질문 → Claude 답 → 메일 부탁 → 되물음 → 답 → 되물음 → 답(작업 생성).
    /// 되물음이 이어져도 작업을 만드는 마지막 답까지 Claude 문답이 붙어야 한다.
    @Test func claudeAnswerStaysAttachedThroughRepeatedAsks() async throws {
        let cloud = FakeAskProvider([.success(Self.answer)])
        let agent = AskingTwiceAgent()
        let session = session(cloud: cloud, agent: agent)
        await session.send("출시일은?", meetings: [meeting])
        await session.send("메일 초안 써줘", meetings: [meeting])
        await session.send("나한테 보낼 거야", meetings: [meeting])
        await session.send("me@mail.test", meetings: [meeting])

        let received = await agent.received
        #expect(received.map(\.text) == ["출시일은?", "메일 초안 써줘", "나한테 보낼 거야", "me@mail.test"])
        for message in received.dropFirst() {
            let sent = try #require(message.context)
            #expect(sent.hasPrefix("오늘 날짜: "), "\(message.text)")
            #expect(sent.contains("\n\n## 방금 나눈 회의 질문과 답\n질문: 출시일은?\n답: 12월 3일입니다."), "\(message.text)")
            #expect(sent.contains("## 주간 회의"), "\(message.text)")
        }
        let state = try #require(session.messages.last?.agent)
        #expect(state.phase == .awaitingApproval)
        #expect(state.request == "메일 초안 써줘\n나한테 보낼 거야\nme@mail.test")
    }

    /// 한 번의 되물음이 말풍선 여러 개로 와도 처음 부탁까지 거슬러 올라간다.
    @Test func askWithSeveralRepliesStillCountsAsOneAsk() async throws {
        let cloud = FakeAskProvider([.success(Self.answer)])
        let agent = AskingTwiceAgent(repliesPerAsk: 3)
        let session = session(cloud: cloud, agent: agent)
        await session.send("출시일은?", meetings: [meeting])
        await session.send("메일 초안 써줘", meetings: [meeting])
        await session.send("나한테 보낼 거야", meetings: [meeting])
        await session.send("me@mail.test", meetings: [meeting])

        let sent = try #require(await agent.received.last?.context)
        #expect(sent.contains("질문: 출시일은?"))
        #expect(sent.contains("답: 12월 3일입니다."))
        #expect(session.messages.last?.agent?.request == "메일 초안 써줘\n나한테 보낼 거야\nme@mail.test")
    }

    /// 되물음과 상관없는 오래된 Claude 답은 붙이지 않는다 (기준만 옮겼고 범위는 그대로다).
    @Test func oldClaudeAnswerIsNotAttachedToALaterRequest() async throws {
        let cloud = FakeAskProvider([.success(Self.answer)])
        let agent = MockAgentClient()
        let session = session(cloud: cloud, agent: agent)
        await session.send("출시일은?", meetings: [meeting])
        await session.send("안녕", meetings: [meeting])
        await session.send("고마워", meetings: [meeting])
        await session.send("안녕하세요", meetings: [meeting])
        await session.send("메일 초안 써줘", meetings: [meeting])
        await session.send("나에게만", meetings: [meeting])

        let sent = try #require(await agent.received.last?.context)
        #expect(!sent.contains("방금 나눈 회의 질문과 답"))
        #expect(sent.contains("## 주간 회의"))
        #expect(session.messages.last?.agent?.phase == .awaitingApproval)
    }

    @Test func slowReplyCanBeRetriedWithoutRepeatingTheMessage() async throws {
        let agent = SlowMainAgent(failures: 1)
        let session = session(agent: agent)
        await session.send("안녕", meetings: [meeting])

        let failed = try #require(session.messages.last)
        #expect(failed.role == .error)
        #expect(failed.text == AgentError.slow.localizedDescription)
        #expect(failed.retryQuestion == "안녕")
        // 다시 시도도 처음처럼 맥이 정한다
        #expect(failed.retryEngine == nil)

        await session.send("안녕", meetings: [meeting], engine: failed.retryEngine)
        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(await agent.attempts == 2)
    }

    @Test func claudeFailureRetriesWithoutAskingTheMacAgain() async throws {
        let cloud = FakeAskProvider([.failure(.server(code: "overloaded", message: "잠시 후 다시 시도해 주세요.", retryable: true)), .success(Self.answer)])
        let agent = MockAgentClient()
        let session = session(cloud: cloud, agent: agent)
        await session.send("출시일은?", meetings: [meeting])

        let failed = try #require(session.messages.last)
        #expect(failed.role == .error)
        #expect(failed.retryEngine == .cloud)
        await session.send("출시일은?", meetings: [meeting], engine: failed.retryEngine)
        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(await agent.received.count == 1)
    }

    @Test func workerQuestionIsAnsweredAsNewTaskWithOriginalRequest() async throws {
        let agent = MockAgentClient()
        let session = AskSession(provider: nil, agent: agent, pollInterval: .zero)
        // 작업 담당이 정보가 부족해 멈춘 뒤의 답은 대화 담당을 거치지 않고 원래 부탁과 묶어 다시 맡긴다
        await session.send("그 회의 언제였지?", meetings: [], engine: .local)
        #expect(session.messages.last?.agent?.phase == .needsInput)
        await session.send("주간 회의", meetings: [meeting])
        let next = try #require(session.messages.last?.agent)
        #expect(next.task.contains("그 회의 언제였지?"))
        #expect(next.task.contains("답: 주간 회의"))
        #expect(await agent.received.isEmpty)
    }
}

struct AgentReplyDecodeTests {
    @Test func taskReplyCarriesTitleAndBrief() throws {
        let json = """
        {"conversation_id":"c_1","replies":[{"text":"네, 매출 자료 요청 메일 초안 준비할게요."}],
         "action":{"type":"task","task":{"id":"T9","status":"queued","task":"펼친 지시문","steps":[],
                   "title":"매출 자료 요청 메일 초안",
                   "brief":{"purpose":"매출 자료 요청","targets":["kim@mail.test"],"instructions":"초안을 쓴다"}}}}
        """
        let reply = try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200)
        #expect(reply.conversationID == "c_1")
        #expect(reply.replies == ["네, 매출 자료 요청 메일 초안 준비할게요."])
        guard case .task(let state) = reply.action else {
            Issue.record("작업이 아님")
            return
        }
        #expect(state.id == "T9")
        #expect(state.isQueued)
        #expect(state.title == "매출 자료 요청 메일 초안")
        #expect(state.brief?.targets == ["kim@mail.test"])
    }

    @Test func askNoneAndRouteReplies() throws {
        let ask = #"{"conversation_id":"c_1","conversation_reset":true,"replies":[{"text":"누구에게 보낼까요?"}],"action":{"type":"ask","choices":["김팀장","이대리"]}}"#
        #expect(try AgentHTTPClient.decodeReply(data: Data(ask.utf8), status: 200).action == .ask(choices: ["김팀장", "이대리"]))
        let open = #"{"conversation_id":"c_1","replies":[{"text":"어떤 메일인가요?"}],"action":{"type":"ask"}}"#
        #expect(try AgentHTTPClient.decodeReply(data: Data(open.utf8), status: 200).action == .ask(choices: []))
        let chat = #"{"conversation_id":"c_1","replies":[{"text":"안녕하세요."}],"action":{"type":"none"}}"#
        #expect(try AgentHTTPClient.decodeReply(data: Data(chat.utf8), status: 200).action == AgentReply.Action.none)
        let route = #"{"conversation_id":"c_1","replies":[],"action":{"type":"route_claude"}}"#
        let routed = try AgentHTTPClient.decodeReply(data: Data(route.utf8), status: 200)
        #expect(routed.action == .routeClaude)
        #expect(routed.replies.isEmpty)
    }

    @Test func unknownActionWithReplyIsShownAsPlainAnswer() throws {
        // 서버가 나중에 종류를 늘려도 답이 있으면 보여 준다. 답도 없으면 읽지 못한 것으로 본다
        let future = #"{"conversation_id":"c_1","replies":[{"text":"확인했어요."}],"action":{"type":"schedule"}}"#
        #expect(try AgentHTTPClient.decodeReply(data: Data(future.utf8), status: 200).action == AgentReply.Action.none)
        let empty = #"{"conversation_id":"c_1","replies":[],"action":{"type":"schedule"}}"#
        #expect(throws: AgentError.invalidResponse) { try AgentHTTPClient.decodeReply(data: Data(empty.utf8), status: 200) }
    }

    @Test func errorsKeepTheirMeaning() {
        let busy = Data(#"{"error":{"code":"busy","message":"대기열이 찼습니다"}}"#.utf8)
        #expect(throws: AgentError.busy) { try AgentHTTPClient.decodeReply(data: busy, status: 429) }
        let model = Data(#"{"error":{"code":"model_error","message":"모델이 답하지 못했습니다"}}"#.utf8)
        #expect(throws: AgentError.server("모델이 답하지 못했습니다")) { try AgentHTTPClient.decodeReply(data: model, status: 502) }
    }

    @Test func recentClaudeAnswerComesFirstInContext() {
        let request = AskRequest(question: "q", history: [],
                                 meetings: [.init(ref: "m1", title: "주간 회의", date: "11월 10일", summary: nil, utterances: [])],
                                 otherMeetings: [])
        let text = AgentContext.text(from: request, recent: [.init(role: .user, text: "출시일은?"), .init(role: .assistant, text: "12월 3일")])
        #expect(text?.hasPrefix("## 방금 나눈 회의 질문과 답\n질문: 출시일은?\n답: 12월 3일") == true)
        #expect(text?.contains("## 주간 회의 (11월 10일)") == true)
    }
}
