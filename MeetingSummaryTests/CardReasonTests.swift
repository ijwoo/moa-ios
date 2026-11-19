import Foundation
import Testing
@testable import MeetingSummary

// 못 한 일의 답변 카드에 붙는 한 줄 까닭 (D118). 모두 지어낸 값이다.

@Suite("답변 카드: 못 한 일의 까닭")
struct CardReasonTests {
    static func state(blocked: [String], summary: String = "", card: String) throws -> AgentTaskState {
        let blockedJSON = String(data: try JSONEncoder().encode(blocked), encoding: .utf8)!
        let json = """
        {"id":"t_fail1","status":"failed","task":"보안 확인 체크해줘","title":"site.test에서 하기",\
        "created_at":"2026-11-17T01:00:00+00:00","updated_at":"2026-11-17T01:00:30+00:00","steps":[],\
        "result":{"outcome":"failed","summary":"\(summary)","approved_drafts":[],\
        "report":{"done":[],"blocked":\(blockedJSON),"sources":["https://site.example.org/check"],"card":\(card)}}}
        """
        return try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
    }

    @Test func aBareFailedCardTakesTheBlockedLine() throws {
        let state = try Self.state(
            blocked: ["보안 확인 화면에서 막혔어요. 사람인지 확인하는 칸은 제가 누르지 않아요."],
            card: #"{"kind":"failed","title":"하지 못했어요","actions":[{"label":"사이트에서 보기","url":"https://site.example.org/check"}]}"#
        )
        let card = try #require(state.report?.card)
        #expect(state.cardReason(for: card)?.hasPrefix("보안 확인 화면에서 막혔어요") == true)
    }

    @Test func aCardThatAlreadySaysWhyGetsNothing() throws {
        let withSubtitle = try Self.state(
            blocked: ["막혔어요"],
            card: #"{"kind":"failed","title":"하지 못했어요","subtitle":"로그인이 풀렸어요"}"#
        )
        #expect(withSubtitle.cardReason(for: try #require(withSubtitle.report?.card)) == nil)
        let answer = try Self.state(blocked: ["막혔어요"], card: #"{"kind":"answer","title":"결과"}"#)
        #expect(answer.cardReason(for: try #require(answer.report?.card)) == nil)
        // 제목과 같은 말은 되풀이하지 않는다
        let same = try Self.state(blocked: ["하지 못했어요"], card: #"{"kind":"failed","title":"하지 못했어요"}"#)
        #expect(same.cardReason(for: try #require(same.report?.card)) != "하지 못했어요")
    }
}

@Suite("답 글의 소제목 (D119)")
struct AnswerHeadingTests {
    @Test func hashLinesBecomeHeadings() {
        let lines = AnswerText.lines("## 잘 들어간 부분\n- 제목과 설명\n### **빠진 부분**\n태그가 비어 있어요.")
        #expect(lines == [.heading("잘 들어간 부분"), .bullet("제목과 설명"), .heading("빠진 부분"), .text("태그가 비어 있어요.")])
        // #만 있거나 빈칸이 없거나 넷 이상이면 소제목이 아니다
        #expect(AnswerText.heading("#해시태그") == nil)
        #expect(AnswerText.heading("#### 너무 깊다") == nil)
        #expect(AnswerText.lines("# 제목만") == [.heading("제목만")])
    }
}
