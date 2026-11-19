import Foundation

// 쇼핑 "옆에서 봐 주기" (D74).
// 앱 안의 웹 화면에서 내가 직접 쇼핑하고, "확인해 줘"를 누를 때만 앱이 그 화면의 상품 정보를 읽어 맥에 보낸다.
// 여기에는 화면이 없는 규칙만 둔다: 어떤 주소를 여는지, 어떤 화면을 읽는지, 읽은 값을 어떻게 다듬어 보내는지.

/// 앱 안의 쇼핑 화면이 여는 곳. 주소는 앱이 만들고, 여기 적힌 호스트만 연다 (서버가 준 주소를 열지 않는다)
struct ShopSite: Equatable, Sendable {
    /// 화면에 보이는 이름
    let name: String
    /// 검색 결과(목록)를 읽는 호스트
    let listHosts: Set<String>
    /// 상품 화면을 읽는 호스트
    let productHosts: Set<String>
    /// 열기만 하고 읽지 않는 호스트 (로그인)
    let plainHosts: Set<String>
    /// 그 가운데 로그인 화면의 호스트. 맡긴 찾기를 하다 여기로 넘어가면 멈춘다 (로그인은 내가 직접 한다)
    let loginHosts: Set<String>
    /// 이 이름으로 끝나는 호스트도 열기만 한다 (검색에서 상품으로 넘어가는 주소 같은 것)
    let openSuffixes: [String]
    /// 검색 주소 (여기에 `query`를 붙인다)
    let searchBase: String

    /// 네이버 쇼핑: 쇼핑 검색, 스마트스토어, 브랜드스토어, 로그인.
    /// 주문서·결제(pay)와 그 밖의 주소는 여기 없다: 앱 안에서 열지 않는다
    static let naver = ShopSite(
        name: "네이버 쇼핑",
        listHosts: ["search.shopping.naver.com", "msearch.shopping.naver.com"],
        productHosts: ["smartstore.naver.com", "m.smartstore.naver.com", "brand.naver.com", "m.brand.naver.com"],
        plainHosts: ["nid.naver.com", "shopping.naver.com"],
        loginHosts: ["nid.naver.com"],
        openSuffixes: [".shopping.naver.com"],
        searchBase: "https://search.shopping.naver.com/search/all"
    )

    /// 앱 안에서 열어도 되는 주소인지: https이고, 아이디·비밀번호가 든 주소가 아니고, 정해 둔 호스트일 것
    func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user() == nil, url.password() == nil,
              let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        return listHosts.contains(host) || productHosts.contains(host) || plainHosts.contains(host)
            || openSuffixes.contains(where: host.hasSuffix)
    }

    /// 로그인 화면의 주소인지
    func isLogin(_ url: URL?) -> Bool {
        guard allows(url), let host = url?.host()?.lowercased() else { return false }
        return loginHosts.contains(host)
    }

    /// 이 주소가 읽을 수 있는 화면이면 그 종류와, 맥에 알릴 주소를 준다.
    /// 검색 결과와 상품 화면만 읽는다. 로그인·장바구니·주문·내 정보 같은 화면은 nil이다 (읽지도 보내지도 않는다)
    func page(for url: URL?) -> ShopPage? {
        guard allows(url), let url, let host = url.host()?.lowercased() else { return nil }
        let path = url.path(percentEncoded: true)
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        let kind: ShopView.Kind
        if listHosts.contains(host), parts.first == "search" {
            kind = .list
        } else if productHosts.contains(host), parts.count == 3, parts[1] == "products",
                  !parts[2].isEmpty, parts[2].allSatisfy({ $0.isASCII && $0.isNumber }) {
            kind = .product
        } else {
            return nil
        }
        // 맥에는 호스트와 경로만 알린다 (물음표 뒤는 뗀다: 거기에 내가 어디서 왔는지 같은 값이 붙는다)
        let address = "https://\(host)\(path)"
        guard address.count <= ShopView.addressLimit, !address.contains(where: \.isWhitespace) else { return nil }
        return ShopPage(kind: kind, address: address)
    }

    /// 검색어로 검색 주소를 만든다. 검색어가 비면 nil
    func searchURL(for query: String) -> URL? {
        guard let query = ShopText.clean(query, limit: ShopView.queryLimit),
              var parts = URLComponents(string: searchBase) else { return nil }
        parts.queryItems = [URLQueryItem(name: "query", value: query)]
        // "+"는 그대로 두면 빈칸으로 읽힌다
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url, allows(url) else { return nil }
        return url
    }

    /// 알림에 적을 호스트 (https 주소일 때만)
    static func host(of url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http",
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return String(host.prefix(80))
    }
}

