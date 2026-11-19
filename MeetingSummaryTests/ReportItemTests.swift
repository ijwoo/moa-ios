import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

/// 찾은 상품 목록 (D72): 맥이 `result.report.items`로 준 상품을 대화에서 카드로 그리고, 고른 상품의 번호를 맥에 알린다.
/// 여기의 물건·가게·값·주소는 모두 지어낸 것이다
@MainActor
@Suite("상품 목록: 찾은 상품을 카드로 그리고, 고른 것을 알린다")
struct ReportItemTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func mac(lists: Bool = true) -> MockAgentClient {
        MockAgentClient(v2: true, dialogCloud: MockDialogCloud(marksWriter: true, findsPages: true, listsItems: lists))
    }

    private func session(_ agent: MockAgentClient) async -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero, weather: MockWeatherService())
        session.attach(context)
        await session.checkAgent()
        return session
    }

    /// 작업 상태 응답에서 보고의 상품 목록을 읽는다 (`items`는 JSON 배열의 글)
    private func items(_ items: String) throws -> [AgentItem]? {
        let json = """
        {"id":"t_shop1","status":"completed","task":"무선 이어폰 추천해줘","title":"상품 찾기",\
        "created_at":"2026-11-14T09:30:00+00:00","updated_at":"2026-11-14T09:30:41+00:00","steps":[],\
        "result":{"outcome":"completed","summary":"무선 이어폰을 찾았어요","approved_drafts":[],\
        "report":{"done":["무선 이어폰을 찾았어요."],"blocked":[],"sources":[],"items":\(items)}}}
        """
        return try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200).report?.items
    }

    private func body(features: Set<String>, task: String?, item: String?) throws -> [String: Any] {
        let body = AgentHTTPClient.MessageBody(
            text: "이걸로 할게요", conversationID: "c_1", context: nil, messageID: "m_1", replyTaskID: task,
            tone: "friendly", features: features, extras: MessageExtras(replyItemID: item)
        )
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    // MARK: - 맥과 맞춘 값

    @Test func namesMatchTheMac() {
        #expect(AgentFeature.reportItems == "report_items")
        #expect(AgentItem.reportLimit == 8)
    }

    // MARK: - 읽기

    @Test func anItemIsReadAsSent() throws {
        let found = try #require(try items("""
        [{"id": "i1", "title": "소리콩 2 무선 이어폰", "price": 89000, "mall": "가상몰", "brand": "소리콩",
          "url": "https://shop.example.com/earbuds/sorikong-2", "image": "https://img.example.com/sorikong-2.jpg"}]
        """))
        #expect(found.count == 1)
        let item = found[0]
        #expect(item.id == "i1")
        #expect(item.title == "소리콩 2 무선 이어폰")
        #expect(item.price == 89_000)
        #expect(item.mall == "가상몰")
        #expect(item.brand == "소리콩")
        #expect(item.url.absoluteString == "https://shop.example.com/earbuds/sorikong-2")
        #expect(item.image?.absoluteString == "https://img.example.com/sorikong-2.jpg")
        #expect(item.shipping == nil && item.detail == nil)
        #expect(item.priceText == "89,000원")
        #expect(item.caption == "가상몰 · 소리콩")
    }

    @Test func laterKeysAreReadWhenTheyCome() throws {
        let item = try #require(try items("""
        [{"id": "i2", "title": "가상 단백질 음료 초코", "price": 27400, "mall": "가상몰", "url": "https://shop.example.com/p/2",
          "shipping": "무료배송", "detail": "250ml × 18팩", "rank": 1}]
        """)?.first)
        #expect(item.shipping == "무료배송")
        #expect(item.detail == "250ml × 18팩")
        #expect(item.caption == "가상몰 · 무료배송")
    }

    @Test func aBadItemIsDroppedAlone() throws {
        let found = try #require(try items("""
        [{"id": "i1", "title": "이름과 주소가 있는 상품", "price": 1000, "url": "https://shop.example.com/1"},
         {"id": "i2", "price": 2000, "url": "https://shop.example.com/2"},
         {"id": "i3", "title": "   ", "url": "https://shop.example.com/3"},
         {"id": "i4", "title": "주소가 없는 상품", "price": 4000},
         {"id": "i5", "title": "http 주소", "url": "http://shop.example.com/5"},
         {"id": "i6", "title": "내부 주소", "url": "https://mac.local/6"},
         {"id": "i7", "title": "숫자 주소", "url": "https://192.168.0.7/7"},
         "글자", 7, null, ["배열"],
         {"id": "i8", "title": "마지막 상품", "price": 8000, "url": "https://shop.example.com/8"}]
        """))
        #expect(found.map(\.id) == ["i1", "i8"])
    }

    @Test func aPriceIsOnlyAWholePositiveNumber() throws {
        func price(_ value: String) throws -> Int? {
            try #require(try items(#"[{"title": "상품", "price": \#(value), "url": "https://shop.example.com/1"}]"#)?.first).price
        }
        #expect(try price("89000") == 89_000)
        #expect(try price("1") == 1)
        #expect(try price("89000.0") == 89_000)
        // 글자로 온 값은 짐작하지 않는다. 0·음수·소수·참거짓도 값이 아니다
        #expect(try price(#""89000""#) == nil)
        #expect(try price(#""89,000원""#) == nil)
        #expect(try price("0") == nil)
        #expect(try price("-500") == nil)
        #expect(try price("89000.5") == nil)
        #expect(try price("true") == nil)
        #expect(try price("null") == nil)
        #expect(try price("1e15") == nil)
        // 값이 없어도 상품은 보여 준다 (값만 그리지 않는다)
        let bare = try #require(try items(#"[{"title": "값이 없는 상품", "url": "https://shop.example.com/1"}]"#)?.first)
        #expect(bare.price == nil && bare.priceText == nil)
    }

    @Test func aBadPictureOrOddTextDropsOnlyThatPart() throws {
        let item = try #require(try items("""
        [{"id": 3, "title": "소리콩 2\\n무선   이어폰 ", "price": 89000, "mall": 12, "brand": "  ",
          "url": "https://shop.example.com/1", "image": "http://img.example.com/1.jpg", "shipping": ["무료"], "detail": null}]
        """)?.first)
        #expect(item.id == nil)
        #expect(item.title == "소리콩 2 무선 이어폰")
        #expect(item.mall == nil && item.brand == nil && item.shipping == nil && item.detail == nil)
        #expect(item.image == nil)
        // 파는 곳 이름이 없으면 실제로 열리는 주소를 보여 준다
        #expect(item.caption.isEmpty)
        #expect(item.host == "shop.example.com")
    }

    @Test func theSameAddressOrNumberComesOnce() throws {
        let found = try #require(try items("""
        [{"id": "i1", "title": "첫 상품", "url": "https://shop.example.com/1"},
         {"id": "i2", "title": "같은 주소", "url": "https://shop.example.com/1"},
         {"id": "i1", "title": "같은 번호", "url": "https://shop.example.com/3"},
         {"id": "i4", "title": "넷째", "url": "https://shop.example.com/4"}]
        """))
        #expect(found.map(\.title) == ["첫 상품", "넷째"])
    }

    @Test func atMostEightAreShown() throws {
        let many = (1...12).map { #"{"id": "i\#($0)", "title": "상품 \#($0)", "price": \#($0 * 1000), "url": "https://shop.example.com/\#($0)"}"# }
        let found = try #require(try items("[\(many.joined(separator: ","))]"))
        #expect(found.count == 8)
        #expect(found.last?.id == "i8")
    }

    @Test func anOddListIsNoList() throws {
        #expect(try items("[]") == nil)
        #expect(try items(#""상품""#) == nil)
        #expect(try items("3") == nil)
        #expect(try items(#"{"title": "상품"}"#) == nil)
        #expect(try items("null") == nil)
    }

    @Test func aReportWithOnlyItemsIsNotEmpty() {
        #expect(AgentReport().isEmpty)
        #expect(!AgentReport(items: [MockShop.items[0]]).isEmpty)
    }

    @Test func theListSurvivesStoring() throws {
        let report = AgentReport(done: ["찾았어요."], items: MockShop.items)
        let back = try JSONDecoder().decode(AgentReport.self, from: JSONEncoder().encode(report))
        #expect(back == report)
        // 상품 목록이 없던 때 저장한 보고도 읽힌다
        let old = try JSONDecoder().decode(AgentReport.self, from: Data(#"{"done": ["찾았어요."], "blocked": [], "sources": []}"#.utf8))
        #expect(old.items == nil)
    }

    // MARK: - 요청

    @Test func theItemNumberGoesOnlyToAMacThatKnowsIt() throws {
        let both: Set<String> = [AgentFeature.replyTo, AgentFeature.reportItems]
        let reply = try #require(try body(features: both, task: "t_1", item: "i2")["reply_to"] as? [String: String])
        #expect(reply == ["task_id": "t_1", "item_id": "i2"])
        // 상품 목록을 모르는 맥에는 작업 번호만 간다
        let old = try #require(try body(features: [AgentFeature.replyTo], task: "t_1", item: "i2")["reply_to"] as? [String: String])
        #expect(old == ["task_id": "t_1"])
        // 가리킨 작업이 없으면 상품 번호도 가지 않는다
        #expect(try body(features: both, task: nil, item: "i2")["reply_to"] == nil)
        #expect(try body(features: [AgentFeature.reportItems], task: "t_1", item: "i2")["reply_to"] == nil)
        // 고르지 않은 답장은 전과 같다
        let plain = try #require(try body(features: both, task: "t_1", item: nil)["reply_to"] as? [String: String])
        #expect(plain == ["task_id": "t_1"])
    }

    // MARK: - 대화

    @Test func askingForSomethingToBuyBringsAList() async {
        let agent = mac()
        let session = await session(agent)
        await session.send("무선 이어폰 추천해줘", meetings: [])
        let task = session.messages.last(where: { $0.role == .agent })?.agent
        #expect(task?.phase == .done)
        #expect(task?.report?.items == MockShop.items)
        #expect(task?.report?.done == MockShop.answer)
        #expect(session.showsItemPick)
        #expect(session.canPickItemNow)
    }

    @Test func pickingSendsTheTaskAndTheItemNumber() async throws {
        let agent = mac()
        let session = await session(agent)
        await session.send("무선 이어폰 추천해줘", meetings: [])
        let card = try #require(session.messages.last(where: { $0.role == .agent }))
        let task = try #require(card.agent)
        let item = MockShop.items[1]

        await session.pick(item, from: task.id, meetings: [])
        // 내 말로 남는다: 그 일에 답장한 말이고, 상품 이름은 받은 그대로다
        let mine = try #require(session.messages.last(where: { $0.role == .user }))
        #expect(mine.text == "이걸로 할게요: \(item.title)")
        #expect(mine.replyTo?.messageID == card.id)
        #expect(mine.replyTo?.isTask == true)
        #expect(mine.replyTo?.itemID == "i2")
        // 맥에는 작업 번호와 상품 번호가 간다
        #expect(await agent.replyTaskIDs.last == task.id)
        #expect(await agent.receivedExtras.last?.replyItemID == "i2")
        // 맥은 글이 아니라 번호로 집는다
        #expect(session.messages.last?.role == .assistant)
        #expect(session.messages.last?.text == "네, ‘\(item.title)’ 골랐어요.")
    }

    @Test func aMacWithoutListsGetsNoPick() async throws {
        let agent = mac(lists: false)
        let session = await session(agent)
        #expect(!session.showsItemPick)
        await session.send("소리콩 2 가격 찾아줘", meetings: [])
        let task = try #require(session.messages.last(where: { $0.role == .agent })?.agent)
        #expect(task.report?.items == nil)
        let before = session.messages.count
        await session.pick(MockShop.items[0], from: task.id, meetings: [])
        #expect(session.messages.count == before)
        #expect(await agent.receivedExtras.allSatisfy { $0.replyItemID == nil })
    }

    @Test func onlyAnItemOfThatListCanBePicked() async throws {
        let agent = mac()
        let session = await session(agent)
        await session.send("무선 이어폰 추천해줘", meetings: [])
        let task = try #require(session.messages.last(where: { $0.role == .agent })?.agent)
        let before = session.messages.count
        let stranger = AgentItem(id: "i9", title: "목록에 없는 상품", url: URL(string: "https://shop.example.com/9")!)
        await session.pick(stranger, from: task.id, meetings: [])
        await session.pick(MockShop.items[0], from: "t_없는작업", meetings: [])
        #expect(session.messages.count == before)
    }

    @Test func thePickSurvivesReopening() async throws {
        let agent = mac()
        let session = await session(agent)
        await session.send("무선 이어폰 추천해줘", meetings: [])
        let task = try #require(session.messages.last(where: { $0.role == .agent })?.agent)
        await session.pick(MockShop.items[2], from: task.id, meetings: [])
        try context.save()

        let reopened = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero, weather: MockWeatherService())
        reopened.attach(context)
        // 목록도, 무엇을 골랐는지도 남아 있다
        #expect(reopened.messages.first(where: { $0.role == .agent })?.agent?.report?.items == MockShop.items)
        #expect(reopened.messages.last(where: { $0.role == .user })?.replyTo?.itemID == "i3")
    }

    @Test func anOrdinaryReplyCarriesNoItemNumber() async throws {
        let agent = mac()
        let session = await session(agent)
        await session.send("무선 이어폰 추천해줘", meetings: [])
        let card = try #require(session.messages.last(where: { $0.role == .agent }))
        await session.send("더 싼 건 없어?", meetings: [], replyTo: session.quote(for: card.id))
        #expect(await agent.replyTaskIDs.last == card.agent?.id)
        #expect(await agent.receivedExtras.last?.replyItemID == nil)
    }

    @Test func theSetupNamesListsOnlyWhenTheMacDoes() async {
        #expect(await mac().supports(AgentFeature.reportItems))
        #expect(await mac(lists: false).supports(AgentFeature.reportItems) == false)
        #expect(MockDialogCloud(demo: "shop").listsItems)
        #expect(MockDialogCloud(demo: "shop").reacts)
        #expect(MockDialogCloud(demo: "react").listsItems == false)
        // 찾기를 하지 않는 맥은 목록도 주지 않는다
        #expect(MockDialogCloud(listsItems: true).listsItems == false)
    }

    // MARK: - 데이터 처리 방식

    @Test func theDataPageTellsAboutListsOnlyWhenTheMacDoes() async {
        let with = await DialogSetup(agent: mac())
        #expect(with.listsItems)
        #expect(with.stored.hasSuffix(" items"))
        #expect(DialogSetup(stored: with.stored) == with)
        let without = await DialogSetup(agent: mac(lists: false))
        #expect(!without.listsItems)
        #expect(!without.stored.contains("items"))
        // 로컬 판단이면 Claude가 다시 볼 것도 없다
        #expect(DialogSetup(place: .local, listsItems: true) == .local)

        func notes(_ setup: DialogSetup) -> String {
            MacAgentFacts(setup: setup).rows.map { $0.text + " " + ($0.note ?? "") }.joined(separator: "\n")
        }
        let told = notes(with)
        #expect(told.contains("찾은 상품을 목록으로 보여 드려요. 주문은 하지 않아요"))
        #expect(told.contains("찾은 상품 목록은 공개 정보라 대화 기록에 남아서 다음 말을 판단할 때 Claude가 다시 봐요."))
        #expect(told.contains("이 아이폰이 그 페이지에 직접 접속"))
        #expect(!notes(without).contains("상품"))
    }

    @Test func theSpokenLineNamesPriceAndSeller() {
        #expect(ReportItemCards.spoken(MockShop.items[0]) == "소리콩 2 무선 이어폰 노이즈 캔슬링, 89,000원, 가상몰 · 소리콩")
        let bare = AgentItem(title: "값이 없는 상품", url: URL(string: "https://www.shop.example.com/1")!)
        #expect(ReportItemCards.spoken(bare) == "값이 없는 상품, shop.example.com")
    }
}
