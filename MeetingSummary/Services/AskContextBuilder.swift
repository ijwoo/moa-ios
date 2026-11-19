import Foundation

/// 질문 하나에 대해 프록시로 보낼 자료를 고른다.
///
/// - 모든 회의를 다 보내면 비용이 커지므로, 질문 낱말이 많이 나오는 회의부터 글자 수 한도까지 담는다.
/// - 맞는 낱말이 하나도 없으면("지난번 회의 정리해 줘" 등) 최근 회의부터 담는다.
/// - 질문이 "오늘 회의", "어제 회의", "11월 10일 회의"처럼 회의한 날을 직접 가리키면 그 날 회의만 담는다.
///   그 날 회의가 없으면 평소대로 고르고, 없다는 사실을 함께 보낸다 (다른 날 회의를 그 날 것처럼 답하지 않게).
/// - 담지 못한 회의는 제목·날짜·주제만 목록으로 보낸다 (Claude가 "그 회의는 못 봤다"고 말할 수 있게).
/// - 말풍선마다 짧은 번호(m1-u3)를 붙이고, 번호 → 실제 회의·말풍선 대응표를 함께 돌려준다.
enum AskContextBuilder {
    /// 한 번에 보내는 말풍선 글자 수 한도 (대략 4~6만 토큰)
    static let characterBudget = 60_000
    /// 내용 없이 목록으로만 보내는 회의 수 한도
    static let maxListedMeetings = 30

    struct Reference: Equatable, Sendable {
        let meetingID: UUID
        /// 예전 회의(말풍선 없음)는 nil
        let utteranceID: UUID?
        let start: TimeInterval?
        let text: String
    }

    struct Context {
        let request: AskRequest
        let references: [String: Reference]
    }

    /// 회의 하나를 보낼 수 있는 형태로 옮긴 것 (SwiftData 모델과 분리해 테스트하기 쉽게)
    struct Source: Sendable {
        struct Line: Sendable {
            let id: UUID?
            let start: TimeInterval
            let text: String
        }
        let id: UUID
        let title: String
        let date: Date
        let topic: String?
        let summary: String?
        let lines: [Line]

        var characterCount: Int { lines.reduce(0) { $0 + $1.text.count } }
    }

    @MainActor
    static func sources(from meetings: [Meeting]) -> [Source] {
        meetings.compactMap { meeting in
            let utterances = meeting.sortedUtterances
            let lines: [Source.Line] = utterances.isEmpty
                ? (meeting.transcript.isEmpty ? [] : [.init(id: nil, start: 0, text: meeting.transcript)])
                : utterances.map { .init(id: $0.id, start: $0.start, text: $0.text) }
            guard !lines.isEmpty else { return nil }
            let summary = meeting.summary.map { [$0.topic, $0.body].filter { !$0.isEmpty }.joined(separator: " — ") }
            return Source(
                id: meeting.id, title: meeting.title, date: meeting.date,
                topic: meeting.summary?.topic, summary: summary, lines: lines
            )
        }
    }

