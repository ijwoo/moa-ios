import Foundation

// 활동 탭과 전역 검색 (D120, 맥의 D103): 맥에 남은 끝난 작업·예약 실행을 받아 이 기기의 회의와 한 줄로 놓는다.
// 앱 쪽 명세: local-ai-agent docs/API.md "활동 · 전역 검색" 절.

/// 맥에 남은 활동 하나 (끝난 작업, 예약 실행, 검색에서는 예약 자체도)
struct ActivityEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case task
        /// 예약이 돈 기록
        case routine
        /// 예약 자체 (검색에서만)
        case routineDefinition = "routine_def"
    }

    var id: String
    var kind: Kind
    var at: Date
    var title: String
    var status: String?
    /// 한 줄 (카드의 부제·결과의 첫 줄). 맥이 숨긴 작업(`private`)에는 없다
    var line: String?
    var conversationID: String?
    /// 예약 실행이 작업이 됐으면 그 작업
    var taskID: String?
    var cardKind: String?
    /// 검색에서 맞은 곳의 앞뒤
    var snippet: String?

    /// 끝내지 못했는지 (줄의 표시)
    var isFailed: Bool {
        cardKind == "failed" || ["failed", "cancelled", "missed"].contains(status ?? "")
    }

    /// 지금 내 답을 기다리는지 (승인·질문. 보내기 대기는 사람이 할 일이 아니라 뺀다)
    var isWaiting: Bool { ["awaiting_approval", "awaiting_input"].contains(status ?? "") }
}

enum ActivityDecoding {
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct Row: Decodable {
        let kind: String?
        let id: String
        let at: String?
        let title: String?
        let status: String?
        let line: String?
        let conversation_id: String?
        let task_id: String?
        let card_kind: String?
        let card_title: String?
        let card_subtitle: String?
        let snippet: String?
        let `private`: Bool?

        var entry: ActivityEntry? {
            guard let kind = ActivityEntry.Kind(rawValue: kind ?? "task"), AgentHTTPClient.isPathSafe(id),
                  let date = ActivityDecoding.date(at) else { return nil }
            let name = [title, card_title].compactMap { ActivityDecoding.clean($0, limit: 60) }.first ?? "맥의 작업"
            let hidden = `private` == true
            return ActivityEntry(
                id: id, kind: kind, at: date, title: name, status: clean(status),
                line: hidden ? nil : [card_subtitle, line].compactMap { ActivityDecoding.clean($0, limit: 90) }.first,
                conversationID: conversation_id.flatMap { AgentHTTPClient.isPathSafe($0) ? $0 : nil },
                taskID: task_id.flatMap { AgentHTTPClient.isPathSafe($0) ? $0 : nil },
                cardKind: clean(card_kind), snippet: hidden ? nil : ActivityDecoding.clean(snippet, limit: 120)
            )
        }

        private func clean(_ text: String?) -> String? { ActivityDecoding.clean(text, limit: 40) }
    }

    /// `{"<key>": [...]}`를 읽어 시각 순(최근 것부터)으로. 읽지 못한 줄은 버린다
    static func entries(data: Data, status: Int, key: String) throws -> [ActivityEntry] {
        guard (200..<300).contains(status) else { throw AgentHTTPClient.decodeError(data: data, status: status) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object[key] as? [Any],
              let listData = try? JSONSerialization.data(withJSONObject: list),
              let rows = try? JSONDecoder().decode([Lossy<Row>].self, from: listData) else { throw AgentError.invalidResponse }
        return rows.compactMap(\.value?.entry).sorted { $0.at > $1.at }
    }

    /// 맥의 시각 (작업은 UTC, 예약은 +09:00. 소수 초가 있을 수도 없을 수도 있다)
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return flat.isEmpty ? nil : String(flat.prefix(limit))
    }
}

/// 활동 탭의 맥 쪽 목록. 맥이 `activity`를 알릴 때만 받는다 (모르면 이 기기의 회의만 보인다)
@MainActor
@Observable
final class ActivityModel {
    private let agent: (any AgentProviding)?
    private(set) var entries: [ActivityEntry] = []
    private(set) var isOffered = false
    private(set) var hasLoaded = false
    private(set) var loadFailed = false
    private var isLoading = false

    init(agent: (any AgentProviding)?) {
        self.agent = agent
    }

    func load() async {
        guard let agent, !isLoading else {
            hasLoaded = true
            return
        }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        guard await agent.isReachable() else {
            loadFailed = true
            return
        }
        isOffered = await agent.supports(AgentFeature.activity)
        guard isOffered else {
            entries = []
            loadFailed = false
            return
        }
        do {
            entries = try await agent.activity(limit: 50)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// 맥 쪽 기록에서 찾기 (받지 못하면 빈 목록)
    func search(_ query: String) async -> [ActivityEntry] {
        guard let agent else { return [] }
        if !isOffered, !(await agent.supports(AgentFeature.activity)) { return [] }
        return (try? await agent.searchMac(query, limit: 30)) ?? []
    }
}

/// 활동 탭의 한 줄: 맥의 활동 또는 이 기기의 회의 (날짜 묶음에 함께 놓는다)
enum ActivityItem: Identifiable {
    case mac(ActivityEntry)
    case meeting(Meeting)

    var id: String {
        switch self {
        case .mac(let entry): "mac-\(entry.kind.rawValue)-\(entry.id)"
        case .meeting(let meeting): "meeting-\(meeting.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .mac(let entry): entry.at
        case .meeting(let meeting): meeting.date
        }
    }

    /// 날짜로 묶는다 (오늘 · 어제 · 날짜). 묶음 안은 최근 것부터
    @MainActor
    static func days(_ items: [ActivityItem], now: Date = .now, calendar: Calendar = .current) -> [(title: String, items: [ActivityItem])] {
        let sorted = items.sorted { $0.date > $1.date }
        var order: [String] = []
        var groups: [String: [ActivityItem]] = [:]
        for item in sorted {
            let key = SidebarText.day(item.date, now: now, calendar: calendar)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.map { (title: $0, items: groups[$0] ?? []) }
    }
}
