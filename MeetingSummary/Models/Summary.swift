import Foundation
import SwiftData

@Model
final class Summary {
    var topic: String
    /// 요약 본문 (`summary`는 모델 이름과 헷갈려서 `body`로 둔다)
    var body: String
    var decisions: [String]
    var openQuestions: [String]

    @Relationship(deleteRule: .cascade, inverse: \ActionItem.summary)
    var actionItems: [ActionItem]

    var meeting: Meeting?

    init(
        topic: String,
        body: String,
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [String] = []
    ) {
        self.topic = topic
        self.body = body
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    /// SwiftData의 to-many 관계는 순서를 보장하지 않으므로 `order`로 정렬해서 쓴다.
    var sortedActionItems: [ActionItem] {
        actionItems.sorted { $0.order < $1.order }
    }
}
