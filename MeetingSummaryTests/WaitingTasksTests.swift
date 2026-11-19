import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 기다리는 작업 (D113). 모두 지어낸 값이다.

@Suite("기다리는 작업: 맥이 준 것 읽기")
struct WaitingTaskDecodingTests {
    @Test func onlyTasksWaitingOnMeAreKept() throws {
        // 거르기를 모르는 맥(서버를 다시 띄우기 전)은 모든 작업을 준다
        let tasks = try AgentWaitingTask.decode(data: Data("""
        {"tasks":[
         {"id":"t_1","status":"awaiting_approval","task":"보고서 메일 보내기: 주간","title":"보고서 메일 보내기","conversation_id":"c_mac1"},
         {"id":"t_2","status":"running","task":"보고서 만들기"},
         {"id":"t_3","status":"awaiting_input","task":"어느 파일을 붙일까요?\\n둘째 줄","title":"","conversation_id":"../x"},
         {"id":"t 4","status":"awaiting_approval","task":"번호가 이상하다"},
         {"id":"t_5","status":"completed","task":"끝"},
         {"id":"t_6"}, 3]}
        """.utf8), status: 200)
        #expect(tasks.map(\.id) == ["t_1", "t_3"])
        #expect(tasks[0].isApproval && tasks[0].title == "보고서 메일 보내기" && tasks[0].conversationID == "c_mac1")
        #expect(!tasks[1].isApproval && tasks[1].title == "어느 파일을 붙일까요?" && tasks[1].conversationID == nil)
        #expect(AgentWaitingTask.statuses.joined(separator: ",") == "awaiting_approval,awaiting_input")
    }
}

@MainActor
@Suite("기다리는 작업과 맥이 만든 대화")
struct WaitingTaskChatTests {
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

    /// 실기기 2026-11-17: 맥이 만든 대화의 두 번째 승인 알림을 눌렀는데, 기기에 저장된 기록만 열려 승인 카드가 없었다
    @Test func aNewTaskInAStoredMacConversationShowsItsApprovalCard() async throws {
        let agent = MockAgentClient(v2: true)
        let session = await session(agent)
        let first = await agent.seedMacTask(conversationID: "c_mac_1", title: "예산 확인")
        #expect(await session.openTaskInItsConversation(id: first, conversationID: "c_mac_1") == .opened)
        // 그 대화는 기기에 저장됐다
        #expect(try context.fetch(FetchDescriptor<Conversation>()).contains { $0.agentConversationID == "c_mac_1" })

        // 다른 대화로 옮겨 간 뒤, 맥이 같은 대화에 새 작업을 만들었다
        session.reset()
        let second = await agent.seedMacTask(conversationID: "c_mac_1")
        #expect(await session.openTaskInItsConversation(id: second, conversationID: "c_mac_1") == .opened)
        #expect(session.agentConversationID == "c_mac_1")
        #expect(session.messages.contains { $0.agent?.id == first })
        let card = try #require(session.messages.last { $0.agent?.id == second }?.agent)
        #expect(card.phase == .awaitingApproval)
        let draft = try #require(card.draft)
        #expect(draft.fields.contains { $0.label == "본문" && $0.value.contains("\n") })
        // 승인이 맥에 간다
        await session.decide(second, approve: true)
        #expect(try await agent.waitingTasks().map(\.id) == [first])
        // 같은 작업을 다시 열어도 두 번 붙지 않는다
        #expect(await session.openTaskInItsConversation(id: second, conversationID: "c_mac_1") == .opened)
        #expect(session.messages.filter { $0.agent?.id == second }.count == 1)
    }

    @Test func aNewTaskInTheOpenConversationIsAddedToIt() async throws {
        let agent = MockAgentClient(v2: true)
        let session = await session(agent)
        let first = await agent.seedMacTask(conversationID: "c_mac_2")
        _ = await session.openTaskInItsConversation(id: first, conversationID: "c_mac_2")
        let second = await agent.seedMacTask(conversationID: "c_mac_2")
        #expect(await session.openTaskInItsConversation(id: second, conversationID: "c_mac_2") == .opened)
        #expect(session.messages.last { $0.agent != nil }?.agent?.id == second)
        #expect(session.messages.last { $0.agent != nil }?.agent?.draft != nil)
        // 맥에 없는 작업이면 아무것도 붙이지 않는다
        let count = session.messages.count
        #expect(await session.attachTask(id: "t_none") == false)
        #expect(session.messages.count == count)
    }

    @Test func waitingTasksAreListedUntilTheyAreShownHere() async throws {
        let agent = MockAgentClient(v2: true, waitingDemo: true)
        let session = await session(agent)
        await session.checkWaitingTasks()
        let waiting = try #require(session.waitingElsewhere.first)
        #expect(session.waitingElsewhere.count == 1 && waiting.isApproval && waiting.conversationID == "c_mac_workroom")
        #expect(await session.openWaiting(waiting) == .opened)
        // 지금 대화에 카드로 보이면 줄에서 빠진다
        #expect(session.waitingElsewhere.isEmpty)
        #expect(session.messages.contains { $0.agent?.id == waiting.id && $0.agent?.draft != nil })

        // "나중에"로 접으면 다시 받아도 보이지 않는다 (새로 생긴 것은 보인다)
        session.reset()
        await session.checkWaitingTasks()
        #expect(session.waitingElsewhere.map(\.id) == [waiting.id])
        session.dismissWaiting()
        await session.checkWaitingTasks()
        #expect(session.waitingElsewhere.isEmpty)
        let newer = await agent.seedMacTask(conversationID: nil)
        await session.checkWaitingTasks()
        #expect(session.waitingElsewhere.map(\.id) == [newer])
    }
}
