import Foundation
import Testing
@testable import MeetingSummary

// 고르기 카드 (D111): 6개까지의 후보, 여러 개 고르기, 후보의 그림, 답 뒤의 다음 말. 모두 지어낸 값이다.

@Suite("고르기 카드")
struct ChoiceCardTests {
    static func reply(_ json: String) throws -> AgentReply {
        try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200)
    }

    @Test func askKeepsSixChoicesAndReadsMultiAndImages() throws {
        let reply = try Self.reply("""
        {"conversation_id":"c1","replies":[{"text":"어느 것을 놓을까요?"}],
         "action":{"type":"ask","choices":["가"," 나 ","다","라","마","바","사","가",""],"recommended":"다","multi":true,
          "choice_details":[{"text":"가","image":"https://img.hanbit.co.kr/a.png"},
                            {"text":"나","image":"http://img.hanbit.co.kr/b.png"},
                            {"text":"다","image":"https://localhost/c.png"},
                            {"text":"없는 후보","image":"https://img.hanbit.co.kr/d.png"},
                            {"text":"라"}, 7]}}
        """)
        // 빈 것·겹친 것을 빼고 6개까지
        #expect(reply.action == .ask(choices: ["가", "나", "다", "라", "마", "바"]))
        #expect(reply.recommended == "다")
        #expect(reply.multi)
        // https 공개 주소이고 후보에 있는 줄만
        #expect(reply.choiceImages == ["가": URL(string: "https://img.hanbit.co.kr/a.png")!])
        #expect(reply.next.isEmpty)
    }

    @Test func multiNeedsTwoChoicesAndATrueFlag() throws {
        let one = try Self.reply("""
        {"conversation_id":"c1","replies":[{"text":"이거요?"}],"action":{"type":"ask","choices":["네"],"multi":true}}
        """)
        #expect(!one.multi)
        let odd = try Self.reply("""
        {"conversation_id":"c1","replies":[{"text":"뭐요?"}],"action":{"type":"ask","choices":["가","나"],"multi":"yes","choice_details":"x"}}
        """)
        #expect(!odd.multi && odd.choiceImages.isEmpty)
        #expect(odd.action == .ask(choices: ["가", "나"]))
    }

    @Test func answerMayCarryNextChoices() throws {
        let reply = try Self.reply("""
        {"conversation_id":"c1","replies":[{"text":"이런 차이가 있어요."}],
         "action":{"type":"none","next":{"choices":["더 쉬운 예","표로 보여 줘","표로 보여 줘","네 번째","다섯 번째"],"recommended":"표로 보여 줘"}}}
        """)
        #expect(reply.next == ["더 쉬운 예", "표로 보여 줘", "네 번째"])
        #expect(reply.nextRecommended == "표로 보여 줘")
        // 꼴이 다르면 다음 말만 없다
        let odd = try Self.reply("""
        {"conversation_id":"c1","replies":[{"text":"고마워요"}],"action":{"type":"none","next":["가"]}}
        """)
        #expect(odd.next.isEmpty && odd.replies == ["고마워요"])
    }

    @Test func reportCardMayCarryNextChoices() throws {
        let state = try ReportCardTests.decode("""
        {"kind":"answer","title":"최근 결제 내역","next":{"choices":["지난달도 볼래","","지난달도 볼래"]}}
        """)
        #expect(state.report?.card?.next == ["지난달도 볼래"])
        let none = try ReportCardTests.decode("""
        {"kind":"answer","title":"최근 결제 내역"}
        """)
        #expect(none.report?.card?.next == nil)
    }

    @Test func pickedChoicesJoinInTheirOrder() {
        #expect(AgentChoices.joined(["다", "가"], in: ["가", "나", "다"]) == "가, 다")
        #expect(AgentChoices.joined([], in: ["가"]) == "")
    }

    @Test func savedCardsWithoutNextStillDecode() throws {
        let old = #"{"kind":"answer","title":"제목","blocks":[],"actions":[]}"#
        let card = try JSONDecoder().decode(AgentReportCard.self, from: Data(old.utf8))
        #expect(card.next == nil)
    }
}
