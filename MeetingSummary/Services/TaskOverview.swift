import Foundation

/// 할 일 진행 상황 (화면 표시용 계산만, 데이터는 바꾸지 않는다).
///
/// - 회의에 속한 할 일만 센다 (요약이 지워진 할 일 제외).
/// - "기한 지남"은 사용자가 확정한 날짜(`dueDate`)가 있는 할 일만 센다. "금요일까지" 같은 원문은 날짜로 추측하지 않는다.
struct TaskOverview {
    let total: Int
    let completed: Int
    let open: Int
    /// 미리알림에 연결된 할 일 (완료 포함)
    let linkedToReminders: Int
    /// 진행 중이면서 미리알림에 아직 없는 할 일
    let pendingReminderItems: [ActionItem]
    /// 진행 중이면서 확정 기한이 오늘 이전인 할 일
    let overdue: Int

    var hasTasks: Bool { total > 0 }
    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    init(items: [ActionItem], now: Date = .now, calendar: Calendar = .current) {
        let tasks = items.filter { $0.summary?.meeting != nil }
        let today = calendar.startOfDay(for: now)
        total = tasks.count
        completed = tasks.filter(\.isCompleted).count
        open = total - completed
        linkedToReminders = tasks.filter(\.isAddedToReminders).count
        pendingReminderItems = tasks.filter { !$0.isCompleted && !$0.isAddedToReminders }
        overdue = tasks.filter { !$0.isCompleted && ($0.dueDate.map { $0 < today } ?? false) }.count
    }

    static func isOverdue(_ item: ActionItem, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard !item.isCompleted, let due = item.dueDate else { return false }
        return due < calendar.startOfDay(for: now)
    }
}
