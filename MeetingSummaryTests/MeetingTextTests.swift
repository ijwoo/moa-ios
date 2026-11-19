import Foundation
import Testing
@testable import MeetingSummary

@MainActor
struct MeetingTextTests {
    private func sampleMeeting() -> Meeting {
        let meeting = Meeting(title: "주간 회의", duration: 3725)
        meeting.appendUtterance(Utterance(start: 0, end: 4, text: "출시 일정을 논의합니다."))
        meeting.appendUtterance(Utterance(start: 65.4, end: 70, text: "디자인은 금요일까지입니다."))
        return meeting
    }

    @Test func searchMatchesTitleAndTranscriptCaseInsensitively() {
        let meeting = sampleMeeting()
        #expect(MeetingText.matches(meeting, query: ""))
        #expect(MeetingText.matches(meeting, query: "주간"))
        #expect(MeetingText.matches(meeting, query: "금요일"))
        #expect(!MeetingText.matches(meeting, query: "결제"))

        meeting.title = "Beta 점검"
        #expect(MeetingText.matches(meeting, query: "beta"))
    }

    @Test func searchMatchesSummary() {
        let meeting = sampleMeeting()
        meeting.summary = Summary(topic: "결제 연동", body: "PG사를 비교했다")
        #expect(MeetingText.matches(meeting, query: "결제"))
        #expect(MeetingText.matches(meeting, query: "pg사"))
    }

    @Test func timestampFormat() {
        #expect(MeetingText.timestamp(0) == "00:00")
        #expect(MeetingText.timestamp(65.9) == "01:05")
        #expect(MeetingText.timestamp(3725) == "1:02:05")
    }

    @Test func exportContainsTimedUtterances() {
        let text = MeetingText.exportText(for: sampleMeeting())
        #expect(text.hasPrefix("주간 회의\n"))
        #expect(text.contains("녹음 길이: 1:02:05"))
        #expect(text.contains("[대화]\n[00:00] 출시 일정을 논의합니다.\n[01:05] 디자인은 금요일까지입니다."))
        #expect(!text.contains("[요약]"))
    }

    @Test func exportIncludesSpeakerAndSummaryWhenPresent() {
        let meeting = sampleMeeting()
        meeting.sortedUtterances[0].speaker = "참여자 1"
        meeting.summary = Summary(
            topic: "출시", body: "일정 점검",
            decisions: ["12월 출시"],
            actionItems: [ActionItem(task: "시안 전달", owner: "김지원", dueText: nil)]
        )
        let text = MeetingText.exportText(for: meeting)
        #expect(text.contains("[00:00] 참여자 1: 출시 일정을 논의합니다."))
        #expect(text.contains("결정 사항:\n- 12월 출시"))
        #expect(text.contains("- 시안 전달 (김지원)"))
    }

    @Test func exportFallsBackToTranscriptForOldMeetings() {
        let meeting = Meeting(title: "예전 회의", transcript: "구간 방식으로 받아쓴 텍스트")
        #expect(MeetingText.exportText(for: meeting).contains("[대화]\n구간 방식으로 받아쓴 텍스트"))
    }

    @Test func exportFileNameIsSafe() {
        let meeting = Meeting(title: "회의 11/10 1:31")
        #expect(MeetingText.exportFileName(for: meeting) == "회의 11-10 1-31.txt")
    }
}
