import EventKit
import Foundation

// 오늘 일정 (D95): 내 공간의 "오늘 일정" 카드가 이 아이폰의 캘린더에서 읽는다.
// 일정은 이 기기 밖으로 나가지 않는다 — 맥으로도 Claude로도 보내지 않고, 저장하지도 않는다.

/// 오늘의 일정 하나 (카드에 보이는 것만)
struct DayEvent: Equatable, Sendable, Identifiable {
    let id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false

    /// 줄 앞의 때: "종일" · "10:00"
    func timeText(calendar: Calendar = .current) -> String {
        if isAllDay { return "종일" }
        let parts = calendar.dateComponents([.hour, .minute], from: start)
        return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// 다음 일정의 때: "오후 3:00 · 5분 뒤" · "오후 2:00 · 지금" · "종일"
    func whenText(now: Date = .now, calendar: Calendar = .current) -> String {
        isAllDay ? "종일" : "\(SpaceTime.clock(start, calendar: calendar)) · \(SpaceTime.until(start, now: now))"
    }
}

enum DayEvents {
    enum Access: Equatable, Sendable { case allowed, notAsked, denied }

    /// 카드에 보일 차례: 종일 일정 먼저, 그다음 시작 시각 차례. 이미 끝난 일정은 뺀다
    static func remaining(_ events: [DayEvent], now: Date = .now) -> [DayEvent] {
        events
            .filter { $0.isAllDay || $0.end > now }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start == b.start ? a.title < b.title : a.start < b.start
            }
    }
}

/// 오늘 일정을 주는 곳 (실제: 이 아이폰의 캘린더. 시험·데모: 지어낸 일정)
protocol DayEventsProviding: Sendable {
    func access() -> DayEvents.Access
    /// 권한을 묻는다 (아직 묻지 않았을 때만 시스템 창이 뜬다). 허용했으면 true
    func request() async -> Bool
    /// 오늘(이 기기의 달력으로) 걸친 일정. 권한이 없으면 빈 목록
    func today(now: Date) -> [DayEvent]
}

/// 이 아이폰의 캘린더 (EventKit). 읽기만 한다 — 일정을 만들거나 고치지 않는다
struct SystemDayEvents: DayEventsProviding {
    func access() -> DayEvents.Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func request() async -> Bool {
        guard access() == .notAsked else { return access() == .allowed }
        return (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    func today(now: Date) -> [DayEvent] {
        guard access() == .allowed else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let store = EKEventStore()
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).compactMap { event in
            // 거절한 초대는 내 일정이 아니다
            guard event.status != .canceled, let from = event.startDate, let to = event.endDate else { return nil }
            let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return DayEvent(
                id: "\(event.calendarItemIdentifier)-\(from.timeIntervalSince1970)", title: title.isEmpty ? "제목 없는 일정" : title,
                start: from, end: to, isAllDay: event.isAllDay
            )
        }
    }
}

#if DEBUG
/// 지어낸 일정 (화면 확인과 테스트용). 실제 캘린더를 읽지 않고 권한도 묻지 않는다
final class MockDayEvents: DayEventsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var state: DayEvents.Access
    private let grants: Bool
    private let events: [DayEvent]?

    /// `grants`: 물었을 때 허용하는지. `events`가 nil이면 오늘의 지어낸 일정 셋
    init(access: DayEvents.Access = .allowed, grants: Bool = true, events: [DayEvent]? = nil) {
        state = access
        self.grants = grants
        self.events = events
    }

    /// 실행 인자 `-demoCalendar ask|denied|none`: 아직 묻지 않은 기기 / 꺼 둔 기기 / 일정이 없는 날
    static func fromArguments() -> MockDayEvents {
        switch UserDefaults.standard.string(forKey: "demoCalendar") {
        case "ask": MockDayEvents(access: .notAsked)
        case "denied": MockDayEvents(access: .denied)
        case "none": MockDayEvents(events: [])
        default: MockDayEvents()
        }
    }

    func access() -> DayEvents.Access { lock.withLock { state } }

    func request() async -> Bool {
        lock.withLock {
            if state == .notAsked { state = grants ? .allowed : .denied }
            return state == .allowed
        }
    }

    func today(now: Date) -> [DayEvent] {
        guard access() == .allowed else { return [] }
        if let events { return events }
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now }
        // 지금이 몇 시든 화면에 보이게, 끝나는 때는 모두 오늘 밤으로 둔다
        return [
            DayEvent(id: "demo-1", title: "팀 미팅", start: at(10), end: at(23, 59)),
            DayEvent(id: "demo-2", title: "병원 예약", start: at(14), end: at(23, 59)),
            DayEvent(id: "demo-3", title: "저녁 약속", start: at(19), end: at(23, 59)),
        ]
    }
}
#endif
