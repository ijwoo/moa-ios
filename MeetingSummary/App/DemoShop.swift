#if DEBUG
import Foundation

/// 개발용 가상 쇼핑몰 (D74). 쇼핑 화면의 스크린샷과 테스트에만 쓴다 (Release·TestFlight 빌드에는 없다).
/// 실제 쇼핑몰을 흉내 내지 않는다: 이름도 주소(`.test`)도 상품도 가상이고, 페이지는 앱이 그린다. 어디에도 접속하지 않는다
extension ShopSite {
    static let demo = ShopSite(
        name: "가상 쇼핑몰",
        listHosts: ["search.shop.test"],
        productHosts: ["store.shop.test"],
        plainHosts: ["login.shop.test"],
        loginHosts: ["login.shop.test"],
        openSuffixes: [],
        searchBase: "https://search.shop.test/search/all"
    )
}

enum DemoShop {
    /// 실행 인자로 시킨 일은 한 번만 한다 (`-demoShopOpen`, `-demoShopPage` …)
    @MainActor static var didAutoOpen = false
    @MainActor static var didRunDemo = false

    struct Product {
        let id: Int
        let store: String
        let seller: String
        let title: String
        let price: Int
        let original: Int?
        let shipping: String
        let arrival: String
        let options: [String]
    }

    static let products: [Product] = [
        Product(id: 1001, store: "malgeun", seller: "맑은샘 상점", title: "맑은샘 생수 2L 6개", price: 5_900, original: 7_200,
                shipping: "배송비 3,000원", arrival: "내일(목) 도착 예정", options: ["2L 6개", "2L 12개 (+5,500원)", "500mL 20개 (+2,100원)"]),
        Product(id: 1002, store: "sandle", seller: "산들마켓", title: "산들 암반수 2L 6개 무라벨", price: 6_480, original: nil,
                shipping: "무료배송", arrival: "모레(금) 도착 예정", options: []),
        Product(id: 1003, store: "haneul", seller: "하늘식품", title: "하늘물 먹는샘물 2L 6개입", price: 4_950, original: 5_500,
                shipping: "배송비 3,500원", arrival: "11/20 도착 예정", options: ["1묶음", "2묶음 (+4,700원)"]),
        Product(id: 1004, store: "malgeun", seller: "맑은샘 상점", title: "맑은샘 생수 2L 12개 대용량", price: 10_900, original: 13_800,
                shipping: "무료배송", arrival: "내일(목) 도착 예정", options: []),
        Product(id: 1005, store: "dongne", seller: "동네물가게", title: "숲속 생수 2L 6개 정기배송 가능", price: 6_100, original: nil,
                shipping: "배송비 2,500원", arrival: "모레(금) 도착 예정", options: []),
        Product(id: 1006, store: "sandle", seller: "산들마켓", title: "산들 탄산수 플레인 500mL 20개", price: 11_800, original: 14_000,
                shipping: "무료배송", arrival: "모레(금) 도착 예정", options: ["플레인", "레몬", "라임"]),
    ]

    static func productURL(_ product: Product) -> URL {
        URL(string: "https://store.shop.test/\(product.store)/products/\(product.id)")!
    }

    static let cartURL = URL(string: "https://store.shop.test/cart")!

    /// 이 주소의 가상 페이지. 가상 쇼핑몰의 주소가 아니면 nil
    static func html(for url: URL) -> String? {
        guard ShopSite.demo.allows(url), let host = url.host() else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        switch host {
        case "search.shop.test":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
            return page(title: "검색: \(query)", body: list(query: query))
        case "store.shop.test":
            if parts == ["cart"] { return page(title: "장바구니", body: cart) }
            if parts.count == 3, parts[1] == "products", let product = products.first(where: { String($0.id) == parts[2] && $0.store == parts[0] }) {
                return page(title: product.title, body: detail(product), head: head(product))
            }
            return page(title: "없는 화면", body: "<p class=\"note\">없는 화면이에요.</p>")
        case "login.shop.test":
            return page(title: "로그인", body: "<h1>로그인</h1><p class=\"note\">가상 쇼핑몰의 로그인 화면이에요. 실제 로그인은 없어요.</p>")
        default:
            return nil
        }
    }

    // MARK: - 페이지

    private static func won(_ price: Int) -> String { ShopText.won(price) }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func list(query: String) -> String {
        let cards = products.map { product in
            let original = product.original.map { "<del>\(won($0))</del>" } ?? ""
            return """
            <a class="card" href="\(productURL(product).absoluteString)">
              <div class="thumb" aria-hidden="true"></div>
              <div class="info">
                <div class="name">\(escape(product.title))</div>
                <div class="price"><strong>\(won(product.price))</strong> \(original)</div>
                <div class="meta">\(escape(product.shipping))</div>
                <div class="meta">\(escape(product.seller))</div>
              </div>
            </a>
            """
        }.joined(separator: "\n")
        return """
        <div class="search">\(escape(query.isEmpty ? "검색어" : query))</div>
        <p class="note">가상 상품 \(products.count)개 · 화면 확인용</p>
        \(cards)
        """
    }

