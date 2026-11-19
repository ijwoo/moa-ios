import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

/// 대화 담당의 반응 (D70): 맥이 내 말에 이모지 하나를 달 수 있다. 앱은 그릴 수 있다고 알린 요청에만 받는다.
/// 여기의 대화는 모두 가상의 말이다
@MainActor
@Suite("반응: 대화 담당이 내 말에 이모지를 단다")
struct AgentReactionTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func mac(reacts: Bool = true, weather: Bool = false) -> MockAgentClient {
        MockAgentClient(v2: true, dialogCloud: MockDialogCloud(marksWriter: true, showsWeather: weather, reacts: reacts))
    }

    private func session(_ agent: MockAgentClient) -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero, weather: MockWeatherService())
        session.attach(context)
        return session
    }

    private func decode(_ json: String, accepts: Bool = true) throws -> AgentReply {
        try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200, acceptsReaction: accepts)
    }

    private func body(features: Set<String>, extras: MessageExtras) throws -> [String: Any] {
        let body = AgentHTTPClient.MessageBody(
            text: "ㅇㅋ", conversationID: "c_1", context: nil, messageID: "m_1", replyTaskID: nil,
            tone: "friendly", features: features, extras: extras
        )
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    // MARK: - 맥과 맞춘 값

    @Test func namesMatchTheMac() {
        #expect(AgentFeature.reaction == "reaction")
        #expect(MessageExtras.reactionFeature == "reaction")
        #expect(AgentReaction.allowed == ["👍", "❤️", "😂", "😮", "😢", "🙏", "👌", "🎉"])
    }

    @Test func onlyTheAgreedEmojiAreKnown() {
        for emoji in AgentReaction.allowed { #expect(AgentReaction.known(emoji) == emoji) }
        // 하트는 꾸밈 표시가 빠져 와도 같은 것으로 읽는다
        #expect(AgentReaction.known("\u{2764}") == "❤️")
        #expect(AgentReaction.known(" 👌\n") == "👌")
        #expect(AgentReaction.known("🔥") == nil)
        #expect(AgentReaction.known("👍👍") == nil)
        #expect(AgentReaction.known("좋아요") == nil)
        #expect(AgentReaction.known("") == nil)
        #expect(AgentReaction.known(nil) == nil)
    }

    // MARK: - 요청

    @Test func theNameGoesOnlyToAMacThatKnowsIt() throws {
        let extras = MessageExtras(clientFeatures: ["weather", "reaction"])
        #expect(try body(features: [], extras: extras)["client_features"] == nil)
        #expect(try body(features: [AgentFeature.weatherAction], extras: extras)["client_features"] as? [String] == ["weather"])
        #expect(try body(features: [AgentFeature.reaction], extras: extras)["client_features"] as? [String] == ["reaction"])
        let both = try body(features: [AgentFeature.weatherAction, AgentFeature.reaction], extras: extras)
        #expect(both["client_features"] as? [String] == ["weather", "reaction"])
        // 모르는 이름은 보내지 않는다
        let odd = MessageExtras(clientFeatures: ["reaction", "sticker"])
        #expect(try body(features: [AgentFeature.reaction], extras: odd)["client_features"] as? [String] == ["reaction"])
    }

    // MARK: - 응답

    @Test func aReplyCanCarryAReaction() throws {
        let reply = try decode("""
        {"conversation_id": "c_1", "replies": [{"text": "별거 아니에요 ㅎㅎ", "by": "claude"}], "action": {"type": "none"}, "reaction": "🙏"}
        """)
        #expect(reply.replies == ["별거 아니에요 ㅎㅎ"])
        #expect(reply.reaction == "🙏")
        #expect(reply.action == AgentReply.Action.none)
    }

    @Test func aReactionAloneIsAnAnswer() throws {
        let only = #"{"conversation_id": "c_1", "replies": [], "action": {"type": "none"}, "reaction": "👌"}"#
        let reply = try decode(only)
        #expect(reply.replies.isEmpty)
        #expect(reply.reaction == "👌")
        // 알리지 않은 요청에는 말이 있어야 한다 (전과 같다)
        #expect(throws: AgentError.invalidResponse) { try decode(only, accepts: false) }
    }

    @Test func oddReactionsAreReadAsNone() throws {
        func reaction(_ value: String, accepts: Bool = true) throws -> String? {
            try decode(
                #"{"conversation_id": "c_1", "replies": [{"text": "네!"}], "action": {"type": "none"}, "reaction": \#(value)}"#,
                accepts: accepts
            ).reaction
        }
        #expect(try reaction(#""🎉""#) == "🎉")
        #expect(try reaction(#""🔥""#) == nil)
        #expect(try reaction("3") == nil)
        #expect(try reaction("true") == nil)
        #expect(try reaction("null") == nil)
        #expect(try reaction(#"["👍"]"#) == nil)
        // 알리지 않은 요청에 온 반응은 읽지 않는다
        #expect(try reaction(#""🎉""#, accepts: false) == nil)
        // 모르는 반응만 있고 말이 없으면 답이 아니다
        #expect(throws: AgentError.invalidResponse) {
            try decode(#"{"conversation_id": "c_1", "replies": [], "action": {"type": "none"}, "reaction": "🔥"}"#)
        }
    }

    @Test func aTaskReplyCanCarryAReactionToo() throws {
        let reply = try decode("""
        {"conversation_id": "c_1", "replies": [{"text": "네, 준비할게요."}], "reaction": "👍",
         "action": {"type": "task", "task": {"id": "t_1", "status": "queued", "task": "회의록 정리", "steps": []}}}
        """)
        #expect(reply.reaction == "👍")
        if case .task(let state) = reply.action { #expect(state.id == "t_1") } else { Issue.record("작업이 아니다") }
    }

    // MARK: - 대화

    @Test func aReactionLandsOnMyBubble() async {
        let agent = mac()
        let session = session(agent)
        await session.send("고마워", meetings: [])
        #expect(await agent.receivedExtras == [MessageExtras(clientFeatures: ["reaction"])])
        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(session.messages[0].agentReaction == "🙏")
        // 내가 붙이는 반응과는 따로다
        #expect(session.messages[0].reaction == nil)
        #expect(session.messages[1].agentReaction == nil)
    }

    @Test func aReactionAloneLeavesNoBubbleAndNoError() async {
        let agent = mac()
        let session = session(agent)
        await session.send("ㅇㅋ", meetings: [])
        #expect(session.messages.map(\.role) == [.user])
        #expect(session.messages[0].agentReaction == "👌")
        #expect(!session.isLoading)

        // 답을 받은 말이다: 화면으로 돌아와도 다시 보내지 않고, 답을 못 받았다고 하지 않는다
        await session.resumeMessage(meetings: [])
        #expect(session.messages.map(\.role) == [.user])
        #expect(await agent.received.count == 1)
    }

    @Test func theSameWordsAgainAreANewMessage() async {
        let agent = mac()
        let session = session(agent)
        await session.send("ㅇㅋ", meetings: [])
        await session.send("ㅇㅋ", meetings: [])
        #expect(session.messages.map(\.text) == ["ㅇㅋ", "ㅇㅋ"])
        #expect(session.messages.map(\.agentReaction) == ["👌", "👌"])
        let ids = await agent.messageIDs
        #expect(ids.count == 2 && ids[0] != ids[1])
    }

    @Test func myOwnReactionSitsBesideIt() async {
        let session = session(mac())
        await session.send("나 합격했어", meetings: [])
        let mine = session.messages[0].id
        #expect(session.messages[0].agentReaction == "🎉")
        session.react(mine, with: "❤️")
        #expect(session.messages[0].reaction == "❤️")
        #expect(session.messages[0].agentReaction == "🎉")
        // 내 반응을 떼어도 받은 반응은 그대로다
        session.react(mine, with: "❤️")
        #expect(session.messages[0].reaction == nil)
        #expect(session.messages[0].agentReaction == "🎉")
    }

    @Test func theReactionSurvivesReopening() async throws {
        let agent = mac()
        let session = session(agent)
        await session.send("ㅇㅋ", meetings: [])
        try context.save()

        let reopened = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero, weather: MockWeatherService())
        reopened.attach(context)
        #expect(reopened.messages.map(\.agentReaction) == ["👌"])
        // 다시 열어도 답을 받은 말이다
        await reopened.resumeMessage(meetings: [])
        #expect(reopened.messages.map(\.role) == [.user])
        #expect(await agent.received.count == 1)
    }

    @Test func aMacThatDoesNotReactIsAskedAsBefore() async {
        let agent = mac(reacts: false)
        let session = session(agent)
        await session.send("고마워", meetings: [])
        #expect(await agent.receivedExtras == [.none])
        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(session.messages[0].agentReaction == nil)
    }

    @Test func aReactionIsIgnoredWhenIDidNotAskForIt() async {
        // 반응을 모른다고 한 맥이 반응을 보내도 붙이지 않는다
        let agent = mac(reacts: false)
        await agent.script(AgentReply(conversationID: "c_1", replies: ["네!"], action: .none, reaction: "👍"))
        let session = session(agent)
        await session.send("이거 봐", meetings: [])
        #expect(session.messages[0].agentReaction == nil)
        #expect(session.messages.last?.text == "네!")
    }

    @Test func anUnknownEmojiIsNotDrawn() async {
        let agent = mac()
        await agent.script(AgentReply(conversationID: "c_1", replies: ["네!"], action: .none, reaction: "🔥"))
        let session = session(agent)
        await session.send("이거 봐", meetings: [])
        #expect(session.messages[0].agentReaction == nil)
    }

    @Test func weatherAndReactionGoTogether() async {
        let agent = mac(weather: true)
        let session = session(agent)
        await session.send("고마워", meetings: [])
        #expect(await agent.receivedExtras == [MessageExtras(clientFeatures: ["weather", "reaction"])])
        #expect(session.messages[0].agentReaction == "🙏")
    }

    @Test func aTaskCanComeWithAReaction() async {
        let agent = mac()
        let task = AgentTaskState(id: "t_9", task: "회의록 정리", steps: [], phase: .done)
        await agent.script(AgentReply(conversationID: "c_1", replies: ["네, 해 둘게요."], action: .task(task), reaction: "👍"))
        let session = session(agent)
        await session.send("회의록 정리해 줘", meetings: [])
        #expect(session.messages[0].agentReaction == "👍")
        #expect(session.messages.contains { $0.agent?.id == "t_9" })
    }

    @Test func theSetupNamesReactOnlyWhenTheMacDoes() async {
        #expect(await mac().supports(AgentFeature.reaction))
        #expect(await mac(reacts: false).supports(AgentFeature.reaction) == false)
        #expect(MockDialogCloud(demo: "react").reacts)
        #expect(MockDialogCloud(demo: "react").showsWeather)
        #expect(MockDialogCloud(demo: "weather").reacts == false)
    }
}
