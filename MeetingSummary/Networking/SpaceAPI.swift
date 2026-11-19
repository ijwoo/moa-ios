import Foundation

// 내 공간 (D94. 맥의 D87, `space`): 말한 대로 카드를 모아 한 화면을 만든다.
// 화면은 데이터다 — 맥은 "어떤 카드를 어떤 크기로 어느 차례에"만 주고, 그리는 것은 앱이 미리 만들어 둔 카드·블록이다.
// 구성도 카드의 내용도 이 기기에 저장하지 않는다 (화면이 떠 있는 동안 메모리에만 있다).

/// 카드 안의 한 덩어리 (맥이 채운 카드의 내용). 모르는 종류는 읽을 때 버린다
enum SpaceBlock: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var title: String
        var subtitle: String?
        var trailing: String?
        /// 지난번에 없던 줄 (D103. 맥이 견줘 알려 준다)
        var isNew = false
    }

    case text(String)
    /// 큰 값 하나
    case stat(label: String?, value: String, note: String?)
    case list([Item])
    /// 0…1
    case progress(label: String?, ratio: Double)
    /// 이름·값 짝 2~4개를 나란히 (D108. "살 때 / 팔 때", "최고 / 최저")
    case pairs([Pair])
    /// 다가오는 날 하나 (D108). 오늘부터 며칠 남았는지는 앱이 센다
    case date(label: String, day: DateComponents, note: String?)

    struct Pair: Codable, Equatable, Sendable {
        var label: String
        var value: String
    }

    /// 카드 하나에 그리는 덩어리 수
    static let limit = 4
    /// 목록 하나의 줄 수
    static let itemLimit = 6
}

/// 내 공간의 카드 하나
struct SpaceCard: Identifiable, Equatable, Sendable {
    /// 앱이 그릴 줄 아는 종류. 모르는 종류의 카드는 읽을 때 건너뛴다 (종류는 늘어난다)
    enum Kind: String, CaseIterable, Sendable {
        case calendarToday = "calendar_today"
        case weather
        case meetingTodos = "meeting_todos"
        case mailToday = "mail_today"
        case routineResult = "routine_result"
        case custom

        /// 앱이 자기 데이터로 채우는 카드인지 (맥은 그 내용을 모른다)
        var filledByApp: Bool {
            switch self {
            case .calendarToday, .weather, .meetingTodos: true
            case .mailToday, .routineResult, .custom: false
            }
        }

        /// 앱이 채울 수 있는 카드의 종류 (말로 고칠 때 맥에 알린다, D95). 오늘 일정은 캘린더를 읽게 된 뒤부터 든다
        static let appCards = allCases.filter(\.filledByApp).map(\.rawValue)

        /// 카드 머리의 아이콘 (SF Symbols)
        var symbol: String {
            switch self {
            case .calendarToday: "calendar"
            case .weather: "sun.max"
            case .meetingTodos: "checkmark.square"
            case .mailToday: "envelope"
            case .routineResult: "clock.arrow.circlepath"
            case .custom: "sparkles"
            }
        }
    }

    enum Size: String, Sendable {
        /// 반 칸: small 둘이 이어지면 한 줄에 나란히 놓인다
        case small
        case medium
        /// 한 줄, 내용을 더 많이 보인다
        case large

        /// 화면에 쓰는 이름
        var label: String {
            switch self {
            case .small: "작게"
            case .medium: "보통"
            case .large: "크게"
            }
        }
    }

    /// 맥이 채우는 카드의 상태
    enum State: String, Sendable {
        case ok
        /// 15분이 지난 내용: 보여 주되 새로 받는다
        case stale
        /// 아직 채운 적 없음: 새로 받는다
        case empty
        /// 채울 수 없다: `why`를 카드에 보인다 (값을 지어내 채우지 않는다)
        case unavailable
    }

    /// 오늘 온 메일 카드의 한 줄
    struct Mail: Equatable, Sendable {
        var time: String?
        var from: String?
        var subject: String
        var service: String?
    }

    /// 카드의 단추 (맥이 준다): 단추의 글과, 누르면 대화로 보내는 말
    struct Action: Equatable, Sendable {
        var label: String
        var say: String

        static let labelLimit = 16
    }

    /// 카드에서 바로 하는 일 (D103. 맥의 코드가 정한 것만 온다, 2개까지)
    struct Quick: Equatable, Sendable, Identifiable {
        enum Kind: Equatable, Sendable {
            /// 누르면 이 말을 대화로 보낸다 ("자세히 묻기")
            case say(String)
            /// 누르면 이 예약을 지금 한 번 돌린다 ("지금 가져오기")
            case run(String)
        }

        var label: String
        var kind: Kind
        var id: String { label }

        static let limit = 2
    }

    /// 오늘 온 메일에서 챙겨야 할 메일 하나 (D96. 맥이 고른 것)
    struct Pick: Equatable, Sendable {
        var title: String
        /// 무엇을 해야 하는지 한 줄
        var note: String?
        var service: String?
        /// 이 메일을 눌렀을 때 대화로 보낼 말 (D103)
        var say: String?
    }