/// 읽을 수 있는 화면 하나: 종류와, 맥에 알릴 주소(호스트와 경로)
struct ShopPage: Equatable, Sendable {
    let kind: ShopView.Kind
    let address: String
}

/// 화면에서 읽어 맥에 보내는 것 (`view`). 맥과 맞춘 꼴이다.
/// 상품의 공개 정보만 담는다 (내 이름·주소·회원 정보 같은 것은 넣지 않는다). 맥은 이것을 대화 기록에 두고 Claude가 본다
struct ShopView: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case product, list }

    struct Option: Codable, Equatable, Sendable {
        var name: String
        var values: [String]
    }

    struct Item: Codable, Equatable, Sendable {
        var title: String
        var price: Int?
        var mall: String?
        /// 이 기기에서 그 상품의 화면을 바로 열 수 있는지 (D77). 맥의 작업이 시킨 검색의 목록에만 적는다:
        /// 맥은 이것이 참인 줄에서만 "열어라"를 고른다. 내가 "확인해 줘"로 보내는 목록에는 없다
        var canOpen: Bool?

        private enum CodingKeys: String, CodingKey {
            case title, price, mall
            case canOpen = "can_open"
        }
    }

    struct Fields: Codable, Equatable, Sendable {
        var title: String?
        var price: Int?
        var originalPrice: Int?
        /// 회원가라고 확실히 읽었을 때만 true (아니면 없다)
        var memberPrice: Bool?
        var shipping: String?
        var seller: String?
        var arrival: String?
        var stock: String?
        var options: [Option]?
        var items: [Item]?

        enum CodingKeys: String, CodingKey {
            case title, price, shipping, seller, arrival, stock, options, items
            case originalPrice = "original_price"
            case memberPrice = "member_price"
        }
    }

    var kind: Kind
    var url: String
    var fields: Fields

    // 맥과 맞춘 한도
    static let queryLimit = 80
    static let addressLimit = 280
    static let titleLimit = 200
    static let shippingLimit = 80
    static let sellerLimit = 60
    static let arrivalLimit = 80
    static let stockLimit = 60
    static let optionLimit = 8
    static let optionNameLimit = 40
    static let optionValueLimit = 20
    static let optionValueTextLimit = 60
    static let itemLimit = 8
    static let itemTitleLimit = 120
    /// 상품 하나에서 살펴보는 링크의 수와 주소의 길이 (이 기기 안에서만 쓴다)
    static let linkLimit = 6
    static let linkLengthLimit = 2000
    static let mallLimit = 40
    /// 맥은 20000자를 넘는 `view`를 버린다 (한글 한 글자를 여섯 자로 센다). 여유를 두고 맞춘다
    static let sizeLimit = 18000
    /// 화면에서 읽어 온 글의 한도 (이보다 크면 읽지 않은 것으로 한다)
    static let rawLimit = 400_000

    /// 화면에서 읽어 온 것(읽는 스크립트가 준 JSON)을 맥과 맞춘 꼴로 다듬는다.
    /// 읽은 값만 넣는다: 가격은 양의 정수일 때만, 원래 가격은 지금 가격보다 클 때만, 회원가는 참이라고 읽었을 때만.
    /// 쓸 만한 것이 없으면 nil (그때는 보내지 않는다)
    static func read(page: ShopPage, json: String?) -> ShopView? {
        parse(page: page, json: json)?.view
    }

    /// 링크를 찾지 못한 까닭으로 받는 낱말 (읽는 스크립트가 적는다. 그 밖의 글은 버린다)
    static let linkGaps: Set<String> = ["no_anchor", "no_href"]

    /// 위와 같되, 목록이면 상품마다 그 상품으로 가는 링크의 주소도 함께 준다 (`links[i]`가 `fields.items[i]`의 것이다).
    /// 주소는 이 기기에서 상품 화면을 열 때만 쓴다. 맥으로 보내는 것(`view`)에는 들어가지 않는다 (D75).
    /// `gaps[i]`: 그 상품의 링크를 하나도 찾지 못했을 때 그 까닭 (D77. `linkGaps`의 낱말)
    static func parse(page: ShopPage, json: String?) -> (view: ShopView, links: [[URL]], gaps: [String?])? {
        guard let json, json.utf8.count <= rawLimit,
              let raw = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        var fields = Fields()
        var links: [[URL]] = []
        var gaps: [String?] = []
        switch page.kind {
        case .product:
            fields.title = ShopText.clean(raw["title"], limit: titleLimit)
            fields.price = ShopText.price(raw["price"])
            if let price = fields.price, let original = ShopText.price(raw["original_price"]), original > price {
                fields.originalPrice = original
            }
            if ShopText.isTrue(raw["member_price"]), fields.price != nil { fields.memberPrice = true }
            fields.shipping = ShopText.publicLine(raw["shipping"], limit: shippingLimit)
            fields.seller = ShopText.publicLine(raw["seller"], limit: sellerLimit)
            fields.arrival = ShopText.publicLine(raw["arrival"], limit: arrivalLimit)
            fields.stock = ShopText.publicLine(raw["stock"], limit: stockLimit)
            let options = (raw["options"] as? [Any] ?? []).compactMap { entry -> Option? in
                guard let entry = entry as? [String: Any],
                      let name = ShopText.clean(entry["name"], limit: optionNameLimit) else { return nil }
                var seen = Set<String>()
                let values = (entry["values"] as? [Any] ?? [])
                    .compactMap { ShopText.publicLine($0, limit: optionValueTextLimit) }
                    .filter { seen.insert($0).inserted }
                    .prefix(optionValueLimit)
                return values.isEmpty ? nil : Option(name: name, values: Array(values))
            }
            if !options.isEmpty { fields.options = Array(options.prefix(optionLimit)) }
            guard fields.title != nil || fields.price != nil else { return nil }
        case .list:
            var seen = Set<String>()
            var items: [Item] = []
            for entry in raw["items"] as? [Any] ?? [] where items.count < itemLimit {
                guard let entry = entry as? [String: Any],
                      let title = ShopText.clean(entry["title"], limit: itemTitleLimit), seen.insert(title).inserted else { continue }
                items.append(Item(title: title, price: ShopText.price(entry["price"]), mall: ShopText.publicLine(entry["mall"], limit: mallLimit)))
                links.append(
                    (entry["links"] as? [Any] ?? []).prefix(linkLimit)
                        .compactMap { ($0 as? String).flatMap { $0.count <= linkLengthLimit ? URL(string: $0) : nil } }
                        .filter { $0.scheme?.lowercased() == "https" }
                )
                gaps.append((entry["why"] as? String).flatMap { linkGaps.contains($0) ? $0 : nil })
            }
            guard !items.isEmpty else { return nil }
            fields.items = items
        }
        let view = ShopView(kind: page.kind, url: page.address, fields: fields).fitted()
        // 크기를 맞추느라 뒤의 상품을 뺐으면 링크도 그만큼만 남긴다 (차례가 어긋나지 않게)
        let count = view.fields.items?.count ?? 0
        return (view, Array(links.prefix(count)), Array(gaps.prefix(count)))
    }

    /// 맥이 받는 크기 안에 들게 줄인다: 옵션의 값을 뒤에서부터, 그래도 크면 옵션을, 목록이면 뒤의 상품을 뺀다
    func fitted(limit: Int = ShopView.sizeLimit) -> ShopView {
        var view = self
        while view.macSize > limit {
            if var options = view.fields.options, !options.isEmpty {
                // 값이 가장 많은 옵션에서 하나씩 뺀다
                let index = options.indices.max { options[$0].values.count < options[$1].values.count } ?? 0
                if options[index].values.count > 1 {
                    options[index].values.removeLast()
                } else {
                    options.remove(at: index)
                }
                view.fields.options = options.isEmpty ? nil : options
            } else if var items = view.fields.items, items.count > 1 {
                items.removeLast()
                view.fields.items = items
            } else {
                break
            }
        }
        return view
    }

    /// 맥이 세는 크기: 맥은 이 값을 빈칸을 넣고(", "와 ": ") ASCII가 아닌 글자를 `\uXXXX`로 풀어 쓴 길이로 센다
    var macSize: Int {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else { return .max }
        return Self.macLength(object)
    }

    static func macLength(_ value: Any) -> Int {
        switch value {
        case let text as String:
            return 2 + text.unicodeScalars.reduce(0) { sum, scalar in
                switch scalar.value {
                case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: sum + 2
                case 0x20...0x7E: sum + 1
                case 0x10000...: sum + 12
                default: sum + 6
                }
            }
        case let number as NSNumber:
            return ShopText.isTrue(number) ? 4 : (CFGetTypeID(number) == CFBooleanGetTypeID() ? 5 : number.stringValue.count)
        case let list as [Any]:
            return 2 + list.reduce(0) { $0 + macLength($1) } + max(0, list.count - 1) * 2
        case let pairs as [String: Any]:
            return 2 + pairs.reduce(0) { $0 + macLength($1.key) + 2 + macLength($1.value) } + max(0, pairs.count - 1) * 2
        default:
            return 4
        }
    }

    // MARK: - 화면에 보여 주는 글

    struct Line: Equatable, Identifiable, Sendable {
        let label: String
        let value: String
        var id: String { label + value }
    }

    /// "화면에서 읽은 것"으로 보여 줄 줄들. 맥에 보낸 값과 같은 것을 같은 차례로 보여 준다
    var lines: [Line] {
        switch kind {
        case .product:
            var lines: [Line] = []
            if let title = fields.title { lines.append(Line(label: "상품", value: title)) }
            if let price = fields.price {
                var text = ShopText.won(price)
                if fields.memberPrice == true { text += " (회원가)" }
                if let original = fields.originalPrice { text += " · 원래 \(ShopText.won(original))" }
                lines.append(Line(label: "가격", value: text))
            }
            if let shipping = fields.shipping { lines.append(Line(label: "배송", value: shipping)) }
            if let arrival = fields.arrival { lines.append(Line(label: "도착", value: arrival)) }
            if let seller = fields.seller { lines.append(Line(label: "판매", value: seller)) }
            if let stock = fields.stock { lines.append(Line(label: "재고", value: stock)) }
            for option in fields.options ?? [] {
                lines.append(Line(label: option.name, value: option.values.joined(separator: ", ")))
            }
            return lines
        case .list:
            return (fields.items ?? []).enumerated().map { index, item in
                let tail = [item.price.map(ShopText.won), item.mall].compactMap { $0 }.joined(separator: " · ")
                return Line(label: "\(index + 1)", value: tail.isEmpty ? item.title : "\(item.title) — \(tail)")
            }
        }
    }

    /// 읽지 못한 것 (상품 화면에서만). 보여 줄 때 "읽지 못했어요"라고 알린다
    var missing: [String] {
        guard kind == .product else { return [] }
        var names: [String] = []
        if fields.title == nil { names.append("상품 이름") }
        if fields.price == nil { names.append("가격") }
        if fields.shipping == nil { names.append("배송비") }
        return names
    }

    /// 호스트 (보여 줄 때)
    var host: String { URL(string: url)?.host() ?? "" }
}

