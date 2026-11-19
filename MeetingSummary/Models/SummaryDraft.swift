import Foundation
import SwiftData

/// 요약 편집용 사본. 편집 화면은 이 사본만 고치고, "저장"할 때만 회의에 반영한다 ("취소"하면 그대로).
struct SummaryDraft: Equatable {
    struct Line: Identifiable, Equatable {
        let id: UUID
        var text: String

        init(id: UUID = UUID(), text: String = "") {
            self.id = id
            self.text = text
        }
    }

    struct ActionDraft: Identifiable, Equatable {
        /// 기존 할 일이면 그 id (미리알림 등록 여부 등을 유지하기 위해)
        let id: UUID
        var task: String
        var owner: String
        var due: String

        init(id: UUID = UUID(), task: String = "", owner: String = "", due: String = "") {
            self.id = id
            self.task = task
            self.owner = owner
            self.due = due
        }
    }

    var title: String
    var topic: String
    var body: String
    var decisions: [Line]
    var actionItems: [ActionDraft]
    var openQuestions: [Line]

    @MainActor
    init(meeting: Meeting) {
        title = meeting.title
        let summary = meeting.summary
        topic = summary?.topic ?? ""
        body = summary?.body ?? ""
        decisions = (summary?.decisions ?? []).map { Line(text: $0) }
        actionItems = (summary?.sortedActionItems ?? []).map {
            ActionDraft(id: $0.id, task: $0.task, owner: $0.owner ?? "", due: $0.dueText ?? "")
        }
        openQuestions = (summary?.openQuestions ?? []).map { Line(text: $0) }
    }

    /// 요약 내용이 하나라도 있는지 (요약이 없던 회의에 빈 요약을 만들지 않기 위해)
    var hasSummaryContent: Bool {
        Self.clean(topic) != nil || Self.clean(body) != nil
            || decisions.contains { Self.clean($0.text) != nil }
            || actionItems.contains { Self.clean($0.task) != nil }
            || openQuestions.contains { Self.clean($0.text) != nil }
    }

    /// 사본을 회의에 반영한다.
    /// - 빈 줄은 버린다. 담당자·기한이 비어 있으면 nil.
    /// - 기존 할 일은 id로 찾아 고친다 (미리알림 등록 여부 유지). 기한 문구가 바뀌면 지정해 둔 날짜는 지운다.
    @MainActor
    func apply(to meeting: Meeting, in context: ModelContext) {
        if let title = Self.clean(title) { meeting.title = title }

        guard meeting.summary != nil || hasSummaryContent else { return }
        let summary: Summary
        if let existing = meeting.summary {
            summary = existing
        } else {
            summary = Summary(topic: "", body: "")
            meeting.summary = summary
        }

        summary.topic = Self.clean(topic) ?? ""
        summary.body = Self.clean(body) ?? ""
        summary.decisions = decisions.compactMap { Self.clean($0.text) }
        summary.openQuestions = openQuestions.compactMap { Self.clean($0.text) }

        let existing = Dictionary(uniqueKeysWithValues: summary.actionItems.map { ($0.id, $0) })
        var kept: [ActionItem] = []
        for draft in actionItems {
            guard let task = Self.clean(draft.task) else { continue }
            let owner = Self.clean(draft.owner)
            let due = Self.clean(draft.due)
            let order = kept.count
            if let item = existing[draft.id] {
                item.task = task
                item.owner = owner
                if item.dueText != due {
                    item.dueText = due
                    item.dueDate = nil
                }
                item.order = order
                kept.append(item)
            } else {
                kept.append(ActionItem(id: draft.id, task: task, owner: owner, dueText: due, order: order))
            }
        }
        let keptIDs = Set(kept.map(\.id))
        for item in summary.actionItems where !keptIDs.contains(item.id) {
            context.delete(item)
        }
        summary.actionItems = kept
    }

    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