    let id: String
    var kind: Kind
    var size: Size
    var title: String
    /// 맥이 채우는 카드에만 있다
    var state: State?
    /// 채울 수 없는 까닭 ("로그인이 필요해요")
    var why: String?
    /// 맥이 이 내용을 채운 때
    var dataAt: Date?
    /// 채울 수 없는 카드에서 대신 할 수 있는 일 하나 (D99). 단추를 누르면 `say`를 대화로 보낸다
    var action: Action?
    /// 카드에서 바로 하는 일 (D103)
    var quicks: [Quick] = []
    /// 내용이 마지막으로 바뀐 때 (처음 채운 것은 바뀐 것이 아니라 없다)
    var changedAt: Date?
    /// 지난번에 없던 줄의 수
    var newCount = 0
    /// 큰 값의 지난번과의 차이 ("+4.5"·"−2.5"). 오른 것이면 `deltaUp`이 참
    var delta: String?
    var deltaUp = false
    /// 값이 쌓인 흐름 (오래된 것부터, 14개까지). 작은 추세선으로 그린다
    var trend: [Double] = []
    var blocks: [SpaceBlock] = []
    /// 오늘 온 메일: 몇 통인지, 어느 메일인지, 목록 (맥의 코드가 만든 것)
    var mailCount: Int?
    var mailServices: [String] = []
    var mails: [Mail] = []
    /// 오늘 온 메일의 맨 위 한 줄 ("챙길 메일 1통". D96). 이것이 있으면 챙길 메일과 나머지 한 줄로 그린다
    var mailHeadline: String?
    /// 챙겨야 할 메일만 (3개까지)
    var mailPicks: [Pick] = []
    /// 나머지를 묶은 한 줄
    var mailRest: String?

    /// 카드 하나에 보이는 챙길 메일의 수
    static let pickLimit = 3
    /// 추세선에 쓰는 값의 수
    static let trendLimit = 14

    /// 새로 받아야 하는 카드인지 (아직 비었거나 오래됐다)
    var needsRefresh: Bool { !kind.filledByApp && (state == .empty || state == .stale) }

    /// 카드 하나에 보이는 줄 수 (큰 카드는 더 많이)
    var lineLimit: Int {
        switch size {
        case .small: 2
        case .medium: 3
        case .large: 6
        }
    }

    /// 오늘 온 메일 카드의 머리 오른쪽 글: "네이버·지메일 · 5통"
    var mailSummary: String? {
        guard kind == .mailToday, let mailCount else { return nil }
        let count = "\(mailCount)통"
        return mailServices.isEmpty ? count : "\(mailServices.joined(separator: "·")) · \(count)"
    }

    /// 맥이 받는 번호의 꼴 (`c_…`). 요청 본문에 그대로 싣는다
    static func isID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// 내 공간의 구성
struct AgentSpace: Equatable, Sendable {
    /// 맥이 권하는 카드 하나 (D108): 누르면 `say`를 말로 고치기에 보낸다
    struct Suggestion: Equatable, Sendable, Identifiable {
        var label: String
        var say: String
        var id: String { label }

        static let limit = 6
    }

    var cards: [SpaceCard] = []
    /// 한 번 되돌릴 것이 있는지
    var canUndo = false
    /// 지금 구성에 없고 바로 만들 수 있는 카드 (맥의 코드가 고른 것, 6개까지)
    var suggestions: [Suggestion] = []

    static let empty = AgentSpace()

    /// 화면의 줄: small 둘이 이어지면 한 줄에 나란히, 나머지는 한 줄에 하나.
    /// 짝이 없는 small도 반 칸만 쓴다 (D106. 전에는 한 줄을 다 썼다 — 줄여도 줄어 보이지 않았다)
    var rows: [[SpaceCard]] {
        var rows: [[SpaceCard]] = []
        var index = 0
        while index < cards.count {
            let card = cards[index]
            if card.size == .small, index + 1 < cards.count, cards[index + 1].size == .small {
                rows.append([card, cards[index + 1]])
                index += 2
            } else {
                rows.append([card])
                index += 1
            }
        }
        return rows
    }
}

/// 맥이 쓴 문장의 "을(를)" 같은 두 갈래 조사를 앞말의 받침에 맞춰 하나로 고친다 (D98. "'날씨'을(를)" → "'날씨'를")
enum Josa {
    /// (받침이 있을 때, 없을 때)
    private static let pairs: [(String, String, String)] = [
        ("을(를)", "을", "를"), ("를(을)", "을", "를"), ("이(가)", "이", "가"), ("가(이)", "이", "가"),
        ("은(는)", "은", "는"), ("는(은)", "은", "는"), ("과(와)", "과", "와"), ("와(과)", "과", "와"),
        ("(으)로", "으로", "로"), ("(이)라", "이라", "라"),
    ]

    static func fix(_ text: String) -> String {
        var result = text
        for (both, closed, open) in pairs {
            while let range = result.range(of: both) {
                // 앞말: 따옴표·괄호·빈칸을 건너뛴 마지막 글자
                let before = result[..<range.lowerBound].last { !"'\"’”」』)] ".contains($0) }
                var particle = hasFinal(before) ? closed : open
                // "로"는 ㄹ 받침 뒤에서도 "로"다 ("서울로")
                if both == "(으)로", finalIndex(before) == 8 { particle = open }
                result.replaceSubrange(range, with: particle)
            }
        }
        return result
    }

