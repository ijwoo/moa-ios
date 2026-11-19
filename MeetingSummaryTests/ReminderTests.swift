import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

struct DueDateSuggesterTests {
    let calendar = DueDateSuggester.koreanCalendar
    /// 2026-11-10 (화) 오후
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15))! }

    private func day(_ text: String?) -> String? {
        DueDateSuggester.suggest(from: text, now: now, calendar: calendar).map {
            let c = calendar.dateComponents([.month, .day], from: $0)
            return "\(c.month!)/\(c.day!)"
        }
    }

    @Test func relativeDays() {
        #expect(day("오늘") == "11/10")
        #expect(day("내일까지") == "11/11")
        #expect(day("모레") == "11/12")
    }

    @Test func weekdays() {
        #expect(day("금요일") == "11/13")
        #expect(day("금요일 오전까지") == "11/13")
        #expect(day("이번 주 금요일") == "11/13")
        #expect(day("화요일") == "11/10")        // 오늘이 화요일
        #expect(day("월요일") == "11/16")        // 이번 주 월요일은 지났으므로 다음 월요일
        #expect(day("다음 주 화요일") == "11/17")
        #expect(day("다음주 월요일") == "11/16")
    }

    @Test func explicitDatesAndMonthEnd() {
        #expect(day("12월 3일") == "12/3")
        #expect(day("이달 말까지") == "11/30")
        #expect(day("이번 달 말") == "11/30")
    }

    @Test func ambiguousTextHasNoSuggestion() {
        #expect(day("다음 주 안") == nil)
        #expect(day("출시 전") == nil)
        #expect(day(nil) == nil)
        #expect(day("") == nil)
    }
}

@MainActor
final class FakeReminderStore: ReminderStore {
    var isAuthorized = true
    var isDenied = false
    var grantOnRequest = true
    var reminders: [String: (title: String, notes: String?, due: Date?, completed: Bool)] = [:]
    private var nextID = 0

    func requestAccess() async -> Bool {
        isAuthorized = grantOnRequest
        isDenied = !grantOnRequest
        return grantOnRequest
    }

    func create(title: String, notes: String?, due: Date?) throws -> String {
        nextID += 1
        let id = "r\(nextID)"
        reminders[id] = (title, notes, due, false)
        return id
    }

    func isCompleted(_ identifier: String) -> Bool? { reminders[identifier]?.completed }

    func setCompleted(_ identifier: String, _ completed: Bool) throws {
        reminders[identifier]?.completed = completed
    }
}

@MainActor
struct ReminderServiceTests {
    let store = FakeReminderStore()
    let service: ReminderService
    let items: [ActionItem]

    init() {
        service = ReminderService(store: store)
        items = [
            ActionItem(task: "디자인 최종본 전달", owner: "김지원", dueText: "금요일", order: 0),
            ActionItem(task: "부하 테스트", order: 1),
        ]
    }

    @Test func addsWithNotesAndConfirmedDate() async throws {
        let friday = Date(timeIntervalSince1970: 1_800_000_000)
        let count = try await service.add([.init(item: items[0], due: friday), .init(item: items[1], due: nil)], meetingTitle: "주간 회의")
        #expect(count == 2)
        let allAdded = items.allSatisfy { $0.isAddedToReminders }
        #expect(allAdded)
        let first = try #require(store.reminders[items[0].reminderIdentifier!])
        #expect(first.title == "디자인 최종본 전달")
        #expect(first.due == friday)
        #expect(first.notes?.contains("회의: 주간 회의") == true)
        #expect(first.notes?.contains("담당: 김지원") == true)
        #expect(store.reminders[items[1].reminderIdentifier!]?.due == nil)
        #expect(items[0].dueDate == friday)
    }

    @Test func doesNotAddTwice() async throws {
        try await service.add([.init(item: items[0], due: nil)], meetingTitle: "회의")
        let again = try await service.add([.init(item: items[0], due: nil)], meetingTitle: "회의")
        #expect(again == 0)
        #expect(store.reminders.count == 1)
    }

    @Test func reAddsWhenDeletedInRemindersApp() async throws {
        try await service.add([.init(item: items[0], due: nil)], meetingTitle: "회의")
        store.reminders.removeAll()
        #expect(service.sync(items) == 1)
        #expect(!items[0].isAddedToReminders)
        #expect(items[0].reminderIdentifier == nil)
        let readded = try await service.add([.init(item: items[0], due: nil)], meetingTitle: "회의")
        #expect(readded == 1)
    }

    @Test func completingInAppCompletesReminder() async throws {
        try await service.add([.init(item: items[0], due: nil)], meetingTitle: "회의")
        service.setCompleted(items[0], true)
        #expect(items[0].isCompleted)
        #expect(items[0].completedAt != nil)
        #expect(store.reminders[items[0].reminderIdentifier!]?.completed == true)
        service.setCompleted(items[0], false)
        #expect(store.reminders[items[0].reminderIdentifier!]?.completed == false)
    }

    @Test func completingInRemindersAppSyncsBack() async throws {
        try await service.add([.init(item: items[0], due: nil)], meetingTitle: "회의")
        try store.setCompleted(items[0].reminderIdentifier!, true)
        #expect(service.sync(items) == 1)
        #expect(items[0].isCompleted)
        #expect(service.sync(items) == 0) // 이미 맞춰짐
    }

    @Test func completingUnregisteredItemOnlyChangesApp() {
        service.setCompleted(items[1], true)
        #expect(items[1].isCompleted)
        #expect(store.reminders.isEmpty)
    }

    @Test func deniedPermissionThrows() async {
        store.isAuthorized = false
        store.grantOnRequest = false
        await #expect(throws: ReminderService.ReminderError.self) {
            try await service.add([.init(item: items[0], due: nil)], meetingTitle: "회의")
        }
        #expect(!items[0].isAddedToReminders)
    }
}
