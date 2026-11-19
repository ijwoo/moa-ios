import Testing
@testable import MeetingSummary

// 번호 붙은 항목으로 온 답을 나눠 보여 주기 (D57). 가게·금액·날짜는 모두 지어낸 것이다.

@Suite("보고의 답: 번호 붙은 항목 나누기")
struct ReportRecordsTests {
    @Test func pipeSeparatedLinesBecomeRecords() throws {
        let records = try #require(ReportRecords.parse("""
        1. 이름: 가상문구 | 금액: 7,400원 | 날짜: 11. 10. 18:59 | 상태: 결제완료
        2. 이름: [가상서점] 처음 만나는 가상 도서(개정판) | 금액: 18,000원 | 날짜: 11. 8. 12:30 | 상태: 구매확정완료
        """))
        #expect(records.intro.isEmpty && records.outro.isEmpty)
        #expect(records.records == [
            .init(id: 1, title: "가상문구", amount: "7,400원", details: ["11. 10. 18:59", "결제완료"]),
            .init(id: 2, title: "[가상서점] 처음 만나는 가상 도서(개정판)", amount: "18,000원", details: ["11. 8. 12:30", "구매확정완료"]),
        ])
    }

    @Test func mockAnswerHasTheShapeTheScreenDivides() throws {
        // 화면 확인용 가상 답도 실제 맥의 답과 같은 모양이어야 한다
        #expect(ReportRecords.parse(MockCaptures.answer)?.records.count == 3)
    }

    @Test func linesAroundTheRecordsAreKept() throws {
        let records = try #require(ReportRecords.parse("""
        최근 결제 2건이에요.

        1) 상품: 가상문구 | 결제금액: 7,400원 | 결제일시: 2026.11.10 18:59
        2) 상품: 가상카페 | 결제금액: 4,500원 | 결제일시: 2026.11.05 09:12
        더 보려면 말씀해 주세요.
        """))
        #expect(records.intro == ["최근 결제 2건이에요."])
        #expect(records.outro == ["더 보려면 말씀해 주세요."])
        #expect(records.records.map(\.title) == ["가상문구", "가상카페"])
        #expect(records.records.map(\.amount) == ["7,400원", "4,500원"])
        #expect(records.records.first?.details == ["2026.11.10 18:59"])
    }

    @Test func nothingIsDroppedExceptKnownLabels() throws {
        // 이름을 모르는 칸은 이름과 함께 남긴다. 값은 하나도 빠지지 않는다
        let record = try #require(ReportRecords.parse("1. 이름: 가상문구 | 금액: 7,400원 | 결제수단: 가상카드 | 메모: 선물: 포장")?.records.first)
        #expect(record.title == "가상문구")
        #expect(record.amount == "7,400원")
        #expect(record.details == ["결제수단 가상카드", "메모 선물: 포장"])
        #expect(record.spoken == "1번, 가상문구, 7,400원, 결제수단 가상카드, 메모 선물: 포장")
    }

    @Test func twoAmountsKeepTheirNames() throws {
        // 금액이 둘이면 어느 것이 무엇인지 이름이 있어야 한다: 오른쪽으로 빼지 않는다
        let record = try #require(ReportRecords.parse("1. 이름: 가상문구 | 결제금액: 7,400원 | 할인금액: 600원")?.records.first)
        #expect(record.amount == nil)
        #expect(record.details == ["결제금액 7,400원", "할인금액 600원"])
        // 이름이 "금액"이 아닌 금액 하나도 이름을 떼지 않는다
        let refund = try #require(ReportRecords.parse("1. 이름: 가상문구 | 환불금액: 7,400원 | 상태: 환불완료")?.records.first)
        #expect(refund.amount == nil)
        #expect(refund.details == ["환불금액 7,400원", "환불완료"])
    }

    @Test func fieldsWithoutNamesAreDividedByTheirShape() throws {
        let record = try #require(ReportRecords.parse("1. 가상문구 | 7,400원 | 11. 10. 18:59 | 결제완료")?.records.first)
        #expect(record.title == "가상문구")
        #expect(record.amount == "7,400원")
        #expect(record.details == ["11. 10. 18:59", "결제완료"])
    }

    @Test(arguments: [
        // 보통 글
        "최근 결제 3건이에요.",
        // 칸이 없는 번호 목록
        "1. 회의록을 정리했어요\n2. 메일 초안을 저장했어요",
        // 줄표 목록
        "- 11월 10일 가상문구 7,400원\n- 11월 8일 가상서점 18,000원",
        // 번호가 차례대로가 아니다
        "1. 이름: 가 | 금액: 100원\n3. 이름: 나 | 금액: 200원",
        // 2부터 시작한다
        "2. 이름: 가 | 금액: 100원",
        // 한 줄만 모양이 다르다
        "1. 이름: 가 | 금액: 100원\n2. 가상서점에서 18,000원",
        // 항목 사이에 다른 줄이 끼어 있다
        "1. 이름: 가 | 금액: 100원\n(배송 중)\n2. 이름: 나 | 금액: 200원",
        // 빈 칸이 있다
        "1. 이름: 가 | | 금액: 100원",
        "1. 이름: | 금액: 100원",
        // 무엇인지 알 수 있는 칸이 없다 (금액뿐)
        "1. 금액: 100원 | 할인금액: 10원",
        // 번호가 아니다
        "3.5만원 | 가상문구",
        "",
    ])
    func otherShapesAreLeftAsText(text: String) {
        #expect(ReportRecords.parse(text) == nil)
    }

    @Test func timesAreNotTakenForFieldNames() throws {
        // "18:59 결제"의 18을 칸 이름으로 보지 않는다
        let record = try #require(ReportRecords.parse("1. 가상문구 | 18:59 결제 | 7,400원")?.records.first)
        #expect(record.details == ["18:59 결제"])
    }
}
