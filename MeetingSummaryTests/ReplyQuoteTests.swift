import Foundation
import Testing
@testable import MeetingSummary

// 말풍선에 답장할 때 그 말을 맥에 함께 보내기 (D124, 맥의 D108). 모두 지어낸 말이다.

@Suite("답장: 말풍선의 글을 함께")
struct ReplyQuoteTests {
    private func object(_ body: AgentHTTPClient.MessageBody) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    private func body(task: String? = nil, quote: MessageExtras.ReplyQuote?, features: Set<String> = [AgentFeature.replyTo]) -> AgentHTTPClient.MessageBody {
        var extras = MessageExtras.none
        extras.replyQuote = quote
        return AgentHTTPClient.MessageBody(
            text: "그거 몇 시였지?", conversationID: "c_1", context: nil, messageID: nil, replyTaskID: task,
            tone: "friendly", features: features, extras: extras
        )
    }

    @Test func aBubbleReplyCarriesItsTextAndWhoSaidIt() throws {
        let said = try #require(MessageExtras.ReplyQuote(text: "내일 오후 3시에 회의가 있어요", role: .assistant))
        #expect(try object(body(quote: said))["reply_to"] as? [String: String] == ["text": "내일 오후 3시에 회의가 있어요", "role": "assistant"])
        let mine = try #require(MessageExtras.ReplyQuote(text: "가상 회의록 정리해줘", role: .user))
        #expect(try object(body(quote: mine))["reply_to"] as? [String: String] == ["text": "가상 회의록 정리해줘", "role": "user"])
    }

    @Test func aTaskReplyStaysAsItWas() throws {
        // 작업에 답장했으면 작업 번호만 (맥은 그것을 먼저 쓴다)
        let said = MessageExtras.ReplyQuote(text: "가상 결과", role: .assistant)
        #expect(try object(body(task: "t_1", quote: said))["reply_to"] as? [String: String] == ["task_id": "t_1"])
    }

    @Test func aMacThatDoesNotKnowRepliesGetsNothing() throws {
        let said = MessageExtras.ReplyQuote(text: "가상 답", role: .assistant)
        #expect(try object(body(quote: said, features: []))["reply_to"] == nil)
    }

    @Test func theTextIsTrimmedAndCut() {
        #expect(MessageExtras.ReplyQuote(text: "  \n ", role: .user) == nil)
        let long = MessageExtras.ReplyQuote(text: " " + String(repeating: "가", count: 700), role: .assistant)
        #expect(long?.text.count == 500 && long?.text.first == "가")
    }
}

@Suite("답장: 대화에서 보내기")
@MainActor
struct ReplyQuoteSessionTests {
    @Test func replyingToABubbleSendsThatBubble() async throws {
        let agent = MockAgentClient(v2: true)
        await agent.script(AgentReply(conversationID: "", replies: ["내일 오후 3시에 가상 회의가 있어요."], action: .none))
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        await session.send("가상 회의 일정 알려줘", meetings: [])
        let answer = try #require(session.messages.last { $0.role == .assistant })
        let quote = try #require(session.quote(for: answer.id))
        await session.send("그거 몇 시라고?", meetings: [], replyTo: quote)
        let sent = await agent.receivedExtras.map(\.replyQuote)
        #expect(sent.first == .some(nil))
        #expect(sent.last == MessageExtras.ReplyQuote(text: "내일 오후 3시에 가상 회의가 있어요.", role: .assistant))
        // 내 말에 답장해도 그 말이 간다
        let mine = try #require(session.messages.first { $0.role == .user })
        await session.send("이거 취소", meetings: [], replyTo: try #require(session.quote(for: mine.id)))
        #expect(await agent.receivedExtras.last?.replyQuote == MessageExtras.ReplyQuote(text: "가상 회의 일정 알려줘", role: .user))
    }
}