    /// - Parameter dayText: 회의한 날을 가리키는 말을 찾을 글. 맥이 되물어 답이 이어진 경우처럼,
    ///   지금 메시지에는 날짜가 없고 처음 부탁에 있을 때 그 글을 함께 넘긴다. 없으면 `question`에서 찾는다.
    static func build(
        question: String, history: [AskRequest.Turn], sources: [Source], budget: Int = characterBudget,
        dayText: String? = nil, now: Date = .now, calendar: Calendar = .current
    ) -> Context {
        let reference = dayReference(in: dayText ?? question, now: now, calendar: calendar)
        var words = keywords(from: question)
        // 날짜를 가리킨 말("11월", "10일")이 회의 내용 속 같은 낱말과 맞아 순위를 바꾸지 않게 한다
        if let reference { words.removeAll { reference.words.contains($0) } }
        let onDay: Set<UUID> = Set(sources.filter { reference?.interval.contains($0.date) == true }.map(\.id))
        let ranked = sources
            .map { (source: $0, score: score($0, keywords: words)) }
            .sorted { a, b in
                // 가리킨 날의 회의가 먼저
                let dayA = onDay.contains(a.source.id), dayB = onDay.contains(b.source.id)
                if dayA != dayB { return dayA }
                if a.score != b.score { return a.score > b.score }
                return a.source.date > b.source.date
            }

        var remaining = budget
        var included: [AskRequest.Meeting] = []
        var listed: [AskRequest.ListedMeeting] = []
        var references: [String: Reference] = [:]

        for (index, entry) in ranked.enumerated() {
            let source = entry.source
            let meetingRef = "m\(index + 1)"
            // 가리킨 날에 회의가 있으면 그 날 회의만 내용을 보낸다.
            // 그렇지 않을 때는, 낱말이 맞는 회의가 하나라도 있으면 맞지 않는 회의는 내용을 보내지 않는다
            let relevant = onDay.isEmpty
                ? entry.score > 0 || !ranked.contains { $0.score > 0 }
                : onDay.contains(source.id)
            guard relevant, remaining > 200 else {
                if listed.count < maxListedMeetings {
                    listed.append(.init(ref: meetingRef, title: source.title, date: format(source.date), topic: source.topic))
                }
                continue
            }

            let lines = select(source.lines, keywords: words, budget: remaining)
            remaining -= lines.reduce(0) { $0 + $1.line.text.count }
            var utterances: [AskRequest.Utterance] = []
            for (position, line) in lines {
                let ref = "\(meetingRef)-u\(position + 1)"
                utterances.append(.init(ref: ref, start: line.start, text: line.text))
                references[ref] = Reference(meetingID: source.id, utteranceID: line.id, start: line.id == nil ? nil : line.start, text: line.text)
            }
            included.append(.init(
                ref: meetingRef, title: source.title, date: format(source.date), summary: source.summary, utterances: utterances
            ))
        }

        var request = AskRequest(question: question, history: history, meetings: included, otherMeetings: listed)
        request.today = formatDay(now, calendar: calendar, weekday: true)
        request.day = reference.map { .init(label: $0.label, found: !onDay.isEmpty) }
        return Context(request: request, references: references)
    }

    // MARK: - 회의한 날을 가리키는 말

    /// 질문이 가리킨 날 (하루 또는 한 주)
    struct DayReference: Equatable, Sendable {
        /// 모델과 사용자에게 보여 줄 표기. 예: "오늘(11월 12일)", "11월 10일", "이번 주(11월 9일~11월 15일)"
        let label: String
        let interval: DateInterval
        /// 날짜를 가리키는 데 쓴 낱말 (내용 찾기에는 쓰지 않는다)
        let words: [String]
    }