    /// 한글 글자의 받침 번호 (없으면 0. 한글이 아니면 nil)
    private static func finalIndex(_ character: Character?) -> Int? {
        guard let scalar = character?.unicodeScalars.first, character?.unicodeScalars.count == 1,
              (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
        return Int((scalar.value - 0xAC00) % 28)
    }

    /// 받침이 있는지. 숫자는 읽는 소리로 본다 (0·1·3·6·7·8은 받침이 있다). 그 밖의 글자는 받침이 없는 것으로 본다
    private static func hasFinal(_ character: Character?) -> Bool {
        if let index = finalIndex(character) { return index != 0 }
        if let character, let digit = character.wholeNumberValue { return [0, 1, 3, 6, 7, 8].contains(digit) }
        return false
    }
}

/// 내 공간에 쓰는 때의 글
enum SpaceTime {
    /// "오전 10:13"
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "ko_KR"), calendar: calendar, timeZone: calendar.timeZone))
    }

    /// "방금" · "40분 전" · "3시간 전" · "어제부터"
    static func ago(_ date: Date, now: Date = .now) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "방금" }
        if minutes < 60 { return "\(minutes)분 전" }
        if minutes < 60 * 24 { return "\(minutes / 60)시간 전" }
        return "\(minutes / (60 * 24))일 전"
    }

    /// 다음 일정까지: "5분 뒤" · "2시간 뒤" · "지금" (이미 시작했다)
    static func until(_ date: Date, now: Date = .now) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "지금" }
        if minutes < 60 { return "\(minutes)분 뒤" }
        return "\(minutes / 60)시간 뒤"
    }

    /// 큰 값을 숫자와 단위로 가른다 ("1,336.0원" → "1,336.0" · "원"). 단위는 작게 쓴다. 숫자로 시작하지 않으면 가르지 않는다
    static func split(_ value: String) -> (number: String, unit: String) {
        guard let first = value.first, first.isNumber || first == "-" || first == "+",
              let last = value.lastIndex(where: \.isNumber) else { return (value, "") }
        let unit = value[value.index(after: last)...].trimmingCharacters(in: .whitespaces)
        // 단위가 길면 값의 일부다 ("3일 뒤 도착" 같은 글): 가르지 않는다
        guard unit.count <= 3 else { return (value, "") }
        return (String(value[...last]), unit)
    }
}

/// 손으로 정한 카드 하나의 자리 (차례는 목록의 차례, 크기는 `small`·`medium`·`large`)
struct SpaceArrangement: Encodable, Equatable, Sendable {
    let id: String
    let size: String

    init(_ card: SpaceCard) {
        id = card.id
        size = card.size.rawValue
    }
}

/// 말로 고친 결과
struct SpaceEdit: Equatable, Sendable {
    var space: AgentSpace
    /// 맥의 코드가 앞뒤 구성을 견줘 쓴 문장 (체크 표시로 보인다). 바뀐 것이 없으면 비어 있다
    var changes: [String] = []
    /// 모델이 덧붙인 한 문장 (못 한 까닭 등). 없을 수 있다
    var say: String?
    /// 맥이 되묻는 중인지 (D105. "주식 보여줘" → "어느 종목 주가를 보여 드릴까요?"). 구성은 그대로이고 `say`가 묻는 말이다.
    /// 사용자의 다음 말을 맥이 그 답으로 읽는다
    var asking = false
}

/// 맥이 준 내 공간을 읽는다. 꼴이 어긋난 카드·덩어리는 그것만 버린다
enum SpaceDecoding {
    typealias Lossy = RoutineDecoding.Lossy

    /// 글자든 숫자든 글로 읽는다 (맥이 값을 숫자로 줄 때가 있다)
    struct Loose: Decodable {
        let text: String?
        init(from decoder: Decoder) throws {
            let box = try decoder.singleValueContainer()
            if let string = try? box.decode(String.self) {
                text = string
            } else if let int = try? box.decode(Int.self) {
                text = String(int)
            } else if let double = try? box.decode(Double.self) {
                text = String(double)
            } else {
                text = nil
            }
        }
    }

    struct BlockDTO: Decodable {
        struct Item: Decodable {
            let title: Loose?
            let subtitle: Loose?
            let trailing: Loose?
            let new: Bool?
        }
        struct PairDTO: Decodable {
            let label: Loose?
            let value: Loose?
        }
        let kind: String?
        let points: [Lossy<Double>]?
        let date: String?
        let text: String?
        let label: String?
        let value: Loose?
        let note: String?
        let items: [Lossy<Item>]?
        /// 같은 `items`를 이름·값 짝으로 읽은 것 (`kind: "pairs"`)
        let pairItems: [Lossy<PairDTO>]?
        let ratio: Double?

        private enum CodingKeys: String, CodingKey { case kind, points, date, text, label, value, note, items, ratio }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? box.decodeIfPresent(String.self, forKey: .kind)
            points = try? box.decodeIfPresent([Lossy<Double>].self, forKey: .points)
            date = try? box.decodeIfPresent(String.self, forKey: .date)
            text = try? box.decodeIfPresent(String.self, forKey: .text)
            label = try? box.decodeIfPresent(String.self, forKey: .label)
            value = try? box.decodeIfPresent(Loose.self, forKey: .value)
            note = try? box.decodeIfPresent(String.self, forKey: .note)
            items = try? box.decodeIfPresent([Lossy<Item>].self, forKey: .items)
            pairItems = try? box.decodeIfPresent([Lossy<PairDTO>].self, forKey: .items)
            ratio = try? box.decodeIfPresent(Double.self, forKey: .ratio)
        }