/// 화면에서 읽은 글을 다듬는 규칙
enum ShopText {
    /// 줄바꿈·연속된 빈칸을 빈칸 하나로, 앞뒤 빈칸을 떼고, 한도에서 자른다. 글이 아니거나 비면 nil
    static func clean(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String else { return nil }
        let words = text.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(limit)).trimmingCharacters(in: .whitespaces)
    }

    /// 상품의 공개 정보로 보이는 줄만 받는다: 사람을 가리키는 말("○○님")이나 배송지·주소가 든 줄은 버린다.
    /// (로그인한 화면은 배송 안내에 내 이름이나 배송지를 섞어 쓸 수 있다. 그런 줄은 맥으로 보내지 않는다)
    static func publicLine(_ value: Any?, limit: Int) -> String? {
        guard let line = clean(value, limit: limit), !looksPersonal(line) else { return nil }
        return line
    }

    static func looksPersonal(_ line: String) -> Bool {
        if line.contains("배송지") || line.contains("주소") || line.contains("@") { return true }
        // "○○님", "회원님": 글자 뒤에 붙은 "님"으로 끝나는 낱말
        for word in line.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "(" || $0 == ")" }) {
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            for ending in ["님", "님의", "님은", "님이", "님께", "님을", "님께서"] where bare.hasSuffix(ending) && bare.count > ending.count {
                return true
            }
        }
        return false
    }

    /// 가격: 0보다 크고 100억보다 작은 정수만. 참·거짓이나 소수, "12,900원~" 같은 글은 가격이 아니다
    static func price(_ value: Any?) -> Int? {
        var number: Int?
        if let raw = value as? NSNumber {
            guard CFGetTypeID(raw) != CFBooleanGetTypeID(), raw.doubleValue.isFinite, raw.doubleValue.rounded() == raw.doubleValue,
                  abs(raw.doubleValue) < 1e12 else { return nil }
            number = Int(raw.doubleValue)
        } else if let text = value as? String {
            var digits = text.trimmingCharacters(in: .whitespaces)
            if digits.hasSuffix("원") { digits.removeLast() }
            let groups = digits.split(separator: ",", omittingEmptySubsequences: false)
            let plain = groups.count == 1
            let grouped = groups.count > 1 && (1...3).contains(groups[0].count) && groups.dropFirst().allSatisfy { $0.count == 3 }
            guard plain || grouped, groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
            number = Int(groups.joined())
        }
        guard let number, number > 0, number < 10_000_000_000 else { return nil }
        return number
    }

    /// JSON의 참(true)일 때만 true (숫자 1이나 글 "true"는 아니다)
    static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// "12,900원"
    static func won(_ price: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ko_KR")
        return (formatter.string(from: NSNumber(value: price)) ?? String(price)) + "원"
    }
}
