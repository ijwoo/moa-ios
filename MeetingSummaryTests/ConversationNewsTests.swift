import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 작업 중에도 대화 옮기기, 떠난 대화의 "진행 중"과 안 읽음 점 (D126). 모두 지어낸 말이다.

@MainActor
@Suite("대화: 작업 중에 옮기기와 안 읽음")
struct ConversationNewsTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    /// 보고서 만들기를 맡기고, 작업이 돌기 시작할 때까지 기다린다
    private func runningReport() async throws -> (AskSession, MockAgentClient, Task<Void, Never>, String) {
        let agent = MockAgentClient(v2: true)
        await agent.enableReport()
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .milliseconds(30))
        session.attach(context)
        let sending = Task { await session.send("가상 자료로 보고서 만들어 줘", meetings: []) }
        for _ in 0..<100 where session.messages.first(where: { $0.agent != nil }) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let task = try #require(session.messages.compactMap(\.agent).first)
        return (session, agent, sending, task.id)
    }

    @Test func aRunningTaskNoLongerBlocksSwitching() async throws {
        let (session, _, sending, taskID) = try await runningReport()
        defer { sending.cancel() }
        #expect(session.isFollowing(taskID))
        // 작업이 도는 중에도 옮길 수 있다
        #expect(session.canSwitchConversation)
        let first = try #require(session.conversation)
        session.reset()
        // 떠난 대화의 작업은 "진행 중"으로 남는다
        #expect(session.workingElsewhere == 1)
        #expect(session.sidebarBadge(for: first) == .working)
        // 새 대화에서는 따라가지 않는다
        #expect(!session.isFollowing(taskID))
    }

    @Test func aTaskThatFinishedWhileAwayLeavesAnUnreadDot() async throws {
        let (session, agent, sending, taskID) = try await runningReport()
        let first = try #require(session.conversation)
        session.reset()
        sending.cancel()
        // 떠나 있는 동안 맥에서 끝났다
        for _ in 0..<20 { _ = try? await agent.state(of: taskID) }
        #expect(try await agent.state(of: taskID).phase == .done)
        #expect(!first.hasUnread)
        await session.refreshConversationNews()
        #expect(session.workingElsewhere == 0)
        #expect(first.hasUnread)
        #expect(session.sidebarBadge(for: first) == nil)
        // 다시 열면 읽은 것이고, 끝난 결과를 맥에서 받아 붙인다
        session.open(first)
        #expect(!first.hasUnread)
        await session.resumeAgent()
        #expect(session.messages.compactMap(\.agent).first { $0.id == taskID }?.phase == .done)
    }

    @Test func comingBackQuicklyFollowsAgain() async throws {
        let (session, _, sending, taskID) = try await runningReport()
        defer { sending.cancel() }
        let first = try #require(session.conversation)
        session.reset()
        // 떠난 쪽의 따라가기가 아직 멈추는 중이어도, 돌아오면 다시 따라간다
        session.open(first)
        #expect(session.workingElsewhere == 0)
        #expect(!session.isFollowing(taskID))
        let resuming = Task { await session.resumeAgent() }
        defer { resuming.cancel() }
        for _ in 0..<100 where !session.isFollowing(taskID) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.isFollowing(taskID))
    }

    @Test func macActivityMarksOtherConversations() throws {
        let session = AskSession(provider: FakeAskProvider([]), agent: MockAgentClient(v2: true), pollInterval: .zero)
        session.attach(context)
        let away = Conversation(title: "가상 지난 대화")
        away.agentConversationID = "c_away"
        away.lastReadAt = .now.addingTimeInterval(-600)
        let here = Conversation(title: "가상 지금 대화")
        here.agentConversationID = "c_here"
        context.insert(away)
        context.insert(here)
        session.open(here)
        session.noteActivity([
            ActivityEntry(id: "t_1", kind: .task, at: .now.addingTimeInterval(-60), title: "가상 작업", status: "completed", conversationID: "c_away"),
            ActivityEntry(id: "t_2", kind: .task, at: .now, title: "가상 작업 2", status: "completed", conversationID: "c_here"),
            ActivityEntry(id: "t_3", kind: .task, at: .now.addingTimeInterval(-3600), title: "오래된 것", status: "completed", conversationID: "c_none"),
        ])
        #expect(away.hasUnread)
        // 지금 보고 있는 대화에는 점을 찍지 않는다
        #expect(!here.hasUnread)
        // 본 뒤의 소식이 아니면 점이 없다
        let old = Conversation(title: "가상 오래된 대화")
        old.agentConversationID = "c_old"
        old.lastReadAt = .now
        context.insert(old)
        session.noteActivity([ActivityEntry(id: "t_4", kind: .task, at: .now.addingTimeInterval(-60), title: "가상", status: "completed", conversationID: "c_old")])
        #expect(!old.hasUnread)
    }
}
