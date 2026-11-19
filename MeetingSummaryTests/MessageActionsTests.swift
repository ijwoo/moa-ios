import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

@Suite("말풍선 길게 누르기: 반응·답장")
@MainActor
struct MessageActionsTests {
    let context: ModelContext
    let meeting: Meeting

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        meeting = Meeting(title: "주간 회의")
        context.insert(meeting)
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
    }

    private func answers(_ texts: String...) -> FakeAskProvider {
        FakeAskProvider(texts.map { .success(.init(answer: $0, found: true, citations: [])) })
    }

    // MARK: - 반응

    @Test func reactionTogglesAndSurvivesRelaunch() async throws {
        let provider = answers("12월 3일입니다.")
        let session = AskSession(provider: provider, agent: nil)
        session.attach(context)
        await session.send("출시일은?", meetings: [meeting])
        let answer = try #require(session.messages.last)

        session.react(answer.id, with: "👍")
        #expect(session.messages.last?.reaction == "👍")
        // 다른 반응을 고르면 바뀐다 (말 하나에 반응 하나)
        session.react(answer.id, with: "🔥")
        #expect(session.messages.last?.reaction == "🔥")

        let reopened = AskSession(provider: provider, agent: nil)
        reopened.attach(context)
        #expect(reopened.messages.map(\.reaction) == [nil, "🔥"])

        // 같은 반응을 다시 고르면 지워지고, 지운 것도 저장된다
        reopened.react(answer.id, with: "🔥")
        #expect(reopened.messages.last?.reaction == nil)
        let again = AskSession(provider: provider, agent: nil)
        again.attach(context)
        #expect(again.messages.last?.reaction == nil)
    }

    @Test func reactingKeepsTheConversationWhereItWas() async throws {
        let session = AskSession(provider: answers("12월 3일입니다."), agent: nil)
        session.attach(context)
        await session.send("출시일은?", meetings: [meeting])
        let conversation = try #require(session.conversation)
        let before = conversation.updatedAt
        let records = conversation.records.count

        session.react(try #require(session.messages.first).id, with: "❤️")
        // 반응은 새 말이 아니다: 기록이 늘지 않고, 기록 목록의 순서(최근 시각)도 그대로다
        #expect(conversation.records.count == records)
        #expect(conversation.updatedAt == before)
    }

    @Test func errorsCannotBeReactedTo() async {
        let session = AskSession(provider: FakeAskProvider([.failure(.notConfigured)]), agent: nil)
        session.attach(context)
        await session.send("출시일은?", meetings: [meeting])
        guard let error = session.messages.last, error.role == .error else {
            Issue.record("오류 메시지가 있어야 한다")
            return
        }
        session.react(error.id, with: "👍")
        #expect(session.messages.last?.reaction == nil)
        #expect(session.quote(for: error.id) == nil)
    }

    // MARK: - 답장

    @Test func excerptFlattensLinesAndCutsLongText() {
        #expect(AskSession.Quote.excerpt("첫 줄\n\n둘째   줄") == "첫 줄 둘째 줄")
        let long = String(repeating: "가", count: 300)
        let cut = AskSession.Quote.excerpt(long)
        #expect(cut.count == AskSession.Quote.maxLength)
        #expect(cut.hasSuffix("…"))
    }

    @Test func replyQuoteIsShownAndSavedWithTheMessage() async throws {
        let provider = answers("12월 3일입니다.", "네, 확정입니다.")
        let session = AskSession(provider: provider, agent: nil)
        session.attach(context)
        await session.send("출시일은?", meetings: [meeting])
        let answer = try #require(session.messages.last)
        let quote = try #require(session.quote(for: answer.id))
        #expect(quote == .init(messageID: answer.id, fromUser: false, text: "12월 3일입니다."))

        await session.send("확정이야?", meetings: [meeting], replyTo: quote)
        #expect(session.messages[2].text == "확정이야?")
        #expect(session.messages[2].replyTo == quote)

        let reopened = AskSession(provider: provider, agent: nil)
        reopened.attach(context)
        #expect(reopened.messages.map(\.replyTo) == [nil, nil, quote, nil])
    }

    @Test func claudeGetsTheQuoteWithTheQuestion() async throws {
        let provider = answers("12월 3일입니다.", "네, 확정입니다.")
        let session = AskSession(provider: provider, agent: nil)
        session.attach(context)
        await session.send("출시일은?", meetings: [meeting])
        let answer = try #require(session.messages.last)

        await session.send("확정이야?", meetings: [meeting], replyTo: session.quote(for: answer.id))
        #expect(provider.requests.last?.question == "(앞에서 받은 답 \"12월 3일입니다.\"에 대한 답장) 확정이야?")
        // 화면과 기록에는 내가 쓴 글만 남는다
        #expect(session.messages[2].text == "확정이야?")
    }

    @Test func quotingMyOwnWordsSaysSo() {
        let quote = AskSession.Quote(messageID: UUID(), fromUser: true, text: "출시일은?")
        #expect(AskSession.questionWithQuote("다시 알려줘", quote: quote) == "(내가 앞에서 한 말 \"출시일은?\"에 대한 답장) 다시 알려줘")
        #expect(AskSession.questionWithQuote("다시 알려줘", quote: nil) == "다시 알려줘")
    }

    @Test func quoteIsLeftOutWhenTheQuestionWouldPassTheServerLimit() {
        let quote = AskSession.Quote(messageID: UUID(), fromUser: false, text: String(repeating: "가", count: 100))
        let short = String(repeating: "나", count: 300)
        #expect(AskSession.questionWithQuote(short, quote: quote).count <= 500)
        #expect(AskSession.questionWithQuote(short, quote: quote) != short)
        // 중계 서버는 500자를 넘는 질문을 거절한다. 넘으면 인용 없이 질문만 보낸다
        let long = String(repeating: "나", count: 480)
        #expect(AskSession.questionWithQuote(long, quote: quote) == long)
    }

    @Test func wordsHandledByTheMacAreNeverQuotedToClaude() async throws {
        let cloud = answers("12월 3일입니다.")
        let session = AskSession(provider: cloud, agent: MockAgentClient(reachable: true), pollInterval: .zero)
        session.attach(context)
        await session.checkAgent()
        // 맥이 직접 답한 말 (인사)
        await session.send("안녕", meetings: [meeting])
        let macAnswer = try #require(session.messages.last)
        #expect(macAnswer.role == .assistant)
        #expect(macAnswer.engine == .local)

        // 그 말에 답장하면서 Claude에게 묻는다: 말풍선에는 인용이 붙지만 Claude로는 질문만 간다
        let quote = try #require(session.quote(for: macAnswer.id))
        await session.send("출시일은?", meetings: [meeting], engine: .cloud, replyTo: quote)
        #expect(session.messages.contains { $0.replyTo == quote })
        #expect(cloud.requests.last?.question == "출시일은?")
    }

    @Test func agentRunsCannotBeQuotedOnAMacThatDoesNotTakeTaskReplies() async throws {
        let session = AskSession(provider: nil, agent: MockAgentClient(reachable: true), pollInterval: .zero)
        session.attach(context)
        await session.checkAgent()
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        let run = try #require(session.messages.first { $0.role == .agent })
        // 인용만 붙고 맥이 무엇을 가리키는지 모르면 알아들은 것처럼 보이기만 한다. 그래서 답장을 두지 않는다
        #expect(!session.canReplyToTask)
        #expect(session.quote(for: run.id) == nil)
    }

    @Test func agentRunsAreQuotedByTitleOnlyAndTakeNoReaction() async throws {
        let session = AskSession(provider: nil, agent: MockAgentClient(reachable: true, v2: true), pollInterval: .zero)
        session.attach(context)
        await session.checkAgent()
        await session.send("메일 초안 써줘", meetings: [meeting], engine: .local)
        let run = try #require(session.messages.first { $0.role == .agent })
        // 맡긴 일은 제목으로만 인용한다 (D59). 결과 글은 인용에 들어가지 않는다
        let quote = try #require(session.quote(for: run.id))
        #expect(quote.isTask == true)
        #expect(quote.text == AskSession.Quote.excerpt(try #require(run.agent).title))
        #expect(quote.label == "맡긴 일")
        session.react(run.id, with: "👍")
        #expect(session.messages.allSatisfy { $0.reaction == nil })
    }

    @Test func recordsSavedBeforeThisFeatureStillLoad() throws {
        let conversation = Conversation(title: "예전 대화")
        context.insert(conversation)
        conversation.records.append(ChatRecord(role: "user", text: "출시일은?"))
        conversation.records.append(ChatRecord(role: "assistant", text: "12월 3일입니다.", createdAt: .now.addingTimeInterval(1)))
        try context.save()

        let session = AskSession(provider: nil, agent: nil)
        session.open(conversation)
        #expect(session.messages.map(\.text) == ["출시일은?", "12월 3일입니다."])
        #expect(session.messages.allSatisfy { $0.reaction == nil && $0.replyTo == nil })
    }

    // MARK: - 답변 글 표시

    @Test func plainAnswersAreShownExactlyAsWritten() {
        // 강조 표시가 없는 글은 손대지 않는다 (별표 하나를 강조로 읽어 글자가 사라지면 안 된다)
        let text = "가격은 2*3*4=24, 파일은 a_b_c.txt"
        #expect(!ChatText.hasMarkup(text))
        #expect(String(ChatText.attributed(text).characters) == text)
    }

    @Test func boldMarkersAreRenderedNotPrinted() {
        let shown = ChatText.attributed("출시일은 **12월 3일**입니다.\n다음 줄")
        #expect(String(shown.characters) == "출시일은 12월 3일입니다.\n다음 줄")
    }
}
