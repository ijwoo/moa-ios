import Foundation
import SwiftData
import Testing
import UIKit
import WebKit
@testable import MeetingSummary

/// 쇼핑 "옆에서 봐 주기" (D74): 앱 안의 쇼핑 화면에서 내가 직접 쇼핑하고, "확인해 줘"를 누를 때만 그 화면에서 읽은 것이 맥으로 간다.
/// 여기의 상품·가게·주소는 모두 가상이다. 실제 쇼핑몰에는 접속하지 않는다 (가상 쇼핑몰의 페이지는 앱이 그린다)
@MainActor
@Suite("쇼핑 화면: 옆에서 봐 주기")
struct ShopViewTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func mac(shop: Bool = true, failing: Int = 0) -> MockAgentClient {
        MockAgentClient(v2: true, failingChecks: failing, dialogCloud: MockDialogCloud(marksWriter: true, opensShop: shop))
    }

    private func session(_ agent: MockAgentClient?, provider: FakeAskProvider = FakeAskProvider([])) -> AskSession {
        let session = AskSession(provider: provider, agent: agent, pollInterval: .zero, weather: MockWeatherService())
        session.attach(context)
        return session
    }

    private func decode(_ json: String, accepts: Bool = true) throws -> AgentReply {
        try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200, acceptsShop: accepts)
    }

    private func body(features: Set<String>, extras: MessageExtras) throws -> [String: Any] {
        let body = AgentHTTPClient.MessageBody(
            text: AskSession.shopCheckText, conversationID: "c_1", context: nil, messageID: "m_1", replyTaskID: nil,
            tone: "friendly", features: features, extras: extras
        )
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    private func url(_ text: String) -> URL? { URL(string: text) }

    private let productPage = ShopPage(kind: .product, address: "https://store.shop.test/malgeun/products/1001")
    private let listPage = ShopPage(kind: .list, address: "https://search.shop.test/search/all")

    /// 상품 화면에서 읽은 것 (가상 상품)
    private var product: ShopView {
        ShopView(kind: .product, url: productPage.address, fields: ShopView.Fields(
            title: "맑은샘 생수 2L 6개", price: 5_900, originalPrice: 7_200, shipping: "배송비 3,000원", seller: "맑은샘 상점",
            arrival: "내일(목) 도착 예정", options: [ShopView.Option(name: "구성", values: ["2L 6개", "2L 12개 (+5,500원)"])]
        ))
    }

    /// 맥이 세는 길이를 JSON 글로 재 본다
    private func macLength(_ json: String) throws -> Int {
        ShopView.macLength(try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed))
    }

    // MARK: - 맥과 맞춘 값

    @Test func namesMatchTheMac() {
        #expect(AgentFeature.shopView == "shop_view")
        #expect(MessageExtras.shopFeature == "shop")
        #expect(AskSession.shopCheckText == "이 화면 확인해 줘")
        #expect(ShopView.Kind.product.rawValue == "product")
        #expect(ShopView.Kind.list.rawValue == "list")
        // 맥의 한도와 같거나 그 안쪽이다
        #expect(ShopView.queryLimit == 80)
        #expect(ShopView.titleLimit == 200)
        #expect(ShopView.shippingLimit == 80)
        #expect(ShopView.sellerLimit == 60)
        #expect(ShopView.arrivalLimit == 80)
        #expect(ShopView.stockLimit == 60)
        #expect(ShopView.optionLimit == 8)
        #expect(ShopView.optionNameLimit == 40)
        #expect(ShopView.optionValueLimit == 20)
        #expect(ShopView.optionValueTextLimit == 60)
        #expect(ShopView.itemLimit == 8)
        #expect(ShopView.itemTitleLimit == 120)
        #expect(ShopView.mallLimit == 40)
        #expect(ShopView.sizeLimit < 20_000)
    }

    // MARK: - 여는 주소

    @Test func onlyNaverShoppingHostsOpen() {
        let site = ShopSite.naver
        for address in [
            "https://search.shopping.naver.com/search/all?query=x",
            "https://msearch.shopping.naver.com/search/all?query=x",
            "https://smartstore.naver.com/gage/products/123",
            "https://m.smartstore.naver.com/gage",
            "https://brand.naver.com/gage/products/123",
            "https://m.brand.naver.com/gage",
            "https://nid.naver.com/nidlogin.login",
            "https://shopping.naver.com/",
            // 검색에서 상품으로 넘어가는 주소 (쇼핑의 하위 호스트)
            "https://cr.shopping.naver.com/adcr",
            "https://SmartStore.Naver.com/gage",
        ] {
            #expect(site.allows(url(address)), "\(address)")
        }
        for address in [
            // https가 아니다
            "http://search.shopping.naver.com/search/all?query=x",
            // 아이디·비밀번호가 든 주소
            "https://me:secret@smartstore.naver.com/gage",
            "https://me@smartstore.naver.com/gage",
            // 주문서·결제
            "https://pay.naver.com/",
            "https://order.pay.naver.com/orderSheet/1",
            "https://m.pay.naver.com/o/home",
            // 그 밖의 네이버와 다른 곳
            "https://www.naver.com/",
            "https://mail.naver.com/",
            "https://evilshopping.naver.com/",
            "https://search.shopping.naver.com.evil.test/search/all",
            "https://shop.test/",
            // 다른 앱을 여는 주소와 글·파일
            "naversearchapp://inappbrowser?url=x",
            "javascript:alert(1)",
            "data:text/html,hi",
            "file:///etc/hosts",
        ] {
            #expect(!site.allows(url(address)), "\(address)")
        }
        #expect(!site.allows(nil))
    }

    @Test func onlySearchResultsAndProductPagesAreRead() {
        let site = ShopSite.naver
        // 검색 결과: 물음표 뒤는 뗀다
        #expect(site.page(for: url("https://search.shopping.naver.com/search/all?query=%EC%83%9D%EC%88%98&frm=NVSHATC"))
            == ShopPage(kind: .list, address: "https://search.shopping.naver.com/search/all"))
        #expect(site.page(for: url("https://msearch.shopping.naver.com/search/all?query=x"))?.kind == .list)
        // 상품 화면: 가게/products/숫자
        #expect(site.page(for: url("https://smartstore.naver.com/gage/products/1234567890?NaPm=abc#review"))
            == ShopPage(kind: .product, address: "https://smartstore.naver.com/gage/products/1234567890"))
        #expect(site.page(for: url("https://m.brand.naver.com/gage/products/42"))
            == ShopPage(kind: .product, address: "https://m.brand.naver.com/gage/products/42"))

        for address in [
            // 가게 첫 화면, 상품 번호가 아닌 것, 상품의 하위 화면
            "https://smartstore.naver.com/gage",
            "https://smartstore.naver.com/gage/products/abc",
            "https://smartstore.naver.com/gage/products/123/qna",
            "https://smartstore.naver.com/gage/cart/123",
            "https://smartstore.naver.com/search/x",
            // 장바구니·내 정보·로그인
            "https://shopping.naver.com/cart",
            "https://shopping.naver.com/my/p/home",
            "https://nid.naver.com/nidlogin.login",
            // 검색이 아닌 화면, 열기만 하는 호스트
            "https://search.shopping.naver.com/",
            "https://search.shopping.naver.com/catalog/123",
            "https://cr.shopping.naver.com/search/all",
            // 열지 않는 주소
            "https://pay.naver.com/search/all",
            "https://order.pay.naver.com/gage/products/1",
            "http://smartstore.naver.com/gage/products/1",
        ] {
            #expect(site.page(for: url(address)) == nil, "\(address)")
        }
        // 주소가 너무 길면 읽지 않는다
        #expect(site.page(for: url("https://search.shopping.naver.com/search/" + String(repeating: "a", count: 300))) == nil)
        #expect(site.page(for: nil) == nil)
    }

    @Test func theAppBuildsTheSearchAddress() throws {
        let site = ShopSite.naver
        let made = try #require(site.searchURL(for: "  생수\n2L   6개 "))
        #expect(made.host() == "search.shopping.naver.com")
        #expect(made.path() == "/search/all")
        #expect(URLComponents(url: made, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "query", value: "생수 2L 6개")])
        #expect(site.page(for: made)?.kind == .list)

        // 검색어의 기호는 주소를 바꾸지 못한다
        let odd = try #require(site.searchURL(for: "C++ 책 & a=b#c?d"))
        #expect(odd.absoluteString.contains("C%2B%2B"))
        #expect(odd.fragment() == nil)
        #expect(odd.host() == "search.shopping.naver.com")
        #expect(URLComponents(url: odd, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "query", value: "C++ 책 & a=b#c?d")])

        // 주소처럼 생긴 검색어도 검색어일 뿐이다
        let link = try #require(site.searchURL(for: "https://pay.shop.test/order"))
        #expect(link.host() == "search.shopping.naver.com")

        // 길면 자르고, 비면 만들지 않는다
        let long = try #require(site.searchURL(for: String(repeating: "가", count: 100)))
        #expect(URLComponents(url: long, resolvingAgainstBaseURL: false)?.queryItems?.first?.value?.count == 80)
        #expect(site.searchURL(for: "") == nil)
        #expect(site.searchURL(for: " \n ") == nil)
    }

    // MARK: - 읽은 것을 다듬기

    @Test func productFieldsAreCleaned() throws {
        let json = """
        {"title": "  맑은샘\\n생수   2L 6개 ", "price": 5900, "original_price": 7200, "member_price": true,
         "shipping": "배송비 3,000원", "seller": "맑은샘 상점", "arrival": "내일(목) 도착 예정", "stock": "남은 수량 3개",
         "options": [{"name": "구성", "values": ["2L 6개", "2L 6개", "2L 12개 (+5,500원)", "", 3]},
                     {"name": "", "values": ["x"]}, {"name": "색", "values": []}, "x"],
         "account": "무시되는 값"}
        """
        let view = try #require(ShopView.read(page: productPage, json: json))
        #expect(view.kind == .product)
        #expect(view.url == "https://store.shop.test/malgeun/products/1001")
        #expect(view.fields == ShopView.Fields(
            title: "맑은샘 생수 2L 6개", price: 5_900, originalPrice: 7_200, memberPrice: true, shipping: "배송비 3,000원",
            seller: "맑은샘 상점", arrival: "내일(목) 도착 예정", stock: "남은 수량 3개",
            options: [ShopView.Option(name: "구성", values: ["2L 6개", "2L 12개 (+5,500원)"])]
        ))

        // 보내는 꼴: 맥과 맞춘 이름으로, 읽지 못한 것은 넣지 않는다
        let sent = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(view)) as? [String: Any])
        #expect(Set(sent.keys) == ["kind", "url", "fields"])
        #expect(sent["kind"] as? String == "product")
        let fields = try #require(sent["fields"] as? [String: Any])
        #expect(Set(fields.keys) == ["title", "price", "original_price", "member_price", "shipping", "seller", "arrival", "stock", "options"])
        #expect(fields["price"] as? Int == 5_900)
        #expect(fields["member_price"] as? Bool == true)

        let bare = try #require(ShopView.read(page: productPage, json: #"{"title": "산들 암반수"}"#))
        let bareSent = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as? [String: Any])
        #expect(Set((bareSent["fields"] as? [String: Any] ?? [:]).keys) == ["title"])
    }

    @Test func aPriceIsOnlyAPositiveWholeNumber() {
        #expect(ShopText.price(5_900) == 5_900)
        #expect(ShopText.price(5_900.0) == 5_900)
        #expect(ShopText.price("5900") == 5_900)
        #expect(ShopText.price("5,900") == 5_900)
        #expect(ShopText.price("5,900원") == 5_900)
        #expect(ShopText.price(" 1,234,567원 ") == 1_234_567)
        #expect(ShopText.price(9_999_999_999) == 9_999_999_999)

        #expect(ShopText.price(true) == nil)
        #expect(ShopText.price(false) == nil)
        #expect(ShopText.price(0) == nil)
        #expect(ShopText.price(-5_900) == nil)
        #expect(ShopText.price(5_900.5) == nil)
        #expect(ShopText.price(10_000_000_000) == nil)
        #expect(ShopText.price("5,900원~") == nil)
        #expect(ShopText.price("5,900원부터") == nil)
        #expect(ShopText.price("₩5,900") == nil)
        #expect(ShopText.price("1,23") == nil)
        #expect(ShopText.price("59,00") == nil)
        #expect(ShopText.price("5.900") == nil)
        #expect(ShopText.price("문의") == nil)
        #expect(ShopText.price("") == nil)
        #expect(ShopText.price(nil) == nil)
        #expect(ShopText.price(["5900"]) == nil)
    }

    @Test func onlyWhatWasReadForSureGoesIn() throws {
        func read(_ json: String) -> ShopView.Fields? { ShopView.read(page: productPage, json: json)?.fields }

        // 원래 가격은 지금 가격보다 클 때만
        #expect(read(#"{"title": "가", "price": 5000, "original_price": 5000}"#)?.originalPrice == nil)
        #expect(read(#"{"title": "가", "price": 5000, "original_price": 4000}"#)?.originalPrice == nil)
        #expect(read(#"{"title": "가", "original_price": 7000}"#)?.originalPrice == nil)
        #expect(read(#"{"title": "가", "price": 5000, "original_price": "7,000원"}"#)?.originalPrice == 7_000)

        // 회원가는 참이라고 읽었을 때만 (숫자 1이나 글은 아니다), 가격이 있을 때만
        #expect(read(#"{"title": "가", "price": 5000, "member_price": 1}"#)?.memberPrice == nil)
        #expect(read(#"{"title": "가", "price": 5000, "member_price": "true"}"#)?.memberPrice == nil)
        #expect(read(#"{"title": "가", "price": 5000, "member_price": false}"#)?.memberPrice == nil)
        #expect(read(#"{"title": "가", "member_price": true}"#)?.memberPrice == nil)
        #expect(read(#"{"title": "가", "price": 5000, "member_price": true}"#)?.memberPrice == true)

        // 가격이 가격 꼴이 아니면 넣지 않는다 (이름만 간다)
        let unpriced = try #require(read(#"{"title": "가", "price": "5,900원~"}"#))
        #expect(unpriced.price == nil)
        #expect(unpriced.title == "가")

        // 이름도 가격도 없으면 보내지 않는다
        #expect(read(#"{"shipping": "무료배송", "seller": "산들마켓"}"#) == nil)
        #expect(read("{}") == nil)
        #expect(read("[1, 2]") == nil)
        #expect(read("읽지 못함") == nil)
        #expect(ShopView.read(page: productPage, json: nil) == nil)
        // 너무 큰 것은 읽지 않은 것으로 한다
        let huge = #"{"title": "가", "price": 5000, "pad": ""# + String(repeating: "a", count: ShopView.rawLimit) + #""}"#
        #expect(ShopView.read(page: productPage, json: huge) == nil)
    }

    /// 로그인한 화면은 배송 안내에 내 이름이나 배송지를 섞어 쓸 수 있다. 그런 줄은 맥으로 가지 않는다
    @Test func linesAboutMeAreDropped() throws {
        let json = """
        {"title": "맑은샘 생수 2L 6개", "price": 5900,
         "shipping": "홍길동님 배송지로 무료배송", "arrival": "길동님께 내일 도착", "seller": "문의 shop@mail.test", "stock": "주소 확인 뒤 주문 가능",
         "options": [{"name": "구성", "values": ["2L 6개", "회원님 전용 12개"]}, {"name": "혜택", "values": ["고객님, 쿠폰이 있어요"]}]}
        """
        let fields = try #require(ShopView.read(page: productPage, json: json)).fields
        #expect(fields.shipping == nil)
        #expect(fields.arrival == nil)
        #expect(fields.seller == nil)
        #expect(fields.stock == nil)
        #expect(fields.options == [ShopView.Option(name: "구성", values: ["2L 6개"])])
        #expect(fields.title == "맑은샘 생수 2L 6개")
        #expect(fields.price == 5_900)

        #expect(ShopText.looksPersonal("가상이름님의 기본 배송지"))
        #expect(ShopText.looksPersonal("회원님 (등급가)"))
        #expect(ShopText.looksPersonal("me@mail.test"))
        #expect(!ShopText.looksPersonal("내일(목) 도착 예정"))
        #expect(!ShopText.looksPersonal("배송비 3,000원"))
        #expect(!ShopText.looksPersonal("달님상점"))
        #expect(!ShopText.looksPersonal("님"))

        // 목록의 판매처도 같다
        let list = try #require(ShopView.read(page: listPage, json: #"{"items": [{"title": "가", "price": 1000, "mall": "길동님 가게"}]}"#))
        #expect(list.fields.items == [ShopView.Item(title: "가", price: 1_000, mall: nil)])
    }

    @Test func productLimitsHold() throws {
        let values = (1...30).map { "\"값 \($0) " + String(repeating: "나", count: 100) + "\"" }.joined(separator: ", ")
        let options = (1...10).map { "{\"name\": \"옵션 \($0) " + String(repeating: "다", count: 50) + "\", \"values\": [\"가\", \"나\"]}" }
        let json = "{\"title\": \"" + String(repeating: "가", count: 300) + "\", \"price\": 5900, \"shipping\": \"" + String(repeating: "a", count: 100)
            + "\", \"seller\": \"" + String(repeating: "b", count: 100) + "\", \"arrival\": \"" + String(repeating: "c", count: 100)
            + "\", \"stock\": \"" + String(repeating: "d", count: 100) + "\", \"options\": [{\"name\": \"구성\", \"values\": [" + values + "]}, "
            + options.joined(separator: ", ") + "]}"
        let fields = try #require(ShopView.read(page: productPage, json: json)).fields
        #expect(fields.title?.count == 200)
        #expect(fields.shipping?.count == 80)
        #expect(fields.seller?.count == 60)
        #expect(fields.arrival?.count == 80)
        #expect(fields.stock?.count == 60)
        let read = try #require(fields.options)
        #expect(read.count == 8)
        #expect(read[0].values.count == 20)
        #expect(read[0].values.allSatisfy { $0.count <= 60 })
        #expect(read.allSatisfy { $0.name.count <= 40 })
    }

    @Test func listItemsAreCleaned() throws {
        let json = """
        {"items": [{"title": " 하늘물  먹는샘물 2L 6개입 ", "price": 4950, "mall": "하늘식품"}, {"title": "하늘물 먹는샘물 2L 6개입", "price": 1},
                   {"title": "산들 암반수 2L 6개 무라벨", "price": "6,480원"}, {"title": "숲속 생수", "price": "문의"}, {"price": 3}, "x", {"title": ""}]}
        """
        let view = try #require(ShopView.read(page: listPage, json: json))
        #expect(view.kind == .list)
        #expect(view.url == "https://search.shop.test/search/all")
        // 같은 이름은 한 번만, 이름이 없는 것은 뺀다. 가격을 못 읽은 상품은 이름만 간다
        #expect(view.fields.items == [
            ShopView.Item(title: "하늘물 먹는샘물 2L 6개입", price: 4_950, mall: "하늘식품"),
            ShopView.Item(title: "산들 암반수 2L 6개 무라벨", price: 6_480, mall: nil),
            ShopView.Item(title: "숲속 생수", price: nil, mall: nil),
        ])
        #expect(view.fields.title == nil)
        #expect(view.missing.isEmpty)

        // 여덟 개까지, 이름과 판매처는 한도에서 자른다
        let many = (1...12).map { "{\"title\": \"상품 \($0) " + String(repeating: "가", count: 200) + "\", \"price\": \($0)000, \"mall\": \"" + String(repeating: "m", count: 80) + "\"}" }
        let long = try #require(ShopView.read(page: listPage, json: "{\"items\": [" + many.joined(separator: ", ") + "]}"))
        #expect(long.fields.items?.count == 8)
        #expect(long.fields.items?.allSatisfy { $0.title.count == 120 && $0.mall?.count == 40 } == true)
        #expect(long.fields.items?.first?.price == 1_000)

        // 상품이 없으면 보내지 않는다. 상품 화면의 값은 목록 화면에서 읽히지 않는다
        #expect(ShopView.read(page: listPage, json: #"{"items": []}"#) == nil)
        #expect(ShopView.read(page: listPage, json: #"{"title": "맑은샘 생수", "price": 5900}"#) == nil)
        // 목록의 값도 상품 화면에서 읽히지 않는다
        #expect(ShopView.read(page: productPage, json: #"{"items": [{"title": "가", "price": 1000}]}"#) == nil)
    }

    // MARK: - 크기

    /// 맥은 `json.dumps(view)`의 길이로 센다: 빈칸을 넣고, ASCII가 아닌 글자는 `\uXXXX`로 풀어 쓴다
    @Test func sizeIsCountedTheWayTheMacCountsIt() throws {
        #expect(try macLength(#""abc""#) == 5)
        #expect(try macLength(#""생수""#) == 14)
        #expect(try macLength(#""a\"b""#) == 6)
        #expect(try macLength(#""a\nb""#) == 6)
        #expect(try macLength(#""😀""#) == 14)
        #expect(try macLength("5900") == 4)
        #expect(try macLength("true") == 4)
        #expect(try macLength("false") == 5)
        #expect(try macLength("null") == 4)
        #expect(try macLength(#"["a", "b"]"#) == 10)
        #expect(try macLength(#"{"k": "v"}"#) == 10)
        #expect(try macLength("[]") == 2)
        #expect(try macLength("{}") == 2)

        // 맥에서 `len(json.dumps(...))`로 잰 값과 같다
        let view = ShopView(kind: .product, url: productPage.address, fields: ShopView.Fields(
            title: "맑은샘 생수 2L 6개", price: 5_900, originalPrice: 7_200, memberPrice: true,
            options: [ShopView.Option(name: "구성", values: ["2L 6개", "2L 12개 (+5,500원)"])]
        ))
        #expect(view.macSize == 298)
        let list = ShopView(kind: .list, url: listPage.address, fields: ShopView.Fields(items: [
            ShopView.Item(title: "하늘물 \"먹는샘물\" 2L", price: 4_950, mall: "하늘식품"), ShopView.Item(title: "B 😀"),
        ]))
        #expect(list.macSize == 230)
    }

    @Test func aViewTooBigForTheMacIsTrimmed() throws {
        let values = (1...20).map { "값 \($0) " + String(repeating: "가", count: 50) }
        let options = (1...8).map { ShopView.Option(name: "옵션 \($0)", values: values) }
        var big = product
        big.fields.options = options
        #expect(big.macSize > 20_000)

        let fitted = big.fitted()
        #expect(fitted.macSize <= ShopView.sizeLimit)
        // 옵션의 값만 줄인다: 이름·가격·배송은 그대로다
        #expect(fitted.fields.title == big.fields.title)
        #expect(fitted.fields.price == big.fields.price)
        #expect(fitted.fields.shipping == big.fields.shipping)
        #expect(fitted.fields.options?.isEmpty == false)
        #expect(fitted.fields.options?.allSatisfy { !$0.values.isEmpty && $0.values == Array(values.prefix($0.values.count)) } == true)

        // 읽을 때부터 줄여 둔다
        let raw: [String: Any] = ["title": "맑은샘 생수 2L 6개", "price": 5_900, "options": options.map { ["name": $0.name, "values": $0.values] }]
        let json = try #require(String(data: JSONSerialization.data(withJSONObject: raw), encoding: .utf8))
        let read = try #require(ShopView.read(page: productPage, json: json))
        #expect(read.macSize <= ShopView.sizeLimit)
        #expect(read.fields.price == 5_900)

        // 들어가는 것은 건드리지 않는다
        #expect(product.fitted() == product)

        // 목록은 뒤의 상품부터 빼고, 하나는 남긴다. 더 줄일 것이 없으면 멈춘다
        let items = (1...8).map { ShopView.Item(title: "상품 \($0) " + String(repeating: "가", count: 100), price: $0 * 1_000) }
        let list = ShopView(kind: .list, url: listPage.address, fields: ShopView.Fields(items: items))
        let short = list.fitted(limit: 2_000)
        #expect(short.macSize <= 2_000)
        #expect(short.fields.items == Array(items.prefix(short.fields.items?.count ?? 0)))
        #expect((1..<8).contains(short.fields.items?.count ?? 0))
        #expect(list.fitted(limit: 10).fields.items == [items[0]])
        var plain = product
        plain.fields.options = nil
        #expect(plain.fitted(limit: 10) == plain)
    }

    // MARK: - 화면에 보여 주는 글

    @Test func theSheetShowsExactlyWhatWasSent() {
        var view = product
        view.fields.memberPrice = true
        view.fields.stock = "남은 수량 3개"
        #expect(view.lines == [
            ShopView.Line(label: "상품", value: "맑은샘 생수 2L 6개"),
            ShopView.Line(label: "가격", value: "5,900원 (회원가) · 원래 7,200원"),
            ShopView.Line(label: "배송", value: "배송비 3,000원"),
            ShopView.Line(label: "도착", value: "내일(목) 도착 예정"),
            ShopView.Line(label: "판매", value: "맑은샘 상점"),
            ShopView.Line(label: "재고", value: "남은 수량 3개"),
            ShopView.Line(label: "구성", value: "2L 6개, 2L 12개 (+5,500원)"),
        ])
        #expect(view.missing.isEmpty)
        #expect(view.host == "store.shop.test")

        // 읽지 못한 것은 읽지 못했다고 알린다
        let titleOnly = ShopView(kind: .product, url: productPage.address, fields: ShopView.Fields(title: "산들 암반수"))
        #expect(titleOnly.lines == [ShopView.Line(label: "상품", value: "산들 암반수")])
        #expect(titleOnly.missing == ["가격", "배송비"])
        let priceOnly = ShopView(kind: .product, url: productPage.address, fields: ShopView.Fields(price: 12_900, shipping: "무료배송"))
        #expect(priceOnly.lines.map(\.value) == ["12,900원", "무료배송"])
        #expect(priceOnly.missing == ["상품 이름"])

        let list = ShopView(kind: .list, url: listPage.address, fields: ShopView.Fields(items: [
            ShopView.Item(title: "하늘물 먹는샘물 2L 6개입", price: 4_950, mall: "하늘식품"),
            ShopView.Item(title: "산들 암반수 2L 6개 무라벨", price: 6_480),
            ShopView.Item(title: "숲속 생수"),
        ]))
        #expect(list.lines == [
            ShopView.Line(label: "1", value: "하늘물 먹는샘물 2L 6개입 — 4,950원 · 하늘식품"),
            ShopView.Line(label: "2", value: "산들 암반수 2L 6개 무라벨 — 6,480원"),
            ShopView.Line(label: "3", value: "숲속 생수"),
        ])
        #expect(list.missing.isEmpty)
    }

    // MARK: - 요청

    @Test func theViewGoesOnlyToAMacThatKnowsIt() throws {
        var extras = MessageExtras(clientFeatures: ["shop"])
        extras.view = product

        // 쇼핑 화면을 모르는 맥에는 표시도 읽은 것도 가지 않는다
        let old = try body(features: [], extras: extras)
        #expect(old["client_features"] == nil)
        #expect(old["view"] == nil)
        let other = try body(features: [AgentFeature.reaction, AgentFeature.weatherAction], extras: extras)
        #expect(other["client_features"] == nil)
        #expect(other["view"] == nil)

        let known = try body(features: [AgentFeature.shopView], extras: extras)
        #expect(known["client_features"] as? [String] == ["shop"])
        let view = try #require(known["view"] as? [String: Any])
        #expect(view["kind"] as? String == "product")
        #expect(view["url"] as? String == "https://store.shop.test/malgeun/products/1001")
        let fields = try #require(view["fields"] as? [String: Any])
        #expect(fields["title"] as? String == "맑은샘 생수 2L 6개")
        #expect(fields["price"] as? Int == 5_900)
        #expect(fields["original_price"] as? Int == 7_200)
        #expect(fields["member_price"] == nil)

        // 읽은 것이 없는 말에는 `view`가 없다
        #expect(try body(features: [AgentFeature.shopView], extras: MessageExtras(clientFeatures: ["shop"]))["view"] == nil)
        // 앱이 쇼핑 화면을 연다고 알리지 않은 요청에는 붙지 않는다
        var silent = MessageExtras(clientFeatures: ["reaction"])
        silent.view = product
        let mute = try body(features: [AgentFeature.shopView, AgentFeature.reaction], extras: silent)
        #expect(mute["client_features"] as? [String] == ["reaction"])
        #expect(mute["view"] == nil)

        // 큰 것은 맥이 받는 크기로 줄어서 간다
        var big = product
        big.fields.options = (1...8).map { ShopView.Option(name: "옵션 \($0)", values: (1...20).map { "값 \($0) " + String(repeating: "가", count: 50) }) }
        extras.view = big
        let trimmed = try #require(try body(features: [AgentFeature.shopView], extras: extras)["view"])
        #expect(ShopView.macLength(trimmed) <= ShopView.sizeLimit)
    }

    // MARK: - 응답

    @Test func theMacDecidesOnlyTheSearchWords() throws {
        let reply = try decode("""
        {"conversation_id": "c_1", "replies": [{"text": "쇼핑 화면에서 같이 볼게요.", "by": "claude"}],
         "action": {"type": "shop", "query": "  생수\\n2L 6개 "}}
        """)
        #expect(reply.replies == ["쇼핑 화면에서 같이 볼게요."])
        #expect(reply.action == .shop(query: "생수 2L 6개"))

        // 주소가 와도 읽지 않는다: 받는 것은 검색어뿐이다
        let withLink = try decode("""
        {"conversation_id": "c_1", "replies": [{"text": "볼게요."}], "action": {"type": "shop", "query": "생수", "url": "https://pay.shop.test/order/1"}}
        """)
        #expect(withLink.action == .shop(query: "생수"))

        // 길면 자른다
        let long = try decode("""
        {"conversation_id": "c_1", "replies": [{"text": "볼게요."}], "action": {"type": "shop", "query": "\(String(repeating: "가", count: 100))"}}
        """)
        #expect(long.action == .shop(query: String(repeating: "가", count: 80)))
    }

    @Test func aShopReplyWithoutSearchWordsIsJustAnAnswer() throws {
        for query in [#""""#, #""   ""#, "3", "null", #"["생수"]"#, #"{"q": "생수"}"#, "true"] {
            let reply = try decode("""
            {"conversation_id": "c_1", "replies": [{"text": "무엇을 살까요?"}], "action": {"type": "shop", "query": \(query)}}
            """)
            #expect(reply.action == .none, "\(query)")
            #expect(reply.replies == ["무엇을 살까요?"])
        }
        let missing = try decode(#"{"conversation_id": "c_1", "replies": [{"text": "무엇을 살까요?"}], "action": {"type": "shop"}}"#)
        #expect(missing.action == .none)
        // 말도 검색어도 없으면 잘못된 응답이다
        #expect(throws: AgentError.self) {
            try decode(#"{"conversation_id": "c_1", "replies": [], "action": {"type": "shop", "query": ""}}"#)
        }
    }

    @Test func aRequestThatDidNotOfferTheShopGetsNoCard() throws {
        let reply = try decode("""
        {"conversation_id": "c_1", "replies": [{"text": "쇼핑 화면에서 같이 볼게요."}], "action": {"type": "shop", "query": "생수 2L 6개"}}
        """, accepts: false)
        #expect(reply.action == .none)
        #expect(reply.replies == ["쇼핑 화면에서 같이 볼게요."])
    }

    // MARK: - 대화

    @Test func sayingWhatToBuyPutsACardUnderTheAnswer() async {
        let agent = mac()
        let session = session(agent)
        await session.send("생수 2L 6개 사고 싶어", meetings: [])

        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(session.messages.last?.shopQuery == "생수 2L 6개")
        #expect(session.messages.last?.text.contains("생수 2L 6개") == true)
        // 작업은 만들어지지 않는다
        #expect(session.messages.allSatisfy { $0.agent == nil })
        // 앱이 쇼핑 화면을 열 수 있다고만 알렸다. 읽은 화면은 가지 않았다
        #expect(await agent.receivedExtras.map(\.clientFeatures) == [["shop"]])
        #expect(await agent.receivedExtras.allSatisfy { $0.view == nil })
        #expect(await agent.shopViews.isEmpty)
    }

    @Test func pressingCheckSendsWhatWasReadOnce() async throws {
        let agent = mac()
        let session = session(agent)
        await session.send("생수 2L 6개 사고 싶어", meetings: [])
        let before = session.messages.count
        #expect(session.canCheckShopNow)

        let sent = await session.checkShop(product, meetings: [])
        #expect(sent)
        #expect(await agent.shopViews == [product])
        // 읽은 것은 내 말에 붙어 남는다
        let mine = try #require(session.shopCheck(of: product, after: before))
        #expect(mine.role == .user)
        #expect(mine.text == "이 화면 확인해 줘")
        #expect(mine.shopView == product)
        #expect(session.shopCheck(of: product, after: session.messages.count) == nil)
        // 답은 받은 값으로 온다
        let answers = session.answers(after: mine.id)
        #expect(answers.map(\.role) == [.assistant])
        #expect(answers.first?.text.contains("5,900원") == true)
        #expect(answers.first?.text.contains("배송비 3,000원") == true)
        #expect(answers.first?.shopQuery == nil)

        // 그 뒤의 말에는 읽은 화면이 붙지 않는다 (누를 때만 간다)
        await session.send("안녕", meetings: [])
        #expect(await agent.receivedExtras.last?.view == nil)
        #expect(await agent.shopViews.count == 1)
        #expect(session.messages.last { $0.role == .user }?.shopView == nil)
        // 앞의 답은 그 말의 답까지만이다
        #expect(session.answers(after: mine.id).count == 1)

        // 같은 화면을 다시 확인하면 새로 보낸다
        let again = session.messages.count
        await session.checkShop(product, meetings: [])
        #expect(await agent.shopViews.count == 2)
        #expect(session.shopCheck(of: product, after: again)?.id != mine.id)
    }

    @Test func aListCheckAnswersFromTheItemsThatWereRead() async throws {
        let agent = mac()
        let session = session(agent)
        let list = ShopView(kind: .list, url: listPage.address, fields: ShopView.Fields(items: [
            ShopView.Item(title: "맑은샘 생수 2L 6개", price: 5_900), ShopView.Item(title: "하늘물 먹는샘물 2L 6개입", price: 4_950),
        ]))
        await session.checkShop(list, meetings: [])
        let mine = try #require(session.shopCheck(of: list))
        let answer = try #require(session.answers(after: mine.id).first)
        #expect(answer.text.contains("하늘물 먹는샘물 2L 6개입"))
        #expect(answer.text.contains("4,950원"))
    }

    @Test func theCardAndTheReadViewSurviveReopening() async throws {
        let agent = mac()
        let session = session(agent)
        await session.send("생수 2L 6개 사고 싶어", meetings: [])
        await session.checkShop(product, meetings: [])

        let reopened = self.session(agent)
        #expect(reopened.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(reopened.messages[1].shopQuery == "생수 2L 6개")
        #expect(reopened.messages[2].shopView == product)
        #expect(reopened.messages[0].shopView == nil)
        #expect(reopened.messages[3].shopQuery == nil)
        let mine = try #require(reopened.shopCheck(of: product))
        #expect(reopened.answers(after: mine.id).count == 1)
    }

    /// 읽은 화면은 맥만 답할 수 있다: 맥이 꺼져 있어도 회의 질문(Claude 경로)으로 넘기지 않는다
    @Test func anUnreachableMacGetsNothingAndNeitherDoesTheCloud() async throws {
        let agent = mac(failing: 99)
        let provider = FakeAskProvider([])
        let session = session(agent, provider: provider)

        await session.checkShop(product, meetings: [])
        #expect(session.messages.map(\.role) == [.user, .error])
        #expect(session.messages.last?.text == "맥에 연결되지 않아 화면을 확인하지 못했어요.")
        #expect(session.messages.last?.retryQuestion == "이 화면 확인해 줘")
        #expect(provider.requests.isEmpty)
        #expect(await agent.shopViews.isEmpty)
        #expect(await agent.received.isEmpty)
        // 쇼핑 화면은 그 자리에서 이 안내를 보여 준다
        let mine = try #require(session.shopCheck(of: product))
        #expect(session.answers(after: mine.id).map(\.role) == [.error])
    }

    @Test func aMacThatDoesNotKnowTheShopIsNeverSentAView() async {
        let agent = mac(shop: false)
        let session = session(agent)

        let sent = await session.checkShop(product, meetings: [])
        #expect(!sent)
        #expect(session.messages.isEmpty)
        #expect(await agent.received.isEmpty)

        await session.send("안녕", meetings: [])
        #expect(await agent.receivedExtras.allSatisfy { !$0.clientFeatures.contains("shop") && $0.view == nil })
        #expect(session.messages.allSatisfy { $0.shopQuery == nil && $0.shopView == nil })

        // 맥이 없으면 보낼 곳이 없다
        let alone = self.session(nil)
        #expect(!alone.canCheckShopNow)
        let sentAlone = await alone.checkShop(product, meetings: [])
        #expect(!sentAlone)
        #expect(alone.messages.allSatisfy { $0.shopView == nil })
    }

    // MARK: - 데이터 처리 방식

    @Test func thePrivacyScreenSaysWhatHappens() async throws {
        let setup = await DialogSetup(agent: mac())
        #expect(setup.opensShop)
        #expect(setup.stored.split(separator: " ").contains("shopview"))
        #expect(DialogSetup(stored: setup.stored)?.opensShop == true)

        let facts = MacAgentFacts(setup: setup).rows.map { $0.text + " " + ($0.note ?? "") }
        let fact = try #require(facts.first { $0.contains("앱 안의 쇼핑 화면에서 같이 봐요") })
        #expect(fact.contains("이 아이폰이 네이버 쇼핑에 직접 접속"))
        #expect(fact.contains("주문서·결제와 그 밖의 주소는 열지 않아요"))
        #expect(fact.contains("아이디·비밀번호를 읽지도, 저장하지도, 보내지도 않아요"))
        #expect(fact.contains("로그인된 상태(쿠키)는 이 아이폰의 앱 안 쇼핑 화면에만 남고"))
        #expect(fact.contains("읽기만 하고 아무것도 누르지 않아요"))
        #expect(fact.contains("'확인해 줘'를 누를 때만"))
        #expect(fact.contains("화면을 옮길 때마다 가지 않아요"))

        // 쇼핑 화면을 모르는 맥이면 그 줄이 없다
        let plain = await DialogSetup(agent: mac(shop: false))
        #expect(!plain.opensShop)
        #expect(!plain.stored.contains("shopview"))
        #expect(!MacAgentFacts(setup: plain).rows.contains { $0.text.contains("쇼핑 화면") })
        // 대화 판단을 맥 안에서 하는 맥에는 없는 기능이다
        #expect(!DialogSetup(place: .local, opensShop: true).opensShop)
    }

    // MARK: - 가짜 맥과 가상 쇼핑몰

    @Test func theMockPicksSearchWordsFromBuyingSentences() {
        #expect(MockAgentClient.shopQuery(in: "생수 2L 6개 사고 싶어") == "생수 2L 6개")
        #expect(MockAgentClient.shopQuery(in: "휴지를 사야 해") == "휴지")
        #expect(MockAgentClient.shopQuery(in: "생수 가격 알려줘") == nil)
        #expect(MockAgentClient.shopQuery(in: "사고 싶어") == nil)
    }

    @Test func theDemoShopIsDrawnByTheAppAndIsNotNaver() throws {
        let demo = ShopSite.demo
        let search = try #require(demo.searchURL(for: "생수 2L 6개"))
        #expect(search.host() == "search.shop.test")
        #expect(demo.page(for: search)?.kind == .list)
        let list = try #require(DemoShop.html(for: search))
        for product in DemoShop.products {
            #expect(list.contains(product.title))
            #expect(demo.page(for: DemoShop.productURL(product)) == ShopPage(kind: .product, address: DemoShop.productURL(product).absoluteString))
            #expect(DemoShop.html(for: DemoShop.productURL(product))?.contains(ShopText.won(product.price)) == true)
        }
        // 장바구니는 열리지만 읽지 않는다. 주문 주소는 열지 않는다
        #expect(demo.allows(DemoShop.cartURL))
        #expect(demo.page(for: DemoShop.cartURL) == nil)
        #expect(!demo.allows(url("https://pay.shop.test/order/1001")))
        #expect(DemoShop.html(for: try #require(url("https://pay.shop.test/order/1001"))) == nil)
        // 가상 쇼핑몰과 실제 쇼핑몰은 서로의 주소를 열지 않는다
        #expect(!ShopSite.naver.allows(search))
        #expect(!demo.allows(url("https://search.shopping.naver.com/search/all?query=x")))
        #expect(DemoShop.html(for: try #require(url("https://search.shopping.naver.com/search/all?query=x"))) == nil)
        // 검색어의 기호는 페이지를 깨지 못한다
        let odd = try #require(demo.searchURL(for: "<script>alert(1)</script>"))
        #expect(DemoShop.html(for: odd)?.contains("<script>alert(1)</script>") == false)
    }

    // MARK: - 쇼핑 화면 (웹 화면)

    /// 정해 둔 주소가 아니면 웹 화면을 만들기도 전에 멈춘다 (어디에도 접속하지 않는다)
    @Test func theBrowserRefusesOtherAddressesBeforeLoading() throws {
        let naver = ShopBrowser(site: .naver, isPersistent: false)
        let pay = try #require(url("https://order.pay.naver.com/orderSheet/1"))
        naver.visit(pay)
        #expect(naver.notice == .blocked(host: "order.pay.naver.com", url: pay))
        #expect(naver.address == nil)
        #expect(naver.page == nil)
        #expect(!naver.isLoading)

        let plain = try #require(url("http://search.shopping.naver.com/search/all?query=x"))
        naver.visit(plain)
        // https가 아닌 주소는 Safari로 여는 길도 주지 않는다
        #expect(naver.notice == .blocked(host: "search.shopping.naver.com", url: nil))

        naver.visit(try #require(url("naversearchapp://inappbrowser")))
        #expect(naver.notice == .blocked(host: nil, url: nil))
        #expect(naver.address == nil)

        // 검색어가 없으면 열지 않는다
        let empty = ShopBrowser(site: .naver, isPersistent: false)
        empty.open(query: "  ")
        #expect(empty.notice == .failed("검색어가 없어요."))
        #expect(empty.address == nil)
        // 읽을 화면이 없으면 읽은 것도 없다
        #expect(empty.query == nil)
    }

    /// 가상 쇼핑몰의 페이지를 웹 화면에 그려 놓고, 읽는 스크립트가 화면의 값을 그대로 읽는지 본다
    @Test(.timeLimit(.minutes(2))) func theReaderReadsWhatIsOnTheDemoPages() async throws {
        let browser = ShopBrowser(site: .demo, pages: DemoShop.html(for:), isPersistent: false)
        let web = browser.webView()
        web.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) }
        window?.frame = web.frame
        window?.addSubview(web)
        window?.isHidden = false
        defer {
            web.removeFromSuperview()
            window?.isHidden = true
        }

        func settle(at url: URL) async throws {
            for _ in 0..<600 where browser.isLoading || browser.address?.path() != url.path() {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(!browser.isLoading && browser.address?.path() == url.path(), "가상 페이지가 열리지 않았다: \(url.path())")
            try await Task.sleep(for: .milliseconds(300))
        }

        // 검색 결과: 상품마다 이름과 가격
        browser.open(query: "생수 2L 6개")
        try await settle(at: try #require(ShopSite.demo.searchURL(for: "생수 2L 6개")))
        #expect(browser.page == ShopPage(kind: .list, address: "https://search.shop.test/search/all"))
        guard case .view(let list) = await browser.read() else {
            Issue.record("검색 결과를 읽지 못했다")
            return
        }
        #expect(list.kind == .list)
        #expect(list.url == "https://search.shop.test/search/all")
        let items = try #require(list.fields.items)
        #expect(items.map(\.title) == DemoShop.products.map(\.title))
        #expect(items.map(\.price) == DemoShop.products.map(\.price))

        // 상품 화면: 화면에 보이는 값 그대로
        let first = DemoShop.products[0]
        browser.visit(DemoShop.productURL(first))
        try await settle(at: DemoShop.productURL(first))
        #expect(browser.page?.kind == .product)
        #expect(browser.canGoBack)
        guard case .view(let product) = await browser.read() else {
            Issue.record("상품 화면을 읽지 못했다")
            return
        }
        #expect(product.url == "https://store.shop.test/malgeun/products/1001")
        #expect(product.fields.title == first.title)
        #expect(product.fields.price == first.price)
        // 줄이 그어진 가격이 원래 가격이다
        #expect(product.fields.originalPrice == first.original)
        #expect(product.fields.memberPrice == nil)
        #expect(product.fields.shipping?.contains("3,000원") == true)
        #expect(product.fields.arrival?.contains("도착") == true)
        #expect(product.fields.seller == first.seller)
        let option = try #require(product.fields.options?.first)
        #expect(option.name == "구성")
        for value in first.options { #expect(option.values.contains(value)) }
        #expect(product.missing.isEmpty)

        // 줄이 그어진 가격이 없는 상품에는 원래 가격이 없다
        let second = DemoShop.products[1]
        browser.visit(DemoShop.productURL(second))
        try await settle(at: DemoShop.productURL(second))
        guard case .view(let other) = await browser.read() else {
            Issue.record("둘째 상품 화면을 읽지 못했다")
            return
        }
        #expect(other.fields.title == second.title)
        #expect(other.fields.price == second.price)
        #expect(other.fields.originalPrice == nil)
        #expect(other.fields.options == nil)

        // 장바구니: 열리지만 읽지 않는다
        browser.visit(DemoShop.cartURL)
        try await settle(at: DemoShop.cartURL)
        #expect(browser.page == nil)
        #expect(await browser.read() == .nothing)

        // 페이지가 스스로 주문 주소로 가려 해도 열지 않는다
        browser.goBack()
        try await settle(at: DemoShop.productURL(second))
        _ = try? await web.evaluateJavaScript("location.href = 'https://pay.shop.test/order/1002'; 0")
        for _ in 0..<100 where browser.notice == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(browser.notice == .blocked(host: "pay.shop.test", url: url("https://pay.shop.test/order/1002")))
        #expect(browser.address?.host() == "store.shop.test")
    }
}
