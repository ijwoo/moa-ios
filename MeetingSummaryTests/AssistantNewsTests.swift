import Foundation
import Testing
@testable import MeetingSummary

// 개인비서 알림의 줄 (D127). 모두 지어낸 값이다.

@MainActor
@Suite("개인비서 알림: 줄")
struct AssistantNewsTests {
    private func entry(_ status: String?, kind: ActivityEntry.Kind = .task, line: String? = nil) -> ActivityEntry {
        ActivityEntry(id: "t", kind: kind, at: .now, title: "가상 일", status: status, line: line)
    }

    @Test func whatNeedsMeStandsOut() {
        #expect(AssistantNewsView.needsMe(entry("needs_login")))
        #expect(AssistantNewsView.line(entry("needs_login", line: "가상 사이트")) == "로그인 필요")
        #expect(AssistantNewsView.kind(entry("needs_login")) == .login)
        #expect(!AssistantNewsView.needsMe(entry("completed")))
        #expect(AssistantNewsView.kind(entry("completed")) == .done)
        #expect(AssistantNewsView.kind(entry("failed")) == .failed)
        #expect(AssistantNewsView.kind(entry("done", kind: .routine)) == .scheduled)
    }

    @Test func otherLinesComeFromTheMacOrTheStatus() {
        #expect(AssistantNewsView.line(entry("completed", line: "최근 결제 3건")) == "최근 결제 3건")
        #expect(AssistantNewsView.line(entry("failed")) == "끝내지 못했어요")
        #expect(AssistantNewsView.line(entry("completed")) == "끝났어요")
        #expect(AssistantNewsView.line(entry("done", kind: .routine)) == "예약 실행")
    }
}