        var block: SpaceBlock? {
            switch kind {
            case "text":
                return clean(text).map(SpaceBlock.text)
            case "stat":
                guard let value = clean(value?.text) else { return nil }
                return .stat(label: clean(label), value: value, note: clean(note))
            case "list":
                let items = (items ?? []).compactMap(\.value).compactMap { item -> SpaceBlock.Item? in
                    guard let title = clean(item.title?.text) else { return nil }
                    return SpaceBlock.Item(
                        title: title, subtitle: clean(item.subtitle?.text), trailing: clean(item.trailing?.text), isNew: item.new ?? false
                    )
                }
                return items.isEmpty ? nil : .list(Array(items.prefix(SpaceBlock.itemLimit)))
            case "progress":
                guard let ratio, ratio.isFinite else { return nil }
                return .progress(label: clean(label), ratio: min(1, max(0, ratio)))
            case "pairs":
                return pairsBlock
            case "date":
                guard let label = clean(label), let day = Self.day(date) else { return nil }
                return .date(label: String(label.prefix(20)), day: day, note: clean(note))
            default:
                return nil
            }
        }

        /// "2026-12-25" → 그날 (연·월·일만). 꼴이 어긋나면 nil
        static func day(_ text: String?) -> DateComponents? {
            guard let parts = text?.split(separator: "-").compactMap({ Int($0) }), parts.count == 3,
                  (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
            return DateComponents(year: parts[0], month: parts[1], day: parts[2])
        }

        /// 짝은 둘에서 넷까지, 이름과 값이 둘 다 있는 것만 (16자까지). 하나뿐이면 그리지 않는다
        private var pairsBlock: SpaceBlock? {
            let pairs = (pairItems ?? []).compactMap(\.value).compactMap { item -> SpaceBlock.Pair? in
                guard let label = clean(item.label?.text), let value = clean(item.value?.text) else { return nil }
                return SpaceBlock.Pair(label: String(label.prefix(16)), value: String(value.prefix(16)))
            }.prefix(4)
            return pairs.count >= 2 ? .pairs(Array(pairs)) : nil
        }

        /// 추세선의 값 (`kind: "trend"`). 둘은 있어야 선이 된다. 다른 덩어리와 따로 센다 (덩어리 수에 들지 않는다)
        var trend: [Double]? {
            guard kind == "trend" else { return nil }
            let points = (points ?? []).compactMap(\.value).filter(\.isFinite).suffix(SpaceCard.trendLimit)
            return points.count >= 2 ? Array(points) : nil
        }
    }

    struct CardDTO: Decodable {
        struct Mail: Decodable {
            let time: String?
            let from: String?
            let subject: String?
            let service: String?
        }
        struct ActionDTO: Decodable {
            let label: String?
            let say: String?
            let run: String?
        }
        struct Pick: Decodable {
            let title: String?
            let note: String?
            let service: String?
            let say: String?
        }
        struct Delta: Decodable {
            let diff: Double?
            let text: String?
        }
        struct Payload: Decodable {
            let new_count: Int?
            let delta: Lossy<Delta>?
            let headline: String?
            let picks: [Lossy<Pick>]?
            let rest: String?
            let blocks: [Lossy<BlockDTO>]?
            let count: Int?
            let services: [Lossy<String>]?
            let items: [Lossy<Mail>]?
        }
        let id: String
        let type: String?
        let size: String?
        let title: String?
        let state: String?
        let why: String?
        let data_at: String?
        let action: Lossy<ActionDTO>?
        let actions: [Lossy<ActionDTO>]?
        let changed_at: String?
        let data: Lossy<Payload>?

        var card: SpaceCard? {
            guard SpaceCard.isID(id), let kind = type.flatMap(SpaceCard.Kind.init(rawValue:)) else { return nil }
            let payload = data?.value
            var card = SpaceCard(
                id: id, kind: kind, size: size.flatMap(SpaceCard.Size.init(rawValue:)) ?? .medium, title: clean(title) ?? Self.fallbackTitle(kind)
            )
            // 앱이 채우는 카드에는 맥의 내용이 없다 (와도 쓰지 않는다)
            guard !kind.filledByApp else { return card }
            card.state = state.flatMap(SpaceCard.State.init(rawValue:)) ?? (payload == nil ? .empty : .ok)
            card.why = clean(why)
            card.dataAt = AgentTime.date(data_at)
            // 단추: 글과 말이 둘 다 있을 때만. 글이 길면 단추로 그리지 않는다 (한 줄 카드의 오른쪽에 놓인다)
            if let label = clean(action?.value?.label), let say = clean(action?.value?.say),
               label.count <= SpaceCard.Action.labelLimit, say.count <= SpaceModel.textLimit {
                card.action = SpaceCard.Action(label: label, say: say)
            }
            // 카드에서 바로 하는 일: 대화로 보낼 말이나 돌릴 예약이 있는 것만, 글이 짧은 것만, 2개까지
            card.quicks = Array((actions ?? []).compactMap(\.value).compactMap { item -> SpaceCard.Quick? in
                guard let label = clean(item.label), label.count <= SpaceCard.Action.labelLimit else { return nil }
                if let run = clean(item.run), AgentHTTPClient.isPathSafe(run) { return SpaceCard.Quick(label: label, kind: .run(run)) }
                if let say = clean(item.say), say.count <= SpaceModel.textLimit { return SpaceCard.Quick(label: label, kind: .say(say)) }
                return nil
            }.prefix(SpaceCard.Quick.limit))
            card.changedAt = AgentTime.date(changed_at)
            card.newCount = max(0, payload?.new_count ?? 0)
            // 지난번과의 차이: 맥이 쓴 글 그대로. 0이면 보이지 않는다
            if let delta = payload?.delta?.value, let text = clean(delta.text), let diff = delta.diff, diff.isFinite, diff != 0 {
                card.delta = String(text.prefix(12))
                card.deltaUp = diff > 0
            }
            card.trend = (payload?.blocks ?? []).compactMap { $0.value?.trend }.last ?? []
            card.blocks = Array((payload?.blocks ?? []).compactMap { $0.value?.block }.prefix(SpaceBlock.limit))
            if kind == .mailToday {
                card.mailCount = payload?.count.map { max(0, $0) }
                card.mailServices = (payload?.services ?? []).compactMap { clean($0.value) }
                card.mailHeadline = clean(payload?.headline)
                card.mailRest = clean(payload?.rest)
                card.mailPicks = Array((payload?.picks ?? []).compactMap(\.value).compactMap { pick in
                    clean(pick.title).map {
                        SpaceCard.Pick(
                            title: $0, note: clean(pick.note), service: clean(pick.service),
                            say: clean(pick.say).flatMap { $0.count <= SpaceModel.textLimit ? $0 : nil }
                        )
                    }
                }.prefix(SpaceCard.pickLimit))
                card.mails = (payload?.items ?? []).compactMap(\.value).compactMap { mail in
                    clean(mail.subject).map { SpaceCard.Mail(time: clean(mail.time), from: clean(mail.from), subject: $0, service: clean(mail.service)) }
                }
            }
            return card
        }

