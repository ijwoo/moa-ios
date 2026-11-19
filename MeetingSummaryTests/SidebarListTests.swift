import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 사이드바의 대화 목록 (D116): 날짜 묶음, 고정, 찾기, 시각, 미리보기, 상태 표시. 모두 지어낸 값이다.

private struct FakeItem: SidebarDated, Identifiable {
    let id: String
    var title: String
    var updatedAt: Date
    var isPinned = false
    var previewText: String?
}

@Suite("사이드바: 대화 묶음과 찾기")
struct SidebarListTextTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func conversationsFallIntoDayGroupsWithPinnedFirst() {
        let now = date(2026, 11, 17, 10)
        let items = [
            FakeItem(id: "a", title: "오늘 것", updatedAt: date(2026, 11, 17, 9)),
            FakeItem(id: "b", title: "어제 것", updatedAt: date(2026, 11, 16, 23)),
            FakeItem(id: "c", title: "사흘 전", updatedAt: date(2026, 11, 14)),
            FakeItem(id: "d", title: "보름 전", updatedAt: date(2026, 11, 2)),
            FakeItem(id: "e", title: "작년", updatedAt: date(2025, 10, 1)),
            FakeItem(id: "f", title: "고정한 옛것", updatedAt: date(2025, 1, 1), isPinned: true),
            FakeItem(id: "g", title: "오늘 더 최근", updatedAt: date(2026, 11, 17, 9, 30)),
        ]
        let sections = SidebarText.sections(items, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["고정됨", "오늘", "어제", "지난 7일", "지난 30일", "이전"])
        #expect(sections[1].items.map(\.id) == ["g", "a"])
        #expect(sections[0].items.map(\.id) == ["f"])
        // 빈 묶음은 빠진다
        #expect(SidebarText.sections([items[0]], now: now, calendar: calendar).map(\.title) == ["오늘"])
    }

    @Test func searchLooksAtTitleAndPreview() {
        let items = [
            FakeItem(id: "a", title: "번개 보고서", updatedAt: date(2026, 11, 17)),
            FakeItem(id: "b", title: "결제내역 알려줘", updatedAt: date(2026, 11, 16), previewText: "최근 결제 3건이에요"),
            FakeItem(id: "c", title: "Weekly Sync", updatedAt: date(2026, 11, 15)),
        ]
        #expect(SidebarText.matching(items, query: " 번개 ").map(\.id) == ["a"])
        #expect(SidebarText.matching(items, query: "결제").map(\.id) == ["b"])
        #expect(SidebarText.matching(items, query: "weekly").map(\.id) == ["c"])
        #expect(SidebarText.matching(items, query: "  ").isEmpty)
    }

    @Test func rowTimeIsShortForToday() {
        let now = date(2026, 11, 17, 10)
        #expect(SidebarText.rowTime(date(2026, 11, 17, 9, 27), now: now, calendar: calendar) == "오전 9:27")
        #expect(SidebarText.rowTime(date(2026, 11, 16, 9), now: now, calendar: calendar) == "어제")
        #expect(SidebarText.rowTime(date(2026, 11, 10), now: now, calendar: calendar) == "11월 10일")
        #expect(SidebarText.rowTime(date(2025, 11, 10), now: now, calendar: calendar).hasPrefix("2025"))
    }

    @Test func previewsAreOneShortLine() {
        #expect(Conversation.snippet("첫 줄\n\n  둘째 줄  ") == "첫 줄 둘째 줄")
        #expect(Conversation.snippet(String(repeating: "가", count: 100)).count == 80)
    }
}

@MainActor
@Suite("사이드바: 대화 고치기와 상태")
struct SidebarListSessionTests {
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

    @Test func oldConversationsFindTheirPreviewInTheRecords() {
        let conversation = Conversation(title: "예전 대화")
        context.insert(conversation)
        #expect(conversation.previewText == nil)
        let first = ChatRecord(role: "user", text: "처음 말", createdAt: .now.addingTimeInterval(-60))
        let last = ChatRecord(role: "assistant", text: "마지막\n답", createdAt: .now)
        let empty = ChatRecord(role: "agent", text: "", createdAt: .now.addingTimeInterval(60))
        conversation.records = [first, last, empty]
        #expect(conversation.previewText == "마지막 답")
        conversation.preview = "저장한 미리보기"
        #expect(conversation.previewText == "저장한 미리보기")
    }

    @Test func renamingAndPinningAreKept() async throws {
        let session = await session(MockAgentClient(v2: true))
        let conversation = Conversation(title: "안녕 1")
        context.insert(conversation)
        session.rename(conversation, to: "  번개 보고서 만들기  ")
        #expect(conversation.title == "번개 보고서 만들기")
        session.rename(conversation, to: "   ")
        #expect(conversation.title == "번개 보고서 만들기")
        session.setPinned(conversation, true)
        let stored = try context.fetch(FetchDescriptor<Conversation>()).first { $0.id == conversation.id }
        #expect(stored?.isPinned == true)
    }

    @Test func aMacConversationWaitingForApprovalIsMarked() async throws {
        let agent = MockAgentClient(v2: true)
        let session = await session(agent)
        let task = await agent.seedMacTask(conversationID: "c_mac_9")
        // 기기에 저장된 그 대화 (지금 보고 있지 않다)
        _ = await session.openTaskInItsConversation(id: task, conversationID: "c_mac_9")
        let stored = try #require(session.conversation)
        // 지금 대화에서는 그 대화의 승인 카드로 안다
        #expect(session.sidebarBadge(for: stored) == .approval)
        session.reset()
        #expect(session.sidebarBadge(for: stored) == nil)
        // 맥이 알려 준 기다리는 작업으로 안다
        await session.checkWaitingTasks()
        #expect(session.sidebarBadge(for: stored) == .approval)
        #expect(AskSession.SidebarBadge.approval.text == "승인 필요")
    }

    @Test func sendingUpdatesTheSavedPreview() async throws {
        let session = await session(MockAgentClient(v2: true))
        await session.send("안녕", meetings: [])
        let conversation = try #require(session.conversation)
        let preview = try #require(conversation.preview)
        #expect(!preview.isEmpty)
        #expect(preview == Conversation.snippet(session.messages.last { !$0.text.isEmpty }?.text ?? ""))
    }
}
