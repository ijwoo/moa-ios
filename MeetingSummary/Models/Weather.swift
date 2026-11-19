import Foundation

/// 날씨를 물은 때 (맥이 준 `action.when`, D66).
enum WeatherWhen: Equatable, Sendable {
    case now
    case today
    case tomorrow
    case week
    /// 날짜를 짚어 물었다 (그곳의 달력으로 읽는다)
    case date(year: Int, month: Int, day: Int)

    /// 맥과 맞춘 값: `now | today | tomorrow | week | YYYY-MM-DD`. 모르는 값·없는 날짜는 오늘로 읽는다
    init(_ raw: String?) {
        switch raw {
        case "now": self = .now
        case "tomorrow": self = .tomorrow
        case "week": self = .week
        default: self = Self.date(from: raw ?? "") ?? .today
        }
    }

    private static func date(from raw: String) -> WeatherWhen? {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        // 달력에 없는 날(2월 30일 등)은 날짜로 읽지 않는다
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar) else { return nil }
        return .date(year: year, month: month, day: day)
    }
}

/// 날씨를 보여 주지 못한 까닭
enum WeatherFailure: String, Codable, Error, Sendable {
    /// 지금 위치를 물었는데 위치 권한이 없다
    case locationDenied
    /// 권한은 있는데 위치를 잡지 못했다
    case locationUnavailable
    /// 말한 지역을 찾지 못했다
    case placeNotFound
    /// 그 날짜의 예보가 없다 (지난 날, 열흘보다 먼 날)
    case noForecast
    /// 날씨를 받아오지 못했다 (연결, 서비스)
    case unavailable
}

/// 날씨를 받아온 그대로 (그곳의 지금과 며칠치). 카드는 여기서 물은 때에 맞는 부분만 고른다
struct WeatherSource: Equatable, Sendable {
    struct Now: Equatable, Sendable {
        var temperature: Int
        var feelsLike: Int
        var condition: String
        var symbol: String
    }

    struct Day: Equatable, Sendable {
        /// 그날 안의 한 시각 (그곳의 달력으로 어느 날인지만 쓴다)
        var date: Date
        var condition: String
        var symbol: String
        var high: Int
        var low: Int
        /// 비·눈이 올 확률 (0…1)
        var rainChance: Double
        /// 바람 (m/s)
        var wind: Double
        var uvIndex: Int
    }

    /// 한 시간의 날씨 (D104. 내 공간의 날씨 카드가 시간별 줄에 쓴다)
    struct Hour: Equatable, Sendable {
        var date: Date
        var symbol: String
        var temperature: Int
    }

    /// 찾은 지역의 이름. 지금 위치면 nil (이 기기의 위치는 이름으로도 남기지 않는다)
    var place: String?
    /// 그곳의 시간대 ("오늘·내일"은 그곳의 달력으로 센다)
    var timeZone: TimeZone
    var now: Now?
    var days: [Day]
    /// 지금부터의 시간별 날씨 (없을 수 있다)
    var hours: [Hour] = []
    /// 지금 위치의 동네 이름 ("안양시". D104). **화면에만 쓴다** — 대화 기록에 남기지 않고, 맥으로도 Claude로도 보내지 않는다
    /// (`place`와 따로 둔 까닭이다: `place`는 대화의 날씨 카드에 저장된다)
    var locality: String?
}

/// 날씨를 받아오는 곳 (실제: WeatherKit과 이 기기의 위치. 시험·데모: 앱이 만든 가상 날씨)
protocol WeatherProviding: Sendable {
    /// `place`가 nil이면 지금 위치의 날씨다
    func weather(place: String?) async -> Result<WeatherSource, WeatherFailure>
}