        static func fallbackTitle(_ kind: SpaceCard.Kind) -> String {
            switch kind {
            case .calendarToday: "오늘 일정"
            case .weather: "날씨"
            case .meetingTodos: "회의에서 나온 할 일"
            case .mailToday: "오늘 온 메일"
            case .routineResult: "예약 결과"
            case .custom: "카드"
            }
        }
    }

    struct SpaceDTO: Decodable {
        struct SuggestionDTO: Decodable {
            let label: String?
            let say: String?
        }
        let cards: [Lossy<CardDTO>]?
        let can_undo: Bool?
        let suggestions: [Lossy<SuggestionDTO>]?

        var space: AgentSpace {
            var seen: Set<String> = []
            // 같은 번호가 두 번 오면 앞의 것만 (화면의 줄을 번호로 가린다)
            let cards = (cards ?? []).compactMap { $0.value?.card }.filter { seen.insert($0.id).inserted }
            // 추천: 글과 말이 둘 다 있고 글이 짧은 것만, 같은 글은 한 번만
            var labels: Set<String> = []
            let suggestions = (suggestions ?? []).compactMap(\.value).compactMap { item -> AgentSpace.Suggestion? in
                guard let label = clean(item.label), label.count <= SpaceCard.Action.labelLimit,
                      let say = clean(item.say), say.count <= SpaceModel.textLimit, labels.insert(label).inserted else { return nil }
                return AgentSpace.Suggestion(label: label, say: say)
            }
            return AgentSpace(cards: cards, canUndo: can_undo ?? false, suggestions: Array(suggestions.prefix(AgentSpace.Suggestion.limit)))
        }
    }

    private struct Wrapper: Decodable {
        let space: SpaceDTO
        let changes: [Lossy<String>]?
        let say: String?
        let asking: Bool?
    }

    static func space(data: Data, status: Int) throws -> AgentSpace {
        try edit(data: data, status: status).space
    }

    static func edit(data: Data, status: Int) throws -> SpaceEdit {
        guard (200..<300).contains(status) else { throw AgentHTTPClient.decodeError(data: data, status: status) }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { throw AgentError.invalidResponse }
        return SpaceEdit(
            space: wrapper.space.space, changes: (wrapper.changes ?? []).compactMap { clean($0.value) }.map(Josa.fix),
            say: clean(wrapper.say).map(Josa.fix),
            // 묻는 말이 있을 때만 되묻기로 본다
            asking: wrapper.asking == true && clean(wrapper.say) != nil
        )
    }

    /// 앞뒤 빈칸을 뗀다. 빈 글이면 nil
    static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

private func clean(_ text: String?) -> String? { SpaceDecoding.clean(text) }

/// 내 공간 화면의 상태. 구성도 내용도 메모리에만 둔다
@MainActor
@Observable
final class SpaceModel {
    /// 방금 말로 고친 것 (고치기 화면에 보인다)
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var text: String
        /// 답을 받기 전에는 nil
        var changes: [String]?
        var say: String?
        /// 하지 못했을 때의 한마디
        var failure: String?
        /// 맥이 되물었다 (`say`가 묻는 말)
        var asking = false
    }

    /// 맥이 받는 말의 길이
    nonisolated static let textLimit = 500

