import Foundation

// 쇼핑 "스스로 찾아 오기" (D75).
// 내가 살 것을 말하면 맥의 작업이 이 아이폰의 쇼핑 화면에 일을 시킨다: "이 검색어로 검색해라", "목록의 이 상품들을 열어 읽어라".
// 앱은 내가 보는 앞에서 그 화면을 옮기고, 읽은 것을 맥에 돌려준다. 여기에는 맥과 주고받는 꼴만 둔다.
//
// 지키는 것:
// - 맥은 주소를 주지 않는다. 검색 주소는 앱이 만들고, 상품은 앱이 방금 읽은 목록의 "몇 번째"로만 가리킨다
// - 앱은 주소를 열기만 한다. 단추(옵션·담기·구매·동의)는 누르지 않는다
// - 한 번에 여는 상품과 한 작업에서 여는 화면의 수에 한도가 있다. 사이트가 막으면 그 자리에서 멈춘다

/// 맥이 폰의 쇼핑 화면에 시키는 일 하나 (작업 상태의 `browser`)
struct AgentBrowse: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// 검색어로 검색 결과를 열고 목록을 읽는다
        case search
        /// 방금 읽은 목록에서 몇 개를 열어 상품 화면을 읽는다
        case open
    }

    /// 이 일의 번호 (결과를 돌려줄 때 그대로 적는다)
    var id: String
    var kind: Kind
    /// 검색어 (`search`)
    var query: String?
    /// 열 상품: 앱이 마지막으로 읽어 보낸 목록에서의 차례, 0부터 (`open`)
    var items: [Int]?

    /// 한 번에 여는 상품 수
    static let openLimit = 3
    /// 한 작업에서 여는 상품 화면 수
    static let taskOpenLimit = 6
    /// 한 작업에서 하는 검색 수
    static let taskSearchLimit = 2
    static let idLimit = 64

    /// 받은 값을 확인해서 만든다. 모르는 종류이거나 값이 맞지 않으면 nil (그 일은 하지 않는다)
    static func make(id: String?, type: String?, query: String?, items: [Int]?) -> AgentBrowse? {
        guard let id, !id.isEmpty, id.count <= idLimit,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let kind = type.flatMap(Kind.init(rawValue:)) else { return nil }
        switch kind {
        case .search:
            guard let query = ShopText.clean(query, limit: ShopView.queryLimit) else { return nil }
            return AgentBrowse(id: id, kind: .search, query: query, items: nil)
        case .open:
            var seen = Set<Int>()
            let wanted = (items ?? []).filter { $0 >= 0 && $0 < ShopView.itemLimit && seen.insert($0).inserted }
            guard !wanted.isEmpty, wanted.count == (items ?? []).count else { return nil }
            return AgentBrowse(id: id, kind: .open, query: nil, items: wanted)
        }
    }
}

/// 시킨 일의 결과 (`POST /v1/tasks/{id}/browser`의 본문)
struct BrowseResult: Encodable, Equatable, Sendable {
    enum Outcome: String, Sendable {
        /// 했다 (읽은 것이 `views`에 있다)
        case ok
        /// 화면은 열렸지만 읽을 만한 것이 없었다
        case nothing
        /// 사이트가 접속을 제한했다 (`status`). 앱은 멈췄고 다시 시도하지 않았다
        case limited
        /// 검색 결과나 상품 화면이 아닌 다른 화면으로 넘어갔다 (로그인·확인 화면 같은 것). 앱은 멈췄다.
        /// `reason`: 로그인 화면이면 `login`, 상품을 열다 그 밖의 곳으로 넘어갔으면 `moved` (D79)
        case blocked
        /// 화면을 열지 못했다. 검색이면 `reason`에 까닭을 적는다 (D77, `BrowseResult.Failure`), 응답 번호 때문이면 `status`도
        case failed
        /// 하지 않았다 (`reason`: 한도를 넘음 `cap`, 읽어 둔 목록이 없음 `no_list`)
        case refused
    }

    /// 읽은 화면 하나. `item`은 목록에서의 차례 (상품 화면일 때)
    struct Entry: Encodable, Equatable, Sendable {
        var item: Int?
        var view: ShopView

        private enum Keys: String, CodingKey { case item, kind, url, fields }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encodeIfPresent(item, forKey: .item)
            try container.encode(view.kind, forKey: .kind)
            try container.encode(view.url, forKey: .url)
            try container.encode(view.fields, forKey: .fields)
        }
    }

    /// 열지 않았거나 읽지 못한 상품 하나
    struct Skip: Encodable, Equatable, Sendable {
        enum Reason: String, Encodable, Sendable {
            /// 목록의 링크가 앱이 여는 호스트이기는 한데 상품 화면으로 바로 가는 주소가 아니다 (거쳐 가는 주소는 앱이 열지 않는다)
            case outside
            /// 목록에 그 차례의 상품이 없거나, 어느 링크가 그 상품의 것인지 가리지 못했다
            case noLink = "no_link"
            /// 그 상품의 이름 둘레에 링크가 없다 (D77)
            case noAnchor = "no_anchor"
            /// 링크는 있는데 https 주소가 없다 (D77)
            case noHref = "no_href"
            /// 링크가 모두 앱이 열지 않는 호스트로 간다: 다른 쇼핑몰이거나 광고 주소다 (D77)
            case otherMall = "other_mall"
            /// 열었더니 상품 화면이 아니었다
            case notProduct = "not_product"
            /// 상품 화면은 열렸지만 읽지 못했다
            case unread
            /// 열지 못했다 (연결, 시간 초과)
            case failed
            /// 한도를 넘어 열지 않았다
            case limit
        }

        var item: Int
        var reason: Reason
    }

    /// 화면을 열지 못한 까닭 (`failed`의 `reason`, D77). 낱말만 보낸다: 오류 문장이나 주소는 보내지 않는다
    enum Failure: String, Sendable {
        /// 연결이 끊겼다
        case netLost = "net_lost"
        /// 연결이 시간 안에 되지 않았다
        case netTimeout = "net_timeout"
        /// 인터넷에 연결되어 있지 않다
        case netOffline = "net_offline"
        /// 그 밖의 이유로 받지 못했다
        case loadError = "load_error"
        /// 웹 화면을 그리는 프로세스가 죽었다
        case webCrashed = "web_crashed"
        /// 사이트가 400 이상의 번호로 답했다 (접속 제한 번호는 `limited`로 따로 간다). 번호는 `status`에
        case httpStatus = "http_status"
        /// 앱이 기다리는 한도(20초)를 넘었다
        case timeout
    }

    var id: String
    var outcome: Outcome
    /// 사이트가 보낸 응답 번호 (`limited`일 때, `failed`의 까닭이 `http_status`일 때)
    var status: Int?
    var reason: String?
    var views: [Entry] = []
    var skipped: [Skip] = []

    private enum Keys: String, CodingKey { case id, result, status, reason, views, skipped }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(outcome.rawValue, forKey: .result)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(views, forKey: .views)
        try container.encode(skipped, forKey: .skipped)
    }
}
