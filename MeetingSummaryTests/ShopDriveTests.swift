import Foundation
import SwiftData
import Testing
import UIKit
import WebKit
@testable import MeetingSummary

/// 쇼핑 "스스로 찾아 오기" (D75): 살 것을 말하면 맥의 작업이 앱의 쇼핑 화면에 검색과 상품 열기를 시키고,
/// 앱이 읽어 온 것으로 상품 목록을 만든다. 앱은 주소를 열기만 하고 아무것도 누르지 않는다.
/// 여기의 상품·가게·주소는 모두 가상이다. 실제 쇼핑몰에는 접속하지 않는다 (가상 쇼핑몰의 페이지는 앱이 그린다)
@MainActor
@Suite("쇼핑 화면: 스스로 찾아 오기")
struct ShopDriveTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func mac(drives: Bool = true) -> MockAgentClient {
        MockAgentClient(v2: true, dialogCloud: MockDialogCloud(
            marksWriter: true, findsPages: true, listsItems: true, opensShop: true, drivesShop: drives
        ))
    }

    private func session(_ agent: MockAgentClient) -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .milliseconds(10), weather: MockWeatherService())
        session.attach(context)
        return session
    }

    private let query = "생수 2L 6개"
    private var searchURL: URL { ShopSite.demo.searchURL(for: query)! }
    private func productURL(_ index: Int) -> URL { DemoShop.productURL(DemoShop.products[index]) }

    private func search(_ id: String = "b1", _ text: String? = nil) -> AgentBrowse {
        AgentBrowse(id: id, kind: .search, query: text ?? query, items: nil)
    }

    private func open(_ id: String, _ items: [Int]) -> AgentBrowse {
        AgentBrowse(id: id, kind: .open, query: nil, items: items)
    }

    /// 화면에 붙어 있는 가상 쇼핑몰의 쇼핑 화면. `pages`: 가상 쇼핑몰의 페이지를 고쳐서 줄 때
    private final class Screen {
        let browser: ShopBrowser
        private let window: UIWindow?

        @MainActor init(pages: (@MainActor (URL) -> String?)? = nil) {
            browser = ShopBrowser(site: .demo, pages: pages ?? DemoShop.html(for:), isPersistent: false)
            browser.pace = .quick
            let web = browser.webView()
            web.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            window = scene.map { UIWindow(windowScene: $0) }
            window?.frame = web.frame
            window?.addSubview(web)
            window?.isHidden = false
        }

        @MainActor func close() {
            browser.webView().removeFromSuperview()
            window?.isHidden = true
        }
    }

    /// 쇼핑 화면이 하는 것과 같다 (`ShopCover`): 할 일이 생기면 하고, 결과를 돌려준다. 작업이 끝날 때까지
    private func serve(_ session: AskSession, _ browser: ShopBrowser, task taskID: String) async throws {
        for _ in 0..<3000 {
            if session.phase(of: taskID)?.isFinished == true { return }
            if let job = session.browseJob, let result = await browser.run(job.command, task: job.taskID) {
                await session.finishBrowse(job, result: result)
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("작업이 끝나지 않았다")
    }

    /// 살 것을 말하고, 작업이 만들어질 때까지 기다린다 (말을 보내는 일은 작업이 끝날 때까지 이어진다)
    private func ask(_ session: AskSession, _ text: String = "생수 2L 6개 사고 싶어") async throws -> (task: String, sending: Task<Void, Never>) {
        let sending = Task { await session.send(text, meetings: []) }
        for _ in 0..<500 where session.messages.last(where: { $0.role == .agent })?.agent == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = try #require(session.messages.last(where: { $0.role == .agent })?.agent)
        return (state.id, sending)
    }

    private func task(status: String, browser: String?) -> String {
        """
        {"id":"t_shop1","status":"\(status)","task":"생수 2L 6개 사고 싶어","title":"상품 찾기",\
        "created_at":"2026-11-14T12:30:00+00:00","updated_at":"2026-11-14T12:30:28+00:00","steps":[]\
        \(browser.map { ",\"browser\":\($0)" } ?? "")}
        """
    }

    private func decode(status: String = "running", browser: String?) throws -> AgentTaskState {
        try AgentHTTPClient.decodeTask(data: Data(task(status: status, browser: browser).utf8), status: 200)
    }

    private var productView: ShopView {
        ShopView(kind: .product, url: "https://store.shop.test/malgeun/products/1001", fields: ShopView.Fields(
            title: "맑은샘 생수 2L 6개", price: 5_900, shipping: "배송비 3,000원", seller: "맑은샘 상점", arrival: "내일(목) 도착 예정"
        ))
    }

    private var listView: ShopView {
        ShopView(kind: .list, url: "https://search.shop.test/search/all", fields: ShopView.Fields(items: [
            ShopView.Item(title: "맑은샘 생수 2L 6개", price: 5_900, mall: "맑은샘 상점"),
            ShopView.Item(title: "산들 암반수 2L 6개 무라벨", price: 6_480, mall: "산들마켓"),
        ]))
    }

    // MARK: - 맥과 주고받는 꼴

    @Test func aCommandIsCheckedBeforeItIsDone() {
        #expect(AgentBrowse.make(id: "b1", type: "search", query: " 생수  2L 6개 ", items: nil) == search("b1", "생수 2L 6개"))
        #expect(AgentBrowse.make(id: "b2", type: "open", query: nil, items: [0, 2, 4]) == open("b2", [0, 2, 4]))
        // 번호가 없거나 이상하면 하지 않는다
        #expect(AgentBrowse.make(id: nil, type: "search", query: "생수", items: nil) == nil)
        #expect(AgentBrowse.make(id: "", type: "search", query: "생수", items: nil) == nil)
        #expect(AgentBrowse.make(id: "b 1", type: "search", query: "생수", items: nil) == nil)
        #expect(AgentBrowse.make(id: String(repeating: "b", count: 65), type: "search", query: "생수", items: nil) == nil)
        // 모르는 일은 하지 않는다 (누르기·주소 열기 같은 것은 없다)
        #expect(AgentBrowse.make(id: "b1", type: "click", query: "생수", items: [0]) == nil)
        #expect(AgentBrowse.make(id: "b1", type: "goto", query: "https://store.shop.test/cart", items: nil) == nil)
        #expect(AgentBrowse.make(id: "b1", type: nil, query: "생수", items: nil) == nil)
        // 검색어가 없는 검색, 고른 것이 없는 열기
        #expect(AgentBrowse.make(id: "b1", type: "search", query: "  ", items: nil) == nil)
        #expect(AgentBrowse.make(id: "b1", type: "search", query: nil, items: [0]) == nil)
        #expect(AgentBrowse.make(id: "b2", type: "open", query: nil, items: []) == nil)
        #expect(AgentBrowse.make(id: "b2", type: "open", query: nil, items: nil) == nil)
        // 목록에 없는 차례, 같은 것을 두 번
        #expect(AgentBrowse.make(id: "b2", type: "open", query: nil, items: [-1]) == nil)
        #expect(AgentBrowse.make(id: "b2", type: "open", query: nil, items: [0, ShopView.itemLimit]) == nil)
        #expect(AgentBrowse.make(id: "b2", type: "open", query: nil, items: [1, 1]) == nil)
        // 검색어는 정해 둔 길이까지만
        let long = AgentBrowse.make(id: "b1", type: "search", query: String(repeating: "가", count: 300), items: nil)
        #expect(long?.query?.count == ShopView.queryLimit)
    }

    @Test func theTaskCarriesACommandOnlyWhileItRuns() throws {
        let searching = try decode(browser: #"{"id":"b1","type":"search","query":"생수 2L 6개"}"#)
        #expect(searching.phase == .running)
        #expect(searching.browse == search())
        #expect(searching.usedShop == true)

        let opening = try decode(browser: #"{"id":"b2","type":"open","items":[0,2,4]}"#)
        #expect(opening.browse == open("b2", [0, 2, 4]))

        // 시킨 일이 없는 작업은 그대로다
        let plain = try decode(browser: nil)
        #expect(plain.phase == .running)
        #expect(plain.browse == nil)
        #expect(plain.usedShop == nil)

        // 진행 중이 아니면 하지 않는다 (기다리는 중, 끝난 작업)
        for status in ["queued", "completed", "failed", "cancelled", "awaiting_approval"] {
            let state = try decode(status: status, browser: #"{"id":"b1","type":"search","query":"생수"}"#)
            #expect(state.browse == nil, "\(status)")
        }

        // 모르는 꼴이어도 작업은 읽힌다 (그 일만 하지 않는다)
        for broken in [#""search""#, "[]", "{}", #"{"id":"b1","type":"click","selector":".buy"}"#, #"{"id":7,"type":"search","query":"생수"}"#,
                       #"{"id":"b1","type":"open","items":"0"}"#, #"{"id":"b1","type":"open","items":[0,"1"]}"#, "null"] {
            let state = try decode(browser: broken)
            #expect(state.phase == .running, "\(broken)")
            #expect(state.browse == nil, "\(broken)")
        }
        // 주소가 딸려 와도 쓰지 않는다 (맥은 주소를 주지 않는다. 앱은 검색어와 차례만 읽는다)
        let withURL = try decode(browser: #"{"id":"b1","type":"search","query":"생수","url":"https://evil.example/"}"#)
        #expect(withURL.browse == search("b1", "생수"))
    }

    @Test func theResultIsSentInTheAgreedShape() throws {
        func json(_ result: BrowseResult) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        }
        // 검색: 목록 하나. 차례(item)는 없다
        let listed = try json(BrowseResult(id: "b1", outcome: .ok, views: [.init(item: nil, view: listView)]))
        #expect(listed["id"] as? String == "b1")
        #expect(listed["result"] as? String == "ok")
        #expect(listed["status"] == nil && listed["reason"] == nil)
        #expect((listed["skipped"] as? [Any])?.isEmpty == true)
        let list = try #require((listed["views"] as? [[String: Any]])?.first)
        #expect(Set(list.keys) == ["kind", "url", "fields"])
        #expect(list["kind"] as? String == "list")
        #expect(list["url"] as? String == "https://search.shop.test/search/all")
        // 목록의 상품에는 이름·값·파는 곳만 있다. 링크의 주소는 맥으로 가지 않는다
        let items = try #require((list["fields"] as? [String: Any])?["items"] as? [[String: Any]])
        #expect(items.allSatisfy { Set($0.keys).isSubset(of: ["title", "price", "mall"]) })

        // 열기: 상품 화면마다 목록에서의 차례가 붙는다. 열지 않은 것은 이유와 함께
        let opened = try json(BrowseResult(
            id: "b2", outcome: .ok, views: [.init(item: 2, view: productView)],
            skipped: [.init(item: 0, reason: .outside), .init(item: 4, reason: .noLink), .init(item: 5, reason: .notProduct)]
        ))
        let product = try #require((opened["views"] as? [[String: Any]])?.first)
        #expect(Set(product.keys) == ["item", "kind", "url", "fields"])
        #expect(product["item"] as? Int == 2)
        #expect(product["kind"] as? String == "product")
        let skipped = try #require(opened["skipped"] as? [[String: Any]])
        #expect(skipped.map { $0["item"] as? Int } == [0, 4, 5])
        #expect(skipped.map { $0["reason"] as? String } == ["outside", "no_link", "not_product"])
        #expect(BrowseResult.Skip.Reason.unread.rawValue == "unread")
        #expect(BrowseResult.Skip.Reason.failed.rawValue == "failed")
        #expect(BrowseResult.Skip.Reason.limit.rawValue == "limit")
        // 링크를 찾지 못한 까닭을 나눠 알린다 (D77)
        #expect([BrowseResult.Skip.Reason.noAnchor, .noHref, .otherMall].map(\.rawValue) == ["no_anchor", "no_href", "other_mall"])

        // 맥의 작업이 시킨 검색의 목록에는 줄마다 "바로 열 수 있는지"가 붙는다 (D77). 주소는 여전히 가지 않는다
        var marked = listView
        marked.fields.items?[0].canOpen = true
        marked.fields.items?[1].canOpen = false
        let flagged = try json(BrowseResult(id: "b1", outcome: .ok, views: [.init(item: nil, view: marked)]))
        let rows = try #require((((flagged["views"] as? [[String: Any]])?.first?["fields"] as? [String: Any])?["items"]) as? [[String: Any]])
        #expect(rows.map { $0["can_open"] as? Bool } == [true, false])
        #expect(rows.allSatisfy { Set($0.keys) == ["title", "price", "mall", "can_open"] })
        // 저장해 둔 것을 다시 읽어도 같다. 이 값이 없던 때의 것도 읽힌다
        #expect(try JSONDecoder().decode(ShopView.self, from: JSONEncoder().encode(marked)) == marked)
        #expect(try JSONDecoder().decode(ShopView.self, from: JSONEncoder().encode(listView)).fields.items?.map(\.canOpen) == [nil, nil])

        // 막힘: 응답 번호. 하지 않음: 이유. 읽은 것이 없어도 views·skipped는 빈 목록으로 간다
        let limited = try json(BrowseResult(id: "b2", outcome: .limited, status: 429))
        #expect(limited["result"] as? String == "limited")
        #expect(limited["status"] as? Int == 429)
        #expect((limited["views"] as? [Any])?.isEmpty == true)
        let refused = try json(BrowseResult(id: "b3", outcome: .refused, reason: "cap"))
        #expect(refused["result"] as? String == "refused")
        #expect(refused["reason"] as? String == "cap")
        #expect(["nothing", "blocked", "failed"] == [BrowseResult.Outcome.nothing, .blocked, .failed].map(\.rawValue))

        // 열지 못함: 까닭을 낱말로 (D77). 응답 번호 때문이면 번호도
        let failed = try json(BrowseResult(id: "b1", outcome: .failed, status: 503, reason: BrowseResult.Failure.httpStatus.rawValue))
        #expect(failed["result"] as? String == "failed")
        #expect(failed["reason"] as? String == "http_status")
        #expect(failed["status"] as? Int == 503)
        let words = [BrowseResult.Failure.netLost, .netTimeout, .netOffline, .loadError, .webCrashed, .httpStatus, .timeout].map(\.rawValue)
        #expect(words == ["net_lost", "net_timeout", "net_offline", "load_error", "web_crashed", "http_status", "timeout"])
        // 맥은 소문자·밑줄 20자 이하의 낱말만 기록에 그대로 남긴다
        #expect(words.allSatisfy { $0.count <= 20 && $0.allSatisfy { $0 == "_" || ($0.isASCII && $0.isLowercase) } })
        // 오류의 문장이 아니라 종류만 고른다
        func word(_ code: Int, domain: String = NSURLErrorDomain) -> BrowseResult.Failure {
            ShopBrowser.failure(for: NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: "가상 오류 문장"]))
        }
        #expect(word(NSURLErrorNetworkConnectionLost) == .netLost)
        #expect(word(NSURLErrorTimedOut) == .netTimeout)
        #expect(word(NSURLErrorNotConnectedToInternet) == .netOffline)
        #expect(word(NSURLErrorCannotFindHost) == .loadError)
        #expect(word(NSURLErrorNetworkConnectionLost, domain: "WebKitErrorDomain") == .loadError)
    }

    @Test func onlyAMacThatKnowsBothIsToldTheAppCanDrive() throws {
        func features(_ known: Set<String>) throws -> [String] {
            let body = AgentHTTPClient.MessageBody(
                text: "생수 2L 6개 사고 싶어", conversationID: "c_1", context: nil, messageID: "m_1", replyTaskID: nil, tone: "friendly",
                features: known, extras: MessageExtras(clientFeatures: [MessageExtras.shopFeature, MessageExtras.shopDriveFeature])
            )
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
            return json["client_features"] as? [String] ?? []
        }
        #expect(try features([AgentFeature.shopView, AgentFeature.shopDrive]) == ["shop", "shop_drive"])
        // 쇼핑 화면만 아는 맥(1단계)에는 알리지 않는다
        #expect(try features([AgentFeature.shopView]) == ["shop"])
        // 쇼핑 화면을 모르는 맥에는 둘 다 알리지 않는다
        #expect(try features([AgentFeature.shopDrive]).isEmpty)
        #expect(try features([]).isEmpty)
    }

    @Test func linksStayNextToTheirItemsAndOnTheDevice() throws {
        let page = ShopPage(kind: .list, address: "https://search.shop.test/search/all")
        let raw = """
        {"items":[
          {"title":"맑은샘 생수 2L 6개","price":5900,"mall":"맑은샘 상점","links":["https://store.shop.test/malgeun/products/1001","https://ad.shop.test/click?x=1"]},
          {"title":"맑은샘 생수 2L 6개","price":5900,"links":["https://store.shop.test/malgeun/products/9999"]},
          {"title":"산들 암반수 2L 6개 무라벨","price":6480,"links":["http://store.shop.test/sandle/products/1002","javascript:void(0)",7]},
          {"title":"하늘물 먹는샘물 2L 6개입","price":4950,"why":"no_anchor"}
        ]}
        """
        let read = try #require(ShopView.parse(page: page, json: raw))
        // 링크를 찾지 못한 까닭도 그 상품의 자리에 있다. 정해 둔 낱말만 받는다
        #expect(read.gaps == [nil, nil, "no_anchor"])
        let odd = try #require(ShopView.parse(page: page, json: #"{"items":[{"title":"가나다라","why":"no_href"},{"title":"마바사아","why":"https://x.test/"},{"title":"자차카타","why":7}]}"#))
        #expect(odd.gaps == ["no_href", nil, nil])
        #expect(!String(decoding: try JSONEncoder().encode(odd.view), as: UTF8.self).contains("no_href"))
        // 이름이 같은 것은 한 번만. 링크는 그 상품의 자리에 그대로 있다
        #expect(read.view.fields.items?.map(\.title) == ["맑은샘 생수 2L 6개", "산들 암반수 2L 6개 무라벨", "하늘물 먹는샘물 2L 6개입"])
        #expect(read.links.count == 3)
        #expect(read.links[0].map(\.absoluteString) == ["https://store.shop.test/malgeun/products/1001", "https://ad.shop.test/click?x=1"])
        // https가 아닌 주소는 버린다
        #expect(read.links[1].isEmpty)
        #expect(read.links[2].isEmpty)
        // 맥으로 가는 것에는 링크가 없다
        let sent = String(decoding: try JSONEncoder().encode(read.view), as: UTF8.self)
        #expect(!sent.contains("products/1001"))
        #expect(!sent.contains("ad.shop.test"))
        // 읽기(`read`)는 전과 같다
        #expect(ShopView.read(page: page, json: raw) == read.view)
    }

    // MARK: - 쇼핑 화면이 시킨 일을 한다

    @Test(.timeLimit(.minutes(2))) func theScreenSearchesAndOpensWhatItWasTold() async throws {
        let screen = Screen()
        defer { screen.close() }
        let browser = screen.browser

        // 읽어 둔 목록이 없으면 열지 않는다
        let early = await browser.run(open("b0", [0]), task: "t1")
        #expect(early == BrowseResult(id: "b0", outcome: .refused, reason: "no_list"))
        #expect(browser.memory.visited.isEmpty)

        // 검색: 쇼핑 화면이 뜨고, 검색 결과에서 목록을 읽는다
        let listed = try #require(await browser.run(search(), task: "t1"))
        #expect(browser.isPresented)
        #expect(browser.drive?.taskID == "t1")
        #expect(listed.outcome == .ok)
        #expect(listed.views.count == 1)
        #expect(listed.views[0].item == nil)
        #expect(listed.views[0].view.kind == .list)
        #expect(listed.views[0].view.fields.items?.map(\.title) == DemoShop.products.map(\.title))
        #expect(listed.views[0].view.fields.items?.map(\.price) == DemoShop.products.map(\.price))
        // 상품마다 그 상품의 화면으로 가는 주소를 기억해 둔다 (기기 안에만)
        #expect(browser.memory.listLinks.count == DemoShop.products.count)
        for (index, links) in browser.memory.listLinks.enumerated() {
            #expect(links.contains(productURL(index)), "\(index)")
        }
        // 줄마다 바로 열 수 있다고 적어 보낸다 (D77)
        #expect(listed.views[0].view.fields.items?.map(\.canOpen) == Array(repeating: true, count: DemoShop.products.count))

        // 열기: 고른 차례의 상품 화면을 열어 화면의 값 그대로 읽는다
        let opened = try #require(await browser.run(open("b2", [0, 2, 4]), task: "t1"))
        #expect(opened.outcome == .ok)
        #expect(opened.skipped.isEmpty)
        #expect(opened.views.map(\.item) == [0, 2, 4])
        for entry in opened.views {
            let product = DemoShop.products[try #require(entry.item)]
            #expect(entry.view.kind == .product)
            #expect(entry.view.url == DemoShop.productURL(product).absoluteString)
            #expect(entry.view.fields.title == product.title)
            #expect(entry.view.fields.price == product.price)
            #expect(entry.view.fields.shipping == product.shipping)
            #expect(entry.view.fields.seller == product.seller)
        }
        #expect(browser.memory.visited == [searchURL, productURL(0), productURL(2), productURL(4)])

        // 같은 일이 다시 오면(결과를 보내다 끊겼을 때) 화면을 다시 열지 않고 같은 결과를 준다
        let again = await browser.run(open("b2", [0, 2, 4]), task: "t1")
        #expect(again == opened)
        #expect(browser.memory.visited.count == 4)

        // 한 번에 셋까지: 넘는 것은 열지 않고 그렇다고 알린다
        let many = try #require(await browser.run(open("b3", [1, 3, 5, 0]), task: "t1"))
        #expect(many.views.map(\.item) == [1, 3, 5])
        #expect(many.skipped == [.init(item: 0, reason: .limit)])
        #expect(browser.memory.visited.count == 7)

        // 한 작업에서 여섯까지: 그 뒤로는 열지 않는다
        let capped = await browser.run(open("b4", [0]), task: "t1")
        #expect(capped == BrowseResult(id: "b4", outcome: .refused, reason: "cap"))
        #expect(browser.memory.visited.count == 7)

        // 같은 검색 결과를 보고 있으면 다시 받지 않는다. 한 작업에서 검색은 둘까지
        #expect(browser.search(query))
        _ = await browser.run(search("b5"), task: "t1")
        let third = await browser.run(search("b6", "탄산수"), task: "t1")
        #expect(third == BrowseResult(id: "b6", outcome: .refused, reason: "cap"))

        // 다른 작업은 따로 센다
        let other = try #require(await browser.run(search("b1"), task: "t2"))
        #expect(other.outcome == .ok)
    }

    @Test(.timeLimit(.minutes(2))) func onlyLinksThatGoStraightToAProductAreOpened() async throws {
        // 목록의 둘째는 광고 주소(다른 호스트), 셋째는 상품이 아닌 화면, 넷째는 정해 둔 호스트가 아닌 주소다
        let screen = Screen { url in
            guard let html = DemoShop.html(for: url) else { return nil }
            return html
                .replacingOccurrences(of: "href=\"https://store.shop.test/sandle/products/1002\"", with: "href=\"https://ad.shop.test/click?to=1002\"")
                .replacingOccurrences(of: "href=\"https://store.shop.test/haneul/products/1003\"", with: "href=\"https://store.shop.test/cart\"")
                .replacingOccurrences(of: "href=\"https://store.shop.test/malgeun/products/1004\"", with: "href=\"https://elsewhere.example/p/1004\"")
        }
        defer { screen.close() }
        let browser = screen.browser

        let listed = try #require(await browser.run(search(), task: "t1"))
        #expect(listed.outcome == .ok)
        // 목록은 그대로 읽힌다 (이름과 값)
        #expect(listed.views[0].view.fields.items?.count == DemoShop.products.count)
        // 열 수 없는 줄은 그렇다고 적어 보낸다: 맥이 그런 줄을 고르지 않게 (D77)
        #expect(listed.views[0].view.fields.items?.map(\.canOpen) == [true, false, false, false, true, true])

        let opened = try #require(await browser.run(open("b2", [1, 2, 0]), task: "t1"))
        // 바로 가는 상품 주소인 첫째만 열었다. 광고 주소와 상품이 아닌 화면은 열지 않았다.
        // 까닭은 나눠 알린다: 앱이 열지 않는 호스트로만 가는 링크, 여는 호스트지만 상품 화면이 아닌 링크
        #expect(opened.outcome == .ok)
        #expect(opened.views.map(\.item) == [0])
        #expect(opened.skipped == [.init(item: 1, reason: .otherMall), .init(item: 2, reason: .outside)])
        #expect(browser.memory.visited == [searchURL, productURL(0)])

        // 열 수 있는 것이 하나도 없으면 아무것도 열지 않고 그렇다고 알린다. 목록에 없는 차례는 링크가 없는 것이다
        let none = try #require(await browser.run(open("b3", [3, 7]), task: "t1"))
        #expect(none.outcome == .nothing)
        #expect(none.views.isEmpty)
        #expect(none.skipped == [.init(item: 3, reason: .otherMall), .init(item: 7, reason: .noLink)])
        #expect(browser.memory.visited.count == 2)
        #expect(browser.notice == nil)
    }

    @Test(.timeLimit(.minutes(2))) func aProductThatTurnsIntoTheLoginScreenStopsTheRest() async throws {
        // 2026-11-15 실제 기기: 연 상품 셋이 모두 로그인 화면으로 넘어갔는데 앱이 셋을 다 열었다.
        // 첫 번째에서 멈춰야 한다 (가상 쇼핑몰: 둘째 상품의 주소가 로그인 화면으로 넘긴다)
        let screen = Screen { url in
            if url == DemoShop.productURL(DemoShop.products[1]) {
                return "<html><body><script>location.replace('https://login.shop.test/')</script></body></html>"
            }
            return DemoShop.html(for: url)
        }
        defer { screen.close() }
        let browser = screen.browser

        #expect(try #require(await browser.run(search(), task: "t1")).outcome == .ok)
        let opened = try #require(await browser.run(open("b2", [0, 1, 2]), task: "t1"))
        // 첫째는 읽었고, 둘째에서 로그인 화면을 만나 멈췄다. 셋째는 열지 않았다
        #expect(opened.outcome == .blocked)
        #expect(opened.reason == "login")
        #expect(opened.views.map(\.item) == [0])
        #expect(opened.skipped == [.init(item: 1, reason: .notProduct)])
        #expect(browser.memory.visited == [searchURL, productURL(0), productURL(1)])
        // 로그인 화면은 그대로 두고, 왜 멈췄는지 알린다. 그 화면은 읽지 않는다
        #expect(browser.address?.host() == "login.shop.test")
        #expect(browser.notice == .login)
        // 화면은 바로 내게 넘어온다 (찾는 중에는 누를 수 없다): 거기서 직접 로그인할 수 있게
        #expect(browser.drive == nil)
        #expect(browser.page == nil)
        #expect(await browser.read() == .nothing)
        // 이 작업에서는 더 하지 않는다
        let more = try #require(await browser.run(open("b3", [2]), task: "t1"))
        #expect(more.outcome == .refused)
        #expect(more.reason == "stopped")
        #expect(browser.memory.visited.count == 3)
        // 맥에는 낱말만 간다 (주소는 가지 않는다)
        let sent = String(decoding: try JSONEncoder().encode(opened), as: UTF8.self)
        #expect(sent.contains(#""result":"blocked""#))
        #expect(sent.contains(#""reason":"login""#))
        #expect(!sent.contains("login.shop.test"))

        // 다른 작업이 새로 찾기 시작하면 알림은 걷힌다
        #expect(try #require(await browser.run(search("b1", "탄산수"), task: "t2")).outcome == .ok)
        #expect(browser.notice == nil)

        // 상품을 두는 곳 안의 다른 화면(없는 상품 같은 것)은 그 상품만 건너뛴다
        #expect(ShopSite.demo.isLogin(URL(string: "https://login.shop.test/")))
        #expect(!ShopSite.demo.isLogin(URL(string: "https://store.shop.test/cart")))
        #expect(ShopSite.naver.isLogin(URL(string: "https://nid.naver.com/nidlogin.login")))
        #expect(!ShopSite.naver.isLogin(URL(string: "http://nid.naver.com/nidlogin.login")))
        #expect(!ShopSite.naver.isLogin(URL(string: "https://shopping.naver.com/")))
    }

    @Test(.timeLimit(.minutes(2))) func aSearchThatTurnsIntoTheLoginScreenSaysSo() async throws {
        let screen = Screen { url in
            if url.host() == "search.shop.test" {
                return "<html><body><script>location.replace('https://login.shop.test/')</script></body></html>"
            }
            return DemoShop.html(for: url)
        }
        defer { screen.close() }
        let browser = screen.browser
        let result = try #require(await browser.run(search(), task: "t1"))
        #expect(result.outcome == .blocked)
        #expect(result.reason == "login")
        #expect(result.views.isEmpty)
        #expect(browser.notice == .login)
        #expect(browser.drive == nil)
        #expect(browser.memory.visited == [searchURL])
    }

    @Test(.timeLimit(.minutes(2))) func whenTheSiteLimitsItStopsAndDoesNotTryAgain() async throws {
        final class Box { var browser: ShopBrowser? }
        let box = Box()
        let second = productURL(1)
        // 둘째 상품 화면에서 사이트가 "접속 제한"으로 답한 것처럼
        let screen = Screen { url in
            if url == second { box.browser?.mainStatus = 429 }
            return DemoShop.html(for: url)
        }
        defer { screen.close() }
        let browser = screen.browser
        box.browser = browser

        _ = try #require(await browser.run(search(), task: "t1"))
        let opened = try #require(await browser.run(open("b2", [0, 1, 2]), task: "t1"))
        // 그 자리에서 멈춘다: 그때까지 읽은 것만 돌려주고, 남은 상품은 열지 않는다
        #expect(opened.outcome == .limited)
        #expect(opened.status == 429)
        #expect(opened.views.map(\.item) == [0])
        #expect(browser.memory.visited == [searchURL, productURL(0), productURL(1)])

        // 그 작업에서는 더 하지 않는다 (다시 시도하지 않는다)
        let next = await browser.run(open("b3", [2]), task: "t1")
        #expect(next == BrowseResult(id: "b3", outcome: .refused, reason: "stopped"))
        let retry = await browser.run(search("b4"), task: "t1")
        #expect(retry == BrowseResult(id: "b4", outcome: .refused, reason: "stopped"))
        #expect(browser.memory.visited.count == 3)
        #expect(ShopBrowser.limitStatuses == [403, 418, 429])
    }

    /// 페이지가 목록을 데이터로 적어 두는 검색 결과 (가상). 줄마다 링크가 놓인 모양이 다르다
    private func dataListPage() -> String {
        let p = DemoShop.products
        func card(_ index: Int, _ inner: String) -> String {
            "<div class=\"card\">\(inner)<strong>\(ShopText.won(p[index].price))</strong></div>"
        }
        func name(_ index: Int) -> String { "<div class=\"name\">\(p[index].title)</div>" }
        let cards = [
            // 0: 이름은 링크 밖에 있고, 같은 칸의 그림만 상품으로 가는 링크다
            card(0, "<a href=\"\(productURL(0).absoluteString)\"><span class=\"thumb\"></span></a>\(name(0))"),
            // 1: 칸에 링크가 없다. 상품 주소는 페이지의 데이터에만 적혀 있다
            card(1, name(1)),
            // 2: 이름을 감싼 링크가 거쳐 가는 주소(다른 호스트)다
            card(2, "<a href=\"https://ad.shop.test/click?to=1003\">\(name(2))</a>"),
            // 3: 링크가 어디에도 없다
            card(3, name(3)),
            // 4: 링크는 있는데 주소가 없다 (스크립트로 여는 링크)
            card(4, "<a href=\"#\">\(name(4))</a>"),
            // 5: 한 칸에 서로 다른 상품의 주소가 둘이다
            card(5, "\(name(5))<a href=\"\(productURL(5).absoluteString)\">보기</a><a href=\"\(productURL(1).absoluteString)\">함께 본 상품</a>"),
        ].joined()
        let rows: [[String: Any]] = [
            ["productTitle": p[0].title, "price": String(p[0].price)],
            ["productTitle": p[1].title, "price": String(p[1].price), "mallProductUrl": productURL(1).absoluteString + "?from=list&x=1"],
            ["productTitle": p[2].title, "price": String(p[2].price), "crUrl": "https://ad.shop.test/click?to=1003"],
            ["productTitle": p[3].title, "price": String(p[3].price)],
            ["productTitle": p[4].title, "price": String(p[4].price)],
            ["productTitle": p[5].title, "price": String(p[5].price)],
        ]
        let data = try! JSONSerialization.data(withJSONObject: ["props": ["pageProps": ["list": rows.map { ["item": $0] }]]])
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width"></head><body>
        <div id="list">\(cards)</div>
        <script id="__NEXT_DATA__" type="application/json">\(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/"))</script>
        </body></html>
        """
    }

    @Test(.timeLimit(.minutes(2))) func aLinkIsLookedForNearTheNameAndTheReasonIsToldWhenThereIsNone() async throws {
        let list = searchURL
        let page = dataListPage()
        let screen = Screen { url in url == list ? page : DemoShop.html(for: url) }
        defer { screen.close() }
        let browser = screen.browser

        let listed = try #require(await browser.run(search(), task: "t1"))
        #expect(listed.outcome == .ok)
        let items = try #require(listed.views[0].view.fields.items)
        #expect(items.map(\.title) == DemoShop.products.map(\.title))
        #expect(items.map(\.price) == DemoShop.products.map(\.price))
        // 같은 칸의 링크와 페이지가 적어 둔 상품 주소로 찾은 둘만 열 수 있다
        #expect(items.map(\.canOpen) == [true, true, false, false, false, false])
        // 페이지가 적어 둔 주소는 물음표 뒤를 떼고 쓴다
        #expect(browser.memory.listLinks[1] == [productURL(1)])
        #expect(browser.memory.listGaps == [nil, nil, nil, "no_anchor", "no_href", nil])
        // 맥으로 가는 것에는 주소도 까닭도 없다
        let sent = String(decoding: try JSONEncoder().encode(listed), as: UTF8.self)
        #expect(!sent.contains("products/") && !sent.contains("ad.shop.test") && !sent.contains("no_anchor"))

        let opened = try #require(await browser.run(open("b2", [0, 1, 2]), task: "t1"))
        #expect(opened.outcome == .ok)
        #expect(opened.views.map(\.item) == [0, 1])
        #expect(opened.views.map(\.view.fields.title) == [DemoShop.products[0].title, DemoShop.products[1].title])
        #expect(opened.skipped == [.init(item: 2, reason: .otherMall)])
        #expect(browser.memory.visited == [searchURL, productURL(0), productURL(1)])

        // 링크가 없는 것, 주소가 없는 것, 어느 상품의 주소인지 가리지 못한 것은 열지 않고 까닭을 알린다
        let none = try #require(await browser.run(open("b3", [3, 4, 5]), task: "t1"))
        #expect(none.outcome == .nothing)
        #expect(none.skipped == [.init(item: 3, reason: .noAnchor), .init(item: 4, reason: .noHref), .init(item: 5, reason: .noLink)])
        #expect(browser.memory.visited.count == 3)
    }

    @Test(.timeLimit(.minutes(2))) func aSearchThatDidNotOpenSaysWhyAndIsNotTriedAgain() async throws {
        final class Box { var browser: ShopBrowser?; var status: Int? }
        let box = Box()
        let list = searchURL
        // 검색 결과를 받지 못한 것처럼(없는 화면), 다음에는 사이트가 503으로 답한 것처럼
        let screen = Screen { url in
            guard url == list else { return DemoShop.html(for: url) }
            guard let status = box.status else { return nil }
            box.browser?.mainStatus = status
            return DemoShop.html(for: url)
        }
        defer { screen.close() }
        let browser = screen.browser
        box.browser = browser

        let lost = try #require(await browser.run(search("b1"), task: "t1"))
        #expect(lost == BrowseResult(id: "b1", outcome: .failed, reason: "load_error"))
        // 다시 열어 보지 않았다. 읽어 둔 목록도 없다
        #expect(browser.memory.visited == [searchURL])
        #expect(!browser.memory.hasList)

        box.status = 503
        let refused = try #require(await browser.run(search("b2"), task: "t2"))
        #expect(refused == BrowseResult(id: "b2", outcome: .failed, status: 503, reason: "http_status"))
        #expect(browser.memory.visited == [searchURL, searchURL])

        // 웹 화면을 그리는 프로세스가 죽은 것은 따로 알린다
        browser.webViewWebContentProcessDidTerminate(browser.webView())
        #expect(browser.loadFailure == .webCrashed)
        // 새 화면을 열기 시작하면 지난 까닭은 지운다
        box.status = 200
        let fine = try #require(await browser.run(search("b3"), task: "t3"))
        #expect(fine.outcome == .ok)
        #expect(browser.loadFailure == nil)
    }

    @Test func aTaskDoneWithASkillHasNothingToSave() throws {
        func done(_ extra: String) throws -> AgentTaskState {
            let json = """
            {"id":"t_1","status":"completed","task":"가상 가게 영업시간 알아봐 줘","steps":[
              {"n":1,"tool":"type","args":{"text":"가상 가게"},"status":"ok"},{"n":2,"tool":"finish","args":{},"status":"ok"}],
             "result":{"outcome":"completed","summary":"끝"}\(extra)}
            """
            return try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
        }
        // 보통의 작업(메일 쓰기): 입력만 하고 저장 없이 끝났으면 알린다
        let plain = try done("")
        #expect(plain.skill == nil)
        #expect(plain.typedWithoutSaving)
        // 둘러보기·찾아보기처럼 기술로 한 작업은 검색칸에 글을 넣은 것뿐이다: 저장 얘기를 하지 않는다 (D77)
        let browse = try done(#","skill":"web_browse""#)
        #expect(browse.skill == "web_browse")
        #expect(!browse.typedWithoutSaving)
        // 글이 아닌 값이 와도 작업은 읽힌다 (없는 것으로 본다)
        #expect(try done(#","skill":7"#).skill == nil)
        #expect(try done(#","skill":null"#).typedWithoutSaving)
        #expect(try done(#","skill":"\#(String(repeating: "a", count: 41))""#).skill == nil)
        // 저장해 둔 기록: 이 값이 없던 때의 것도 읽히고, 있는 것은 그대로 이어진다
        let old = #"{"id":"T","task":"t","steps":["입력 · 본문"],"phase":"done","isQueued":false,"approvedDrafts":[],"lastRevision":0}"#
        #expect(try JSONDecoder().decode(AgentTaskState.self, from: Data(old.utf8)).typedWithoutSaving)
        #expect(try JSONDecoder().decode(AgentTaskState.self, from: JSONEncoder().encode(browse)).skill == "web_browse")
    }

    @Test(.timeLimit(.minutes(2))) func stoppingEndsItAtOnce() async throws {
        let screen = Screen()
        defer { screen.close() }
        let browser = screen.browser
        // 화면을 여는 사이의 틈을 길게 두고, 그 틈에 멈춘다
        browser.pace.gap = .seconds(30)

        _ = try #require(await browser.run(search(), task: "t1"))
        let running = Task { await browser.run(open("b2", [0, 1, 2]), task: "t1") }
        for _ in 0..<300 where browser.drive?.text.contains("상품 화면") != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        browser.stopDrive()
        // 결과는 없다 (맥에 보내지 않는다). 상품 화면은 하나도 열지 않았다
        #expect(await running.value == nil)
        #expect(browser.drive == nil)
        #expect(browser.memory.visited == [searchURL])
        // 그 작업에서는 더 하지 않는다
        let next = await browser.run(open("b3", [0]), task: "t1")
        #expect(next == BrowseResult(id: "b3", outcome: .refused, reason: "stopped"))
    }

    // MARK: - 대화

    @Test(.timeLimit(.minutes(2))) func sayingWhatToBuyBringsBackWhatWasRead() async throws {
        let agent = mac()
        let session = session(agent)
        await session.checkAgent()
        #expect(session.canDriveShop)
        let screen = Screen()
        defer { screen.close() }

        let asked = try await ask(session)
        // 맥은 작업을 만들고 검색을 시켰다. 앱은 "찾아 올 수 있다"고 알렸다
        #expect(await agent.receivedExtras.last?.clientFeatures.contains("shop_drive") == true)
        #expect(session.messages.contains { $0.shopQuery != nil } == false)
        #expect(session.browsingTaskID == asked.task)

        try await serve(session, screen.browser, task: asked.task)
        await asked.sending.value

        // 시킨 일은 검색 하나와 열기 하나였고, 결과는 한 번씩 갔다
        let results = await agent.browseResults
        #expect(results.map(\.result.id) == ["b1", "b2"])
        #expect(results.map(\.result.outcome) == [.ok, .ok])
        #expect(results[1].result.views.map(\.item) == [0, 1, 2])
        #expect(screen.browser.memory.visited == [searchURL, productURL(0), productURL(1), productURL(2)])

        // 작업이 끝나고, 읽어 온 값 그대로 상품 카드가 된다
        let state = try #require(session.messages.last(where: { $0.role == .agent })?.agent)
        #expect(state.phase == .done)
        #expect(state.usedShop == true)
        #expect(state.browse == nil)
        #expect(session.browseJob == nil)
        #expect(session.browsingTaskID == nil)
        let items = try #require(state.report?.items)
        #expect(items.map(\.title) == DemoShop.products.prefix(3).map(\.title))
        #expect(items.map(\.price) == DemoShop.products.prefix(3).map(\.price))
        #expect(items.map(\.mall) == DemoShop.products.prefix(3).map(\.seller))
        #expect(items.map(\.shipping) == DemoShop.products.prefix(3).map(\.shipping))
        #expect(items.map(\.url) == (0..<3).map(productURL))

        // 그 카드에서 고르면 작업 번호와 상품 번호가 간다 (다음 단계의 입구)
        #expect(session.canPickItemNow)
        await session.pick(items[1], from: state.id, meetings: [])
        #expect(await agent.replyTaskIDs.last == state.id)
        #expect(await agent.receivedExtras.last?.replyItemID == "i2")
        #expect(session.messages.last?.text == "네, ‘\(items[1].title)’ 골랐어요.")
    }

    @Test func aMacThatCannotDriveStillOpensTheScreenForMe() async {
        let agent = mac(drives: false)
        let session = session(agent)
        await session.checkAgent()
        #expect(session.canDriveShop == false)
        await session.send("생수 2L 6개 사고 싶어", meetings: [])
        // 1단계 그대로: 작업이 아니라 "쇼핑 화면 열기" 카드
        #expect(session.messages.last?.shopQuery == query)
        #expect(session.messages.allSatisfy { $0.agent == nil })
        #expect(await agent.receivedExtras.map(\.clientFeatures) == [["shop"]])
        #expect(session.browseJob == nil)
    }

    @Test func aBlockedScreenEndsTheTaskWithTheReason() async throws {
        let agent = mac()
        let session = session(agent)
        let asked = try await ask(session)
        let job = try #require(session.browseJob)
        #expect(job.taskID == asked.task)
        #expect(job.command == search())

        // 사이트가 접속을 제한했다고 돌려주면, 맥은 다음 일을 시키지 않고 작업을 끝낸다
        await session.finishBrowse(job, result: BrowseResult(id: "b1", outcome: .limited, status: 418))
        await asked.sending.value
        let state = try #require(session.messages.last(where: { $0.role == .agent })?.agent)
        #expect(state.phase == .failed)
        #expect(state.error == "사이트가 접속을 막아서 작업을 멈췄어요.")
        #expect(state.report?.blocked.first?.contains("418") == true)
        #expect(state.report?.blocked.first?.contains("다시 시도하지 않았어요") == true)
        #expect(session.browseJob == nil)
        #expect(session.browsingTaskID == nil)
        #expect(await agent.browseResults.count == 1)
    }

    @Test func theSameResultIsNotSentTwiceAndAStaleCommandIsNotRedone() async throws {
        let agent = mac()
        let session = session(agent)
        let asked = try await ask(session)
        let first = try #require(session.browseJob)
        let result = BrowseResult(id: "b1", outcome: .ok, views: [.init(item: nil, view: listView)])

        await session.finishBrowse(first, result: result)
        await session.finishBrowse(first, result: result)
        #expect(await agent.browseResults.count == 1)
        // 다음 일(열기)로 넘어갔다. 돌려준 일은 다시 "할 일"이 되지 않는다
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(10)) }
        let second = try #require(session.browseJob)
        #expect(second.command == open("b2", [0, 1]))

        // 맥이 이미 넘어간 일의 결과는 받지 않는다(409): 앱은 조용히 넘어간다
        await session.finishBrowse(second, result: BrowseResult(id: "b2", outcome: .ok, views: [.init(item: 0, view: productView)]))
        await asked.sending.value
        let state = try #require(session.messages.last(where: { $0.role == .agent })?.agent)
        #expect(state.phase == .done)
        #expect(state.report?.items?.map(\.title) == ["맑은샘 생수 2L 6개"])
        #expect(session.messages.contains { $0.role == .error } == false)
    }

    @Test func aResultThatDidNotArriveIsSentAgain() async throws {
        let agent = mac()
        let session = session(agent)
        let asked = try await ask(session)
        let job = try #require(session.browseJob)
        let result = BrowseResult(id: "b1", outcome: .ok, views: [.init(item: nil, view: listView)])

        // 잠깐 끊긴 것은 다시 보낸다
        await agent.failBrowse([.unreachable, .unreachable])
        await session.finishBrowse(job, result: result)
        #expect(await agent.browseResults.count == 1)
        for _ in 0..<50 where session.browseJob == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.browseJob?.command.id == "b2")

        // 열기의 결과에 읽은 것이 없으면, 목록에서 읽은 것만 글로 알리고 끝낸다 (카드는 없다)
        let second = try #require(session.browseJob)
        await session.finishBrowse(second, result: BrowseResult(
            id: "b2", outcome: .nothing, skipped: [.init(item: 0, reason: .outside), .init(item: 1, reason: .outside)]
        ))
        await asked.sending.value
        let state = try #require(session.messages.last(where: { $0.role == .agent })?.agent)
        #expect(state.phase == .done)
        #expect(state.report?.items == nil)
        #expect(state.report?.done.contains { $0.contains("맑은샘 생수 2L 6개") && $0.contains("5,900원") } == true)
        #expect(state.report?.blocked.isEmpty == false)
    }

    @Test func stoppingTheTaskLeavesNothingToDo() async throws {
        let agent = mac()
        let session = session(agent)
        let asked = try await ask(session)
        #expect(session.browseJob != nil)

        await session.cancelAgent(asked.task)
        await asked.sending.value
        #expect(session.phase(of: asked.task) == .canceled)
        #expect(session.browseJob == nil)
        #expect(session.browsingTaskID == nil)
        // 결과는 보내지 않았다
        #expect(await agent.browseResults.isEmpty)
    }

    @Test func thePrivacyScreenSaysTheAppReadsWithoutBeingPressed() async throws {
        let setup = await DialogSetup(agent: mac())
        #expect(setup.opensShop && setup.drivesShop)
        #expect(setup.stored.split(separator: " ").contains("shopdrive"))
        #expect(DialogSetup(stored: setup.stored)?.drivesShop == true)

        let facts = MacAgentFacts(setup: setup).rows.map { $0.text + " " + ($0.note ?? "") }
        let fact = try #require(facts.first { $0.contains("앱이 쇼핑 화면에서 직접 찾아 와요") })
        #expect(fact.contains("'확인해 줘'를 누르지 않아도"))
        #expect(fact.contains("맥으로 가요"))
        #expect(fact.contains("주소를 여는 것까지만 해요"))
        #expect(fact.contains("옵션·담기·구매·동의 같은 단추는 누르지 않고"))
        #expect(fact.contains("한 번에 셋, 한 번 찾을 때 여섯까지만"))
        #expect(fact.contains("다시 시도하지 않아요"))
        #expect(fact.contains("'멈추기'를 누르면 바로 멈추고"))
        // 실제 맥에 맞춘 말: 고르는 것과 견준 말은 Claude가 하고, 상품 주소는 Claude로 가지 않는다
        #expect(fact.contains("목록에서 어느 상품을 열지는 Claude가 골라요"))
        #expect(fact.contains("이름·가격·판매처·배송·옵션·도착 안내예요"))
        #expect(fact.contains("상품 화면의 주소는 Claude로 가지 않아요(대화 기록에도 넣지 않아요)"))
        #expect(fact.contains("내 조건과 견준 말은 Claude가 써요."))
        // 답 아래의 'Claude 사용' 표시는 보이지 않게 했다 (D107): 표시한다고 말하지 않는다
        #expect(!fact.contains("'Claude 사용'"))
        #expect(facts.contains { $0.contains("쇼핑 화면에서 찾아 온 상품을 견준 말 말고는 모두 맥에서 만들어요") })
        // "누를 때만 간다"는 말은 내가 직접 둘러볼 때의 것으로 고쳐 쓴다
        let viewing = try #require(facts.first { $0.contains("앱 안의 쇼핑 화면에서 같이 봐요") })
        #expect(viewing.contains("내가 직접 둘러볼 때는 '확인해 줘'를 누를 때만"))

        // 찾아 오기를 모르는 맥이면 그 줄이 없고, 1단계의 말 그대로다
        let plain = await DialogSetup(agent: mac(drives: false))
        #expect(plain.opensShop && !plain.drivesShop)
        #expect(!plain.stored.contains("shopdrive"))
        let plainFacts = MacAgentFacts(setup: plain).rows.map { $0.text + " " + ($0.note ?? "") }
        #expect(!plainFacts.contains { $0.contains("직접 찾아 와요") })
        #expect(!plainFacts.contains { $0.contains("내가 직접 둘러볼 때는") })
        // 쇼핑 화면이 없으면 찾아 오는 일도 없다
        #expect(!DialogSetup(place: .cloud, drivesShop: true).drivesShop)
        #expect(!DialogSetup(place: .local, opensShop: true, drivesShop: true).drivesShop)
        #expect(DialogSetup(stored: "v2 cloud shopdrive")?.drivesShop == false)
    }

    @Test func theDemoMacDrives() async {
        let cloud = MockDialogCloud(demo: "drive")
        #expect(cloud.drivesShop && cloud.opensShop && cloud.listsItems && cloud.reacts)
        #expect(MockDialogCloud(demo: "browse").drivesShop == false)
        #expect(MockDialogCloud(drivesShop: true).drivesShop == false)
        #expect(MockDialogCloud(demo: "drive", hold: "search").driveHold == .search)
        #expect(await MockAgentClient(v2: true, dialogCloud: cloud).supports(AgentFeature.shopDrive))
        #expect(await MockAgentClient(v2: true, dialogCloud: MockDialogCloud(demo: "browse")).supports(AgentFeature.shopDrive) == false)
    }

    /// 실제 맥(맥의 문서 "쇼핑 — 찾아 와서 견줘 주기")이 주는 꼴 그대로: 단계 이름, 끝난 보고, 새로 생긴 끝나는 이유
    @Test func theRealMacsWordsAreReadable() throws {
        let done = """
        {"id":"t_shopdrive1","status":"completed","task":"생수 2L 6개","title":"쇼핑 화면에서 찾기",\
        "created_at":"2026-11-14T12:30:00+00:00","updated_at":"2026-11-14T12:30:08+00:00","steps":[\
        {"n":1,"tool":"shop_search","args":{},"status":"ok"},{"n":2,"tool":"shop_open","args":{},"status":"ok"}],\
        "result":{"outcome":"completed","summary":"1번이 조건에 맞아요.","report":{"done":["1번이 조건에 맞아요."],"blocked":[],"sources":[],"by":"claude",\
        "items":[{"id":"i1","title":"가상 생수 2L 6개","url":"https://smartstore.naver.com/demo/products/1001","price":4900,"mall":"가상상회","shipping":"3,000원","detail":"수량: 1묶음, 2묶음"}]}}}
        """
        let state = try AgentHTTPClient.decodeTask(data: Data(done.utf8), status: 200)
        #expect(state.phase == .done)
        #expect(state.timeline.contains { $0.text == "쇼핑 검색 결과 읽기" })
        #expect(state.timeline.contains { $0.text == "상품 화면 열어 읽기" })
        #expect(!state.timeline.contains { $0.text.contains("shop_") })
        let item = try #require(state.report?.items?.first)
        #expect(item.title == "가상 생수 2L 6개" && item.price == 4900)
        #expect(state.report?.by == "claude")

        let running = """
        {"id":"t_shopdrive1","status":"running","task":"생수 2L 6개","title":"쇼핑 화면에서 찾기",\
        "created_at":"2026-11-14T12:30:00+00:00","updated_at":"2026-11-14T12:30:04+00:00","steps":[\
        {"n":1,"tool":"shop_search","args":{},"status":"ok"}],"browser":{"id":"b2","type":"open","items":[0,3]}}
        """
        let middle = try AgentHTTPClient.decodeTask(data: Data(running.utf8), status: 200)
        #expect(middle.activity == "쇼핑 화면에서 찾고 있어요")
        #expect(middle.browse == AgentBrowse(id: "b2", kind: .open, query: nil, items: [0, 3]))

        // 폰이 화면을 열지 못했을 때의 끝 (맥이 나중에 더한 것)
        #expect(AgentHTTPClient.TaskDTO.failureText("browser_failed") == "쇼핑 화면에서 읽어 오지 못해 작업을 끝냈어요.")
    }
}
