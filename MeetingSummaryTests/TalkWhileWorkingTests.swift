import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

/// 작업 중 말 걸기 (D71): 맡긴 일이 진행되는 동안에도 말을 보내고, 다른 일을 또 맡길 수 있다.
/// 소식(승인 요청, 결과)이 오면 작업 카드는 그 뒤에 나눈 말들 아래로 내려온다.
/// 여기의 대화·가게·물건은 모두 가상의 것이다
@MainActor
@Suite("작업 중 말 걸기: 일이 진행되는 동안에도 대화한다")
struct TalkWhileWorkingTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private static let mailRequest = "팀에게 주간 회의 메일 초안 써줘"
    private static let findRequest = "소리콩 2 가격 찾아줘"

    private func mac() -> MockAgentClient {
        MockAgentClient(v2: true, dialogCloud: MockDialogCloud(marksWriter: true, findsPages: true))
    }

    /// `poll`: 작업 상태를 묻는 간격. 길게 두면 그동안 작업은 "진행 중"에 머문다 (가짜 맥은 물을 때마다 한 단계씩 나아간다)
    private func session(_ agent: MockAgentClient, poll: Duration = .milliseconds(100)) -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: poll, weather: MockWeatherService())
        session.attach(context)
        return session
    }

    /// 조건이 될 때까지 잠깐씩 기다린다 (다른 일이 진행되게 자리를 비켜 준다)
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<5000 where !condition() { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }

    /// 일을 맡기고, 카드가 뜬 뒤(답은 받았고 작업은 진행 중)에 돌아온다
    private func entrust(_ request: String, to session: AskSession) async throws -> (work: Task<Void, Never>, id: String) {
        let before = Set(session.messages.compactMap { $0.agent?.id })
        let work = Task { await session.send(request, meetings: []) }
        try await wait { !session.isLoading && session.messages.contains { $0.agent.map { !before.contains($0.id) } ?? false } }
        let id = try #require(session.messages.last { $0.agent.map { !before.contains($0.id) } ?? false }?.agent?.id)
        return (work, id)
    }

    private func roles(_ session: AskSession) -> [AskSession.Message.Role] { session.messages.map(\.role) }

    // MARK: - 말 걸기

    @Test func iCanTalkWhileATaskRuns() async throws {
        let agent = mac()
        let session = session(agent)
        let (work, id) = try await entrust(Self.mailRequest, to: session)

        // 답은 받았다: 작업은 진행 중이지만 보낼 수 있다
        #expect(session.isFollowing(id))
        #expect(!session.isLoading)
        #expect(!session.showsThinking)
        #expect(session.status == .working)
        #expect(session.requestBlocker == nil)
        // 작업이 도는 중에도 다른 대화로 옮길 수 있다 (D126. 떠나면 그 작업은 사이드바의 "진행 중"으로)
        #expect(session.canSwitchConversation)
        let card = try #require(session.messages.last)
        #expect(card.agent?.ack == "네, 회의 공유 메일 초안 준비할게요.")

        await session.send("안녕", meetings: [])
        #expect(roles(session) == [.user, .agent, .user, .assistant])
        #expect(session.messages[1].agent?.phase == .running)
        #expect(await agent.received.map(\.text) == [Self.mailRequest, "안녕"])

        // 승인 요청이 오면 카드가 방금 나눈 말들 아래로 내려온다. 맡았다는 한 마디는 맡긴 자리에 남는다
        await work.value
        #expect(roles(session) == [.user, .assistant, .user, .assistant, .agent])
        #expect(session.messages[1].text == "네, 회의 공유 메일 초안 준비할게요.")
        #expect(session.messages[1].engine == .local)
        let moved = try #require(session.messages.last)
        #expect(moved.id == card.id)
        #expect(moved.agent?.phase == .awaitingApproval)
        #expect(moved.agent?.ack == nil)
        #expect(moved.agent?.request == Self.mailRequest)
        #expect(session.hasPendingApproval)
        #expect(!session.isFollowing(id))
        #expect(session.canSwitchConversation)
        #expect(!session.isBusy(moved))
    }

    @Test func theCardStaysWhenNothingCameAfterIt() async throws {
        let session = session(mac(), poll: .zero)
        await session.send(Self.findRequest, meetings: [])
        #expect(roles(session) == [.user, .agent])
        let card = try #require(session.messages.last?.agent)
        #expect(card.phase == .done)
        #expect(card.ack == "네, 찾아볼게요.")
        #expect(card.ackBy == ReplyWriter.claude.rawValue)
    }

    @Test func theAckKeepsWhoWroteIt() async throws {
        let session = session(mac())
        let (work, _) = try await entrust(Self.findRequest, to: session)
        await session.send("안녕", meetings: [])
        await work.value
        #expect(roles(session) == [.user, .assistant, .user, .assistant, .agent])
        #expect(session.messages[1].writer == .claude)
        #expect(AskSession.marksClaude(at: 1, in: session.messages))
        #expect(session.messages.last?.agent?.phase == .done)
        #expect(session.messages.last?.agent?.ackBy == nil)
    }

    @Test func twoTasksRunTogether() async throws {
        let agent = mac()
        let session = session(agent)
        let (mail, mailID) = try await entrust(Self.mailRequest, to: session)
        let (find, findID) = try await entrust(Self.findRequest, to: session)
        #expect(mailID != findID)
        #expect(session.isFollowing(mailID) && session.isFollowing(findID))
        #expect(roles(session) == [.user, .agent, .user, .agent])

        await mail.value
        await find.value
        let cards = session.messages.compactMap(\.agent)
        #expect(cards.first { $0.id == mailID }?.phase == .awaitingApproval)
        #expect(cards.first { $0.id == findID }?.phase == .done)
        #expect(!session.isFollowing(mailID) && !session.isFollowing(findID))
        // 먼저 온 소식(승인 요청)이 위, 나중에 온 소식(찾은 결과)이 아래. 맡았다는 말은 각자 맡긴 자리에 남는다
        #expect(roles(session) == [.user, .assistant, .user, .assistant, .agent, .agent])
        #expect(session.messages.suffix(2).map { $0.agent?.id } == [mailID, findID])
        #expect(session.messages[3].text == "네, 찾아볼게요.")
        // 부탁은 저마다 제 말만 적는다
        #expect(cards.first { $0.id == mailID }?.request == Self.mailRequest)
        #expect(cards.first { $0.id == findID }?.request == Self.findRequest)
    }

    // MARK: - 카드가 놓이는 자리

    @Test func newsWaitsBehindMyUnansweredMessage() async throws {
        let agent = mac()
        let session = session(agent)
        let (work, id) = try await entrust(Self.findRequest, to: session)
        await session.send("안녕", meetings: [])
        // 답을 받지 못한 말: 다시 시도 말풍선이 붙는다
        await agent.failNextMessage(.invalidResponse)
        await session.send("오늘 피곤하다", meetings: [])
        #expect(roles(session) == [.user, .agent, .user, .assistant, .user, .error])

        await work.value
        // 결과는 답을 기다리는 내 말 앞에 놓인다. 내 말의 다시 시도 말풍선은 지워지지 않는다
        #expect(roles(session) == [.user, .assistant, .user, .assistant, .agent, .user, .error])
        #expect(session.messages[4].agent?.id == id)
        #expect(session.messages[4].agent?.phase == .done)
        #expect(session.messages.last?.retryQuestion == "오늘 피곤하다")

        // 다시 보내면 같은 말풍선으로 답을 받는다 (새 말이 하나 더 생기지 않는다)
        await session.send("오늘 피곤하다", meetings: [])
        #expect(roles(session) == [.user, .assistant, .user, .assistant, .agent, .user, .assistant])
    }

    @Test func theOrderSurvivesReopening() async throws {
        let agent = mac()
        let session = session(agent)
        let (work, id) = try await entrust(Self.findRequest, to: session)
        await session.send("안녕", meetings: [])
        await agent.failNextMessage(.invalidResponse)
        await session.send("오늘 피곤하다", meetings: [])
        await work.value
        try context.save()

        let reopened = self.session(agent, poll: .zero)
        // 오류 말풍선은 저장하지 않는다
        #expect(roles(reopened) == [.user, .assistant, .user, .assistant, .agent, .user])
        #expect(reopened.messages.map(\.text).prefix(4) == [Self.findRequest, "네, 찾아볼게요.", "안녕", session.messages[3].text])
        #expect(reopened.messages[1].writer == .claude)
        #expect(reopened.messages[4].agent?.id == id)
        #expect(reopened.messages[4].agent?.ack == nil)
        #expect(reopened.messages[5].text == "오늘 피곤하다")
        // 시각도 그 순서다
        let dates = reopened.messages.map(\.date)
        #expect(dates == dates.sorted())
    }

    @Test func aCardAtTheBottomKeepsItsOrderAfterReopening() async throws {
        let agent = mac()
        let session = session(agent)
        let (work, id) = try await entrust(Self.mailRequest, to: session)
        await session.send("안녕", meetings: [])
        await work.value
        try context.save()

        let reopened = self.session(agent, poll: .zero)
        #expect(roles(reopened) == [.user, .assistant, .user, .assistant, .agent])
        #expect(reopened.messages.last?.agent?.id == id)
        #expect(reopened.hasPendingApproval)
    }

    @Test func myStopIsNotNews() async throws {
        let session = session(mac(), poll: .seconds(5))
        let (work, id) = try await entrust(Self.mailRequest, to: session)
        await session.send("안녕", meetings: [])
        await session.cancelAgent(id)
        work.cancel()
        await work.value
        // 내가 멈춘 카드는 맡긴 자리에 그대로 있다
        #expect(roles(session) == [.user, .agent, .user, .assistant])
        #expect(session.messages[1].agent?.phase == .canceled)
        #expect(session.messages[1].agent?.ack != nil)
    }

    @Test func onlyNewsMovesACard() {
        func state(_ phase: AgentTaskState.Phase) -> AgentTaskState { AgentTaskState(id: "t_1", task: "가상 작업", steps: [], phase: phase) }
        let running = state(.running)
        #expect(AskSession.isNews(state(.done), after: running))
        #expect(AskSession.isNews(state(.failed), after: running))
        #expect(AskSession.isNews(state(.needsInput), after: running))
        #expect(AskSession.isNews(state(.awaitingApproval), after: running))
        // 진행 상황, 보내기 전 기다림, 내가 멈춘 것은 소식이 아니다
        #expect(!AskSession.isNews(running, after: running))
        #expect(!AskSession.isNews(state(.sendPending), after: state(.awaitingApproval)))
        #expect(!AskSession.isNews(state(.canceled), after: running))
        // 같은 상태를 다시 받은 것도 아니다 (화면으로 돌아와 다시 확인할 때)
        #expect(!AskSession.isNews(state(.done), after: state(.done)))
        #expect(!AskSession.isNews(state(.awaitingApproval), after: state(.awaitingApproval)))

        // 질문: 새 질문만 소식이다. 내가 답해 맥이 받은 질문은 아니다
        var asking = state(.awaitingInput)
        asking.pendingQuestion = AgentQuestion(id: "q_1", text: "참조에는 누구를 넣을까요?", choices: [])
        #expect(AskSession.isNews(asking, after: running))
        #expect(!AskSession.isNews(asking, after: asking))
        var received = asking
        received.pendingQuestion?.received = true
        #expect(!AskSession.isNews(received, after: asking))
        var next = asking
        next.pendingQuestion = AgentQuestion(id: "q_2", text: "제목은 무엇으로 할까요?", choices: [])
        #expect(AskSession.isNews(next, after: received))
    }

    // MARK: - 다시 열었을 때

    @Test func everyUnfinishedTaskIsPickedUpAgain() async throws {
        let agent = mac()
        let session = session(agent, poll: .seconds(5))
        let (mail, mailID) = try await entrust(Self.mailRequest, to: session)
        let (find, findID) = try await entrust(Self.findRequest, to: session)
        try context.save()

        // 앱을 다시 연 것처럼: 끝나지 않은 작업 둘을 모두 이어서 확인한다
        let reopened = self.session(agent, poll: .zero)
        #expect(reopened.messages.compactMap(\.agent).map(\.phase) == [.running, .running])
        await reopened.resumeAgent()
        let cards = reopened.messages.compactMap(\.agent)
        #expect(cards.first { $0.id == mailID }?.phase == .awaitingApproval)
        #expect(cards.first { $0.id == findID }?.phase == .done)
        #expect(!reopened.isFollowing(mailID) && !reopened.isFollowing(findID))

        mail.cancel()
        find.cancel()
        await mail.value
        await find.value
    }

    @Test func aCardFromTheHiddenPartComesDown() async throws {
        let agent = mac()
        let session = session(agent, poll: .seconds(5))
        let (work, id) = try await entrust(Self.findRequest, to: session)
        // 일이 진행되는 동안 말을 많이 나눴다
        for _ in 0..<35 { await session.send("안녕", meetings: []) }
        #expect(session.messages.count == 72)
        try context.save()

        let reopened = self.session(agent, poll: .zero)
        #expect(reopened.messages.count == 72)
        // 긴 대화는 최근 것만 그린다: 카드는 아직 그리지 않은 앞쪽에 있다
        #expect(reopened.earlierCount == 12)
        await reopened.resumeAgent()
        // 결과가 오면 맨 아래에 그려진다. 맡았다는 말이 그 자리에 남아, 그리지 않은 말의 수는 그대로다
        #expect(reopened.messages.count == 73)
        #expect(reopened.messages.last?.agent?.id == id)
        #expect(reopened.messages.last?.agent?.phase == .done)
        #expect(reopened.messages[1].role == .assistant)
        #expect(reopened.earlierCount == 12)

        work.cancel()
        await work.value
    }

    // MARK: - 답해야 하는 일은 전과 같다

    @Test func approvalStillComesFirst() async throws {
        let agent = mac()
        let session = session(agent, poll: .zero)
        await session.send(Self.mailRequest, meetings: [])
        #expect(session.hasPendingApproval)
        // 승인 요청에 답하기 전에는 새 말을 보내지 않는다
        await session.send("안녕", meetings: [])
        #expect(await agent.received.count == 1)
        #expect(roles(session) == [.user, .agent])
    }

    @Test func iCanTalkAfterApprovingWhileItFinishes() async throws {
        let agent = mac()
        let session = session(agent)
        let (work, id) = try await entrust(Self.mailRequest, to: session)
        await work.value
        #expect(session.hasPendingApproval)

        let deciding = Task { await session.decide(id, approve: true) }
        try await wait { !session.isLoading && session.messages.contains { $0.agent?.id == id && $0.agent?.phase == .running } }
        // 승인은 전달됐고 맥이 마무리하는 중이다: 그동안 말을 보낼 수 있다
        #expect(session.isFollowing(id))
        await session.send("안녕", meetings: [])
        #expect(roles(session) == [.user, .agent, .user, .assistant])

        await deciding.value
        // 끝났다는 소식에 카드가 다시 내려온다. 맡았다는 말은 처음 맡긴 자리에 남는다
        #expect(roles(session) == [.user, .assistant, .user, .assistant, .agent])
        #expect(session.messages.last?.agent?.phase == .done)
        #expect(!session.isFollowing(id))
    }
}
