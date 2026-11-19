import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

@MainActor
struct SummaryDraftTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func summarizedMeeting() -> Meeting {
        let meeting = Meeting(title: "회의 11월 10일", status: .ready)
        context.insert(meeting)
        meeting.summary = Summary(
            topic: "출시", body: "일정 점검",
            decisions: ["12월 출시", "법무 검토"],
            actionItems: [
                ActionItem(task: "시안 전달", owner: "김지원", dueText: "금요일", isAddedToReminders: true, order: 0),
                ActionItem(task: "부하 테스트", order: 1),
            ],
            openQuestions: ["결제 방식"]
        )
        return meeting
    }

    @Test func untouchedDraftEqualsOriginal() {
        let meeting = summarizedMeeting()
        // 편집 화면은 처음 만든 사본(original)과 편집 중인 사본을 비교해 "수정됨"을 판단한다
        let original = SummaryDraft(meeting: meeting)
        var draft = original
        #expect(draft == original)
        draft.decisions[0].text = "12월 출시!"
        #expect(draft != original)
        draft.decisions[0].text = "12월 출시"
        #expect(draft == original)
        #expect(draft.actionItems.map(\.task) == ["시안 전달", "부하 테스트"])
        #expect(draft.actionItems[1].owner == "")
    }

    @Test func editsDeletesAndAdds() throws {
        let meeting = summarizedMeeting()
        var draft = SummaryDraft(meeting: meeting)
        draft.title = "  주간 회의  "
        draft.decisions.remove(at: 1)
        draft.decisions.append(.init(text: "다음 회의 목요일"))
        draft.actionItems[1].owner = "박민수"
        draft.actionItems.append(.init(task: "매뉴얼 수정", owner: "", due: "이달 말"))
        draft.openQuestions = []
        draft.apply(to: meeting, in: context)
        try context.save()

        #expect(meeting.title == "주간 회의")
        let summary = try #require(meeting.summary)
        #expect(summary.decisions == ["12월 출시", "다음 회의 목요일"])
        #expect(summary.openQuestions.isEmpty)
        let items = summary.sortedActionItems
        #expect(items.map(\.task) == ["시안 전달", "부하 테스트", "매뉴얼 수정"])
        #expect(items[1].owner == "박민수")
        #expect(items[2].owner == nil)     // 빈 담당자는 nil
        #expect(items[2].dueText == "이달 말")
    }

    @Test func keepsReminderStateAndClearsDateWhenDueChanges() {
        let meeting = summarizedMeeting()
        let first = meeting.summary!.sortedActionItems[0]
        first.dueDate = .now
        var draft = SummaryDraft(meeting: meeting)
        draft.actionItems[0].task = "시안 최종본 전달"
        draft.apply(to: meeting, in: context)
        #expect(first.task == "시안 최종본 전달")
        #expect(first.isAddedToReminders)     // 같은 할 일로 유지
        #expect(first.dueDate != nil)         // 기한 문구가 그대로면 날짜 유지

        draft = SummaryDraft(meeting: meeting)
        draft.actionItems[0].due = "다음 주 월요일"
        draft.apply(to: meeting, in: context)
        #expect(first.dueDate == nil)         // 기한 문구가 바뀌면 지정 날짜는 지운다
    }

    @Test func deletedItemsAreRemovedAndOrderFollowsDraft() throws {
        let meeting = summarizedMeeting()
        var draft = SummaryDraft(meeting: meeting)
        draft.actionItems.reverse()
        draft.actionItems.append(.init(task: "   "))  // 빈 줄은 버린다
        draft.actionItems.remove(at: 1)               // "시안 전달" 삭제
        draft.apply(to: meeting, in: context)
        try context.save()
        #expect(meeting.summary?.sortedActionItems.map(\.task) == ["부하 테스트"])
        #expect(try context.fetchCount(FetchDescriptor<ActionItem>()) == 1)
    }

    @Test func emptyDraftDoesNotCreateSummary() {
        let meeting = Meeting(title: "짧은 회의")
        context.insert(meeting)
        var draft = SummaryDraft(meeting: meeting)
        draft.decisions.append(.init(text: "  "))
        draft.apply(to: meeting, in: context)
        #expect(meeting.summary == nil)
    }

    @Test func manualSummaryCanBeWrittenFromScratch() {
        let meeting = Meeting(title: "짧은 회의")
        context.insert(meeting)
        var draft = SummaryDraft(meeting: meeting)
        draft.topic = "직접 쓴 요약"
        draft.actionItems.append(.init(task: "회신하기"))
        draft.apply(to: meeting, in: context)
        #expect(meeting.summary?.topic == "직접 쓴 요약")
        #expect(meeting.summary?.sortedActionItems.first?.owner == nil)
    }
}
