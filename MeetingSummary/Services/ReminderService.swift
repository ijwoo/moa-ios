import EventKit
import Foundation
import Observation

/// iOS 미리알림과 맞닿는 부분. 테스트에서 가짜로 바꿀 수 있게 프로토콜로 둔다.
@MainActor
protocol ReminderStore: AnyObject {
    var isAuthorized: Bool { get }
    var isDenied: Bool { get }
    func requestAccess() async -> Bool
    /// 새 미리알림을 만들고 식별자를 돌려준다.
    func create(title: String, notes: String?, due: Date?) throws -> String
    /// 미리알림의 완료 여부. 지워져서 없으면 nil.
    func isCompleted(_ identifier: String) -> Bool?
    func setCompleted(_ identifier: String, _ completed: Bool) throws
}

/// 할 일 ↔ 미리알림: 등록(중복 방지), 완료 상태 양방향 맞춤.
@MainActor
@Observable
final class ReminderService {
    static let shared = ReminderService(store: EventKitReminderStore())

    enum ReminderError: LocalizedError {
        case denied
        var errorDescription: String? { "미리알림 접근 권한이 없습니다. 설정 → 모아 → 미리알림에서 허용해 주세요." }
    }

    struct Export {
        let item: ActionItem
        /// 사용자가 확인한 기한 (없으면 날짜 없이 등록)
        let due: Date?
    }

    private let store: ReminderStore

    init(store: ReminderStore) {
        self.store = store
    }

    var isDenied: Bool { store.isDenied }

    /// 권한을 확인하고 필요하면 요청한다.
    func ensureAccess() async throws {
        if store.isAuthorized { return }
        guard !store.isDenied, await store.requestAccess() else { throw ReminderError.denied }
    }

    /// 할 일들을 미리알림에 등록한다. 이미 등록돼 있고 미리알림에 남아 있는 것은 건너뛴다.
    /// - Returns: 새로 등록한 개수
    @discardableResult
    func add(_ exports: [Export], meetingTitle: String) async throws -> Int {
        try await ensureAccess()
        var added = 0
        for export in exports {
            let item = export.item
            if let id = item.reminderIdentifier, store.isCompleted(id) != nil { continue }
            let id = try store.create(title: item.task, notes: Self.notes(for: item, meetingTitle: meetingTitle), due: export.due)
            item.reminderIdentifier = id
            item.isAddedToReminders = true
            item.dueDate = export.due
            if item.isCompleted { try? store.setCompleted(id, true) }
            added += 1
        }
        return added
    }

    /// 앱에서 완료/해제하면 미리알림 쪽도 맞춘다.
    func setCompleted(_ item: ActionItem, _ completed: Bool) {
        item.isCompleted = completed
        item.completedAt = completed ? .now : nil
        guard store.isAuthorized, let id = item.reminderIdentifier else { return }
        try? store.setCompleted(id, completed)
    }

    /// 미리알림 앱에서 바뀐 것을 가져온다 (완료 상태, 지워진 미리알림은 연결 해제).
    /// - Returns: 바뀐 할 일 수
    @discardableResult
    func sync(_ items: [ActionItem]) -> Int {
        guard store.isAuthorized else { return 0 }
        var changed = 0
        for item in items {
            guard let id = item.reminderIdentifier else { continue }
            switch store.isCompleted(id) {
            case nil:
                // 미리알림 앱에서 지운 경우
                item.reminderIdentifier = nil
                item.isAddedToReminders = false
                changed += 1
            case let completed? where completed != item.isCompleted:
                item.isCompleted = completed
                item.completedAt = completed ? .now : nil
                changed += 1
            default:
                break
            }
        }
        return changed
    }

    static func notes(for item: ActionItem, meetingTitle: String) -> String {
        var lines = ["회의: \(meetingTitle)"]
        if let owner = item.owner { lines.append("담당: \(owner)") }
        if let due = item.dueText { lines.append("기한(회의 원문): \(due)") }
        lines.append("— 모아 앱에서 추가")
        return lines.joined(separator: "\n")
    }
}

/// 실제 iOS 미리알림 (EventKit)
@MainActor
final class EventKitReminderStore: ReminderStore {
    private let eventStore = EKEventStore()

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    var isDenied: Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .denied, .restricted, .writeOnly: true
        default: false
        }
    }

    func requestAccess() async -> Bool {
        (try? await eventStore.requestFullAccessToReminders()) ?? false
    }

    func create(title: String, notes: String?, due: Date?) throws -> String {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        if let due {
            // 날짜만 (종일). 시간까지 정하면 원문에 없는 시각을 만드는 셈이다.
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
        }
        try eventStore.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func isCompleted(_ identifier: String) -> Bool? {
        (eventStore.calendarItem(withIdentifier: identifier) as? EKReminder)?.isCompleted
    }

    func setCompleted(_ identifier: String, _ completed: Bool) throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        reminder.isCompleted = completed
        try eventStore.save(reminder, commit: true)
    }
}
