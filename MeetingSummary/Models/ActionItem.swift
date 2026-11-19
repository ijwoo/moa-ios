import Foundation
import SwiftData

@Model
final class ActionItem {
    @Attribute(.unique) var id: UUID
    /// 할 일 내용
    var task: String
    /// 담당자. 본문에 없으면 nil (추측해서 채우지 않는다)
    var owner: String?
    /// 기한 원문 (예: "금요일", "다음 주 화요일"). 본문에 없으면 nil
    var dueText: String?
    /// 미리알림에 넣을 실제 날짜. 사용자가 확인·지정한 경우에만 값이 있다.
    var dueDate: Date?
    /// 미리알림 등록 여부
    var isAddedToReminders: Bool
    /// 등록된 EKReminder의 식별자 (중복 등록 방지·추적용)
    var reminderIdentifier: String?
    /// 화면 표시 순서
    var order: Int
    /// 완료 여부. 미리알림에 등록된 할 일은 미리알림 쪽 완료와 서로 맞춘다.
    var isCompleted: Bool = false
    var completedAt: Date?

    var summary: Summary?

    init(
        id: UUID = UUID(),
        task: String,
        owner: String? = nil,
        dueText: String? = nil,
        dueDate: Date? = nil,
        isAddedToReminders: Bool = false,
        order: Int = 0
    ) {
        self.id = id
        self.task = task
        self.owner = owner
        self.dueText = dueText
        self.dueDate = dueDate
        self.isAddedToReminders = isAddedToReminders
        self.order = order
    }
}