    private static func head(_ product: Product) -> String {
        // 상품 정보를 널리 쓰는 표준(JSON-LD)으로도 적어 둔다
        let data: [String: Any] = [
            "@context": "https://schema.org", "@type": "Product", "name": product.title,
            "offers": ["@type": "Offer", "price": product.price, "priceCurrency": "KRW", "seller": ["@type": "Organization", "name": product.seller]],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: data)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        <meta property="og:title" content="\(escape(product.title))">
        <script type="application/ld+json">\(json.replacingOccurrences(of: "</", with: "<\\/"))</script>
        """
    }

    private static func detail(_ product: Product) -> String {
        let original = product.original.map { "<del>\(won($0))</del>" } ?? ""
        let options = product.options.isEmpty ? "" : """
        <label for="opt">구성</label>
        <select id="opt"><option value="">구성을 골라 주세요</option>\(product.options.enumerated().map { "<option value=\"\($0.offset + 1)\">\(escape($0.element))</option>" }.joined())</select>
        """
        return """
        <div class="hero" aria-hidden="true"></div>
        <div class="seller">\(escape(product.seller))</div>
        <h1>\(escape(product.title))</h1>
        <div class="price big"><strong>\(won(product.price))</strong> \(original)</div>
        <dl>
          <dt>배송</dt><dd>\(escape(product.shipping))</dd>
          <dt>도착</dt><dd>\(escape(product.arrival))</dd>
        </dl>
        \(options)
        <div class="buttons">
          <a class="button ghost" href="\(cartURL.absoluteString)">장바구니</a>
          <a class="button" href="https://pay.shop.test/order/\(product.id)">구매하기</a>
        </div>
        <p class="note">가상 상품이에요. 실제로 살 수 없어요.</p>
        """
    }

    private static let cart = """
    <h1>장바구니</h1>
    <p class="note">가상 쇼핑몰의 장바구니예요. 이런 화면은 앱이 읽지 않아요.</p>
    """

    private static func page(title: String, body: String, head: String = "") -> String {
        """
        <!doctype html>
        <html lang="ko"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        \(head)
        <style>
        :root { --bg: #fbfaf7; --ink: #23201b; --dim: #7a746a; --line: #e6e1d6; --card: #ffffff; --brand: #2f7d6b; --block: #dfe9e4; }
        @media (prefers-color-scheme: dark) {
          :root { --bg: #15171a; --ink: #f1efe9; --dim: #a09a8f; --line: #2c2f33; --card: #1d2024; --brand: #6cc3ad; --block: #26332f; }
        }
        * { box-sizing: border-box; }
        body { margin: 0; font: 16px/1.45 -apple-system, sans-serif; background: var(--bg); color: var(--ink); -webkit-text-size-adjust: 100%; }
        header { display: flex; align-items: center; gap: 8px; padding: 14px 16px; border-bottom: 1px solid var(--line); font-weight: 700; color: var(--brand); }
        header span { font-weight: 500; font-size: 12px; color: var(--dim); border: 1px solid var(--line); border-radius: 99px; padding: 1px 8px; }
        main { padding: 16px; }
        h1 { font-size: 20px; margin: 4px 0 10px; }
        .search { border: 1px solid var(--line); border-radius: 12px; padding: 10px 14px; background: var(--card); }
        .note { color: var(--dim); font-size: 13px; }
        .card { display: flex; gap: 12px; padding: 12px; margin: 10px 0; border: 1px solid var(--line); border-radius: 14px; background: var(--card); color: inherit; text-decoration: none; }
        .thumb { flex: none; width: 84px; height: 84px; border-radius: 10px; background: var(--block); }
        .hero { height: 200px; border-radius: 16px; background: var(--block); margin-bottom: 14px; }
        .name { font-weight: 600; }
        .price { margin: 4px 0; }
        .price strong { font-size: 18px; }
        .price.big strong { font-size: 28px; }
        del { color: var(--dim); font-size: 14px; }
        .meta, .seller { color: var(--dim); font-size: 13px; }
        dl { display: grid; grid-template-columns: 56px 1fr; gap: 6px 10px; margin: 14px 0; padding: 12px 0; border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); }
        dt { color: var(--dim); } dd { margin: 0; }
        label { display: block; font-size: 13px; color: var(--dim); margin-bottom: 4px; }
        select { width: 100%; font-size: 16px; padding: 10px; border-radius: 10px; border: 1px solid var(--line); background: var(--card); color: var(--ink); }
        .buttons { display: flex; gap: 10px; margin: 16px 0 8px; }
        .button { flex: 1; text-align: center; padding: 13px; border-radius: 12px; background: var(--brand); color: #fff; font-weight: 600; text-decoration: none; }
        .button.ghost { background: transparent; color: var(--brand); border: 1px solid var(--brand); }
        @media (prefers-color-scheme: dark) { .button { color: #10211c; } }
        </style>
        </head><body>
        <header>가상 쇼핑몰 <span>화면 확인용</span></header>
        <main>
        \(body)
        </main>
        </body></html>
        """
    }
}
#endif