    private let agent: (any AgentProviding)?
    private(set) var space = AgentSpace.empty
    /// 맥이 내 공간을 할 줄 아는지
    private(set) var isOffered = false
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// 마지막으로 받으려다 실패했는지 (맥에 연결되지 않음 포함)
    private(set) var loadFailed = false
    /// 말로 고치는 중 (2~10초)
    private(set) var isEditing = false
    /// 내용을 새로 받는 중인 카드
    private(set) var refreshing: Set<String> = []
    /// 이번에 새로 받으려다 실패한 카드 (다시 저절로 부르지 않는다. 당겨서 새로 받으면 지운다)
    private(set) var refreshFailed: Set<String> = []
    /// 이번에 고치기 화면에서 주고받은 말
    private(set) var turns: [Turn] = []
    /// 고치기 화면을 열었을 때의 구성 (바뀐 카드를 가려 보이려고)
    private(set) var before: AgentSpace?
    /// 방금 한 일이 되지 않았을 때의 한마디
    var notice: String?
    /// 맥이 카드를 손으로 옮기고·크기를 바꾸고·빼는 것을 받는지 (D100). 아니면 말로만 고친다
    private(set) var canArrange = false
    /// 손으로 옮기는 중에 아직 맥에 보내지 않은 차례가 있는지
    private(set) var hasPendingArrange = false
    private var isArranging = false
    /// 손으로 고치기 전의 카드 (맥이 받아 주지 않으면 여기로 되돌린다)
    private var arrangeBase: [SpaceCard]?
    /// "지금 가져오기"로 예약을 돌려 놓고 결과를 기다리는 카드 (D103)
    private(set) var running: Set<String> = []
    /// "지금 가져오기"로 돌린 예약이 카드를 채우지 못하고 대화로 넘어간 카드 → 그 실행 (D128).
    /// 로그인이 필요하거나 물어볼 것이 생기면 맥은 카드 대신 그 실행의 대화에 말한다. 카드에서 그 대화로 바로 가게 한다
    private(set) var runStops: [String: RoutineRun] = [:]

    /// 카드를 채우지 못하고 사람을 기다리거나 끝난 실행인지
    nonisolated static func stopsForUser(_ run: RoutineRun) -> Bool {
        ["needs_reply", "needs_login", "failed", "missed"].contains(run.status)
            || ["needs_input", "failed"].contains(run.taskStatus ?? "")
    }

    /// 카드 아래의 한 줄 (D128)
    nonisolated static func stopText(_ run: RoutineRun) -> String {
        if run.status == "needs_login" { return "로그인이 필요해 대화에서 멈췄어요" }
        if run.status == "needs_reply" || run.taskStatus == "needs_input" { return "물어볼 것이 있어 대화로 넘어갔어요" }
        if run.status == "missed" { return "맥이 꺼져 있어 돌지 못했어요" }
        return "가져오지 못했어요"
    }
    /// 돌려 놓은 예약의 결과를 다시 물어보는 틈과 횟수 (사이트를 읽는 예약은 2~3분 걸린다)
    var runPoll: Duration = .seconds(15)
    var runPollLimit = 16

    init(agent: (any AgentProviding)? = AgentClient.fromEnvironment()) {
        self.agent = agent
    }

    /// 맥이 붙어 있는지 (없으면 내 공간을 쓸 수 없다)
    var hasAgent: Bool { agent != nil }

