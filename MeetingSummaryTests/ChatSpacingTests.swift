import Testing
@testable import MeetingSummary

/// 대화 말풍선 사이 간격 (D150: 참고 앱을 재서 맞췄다)
@MainActor
struct ChatSpacingTests {
    private func message(_ role: AskSession.Message.Role, engine: AskSession.Engine = .local) -> AskSession.Message {
        AskSession.Message(role: role, text: "말", engine: engine)
    }

    @Test func aTurnChangeIsTwelve() {
        #expect(AskView.spacing(previous: message(.user), current: message(.assistant)) == 12)
        #expect(AskView.spacing(previous: message(.assistant), current: message(.user)) == 12)
        #expect(AskView.spacing(previous: message(.agent), current: message(.user)) == 12)
    }

    @Test func bubblesOfTheSameSideSitTwoApart() {
        #expect(AskView.spacing(previous: message(.user), current: message(.user)) == 2)
        #expect(AskView.spacing(previous: message(.assistant), current: message(.assistant)) == 2)
    }

    @Test func cardsAndFootnotesKeepTheirRoom() {
        var reacted = message(.user)
        reacted.reaction = "👍"
        #expect(AskView.spacing(previous: reacted, current: message(.user)) == 10)
        // "Claude 사용"이 붙는 답, 상태 줄, 작업 카드
        #expect(AskView.spacing(previous: message(.assistant, engine: .cloud), current: message(.assistant)) == 10)
        var status = message(.assistant)
        status.isStatus = true
        #expect(AskView.spacing(previous: message(.assistant), current: status) == 10)
        #expect(AskView.spacing(previous: message(.agent), current: message(.assistant)) == 10)
    }

    @Test func bubblePaddingMatchesTheReference() {
        #expect(DS.Chat.bubblePaddingH == 14)
        #expect(DS.Chat.bubblePaddingV == 11)
    }
}
