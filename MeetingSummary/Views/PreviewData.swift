#if DEBUG
import SwiftData

/// SwiftUI 미리보기 전용 샘플 데이터 (목업 내용과 동일)
@MainActor
enum PreviewData {
    static let container: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: config
        )
        let meeting = Meeting(
            title: "베타 출시 점검 회의",
            duration: 754,
            transcript: "오늘 회의에서는 베타 출시 일정을 논의했습니다. 디자인 시안은 금요일까지 확정하기로 했고, 서버 부하 테스트는 다음 주 화요일에 진행합니다.",
            status: .ready
        )
        meeting.summary = Summary(
            topic: "베타 출시 일정",
            body: "베타 출시 일정과 준비 작업을 점검했다.",
            decisions: ["베타 출시일 12월 첫째 주로 확정", "디자인 시안 금요일까지 확정"],
            actionItems: [
                ActionItem(task: "디자인 시안 최종본 전달", owner: "김지원", dueText: "금요일", order: 0),
                ActionItem(task: "서버 부하 테스트 진행", owner: "박민수", dueText: "다음 주 화요일", order: 1),
            ],
            openQuestions: ["결제 연동 방식 (외부 PG vs 자체 구현)"]
        )
        meeting.isRecordingComplete = true
        meeting.utterances = [
            Utterance(start: 0, end: 4.2, text: "오늘 회의에서는 베타 출시 일정을 논의했습니다."),
            Utterance(start: 4.2, end: 8.9, text: "디자인 시안은 금요일까지 확정하기로 했고,"),
            Utterance(start: 8.9, end: 13.5, text: "서버 부하 테스트는 다음 주 화요일에 진행합니다."),
        ]
        container.mainContext.insert(meeting)
        return container
    }()
}
#endif