    func load() async {
        guard let agent, !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        guard await agent.isReachable() else {
            loadFailed = true
            return
        }
        guard await agent.supports(AgentFeature.space) else {
            isOffered = false
            space = .empty
            loadFailed = false
            return
        }
        isOffered = true
        canArrange = await agent.supports(AgentFeature.spaceArrange)
        do {
            let fresh = try await agent.space()
            // 손으로 고치던 중이면 화면을 덮지 않는다 (아직 보내지 않은 차례·크기가 사라지지 않게)
            if !hasPendingArrange, !isEditing { space = fresh }
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// 당겨서 새로 받기: 구성을 다시 받고, 맥이 채우는 카드를 모두 새로 받는다
    func reload() async {
        refreshFailed = []
        await load()
        await refreshStale(all: true)
    }

    /// 비었거나 오래된 카드를 하나씩 새로 받는다 (카드 하나에 0~20초라 카드마다 따로 부른다)
    func refreshStale(all: Bool = false) async {
        let ids = space.cards
            .filter { all ? !$0.kind.filledByApp && $0.state != .unavailable : $0.needsRefresh }
            .map(\.id)
            .filter { !refreshing.contains($0) && !refreshFailed.contains($0) }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refresh(card: id) }
            }
        }
    }

    func refresh(card id: String) async {
        guard let agent, SpaceCard.isID(id), !refreshing.contains(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        do {
            let fresh = try await agent.refreshSpace(card: id)
            // 그 카드만 바꾼다: 그사이 말로 고친 구성을 예전 것으로 덮지 않는다
            if let card = fresh.cards.first(where: { $0.id == id }), let index = space.cards.firstIndex(where: { $0.id == id }) {
                space.cards[index] = card
                // 받았는데도 여전히 비어 있으면 다시 부르지 않는다
                if card.needsRefresh { refreshFailed.insert(id) } else { refreshFailed.remove(id) }
            }
        } catch {
            refreshFailed.insert(id)
        }
    }

    /// 말로 고친다. 맥이 받아들인 뒤에만 화면이 바뀐다
    func edit(_ raw: String) async {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.textLimit))
        guard let agent, !text.isEmpty, !isEditing else { return }
        isEditing = true
        defer { isEditing = false }
        if before == nil { before = space }
        turns.append(Turn(text: text))
        let index = turns.count - 1
        do {
            let result = try await agent.editSpace(text: text)
            space = result.space
            refreshFailed = []
            turns[index].changes = result.changes
            turns[index].say = result.say
            turns[index].asking = result.asking
        } catch {
            turns[index].changes = []
            turns[index].failure = Self.failure(error, doing: "바꾸지")
        }
        await refreshStale()
    }

    // MARK: 카드에서 바로 하기 (D103)

    /// 카드의 "지금 가져오기": 그 예약을 지금 한 번 돌리고, 끝날 때까지 그 카드를 틈틈이 새로 받는다.
    /// 맥이 받아 주지 않으면 한마디로 알린다
    func runNow(card id: String, routine: String) async {
        guard let agent, !running.contains(id) else { return }
        running.insert(id)
        runStops[id] = nil
        let started = Date.now
        defer { running.remove(id) }
        do {
            try await agent.runRoutine(id: routine)
            notice = nil
        } catch {
            notice = Self.failure(error, doing: "가져오지")
            return
        }
        let before = space.cards.first { $0.id == id }?.dataAt
        for _ in 0..<runPollLimit {
            await refresh(card: id)
            // 새 내용이 왔으면 그만 묻는다 (채운 때가 달라졌다). 카드가 빠졌어도 그만둔다
            guard let card = space.cards.first(where: { $0.id == id }) else { return }
            if card.state == .ok, card.dataAt != before { return }
            // 이번 실행이 카드를 채우지 못하고 대화로 넘어갔으면(로그인·물어봄·실패) 그만 묻고 카드에서 그 대화로 가게 한다 (D128)
            if let run = await latestRun(routine, since: started), Self.stopsForUser(run) {
                runStops[id] = run
                return
            }
            try? await Task.sleep(for: runPoll)
            if Task.isCancelled { return }
        }
        // 기다려도 채워지지 않았다
        guard let run = await latestRun(routine, since: started) else { return }
        if Self.finishedWell(run) {
            // 맥에서는 잘 끝났다: 카드가 비어 있는 것은 맥이 아직 채우지 않은 것이라 대화로 보내지 않고 한 번 더 받는다 (D129)
            await refresh(card: id)
        } else if run.canOpen || run.conversationID != nil {
            // 실행이 대화에 남긴 것이 있으면 그리로 가게 한다
            runStops[id] = run
        }
    }

    /// 실행이 잘 끝났는지 (답이 바로 나왔거나, 작업이 되어 끝났다)
    nonisolated static func finishedWell(_ run: RoutineRun) -> Bool {
        run.status == "done" || run.taskStatus == "completed"
    }

    /// 이 예약의 이번 실행 (돌린 뒤의 것만. 맥의 시계와 조금 어긋나도 되게 1분 앞까지 본다)
    private func latestRun(_ routine: String, since started: Date) async -> RoutineRun? {
        guard let agent, let run = try? await agent.routineRuns(routineID: routine, limit: 1).first else { return nil }
        guard (run.ranAt ?? .distantPast) >= started.addingTimeInterval(-60) else { return nil }
        return run
    }

    /// 카드 아래의 "대화에서 보기"를 눌렀거나 닫았다
    func clearRunStop(_ id: String) { runStops[id] = nil }

    // MARK: 손으로 고치기 (D100)

    /// 끌어 옮기는 중: `id` 카드를 `target` 카드의 자리로 옮긴 모습을 화면에만 보인다 (놓으면 `commitArrange`가 맥에 보낸다)
    func previewMove(_ id: String, onto target: String) {
        guard canArrange, id != target,
              let from = space.cards.firstIndex(where: { $0.id == id }), let to = space.cards.firstIndex(where: { $0.id == target }) else { return }
        beginArrange()
        space.cards.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// 한 칸 위나 아래로 (카드 메뉴. 끌 수 없는 사람도 옮길 수 있게)
    func move(_ id: String, by offset: Int) async {
        guard canArrange, let from = space.cards.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + offset), space.cards.count - 1)
        guard to != from else { return }
        beginArrange()
        space.cards.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        await commitArrange()
    }

    /// 핸들을 끄는 중: 카드를 그 크기로 바꾼 모습을 화면에만 보인다 (놓으면 `commitArrange`가 맥에 보낸다)
    func previewResize(_ id: String, to size: SpaceCard.Size) {
        guard canArrange, let index = space.cards.firstIndex(where: { $0.id == id }), space.cards[index].size != size else { return }
        beginArrange()
        space.cards[index].size = size
    }

    /// 크기를 바꾼다 (모서리 핸들, 카드 메뉴)
    func resize(_ id: String, to size: SpaceCard.Size) async {
        guard canArrange, let index = space.cards.firstIndex(where: { $0.id == id }), space.cards[index].size != size else { return }
        beginArrange()
        space.cards[index].size = size
        await commitArrange()
    }

    /// 카드를 뺀다 (카드 메뉴)
    func remove(_ id: String) async {
        guard canArrange, space.cards.contains(where: { $0.id == id }) else { return }
        beginArrange()
        space.cards.removeAll { $0.id == id }
        await commitArrange()
    }

    private func beginArrange() {
        if before == nil { before = space }
        if arrangeBase == nil { arrangeBase = space.cards }
        hasPendingArrange = true
    }

    /// 화면에 보인 차례·크기를 맥에 보낸다. 맥이 받아들이지 않으면 고치기 전으로 되돌린다.
    /// 보내는 중에 또 고쳤으면 끝난 뒤에 한 번 더 보낸다 (마지막 모습이 맥에 남게)
    func commitArrange() async {
        guard let agent, hasPendingArrange, !isArranging else { return }
        isArranging = true
        defer { isArranging = false }
        while hasPendingArrange {
            hasPendingArrange = false
            let sent = space.cards
            guard sent != arrangeBase else { break }
            do {
                let result = try await agent.arrangeSpace(sent.map(SpaceArrangement.init))
                // 그사이 또 고쳤으면 화면은 그대로 두고 다시 보낸다
                if !hasPendingArrange {
                    space = result.space
                    arrangeBase = nil
                } else {
                    arrangeBase = result.space.cards
                }
                refreshFailed = []
                notice = nil
                turns.append(Turn(text: "직접 고침", changes: result.changes.isEmpty ? ["카드를 고쳤어요"] : result.changes))
            } catch {
                hasPendingArrange = false
                if let arrangeBase { space.cards = arrangeBase }
                arrangeBase = nil
                turns.append(Turn(text: "직접 고침", changes: [], failure: Self.failure(error, doing: "고치지")))
                return
            }
        }
        arrangeBase = nil
    }

    /// 한 번 되돌린다
    func undo() async {
        guard let agent, !isEditing else { return }
        isEditing = true
        defer { isEditing = false }
        do {
            let result = try await agent.undoSpace()
            space = result.space
            refreshFailed = []
            notice = nil
            if !turns.isEmpty { turns.append(Turn(text: "되돌리기", changes: result.changes.isEmpty ? ["앞의 화면으로 되돌렸어요"] : result.changes)) }
        } catch {
            notice = (error as? AgentError) == .conflict ? "되돌릴 것이 없어요." : Self.failure(error, doing: "되돌리지")
        }
        await refreshStale()
    }

    /// 비운다
    func clear() async {
        guard let agent, !isEditing else { return }
        isEditing = true
        defer { isEditing = false }
        do {
            space = try await agent.clearSpace().space
            refreshFailed = []
            notice = nil
        } catch {
            notice = Self.failure(error, doing: "비우지")
        }
    }

    /// 고치기 화면을 닫았다: 주고받은 말을 지운다
    func finishEditing() {
        turns = []
        before = nil
    }

    /// 고치기 화면의 미리 보기에서, 이번에 빠진 카드 (열었을 때는 있었는데 지금은 없다)
    var removed: [SpaceCard] {
        guard let before else { return [] }
        let now = Set(space.cards.map(\.id))
        return before.cards.filter { !now.contains($0.id) }
    }

    /// 이번에 바뀐 카드인지 (새로 생겼거나, 크기·자리가 달라졌다)
    func changed(_ card: SpaceCard) -> Bool { change(card) != nil }

    /// 미리 보기에 붙이는 표시: 무엇이 바뀌었는지 ("새로" · "크게" · "작게" · "옮김" · "이름"). 바뀌지 않았으면 nil
    func change(_ card: SpaceCard) -> String? {
        guard let before, before != space else { return nil }
        guard let old = before.cards.first(where: { $0.id == card.id }) else { return "새로" }
        var marks: [String] = []
        if let direction = moved(card) { marks.append(direction) }
        // 크기는 바뀐 뒤의 이름으로 (맥의 문장 "보통 크기로"와 같은 말이 되게)
        if old.size != card.size { marks.append(Self.name(card.size)) }
        if old.title != card.title { marks.append("이름") }
        return marks.isEmpty ? nil : marks.joined(separator: " · ")
    }

    /// 미리 보기에 표시를 붙일지: 모든 카드가 새 카드면 붙이지 않는다 (전부에 붙으면 아무것도 가려지지 않는다)
    var marksChanges: Bool {
        !space.cards.isEmpty && !(removed.isEmpty && space.cards.allSatisfy { change($0) == "새로" })
    }

    private static func name(_ size: SpaceCard.Size) -> String { size.label }

    /// 방금 말로 고친 것의 한 줄 (화면 위에 잠깐 띄우는 알림, D98). 고치는 중이면 nil
    var lastSummary: String? {
        guard let turn = turns.last, let changes = turn.changes else { return nil }
        if let failure = turn.failure { return failure }
        guard let first = changes.first else { return turn.say ?? "바뀐 것이 없어요." }
        return changes.count > 1 ? "\(first) 외 \(changes.count - 1)건" : first
    }

    /// 맥이 방금 되물었는지 (D105): 알림에 묻는 말을 보이고 입력창을 열어 둔다
    var isAsked: Bool { turns.last?.asking == true }

    /// 방금 고친 것이 실제로 화면을 바꿨는지 (되돌리기를 보일지)
    var lastChanged: Bool { turns.last?.changes?.isEmpty == false && turns.last?.failure == nil }

    /// 자리를 옮긴 카드면 어느 쪽으로 갔는지 ("위로" · "아래로")
    private func moved(_ card: SpaceCard) -> String? {
        guard let before else { return nil }
        // 자리가 달라졌는지는 남아 있는 카드끼리의 차례로 본다 (다른 카드가 빠져 밀린 것은 바뀐 것이 아니다)
        let kept = Set(space.cards.map(\.id)).intersection(before.cards.map(\.id))
        let was = before.cards.map(\.id).filter(kept.contains)
        let now = space.cards.map(\.id).filter(kept.contains)
        guard was != now, let from = was.firstIndex(of: card.id), let to = now.firstIndex(of: card.id) else { return nil }
        // 옮긴 카드 하나만 표시한다: 그 카드를 빼면 나머지의 차례가 그대로인 카드
        guard from != to, was.filter({ $0 != card.id }) == now.filter({ $0 != card.id }) else { return nil }
        return to < from ? "위로" : "아래로"
    }

    static func failure(_ error: Error, doing: String) -> String {
        switch error as? AgentError {
        case .unreachable?: "맥에 연결되지 않아 \(doing) 못했어요."
        case .slow?: "맥이 시간 안에 답하지 못해 \(doing) 못했어요. 잠시 뒤에 다시 해 주세요."
        default: "\(doing) 못했어요. 잠시 뒤에 다시 해 주세요."
        }
    }
}
