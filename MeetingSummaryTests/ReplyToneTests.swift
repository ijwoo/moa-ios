import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

@Suite("답변 말투 설정")
@MainActor
struct ReplyToneTests {
    private func defaults() -> UserDefaults {
        let name = "tone-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func friendlyUntilTheUserChooses() {
        #expect(ReplyTone.current(defaults()) == .friendly)
    }

    @Test func storedChoiceIsUsed() {
        let defaults = defaults()
        defaults.set(ReplyTone.formal.rawValue, forKey: AppSettings.Key.replyTone)
        #expect(ReplyTone.current(defaults) == .formal)
    }

    @Test func unknownStoredValueFallsBackToFriendly() {
        let defaults = defaults()
        defaults.set("casual", forKey: AppSettings.Key.replyTone)
        #expect(ReplyTone.current(defaults) == .friendly)
    }

    @Test func valuesMatchTheServerContract() {
        // 맥(local-ai-agent)과 프록시가 받는 값. 바꾸면 양쪽이 400을 준다
        #expect(ReplyTone.allCases.map(\.rawValue) == ["friendly", "formal"])
        #expect(ReplyTone.allCases.map(\.title) == ["친근하게", "딱딱하게"])
    }

    @Test func claudeQuestionCarriesTheChosenTone() async throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let meeting = Meeting(title: "주간 회의")
        context.insert(meeting)
        meeting.appendUtterance(Utterance(start: 0, end: 5, text: "베타 출시는 12월 3일로 정했습니다."))
        let provider = FakeAskProvider([
            .success(.init(answer: "12월 3일입니다.", found: true, citations: [])),
            .success(.init(answer: "12월 3일이에요.", found: true, citations: [])),
        ])
        var tone = ReplyTone.formal
        let session = AskSession(provider: provider, agent: nil, tone: { tone })
        await session.send("출시일은?", meetings: [meeting])
        tone = .friendly
        await session.send("다시 알려줘", meetings: [meeting])
        #expect(provider.requests.map(\.tone) == ["formal", "friendly"])
    }

    @Test func toneIsLeftOutOfTheRequestWhenUnset() throws {
        let request = AskRequest(question: "q", history: [], meetings: [], otherMeetings: [])
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!json.contains("tone"))
    }
}
