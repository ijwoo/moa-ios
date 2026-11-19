import Foundation
import Testing
@testable import MeetingSummary

// 답변 카드 (`report.card`, D110). 모두 지어낸 값이다.

@Suite("답변 카드")
struct ReportCardTests {
    static func task(status: String = "completed", card: String) -> String {
        """
        {"id":"t_card1","status":"\(status)","task":"결제내역 알려줘","title":"결제내역 확인",\
        "created_at":"2026-11-16T12:30:00+00:00","updated_at":"2026-11-16T12:30:28+00:00","steps":[],\
        "result":{"outcome":"\(status)","summary":"결제내역을 읽었어요","approved_drafts":[],\
        "report":{"done":["최근 결제 3건이에요."],"blocked":[],"sources":[],"card":\(card)}}}
        """
    }

    static func decode(_ card: String, status: String = "completed") throws -> AgentTaskState {
        try AgentHTTPClient.decodeTask(data: Data(task(status: status, card: card).utf8), status: 200)
    }

    @Test func anAnswerCardIsReadWithItsBlocksAndActions() throws {
        let state = try Self.decode("""
        {"kind":"answer","title":"  최근 결제 내역 ","subtitle":"가상페이 · 이번 주",
         "blocks":[{"kind":"stat","label":"이번 주","value":"84,300원"},{"kind":"chart"},
                   {"kind":"list","items":[{"title":"달빛 서점","trailing":"32,000원"}]},
                   {"kind":"pairs","items":[{"label":"살 때","value":"1"},{"label":"팔 때","value":"2"}]},
                   {"kind":"text","text":"네 번째라 빠진다"}],
         "actions":[{"label":"쇼핑몰에서 보기","url":"https://shop.hanbit.co.kr/orders"},
                    {"label":"다시 로그인","site":"hanbit-shop"},
                    {"label":"셋째","url":"https://shop.hanbit.co.kr/x"}]}
        """)
        let card = try #require(state.report?.card)
        #expect(card.kind == .answer && card.title == "최근 결제 내역" && card.subtitle == "가상페이 · 이번 주")
        // 모르는 블록은 건너뛰고 셋까지
        #expect(card.blocks.count == 3)
        #expect(card.blocks[0] == .stat(label: "이번 주", value: "84,300원", note: nil))
        #expect(card.actions == [
            AgentReportCard.Action(label: "쇼핑몰에서 보기", url: URL(string: "https://shop.hanbit.co.kr/orders")),
            AgentReportCard.Action(label: "다시 로그인", site: "hanbit-shop"),
        ])
        // 줄글(`done`)도 그대로 남는다 (작업 상세와 기록에 쓴다)
        #expect(state.report?.done == ["최근 결제 3건이에요."])
    }

    @Test func unsafeActionsAndBrokenCardsAreDropped() throws {
        let state = try Self.decode("""
        {"kind":"result","title":"장바구니에 담았어요",
         "actions":[{"label":"내부 주소","url":"https://mac.tailnet.ts.net/x"},{"label":"http","url":"http://shop.hanbit.co.kr"},
                    {"label":"이상한 사이트","site":"../x"},{"label":"아무것도 없음"}]}
        """)
        #expect(state.report?.card?.actions.isEmpty == true)
        // 종류나 제목이 없으면 카드만 버리고 보고는 남긴다
        let noKind = try Self.decode(#"{"title":"제목만"}"#)
        #expect(noKind.report?.card == nil && noKind.report?.done == ["최근 결제 3건이에요."])
        let notObject = try Self.decode(#""카드""#)
        #expect(notObject.report?.card == nil)
    }

    @Test func aCardIsKeptInTheChatRecord() throws {
        // 대화 기록에 저장했다가 다시 읽어도 같다 (블록의 날짜까지)
        let card = AgentReportCard(
            kind: .failed, title: "로그인이 풀렸어요",
            blocks: [.date(label: "다음 결제일", day: DateComponents(year: 2026, month: 12, day: 1), note: nil), .pairs([
                SpaceBlock.Pair(label: "살 때", value: "1"), SpaceBlock.Pair(label: "팔 때", value: "2"),
            ])],
            actions: [AgentReportCard.Action(label: "다시 로그인", site: "hanbit-shop")]
        )
        var report = AgentReport(done: ["x"])
        report.card = card
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(AgentReport.self, from: data).card == card)
        // 카드가 없던 때의 기록도 읽힌다
        let old = try JSONDecoder().decode(AgentReport.self, from: Data(#"{"done":["x"],"blocked":[],"sources":[]}"#.utf8))
        #expect(old.card == nil)
    }

    @Test func askBackMayRecommendOneChoiceAndShortLinesAreStatus() throws {
        let json = """
        {"conversation_id":"c1","replies":[{"text":"예약했어요 · 매일 오전 8:00","kind":"status"},{"text":"어느 쪽으로 할까요?"}],
         "action":{"type":"ask","choices":["가까운 날","다음 주"],"recommended":"다음 주"}}
        """
        let reply = try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200)
        #expect(reply.recommended == "다음 주")
        #expect(reply.isStatus(at: 0) && !reply.isStatus(at: 1))
        // 선택지에 없는 후보는 받지 않는다
        let odd = try AgentHTTPClient.decodeReply(data: Data("""
        {"conversation_id":"c1","replies":[{"text":"어느 쪽?"}],"action":{"type":"ask","choices":["가","나"],"recommended":"다"}}
        """.utf8), status: 200)
        #expect(odd.recommended == nil && odd.statusLines.isEmpty)
    }
}

// 대화의 답변 카드는 글을 자르지 않는다 (D133). 내 공간 카드는 그대로 칸에 맞춰 자른다
@Suite("답변 카드 글 길이")
struct ReportCardFullTextTests {
    @Test func chatCardShowsAllText() {
        #expect(SpaceBlockView.textLines(size: .large, full: true) == nil)
        #expect(SpaceBlockView.textLines(size: .large, full: false) == 6)
        #expect(SpaceBlockView.textLines(size: .medium, full: false) == 3)
        #expect(SpaceBlockView.textLines(size: .small, full: false) == 2)
    }

    @Test func pairsWrapInNarrowPlaces() {
        // 대화 카드의 넷은 둘씩 두 줄 (한 줄에 넷이면 "+17 (총 18명)" 같은 값이 줄어 읽기 어렵다)
        #expect(SpaceBlockView.pairColumns(count: 4, tile: false, full: true) == 2)
        #expect(SpaceBlockView.pairColumns(count: 2, tile: false, full: true) == 2)
        // 내 공간 넓은 카드는 그대로 한 줄에
        #expect(SpaceBlockView.pairColumns(count: 4, tile: false, full: false) == 4)
        #expect(SpaceBlockView.pairColumns(count: 3, tile: true, full: false) == 2)
        #expect(SpaceBlockView.pairColumns(count: 0, tile: false, full: false) == 1)
    }
}
