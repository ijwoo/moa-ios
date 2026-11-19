import Foundation

// 홈 화면 위젯의 내용 (D109). 앱과 위젯이 함께 쓴다 (테스트는 앱 쪽에서 한다).
//
// 위젯은 맥에 직접 묻는다 (`GET /v1/space/widget`. 모델을 부르지 않아 바로 답한다).
// 주소·토큰은 앱과 같은 값(Config/Secrets.xcconfig → 위젯의 Info.plist)이라 앱 그룹이 필요 없다.
// 맥에 닿지 못하면 지난 모습을 보여야 하므로, 마지막으로 받은 것을 **위젯 자신의 저장 공간에만** 남긴다
// (잠금이 처음 풀린 뒤에만 읽힌다. 앱은 읽지 않는다). 사용자가 알고 받아들였다 (2026-11-16 "ㅇㅇ 알겠어").

/// 위젯에 보일 카드 하나 (맥이 채우는 카드만)
struct SpaceWidgetItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    /// 크게 보일 값 ("8통", "1,336.0원"). 날짜 카드면 YYYY-MM-DD
    var value: String?
    /// 한 줄 (이름표, 목록의 첫 줄, 채울 수 없는 까닭)
    var line: String?
    /// 날짜 카드의 그날 (YYYY-MM-DD) — 위젯이 남은 날을 센다
    var date: String?
    var newCount: Int?
    /// 채울 수 없는 카드
    var unavailable: Bool
}

/// 위젯이 받은 것 한 벌
struct SpaceWidgetSnapshot: Codable, Equatable, Sendable {
    var items: [SpaceWidgetItem]
    /// 맥에서 받은 때
    var fetchedAt: Date

    /// 위젯 크기마다 보이는 카드의 수
    static func limit(small: Bool, large: Bool) -> Int { small ? 1 : (large ? 6 : 4) }
}

enum SpaceWidgetDecoding {
    private struct Wrapper: Decodable {
        struct Widget: Decodable {
            let items: [Lossy<Item>]?
        }
        struct Item: Decodable {
            let id: String
            let title: String?
            let source: String?
            let state: String?
            let value: String?
            let line: String?
            let date: String?
            let new_count: Int?
        }
        let widget: Widget
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// 맥의 답을 읽는다. 2xx가 아니거나 꼴이 어긋나면 nil.
    /// 앱이 자기 데이터로 채우는 카드(일정·날씨·회의 할 일)와 아직 비어 있는 카드는 위젯에 보이지 않는다
    static func snapshot(data: Data, status: Int, now: Date = .now) -> SpaceWidgetSnapshot? {
        guard (200..<300).contains(status), let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { return nil }
        let items = (wrapper.widget.items ?? []).compactMap(\.value).compactMap { item -> SpaceWidgetItem? in
            guard item.source == "mac", item.state != "empty", let title = clean(item.title) else { return nil }
            let unavailable = item.state == "unavailable"
            let value = unavailable ? nil : clean(item.value)
            let line = clean(item.line)
            // 보일 것이 없으면 뺀다
            guard value != nil || line != nil else { return nil }
            return SpaceWidgetItem(
                id: item.id, title: String(title.prefix(20)), value: value.map { String($0.prefix(16)) }, line: line.map { String($0.prefix(40)) },
                date: clean(item.date), newCount: (item.new_count ?? 0) > 0 ? item.new_count : nil, unavailable: unavailable
            )
        }
        return SpaceWidgetSnapshot(items: Array(items.prefix(8)), fetchedAt: now)
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// 날짜 카드의 남은 날 ("D-39", "오늘")
enum SpaceWidgetDays {
    static func left(until text: String, now: Date = .now, calendar: Calendar = .current) -> Int? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day
    }

    static func badge(_ text: String, now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let left = left(until: text, now: now, calendar: calendar) else { return nil }
        if left == 0 { return "오늘" }
        return left > 0 ? "D-\(left)" : "D+\(-left)"
    }
}

/// 마지막으로 받은 것 (위젯 자신의 저장 공간). 맥에 닿지 못할 때만 꺼내 쓴다
enum SpaceWidgetCache {
    static var file: URL {
        URL.applicationSupportDirectory.appending(path: "space-widget.json")
    }

    static func save(_ snapshot: SpaceWidgetSnapshot, to file: URL = file) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 잠금이 처음 풀린 뒤에만 읽힌다
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func load(from file: URL = file) -> SpaceWidgetSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SpaceWidgetSnapshot.self, from: data)
    }
}

/// 위젯이 맥에 묻는다 (짧게: 위젯은 오래 기다릴 수 없다)
enum SpaceWidgetFetch {
    enum Outcome: Sendable {
        case fresh(SpaceWidgetSnapshot)
        /// 맥에 닿지 못했다 (지난 것을 보인다)
        case unreachable
        /// 맥이 위젯을 모른다 (예전 맥) 또는 주소·토큰이 없다
        case unsupported
    }

    static func fetch(bundle: Bundle = .main) async -> Outcome {
        guard let host = bundle.object(forInfoDictionaryKey: "MSAgentHost") as? String, !host.isEmpty,
              let token = bundle.object(forInfoDictionaryKey: "MSAgentToken") as? String, !token.isEmpty,
              let url = URL(string: "https://\(host)/v1/space/widget") else { return .unsupported }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.setValue(token, forHTTPHeaderField: "X-App-Token")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request) else { return .unreachable }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return .unsupported }
        guard let snapshot = SpaceWidgetDecoding.snapshot(data: data, status: status) else { return .unreachable }
        return .fresh(snapshot)
    }
}
