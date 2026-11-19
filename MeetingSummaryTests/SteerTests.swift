import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 작업 중 끼어들기와 줄 선 까닭 (D152, 맥의 D132). 말은 모두 지어낸 것이다.

@Suite("끼어들기: 응답 해석")
struct SteerDecodingTests {
    private func reply(_ json: String) throws -> AgentReply {
        try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200)
    }

    @Test func aSteerActionPointsAtTheRunningTask() throws {
        let reply = try reply(#"{"conversation_id":"c1","replies":[{"text":"지금 만드는 작업에 전했어요."}],"action":{"type":"steer","task_id":"t_run1","mode":"inject"}}"#)
        #expect(reply.action == .none)
        #expect(reply.replies == ["지금 만드는 작업에 전했어요."])
        #expect(reply.steer == AgentSteer(taskID: "t_run1", mode: .inject))
        #expect(reply.steer?.note == "진행 중인 작업에 전했어요")
    }

    @Test func aTaskWithSteerReplacedTheOldOne() throws {
        let json = #"{"conversation_id":"c1","replies":[{"text":"앞 승인은 거두고 새로 시작해요."}],"action":{"type":"task","task":{"id":"t_new","status":"queued","task":"보고서"},"steer":{"task_id":"t_old","mode":"replace"}}}"#
        let reply = try reply(json)
        guard case .task(let state) = reply.action else {
            Issue.record("작업 행동이어야 한다")
            return
        }
        #expect(state.id == "t_new")
        #expect(reply.steer == AgentSteer(taskID: "t_old", mode: .replace))
    }

    @Test func unsafeOrMissingIDsAreIgnored() throws {
        let unsafe = try reply(#"{"conversation_id":"c1","replies":[{"text":"전했어요."}],"action":{"type":"steer","task_id":"../x","mode":"inject"}}"#)
        #expect(unsafe.steer == nil)
        #expect(unsafe.replies == ["전했어요."])
        let broken = try reply(#"{"conversation_id":"c1","replies":[{"text":"시작해요."}],"action":{"type":"task","task":{"id":"t2","status":"running","task":"x"},"steer":"t_old"}}"#)
        #expect(broken.steer == nil)
        // 예전 맥(steer 없음)은 그대로
        let plain = try reply(#"{"conversation_id":"c1","replies":[{"text":"네"}],"action":{"type":"none"}}"#)
        #expect(plain.steer == nil)
    }

    @Test func taskStateCarriesSteersAndWaitReason() throws {
        let json = #"{"id":"t1","status":"queued","task":"사이트 조회","wait_reason":"브라우저를 쓰는 앞 작업이 끝나면 시작해요","steers":[{"time":"2026-11-19T00:10:00Z","text":"그래프는 막대로 바꿔 줘","applied":true},{"text":"  "},7]}"#
        let state = try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
        #expect(state.isQueued)
        #expect(state.waitReason == "브라우저를 쓰는 앞 작업이 끝나면 시작해요")
        #expect(state.currentStatus == "브라우저를 쓰는 앞 작업이 끝나면 시작해요")
        #expect(state.steers == [AgentSteerNote(time: "2026-11-19T00:10:00Z", text: "그래프는 막대로 바꿔 줘", applied: true)])
    }

    @Test func waitReasonOnlyWhileQueued() throws {
        let running = try AgentHTTPClient.decodeTask(data: Data(#"{"id":"t1","status":"running","task":"x","wait_reason":"이유"}"#.utf8), status: 200)
        #expect(running.waitReason == nil)
        let old = try AgentHTTPClient.decodeTask(data: Data(#"{"id":"t1","status":"queued","task":"x"}"#.utf8), status: 200)
        #expect(old.currentStatus == "앞 작업이 끝나기를 기다리고 있어요")
    }
}

@MainActor
@Suite("끼어들기: 대화")
struct SteerSessionTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    @Test func aChangeDuringARunningTaskGoesToThatTask() async throws {
        let agent = MockAgentClient(v2: true)
        await agent.enableReport()
        await agent.enableSteer()
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .milliseconds(30))
        session.attach(context)
        let sending = Task { await session.send("가상 자료로 보고서 만들어 줘", meetings: []) }
        for _ in 0..<100 where session.messages.first(where: { $0.agent?.phase == .running }) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let task = try #require(session.messages.compactMap(\.agent).first)
        await session.send("그래프는 막대로 바꿔 줘", meetings: [])
        // 새 작업이 생기지 않고, 내 말에 그 작업으로 갔다는 표시가 붙는다
        #expect(session.messages.compactMap(\.agent).count == 1)
        let mine = try #require(session.messages.last { $0.role == .user })
        #expect(mine.steer == AgentSteer(taskID: task.id, mode: .inject))
        // 다음 조회에서 반영된다
        for _ in 0..<100 where session.messages.compactMap(\.agent).first?.steers?.last?.applied != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.messages.compactMap(\.agent).first?.steers?.last?.applied == true)
        sending.cancel()
    }

    @Test func aSteeredMessageKeepsRoomBelowIt() {
        var mine = AskSession.Message(role: .user, text: "줄여 줘", engine: .local)
        mine.steer = AgentSteer(taskID: "t1", mode: .inject)
        #expect(AskView.spacing(previous: mine, current: AskSession.Message(role: .user, text: "또", engine: .local)) == DS.Chat.blockSpacing)
    }
}
