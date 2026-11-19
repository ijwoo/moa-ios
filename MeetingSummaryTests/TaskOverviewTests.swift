import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import MeetingSummary

@MainActor
struct TaskOverviewTests {
    let context: ModelContext
    let calendar = DueDateSuggester.koreanCalendar
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 10))! }

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: d))! }

    @Test func countsOnlyTasksBelongingToMeetings() {
        let meeting = Meeting(title: "회의")
        context.insert(meeting)
        let done = ActionItem(task: "완료한 일", order: 0); done.isCompleted = true; done.isAddedToReminders = true
        let late = ActionItem(task: "기한 지난 일", dueText: "월요일", dueDate: day(10), order: 1)
        let textOnly = ActionItem(task: "원문 기한만", dueText: "어제", order: 2)
        let linked = ActionItem(task: "미리알림 연결", order: 3); linked.isAddedToReminders = true
        meeting.summary = Summary(topic: "t", body: "b", actionItems: [done, late, textOnly, linked])
        let orphan = ActionItem(task: "회의 없는 일")
        context.insert(orphan)

        let overview = TaskOverview(items: [done, late, textOnly, linked, orphan], now: now, calendar: calendar)
        #expect(overview.total == 4)
        #expect(overview.completed == 1)
        #expect(overview.open == 3)
        #expect(overview.linkedToReminders == 2)
        #expect(overview.pendingReminderItems.map(\.task) == ["기한 지난 일", "원문 기한만"])
        // 확정 날짜가 있는 것만 기한 지남. "어제" 같은 원문은 추측하지 않는다
        #expect(overview.overdue == 1)
        #expect(abs(overview.progress - 0.25) < 0.0001)
    }

    @Test func todayIsNotOverdueAndCompletedIsNever() {
        let item = ActionItem(task: "오늘까지", dueDate: day(11))
        #expect(!TaskOverview.isOverdue(item, now: now, calendar: calendar))
        let past = ActionItem(task: "지남", dueDate: day(9))
        #expect(TaskOverview.isOverdue(past, now: now, calendar: calendar))
        past.isCompleted = true
        #expect(!TaskOverview.isOverdue(past, now: now, calendar: calendar))
    }

    @Test func emptyOverviewHasNoTasks() {
        let overview = TaskOverview(items: [])
        #expect(!overview.hasTasks)
        #expect(overview.progress == 0)
    }

    @Test func appearanceModeMapsToColorScheme() {
        #expect(AppearanceMode.system.colorScheme == nil)
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)
        #expect(AppearanceMode(rawValue: "dark") == .dark)
    }
}