    /// "오늘 회의", "어제 한 미팅", "11월 10일 주간 회의", "지난주 회의"처럼 날짜 말이 회의를 직접 꾸밀 때만 찾는다.
    /// 사이에는 시간대("오전"), "한"·"했던", 회의 이름 한 낱말("주간")까지만 올 수 있다.
    /// "오늘까지 할 일 뭐였지?", "오늘까지 회의록 보내기로 했지?"의 "오늘"은 회의한 날이 아니므로 찾지 않는다 (잘못 걸러 내면 답을 놓친다).
    static func dayReference(in text: String, now: Date, calendar: Calendar = .current) -> DayReference? {
        let pattern = /(?<day>오늘|어제|그저께|그제|이번\s?주|지난\s?주|저번\s?주|(?<month>\d{1,2})월\s?(?<date>\d{1,2})일)(?:자|의|에)?(?:\s+(?:(?:오전|오후|아침|점심|저녁)에?\s*)?(?:(?:한|했던|있었던|녹음한|진행한|열린)\s*)?(?:[가-힣A-Za-z0-9]{1,6}\s+)?|\s*)(?:회의|미팅|면담|녹음|통화)/
        guard let match = text.firstMatch(of: pattern) else { return bareDay(in: text, now: now, calendar: calendar) }
        let word = String(match.output.day)
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, _ name: String) -> DayReference? {
            guard let start = calendar.date(byAdding: .day, value: offset, to: today),
                  let interval = calendar.dateInterval(of: .day, for: start) else { return nil }
            return DayReference(label: "\(name)(\(formatDay(start, calendar: calendar)))", interval: interval, words: keywords(from: word))
        }
        func week(_ offset: Int, _ name: String) -> DayReference? {
            // 한 주는 월요일부터 일요일까지로 본다
            var monday = calendar
            monday.firstWeekday = 2
            guard let anchor = monday.date(byAdding: .day, value: 7 * offset, to: today),
                  let interval = monday.dateInterval(of: .weekOfYear, for: anchor),
                  let last = monday.date(byAdding: .day, value: 6, to: interval.start) else { return nil }
            let label = "\(name)(\(formatDay(interval.start, calendar: calendar))~\(formatDay(last, calendar: calendar)))"
            return DayReference(label: label, interval: interval, words: keywords(from: word))
        }
        switch word.filter({ !$0.isWhitespace }) {
        case "오늘": return day(0, "오늘")
        case "어제": return day(-1, "어제")
        case "그제", "그저께": return day(-2, "그저께")
        case "이번주": return week(0, "이번 주")
        case "지난주", "저번주": return week(-1, "지난주")
        default:
            // "11월 10일": 오늘보다 뒤의 날짜면 지난해로 본다 (녹음한 회의는 과거에만 있다)
            guard let month = match.output.month.flatMap({ Int($0) }), let date = match.output.date.flatMap({ Int($0) }) else { return nil }
            var year = calendar.component(.year, from: now)
            for _ in 0..<2 {
                let parts = DateComponents(year: year, month: month, day: date)
                if let start = calendar.date(from: parts), calendar.dateComponents([.month, .day], from: start) == DateComponents(month: month, day: date),
                   start <= today, let interval = calendar.dateInterval(of: .day, for: start) {
                    return DayReference(label: formatDay(start, calendar: calendar), interval: interval, words: keywords(from: word))
                }
                year -= 1
            }
            return nil
        }
    }

    /// "10일 회의"처럼 달 없이 날만 말한 경우: 오늘까지에서 가장 가까운 그 날로 본다 (이번 달에 아직 오지 않은 날이면 지난달).
    /// 회의를 가리키는 말이 바로 뒤에 붙을 때만 읽는다 ("3일 동안 회의"는 날짜가 아니다)
    private static func bareDay(in text: String, now: Date, calendar: Calendar) -> DayReference? {
        let pattern = /(?:^|[^\d월\s])\s*(?<date>\d{1,2})일(?:자|의|에)?\s*(?:회의|미팅|면담|녹음|통화)/
        guard let match = text.firstMatch(of: pattern), let date = Int(match.output.date), (1...31).contains(date) else { return nil }
        let today = calendar.startOfDay(for: now)
        var parts = calendar.dateComponents([.year, .month], from: today)
        for _ in 0..<2 {
            parts.day = date
            if let start = calendar.date(from: parts), calendar.component(.day, from: start) == date,
               calendar.component(.month, from: start) == parts.month,
               start <= today, let interval = calendar.dateInterval(of: .day, for: start) {
                return DayReference(label: formatDay(start, calendar: calendar), interval: interval, words: keywords(from: "\(date)일"))
            }
            // 지난달 (1월이면 지난해 12월)
            parts.day = 1
            guard let first = calendar.date(from: parts), let previous = calendar.date(byAdding: .month, value: -1, to: first) else { return nil }
            parts = calendar.dateComponents([.year, .month], from: previous)
        }
        return nil
    }

    /// "11월 12일" 또는 "11월 12일 (목)"
    static func formatDay(_ date: Date, calendar: Calendar = .current, weekday: Bool = false) -> String {
        let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
        let text = "\(parts.month ?? 0)월 \(parts.day ?? 0)일"
        guard weekday, let index = parts.weekday, (1...7).contains(index) else { return text }
        return text + " (\(["일", "월", "화", "수", "목", "금", "토"][index - 1]))"
    }

    /// 한도 안이면 전부, 넘으면 낱말이 나온 말풍선과 그 앞뒤 2개씩을 고른다 (원래 번호 유지).
    static func select(
        _ lines: [Source.Line], keywords: [String], budget: Int
    ) -> [(position: Int, line: Source.Line)] {
        let total = lines.reduce(0) { $0 + $1.text.count }
        if total <= budget { return Array(lines.enumerated()).map { ($0.offset, $0.element) } }

        var picked = IndexSet()
        for (i, line) in lines.enumerated() where keywords.contains(where: { line.text.localizedCaseInsensitiveContains($0) }) {
            picked.insert(integersIn: max(0, i - 2)...min(lines.count - 1, i + 2))
        }
        if picked.isEmpty { picked.insert(integersIn: 0..<lines.count) } // 맞는 곳이 없으면 앞에서부터

        var result: [(Int, Source.Line)] = []
        var used = 0
        for i in picked {
            let line = lines[i]
            // 말풍선 하나가 한도보다 길면(예전 회의 원문) 잘라서 넣는다
            let text = line.text.count > budget - used ? String(line.text.prefix(max(0, budget - used))) : line.text
            guard !text.isEmpty else { break }
            result.append((i, Source.Line(id: line.id, start: line.start, text: text)))
            used += text.count
            if used >= budget { break }
        }
        return result
    }

    /// 질문에서 찾을 낱말: 2글자 이상, 흔한 조사·의문 표현 제거
    static func keywords(from question: String) -> [String] {
        let stopwords: Set<String> = [
            "뭐야", "뭐였지", "뭐였어", "뭐지", "무엇", "언제", "어떻게", "어디", "누가", "누구", "왜", "했지", "했어",
            "있어", "있었지", "알려줘", "알려", "정리", "정리해", "정리해줘", "해줘", "회의", "회의에서", "지난", "지난번",
            "그거", "그때", "내용", "얘기", "관련", "대해", "대해서",
            // 날짜를 가리키는 말: 회의 내용에 "오늘"이 많이 나온다고 그 회의가 오늘 회의는 아니다
            "오늘", "어제", "그제", "그저께",
        ]
        let particles = ["에서는", "에서", "으로", "까지", "부터", "한테", "에게", "이랑", "랑", "은", "는", "이", "가", "을", "를", "에", "의", "도", "로", "와", "과", "께"]
        return question
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { word -> String in
                var w = word.lowercased()
                if !stopwords.contains(w), let p = particles.first(where: { w.hasSuffix($0) && w.count - $0.count >= 2 }) {
                    w.removeLast(p.count)
                }
                return w
            }
            .filter { $0.count >= 2 && !stopwords.contains($0) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// 제목 3점, 요약 2점, 대화 1점 (낱말이 나온 횟수 기준)
    static func score(_ source: Source, keywords: [String]) -> Int {
        keywords.reduce(0) { total, word in
            total
                + 3 * occurrences(of: word, in: source.title)
                + 2 * occurrences(of: word, in: source.summary ?? "")
                + source.lines.reduce(0) { $0 + occurrences(of: word, in: $1.text) }
        }
    }

    private static func occurrences(of word: String, in text: String) -> Int {
        text.lowercased().components(separatedBy: word).count - 1
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E) a h:mm"
        return f
    }()

    static func format(_ date: Date) -> String { dateFormatter.string(from: date) }
}
