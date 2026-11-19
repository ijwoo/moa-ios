import Foundation

/// 할 일의 기한 문구("금요일", "다음 주 화요일", "11월 20일" 등)를 날짜로 바꾼 **제안**을 만든다.
///
/// 원문에 없는 기한을 만들지 않기 위해, 이 값은 미리알림에 넣기 전에 사용자에게 보여 주고 확인받는 용도로만 쓴다.
/// 해석이 애매한 문구("다음 주 안", "출시 전")는 제안하지 않는다(nil).
enum DueDateSuggester {
    private static let weekdays: [Character: Int] = ["일": 1, "월": 2, "화": 3, "수": 4, "목": 5, "금": 6, "토": 7]

    static func suggest(from text: String?, now: Date = .now, calendar: Calendar = Self.koreanCalendar) -> Date? {
        guard let raw = text?.replacingOccurrences(of: " ", with: ""), !raw.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        func add(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: today) }

        if raw.hasPrefix("오늘") { return today }
        if raw.hasPrefix("내일") { return add(1) }
        if raw.hasPrefix("모레") { return add(2) }

        if raw.contains("이달말") || raw.contains("이번달말") || raw.contains("월말") {
            guard let range = calendar.range(of: .day, in: .month, for: today),
                  let start = calendar.date(from: calendar.dateComponents([.year, .month], from: today))
            else { return nil }
            return calendar.date(byAdding: .day, value: range.count - 1, to: start)
        }

        // N월 N일
        if let match = raw.firstMatch(of: /(\d{1,2})월(\d{1,2})일/),
           let month = Int(match.1), let day = Int(match.2) {
            var components = calendar.dateComponents([.year], from: today)
            components.month = month
            components.day = day
            guard var date = calendar.date(from: components) else { return nil }
            // 한 달 넘게 지난 날짜면 내년으로 본다
            if date < (add(-30) ?? today) { date = calendar.date(byAdding: .year, value: 1, to: date) ?? date }
            return date
        }

        // (이번 주|다음 주) X요일
        if let match = raw.firstMatch(of: /(이번주|다음주|담주)?([월화수목금토일])요일/),
           let target = weekdays[match.2.first!] {
            let isNextWeek = match.1 == "다음주" || match.1 == "담주"
            let current = calendar.component(.weekday, from: today)
            // 월요일 시작 주 기준 요일 위치 (월=0 … 일=6)
            let position = { (weekday: Int) in (weekday + 5) % 7 }
            var delta = position(target) - position(current)
            if isNextWeek {
                delta += 7
            } else if delta < 0 {
                // "금요일"인데 이번 주 금요일이 지났으면 다음 금요일
                delta += 7
            }
            return add(delta)
        }
        return nil
    }

    static var koreanCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }
}