/// 대화에 그리는 날씨 카드 (D66). 대화 기록에 이대로 저장한다.
///
/// 맥(Claude)은 "날씨를 물었다, 어디·언제"만 정하고, 날씨는 이 기기가 Apple 날씨에서 받아 그린다.
/// 그래서 이 기기의 위치는 맥으로도 Claude로도 가지 않는다. 카드에 보인 내용 한 줄(`summary`)만 다음 말과 함께 맥에 알린다
struct WeatherCard: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case now, day, week }

    struct Now: Codable, Equatable, Sendable {
        var temperature: Int
        var feelsLike: Int
        var condition: String
        var symbol: String
    }

    struct Day: Codable, Equatable, Sendable {
        /// "오늘", "내일", "15일 (일)"
        var label: String
        var condition: String
        var symbol: String
        var high: Int
        var low: Int
        /// 비·눈이 올 확률 (%)
        var rainChance: Int
        /// 바람 (m/s)
        var wind: Int
        var uvIndex: Int
    }

    var kind: Kind
    /// 내가 말한 지역 (맥이 준 그대로). 지금 위치를 물었으면 nil
    var asked: String?
    /// 카드 머리에 쓸 지역 이름 (찾은 이름). 지금 위치면 nil
    var place: String?
    /// "지금", "오늘", "내일", "이번 주", "11월 15일 (일)"
    var period: String
    var now: Now?
    var days: [Day] = []
    var failure: WeatherFailure?
    var asOf: Date
    /// 이 카드에 보인 내용을 맥에 알렸는지 (한 번만 알린다)
    var reported = false

    /// 지금 위치를 물은 카드인지
    var isCurrentLocation: Bool { asked == nil }

    // MARK: - 만들기

    /// 받아온 날씨에서 물은 때에 맞는 부분을 골라 카드를 만든다.
    /// "오늘·내일"과 짚은 날짜는 그곳의 달력으로 센다 (다른 나라의 날씨를 물어도 그곳의 오늘이다)
    static func make(
        asked: String?, when: WeatherWhen, result: Result<WeatherSource, WeatherFailure>, now: Date = .now
    ) -> WeatherCard {
        let asked = asked?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        func failed(_ failure: WeatherFailure, place: String? = nil, timeZone: TimeZone = .current) -> WeatherCard {
            WeatherCard(
                kind: kind(for: when), asked: asked, place: place ?? asked,
                period: period(for: when, now: now, timeZone: timeZone), failure: failure, asOf: now
            )
        }
        guard case .success(let source) = result else {
            if case .failure(let failure) = result { return failed(failure) }
            return failed(.unavailable)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = source.timeZone
        let today = calendar.startOfDay(for: now)
        // 지금 위치를 물었으면 찾은 이름이 있어도 쓰지 않는다
        let place = asked == nil ? nil : (source.place?.nilIfEmpty ?? asked)
        func day(_ offset: Int) -> WeatherSource.Day? {
            guard let target = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return source.days.first { calendar.isDate($0.date, inSameDayAs: target) }
        }
        func card(_ kind: Kind, now current: WeatherSource.Now? = nil, days: [(String, WeatherSource.Day)]) -> WeatherCard {
            WeatherCard(
                kind: kind, asked: asked, place: place,
                period: period(for: kind == .day && when == .now ? .today : when, now: now, timeZone: source.timeZone),
                now: current.map { Now(temperature: $0.temperature, feelsLike: $0.feelsLike, condition: $0.condition, symbol: $0.symbol) },
                days: days.map { label, day in
                    Day(
                        label: label, condition: day.condition, symbol: day.symbol, high: day.high, low: day.low,
                        rainChance: Int((min(max(day.rainChance, 0), 1) * 100).rounded()),
                        wind: Int(max(day.wind, 0).rounded()), uvIndex: max(day.uvIndex, 0)
                    )
                },
                asOf: now
            )
        }

        switch when {
        case .now:
            let todays = day(0).map { [("오늘", $0)] } ?? []
            if let current = source.now { return card(.now, now: current, days: todays) }
            // 지금 날씨가 없으면 오늘 예보로 답한다
            return todays.isEmpty ? failed(.noForecast, place: place, timeZone: source.timeZone) : card(.day, days: todays)
        case .today:
            guard let found = day(0) else { return failed(.noForecast, place: place, timeZone: source.timeZone) }
            return card(.day, days: [("오늘", found)])
        case .tomorrow:
            guard let found = day(1) else { return failed(.noForecast, place: place, timeZone: source.timeZone) }
            return card(.day, days: [("내일", found)])
        case .date(let year, let month, let dayOfMonth):
            guard let target = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)),
                  let found = source.days.first(where: { calendar.isDate($0.date, inSameDayAs: target) }) else {
                return failed(.noForecast, place: place, timeZone: source.timeZone)
            }
            let offset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: target)).day
            return card(.day, days: [(offset == 0 ? "오늘" : offset == 1 ? "내일" : dayLabel(target, calendar: calendar), found)])
        case .week:
            let days: [(String, WeatherSource.Day)] = (0..<7).compactMap { offset in
                guard let found = day(offset) else { return nil }
                return (offset == 0 ? "오늘" : offset == 1 ? "내일" : dayLabel(found.date, calendar: calendar), found)
            }
            return days.isEmpty ? failed(.noForecast, place: place, timeZone: source.timeZone) : card(.week, days: days)
        }
    }

    private static func kind(for when: WeatherWhen) -> Kind {
        switch when {
        case .now: .now
        case .week: .week
        default: .day
        }
    }

    private static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    /// "15일 (일)"
    private static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.day, .weekday], from: date)
        return "\(parts.day ?? 0)일 (\(weekdays[((parts.weekday ?? 1) - 1) % 7]))"
    }

    private static func period(for when: WeatherWhen, now: Date, timeZone: TimeZone) -> String {
        switch when {
        case .now: return "지금"
        case .today: return "오늘"
        case .tomorrow: return "내일"
        case .week: return "이번 주"
        case .date(let year, let month, let day):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return "\(month)월 \(day)일" }
            let weekday = calendar.component(.weekday, from: date)
            return "\(month)월 \(day)일 (\(weekdays[(weekday - 1) % 7]))"
        }
    }

    // MARK: - 맥에 알리는 한 줄

    /// 맥에 알리는 글의 가장 긴 길이 (맥과 맞춘 값)
    static let summaryLimit = 300

    /// 카드에 보인 내용 한 줄. 다음 말과 함께 맥에 알려, 이어지는 말("그럼 우산 챙길까?")을 알아듣게 한다.
    /// 지역은 내가 말한 그대로 쓰고(찾은 이름이 아니다), 지금 위치는 "지금 위치"라고만 쓴다 (이 기기의 위치는 글로도 나가지 않는다)
    var summary: String {
        let head = "\(asked ?? "지금 위치") \(period)"
        if let failure {
            return String("\(head): 날씨를 보여 주지 못함 (\(failure.reason))".prefix(Self.summaryLimit))
        }
        let body: String
        switch kind {
        case .now:
            var parts: [String] = []
            if let now { parts.append("\(now.condition), \(now.temperature)도 (체감 \(now.feelsLike)도)") }
            if let today = days.first { parts.append("오늘 \(today.low)~\(today.high)도, 강수확률 \(today.rainChance)%") }
            body = parts.joined(separator: ", ")
        case .day:
            body = days.first.map { "\($0.condition), \($0.low)~\($0.high)도, 강수확률 \($0.rainChance)%" } ?? ""
        case .week:
            body = days.map { "\($0.label) \($0.condition) \($0.low)~\($0.high)도 비 \($0.rainChance)%" }.joined(separator: ", ")
        }
        return String("\(head): \(body)".prefix(Self.summaryLimit))
    }
}

extension WeatherFailure {
    /// 맥에 알리는 글에 쓰는 까닭 (짧게)
    var reason: String {
        switch self {
        case .locationDenied: "위치 권한 없음"
        case .locationUnavailable: "위치를 찾지 못함"
        case .placeNotFound: "지역을 찾지 못함"
        case .noForecast: "그 날짜의 예보 없음"
        case .unavailable: "날씨를 받아오지 못함"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
