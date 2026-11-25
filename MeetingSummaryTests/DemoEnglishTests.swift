import Foundation
import Testing
@testable import MeetingSummary

// English commands in the README demos (`-demoEnglish`). Without the flag the app text stays Korean.
// README 영어 데모 명령. 플래그가 없으면 화면 글은 한국어 그대로다.

@Suite("README English demo commands")
struct DemoEnglishTests {
    @Test func theDemoReelUnderstandsEnglishPriceRequests() {
        #expect(MockAgentClient.englishPriceAsk("Find the lowest price for wireless earbuds"))
        #expect(MockAgentClient.englishPriceAsk("What's the cheapest one?"))
        #expect(!MockAgentClient.englishPriceAsk("Summarize today's email"))
    }

    @Test func steeringUnderstandsEnglishChanges() {
        #expect(MockAgentClient.englishSteer("Switch to a bar chart"))
        #expect(MockAgentClient.englishSteer("Make it shorter"))
        #expect(!MockAgentClient.englishSteer("Make a 1-page report"))
    }

    @Test func withoutTheFlagTextStaysKorean() {
        #expect(!DemoText.english)
        #expect(DemoText.t("모아") == "모아")
        #expect(MockAgentClient.handoverChoices == ["다 했어요", "그만하기"])
    }
}
