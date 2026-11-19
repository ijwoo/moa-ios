import Foundation

// 예약해 둔 일 (D91. 맥의 D80, `routines`): 정한 때에 정한 말을 맥이 대신 건넨다.
// 목록과 실행 기록은 맥에 있다. 앱은 받아서 보여 주고, 켜고 끄고 지우기만 한다 — 이 기기에 따로 저장하지 않는다.

/// 예약 하나
struct AgentRoutine: Identifiable, Equatable, Sendable {
    /// 화면의 묶음 (참고 앱의 차례: 반복 · 일회성 · 일시 중지)
    enum Group: Int, CaseIterable, Sendable {
        case repeating, once, paused

        var title: String {
            switch self {
            case .repeating: "반복"
            case .once: "일회성"
            case .paused: "일시 중지"
            }
        }
    }

    let id: String
    var title: String
    /// 그때 맥이 대신 건네는 말
    var prompt: String
    var enabled: Bool
    /// "once" · "daily" · "weekly" (모르는 값은 반복으로 본다)
    var kind: String
    /// 언제인지 맥이 쓴 글 ("매일 오전 7:30"). 그대로 보여 준다
    var whenText: String
    var nextRunAt: Date?
    var lastRunAt: Date?
    /// 지난번 결과 (`done`·`task`·`needs_reply`·`needs_login`·`failed`·`missed`)
    var lastStatus: String?
    /// 한 번짜리가 이미 돌았다
    var done = false
    /// 지침 (D93): 예약마다 붙여 두는 긴 설명. 돌 때 할 말 뒤에 붙어 간다. 없으면 빈 글
    var notes = ""

    /// 맥이 받는 지침의 길이
    static let notesLimit = 4000

    var group: Group {
        if !enabled { return .paused }
        return kind == "once" ? .once : .repeating
    }

    /// 켜고 끌 수 있는지. 이미 돈 한 번짜리는 다시 켜도 돌 때가 없다
    var canToggle: Bool { !done }

    /// 묶음마다 모아서, 참고 앱의 차례로. 빈 묶음은 빠진다
    static func grouped(_ routines: [AgentRoutine]) -> [(group: Group, routines: [AgentRoutine])] {
        Group.allCases.compactMap { group in
            let items = routines.filter { $0.group == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    /// 지난번에 어떻게 됐는지 한마디 (모르는 값이면 nil)
    static func statusText(_ status: String?) -> String? {
        switch status {
        case "done": "답이 왔어요"
        case "task": "작업으로 진행했어요"
        case "needs_reply": "되물음이 있었어요"
        case "needs_login": "로그인이 필요해 멈췄어요"
        case "failed": "하지 못했어요"
        case "missed": "맥이 꺼져 있어 놓쳤어요"
        default: nil
        }
    }

    /// 줄 아래의 작은 글: 다음에 도는 때, 없으면 지난번 결과
    func detail(now: Date = .now, calendar: Calendar = .current) -> String? {
        if enabled, !done, let nextRunAt { return "다음 \(Self.dayAndTime(nextRunAt, now: now, calendar: calendar))" }
        if done { return Self.statusText(lastStatus).map { "끝났어요 · \($0)" } ?? "끝났어요" }
        return Self.statusText(lastStatus).map { "지난번: \($0)" }
    }

    /// "오늘 오전 7:30" · "내일 오전 7:30" · "11월 20일 오전 7:30"
    static func dayAndTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "ko_KR"), calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return "오늘 \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "내일 \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "어제 \(time)" }
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)월 \(parts.day ?? 0)일 \(time)"
    }
}

/// 예약이 한 번 돈 기록 (맥이 파일에 남긴다, 200건까지. D93 — 전에는 맥의 메모리에만 있었다)
struct RoutineRun: Identifiable, Equatable, Sendable {
    struct Bubble: Equatable, Sendable {
        var text: String
        var writer: ReplyWriter?
    }

    /// `rr_…` (작업 번호가 아니다)
    let id: String
    var routineID: String?
    var title: String
    var status: String
    var ranAt: Date?
    /// 그때 생긴 대화. 이 번호로 이어서 말할 수 있다
    var conversationID: String?
    /// 그때 맥이 한 답 (대화의 말풍선과 같은 꼴)
    var replies: [Bubble] = []
    /// 작업이 됐으면 그 번호
    var taskID: String?
    /// 그 작업이 어떻게 끝났는지 (`completed`·`failed`·`needs_input`. 끝나기 전에는 없다, D93)
    var taskStatus: String?
    /// 그 작업의 결과 글 (작업 자체는 맥이 다시 켜지면 사라져, 기록에 남긴 것)
    var taskResult: [String] = []

    /// 열어 볼 것이 있는지 (답이 있거나 작업이 됐다)
    var canOpen: Bool { !replies.isEmpty || taskID != nil || !taskResult.isEmpty }

    /// 기록 한 줄의 한마디: 작업이 끝났으면 그 결과를, 아니면 실행의 결과를 말한다
    var statusText: String? {
        switch taskStatus {
        case "completed": "작업을 마쳤어요"
        case "failed": "작업을 끝내지 못했어요"
        case "needs_input": "작업이 답을 기다리다 멈췄어요"
        default: AgentRoutine.statusText(status)
        }
    }

    /// 날짜별로 묶는다 (최근 날부터, 받은 차례 그대로). 때를 모르는 기록은 맨 뒤 한 묶음
    static func byDay(_ runs: [RoutineRun], now: Date = .now, calendar: Calendar = .current) -> [(day: String, runs: [RoutineRun])] {
        var groups: [(day: String, runs: [RoutineRun])] = []
        for run in runs {
            let day = run.ranAt.map { dayText($0, now: now, calendar: calendar) } ?? "때를 알 수 없음"
            if let index = groups.firstIndex(where: { $0.day == day }) {
                groups[index].runs.append(run)
            } else {
                groups.append((day, [run]))
            }
        }
        return groups
    }

    /// "오늘" · "어제" · "11월 14일" (해가 다르면 "2025년 12월 30일")
    static func dayText(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "오늘" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "어제" }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let text = "\(parts.month ?? 0)월 \(parts.day ?? 0)일"
        return parts.year == calendar.component(.year, from: now) ? text : "\(parts.year ?? 0)년 \(text)"
    }

    /// 시각만: "오전 7:30"
    static func timeText(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "ko_KR"), calendar: calendar, timeZone: calendar.timeZone))
    }
}

/// 맥이 준 예약·실행 기록을 읽는다. 꼴이 어긋난 항목은 그것만 버린다 (목록 전체를 버리지 않는다)
enum RoutineDecoding {
    struct RoutineDTO: Decodable {
        struct Schedule: Decodable { let kind: String? }
        let id: String
        let title: String?
        let prompt: String?
        let enabled: Bool?
        let schedule: Schedule?
        let when_text: String?
        let next_run_at: String?
        let last_run_at: String?
        let last_status: String?
        let done: Bool?
        let notes: String?

        var routine: AgentRoutine? {
            guard AgentHTTPClient.isPathSafe(id) else { return nil }
            let prompt = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentRoutine(
                id: id, title: title.isEmpty ? (prompt.isEmpty ? "예약" : prompt) : title, prompt: prompt, enabled: enabled ?? true,
                kind: schedule?.kind ?? "", whenText: (when_text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                nextRunAt: AgentTime.date(next_run_at), lastRunAt: AgentTime.date(last_run_at), lastStatus: last_status, done: done ?? false,
                notes: String((notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(AgentRoutine.notesLimit))
            )
        }
    }

    struct RunDTO: Decodable {
        struct Reply: Decodable {
            let text: String?
            let by: String?
        }
        let id: String
        let routine_id: String?
        let title: String?
        let status: String?
        let ran_at: String?
        let conversation_id: String?
        let replies: [Lossy<Reply>]?
        let task_id: String?
        let task_status: String?
        let task_result: [Lossy<String>]?

        var run: RoutineRun? {
            guard AgentHTTPClient.isPathSafe(id) else { return nil }
            let bubbles = (replies ?? []).compactMap(\.value).compactMap { reply -> RoutineRun.Bubble? in
                guard let text = reply.text, !text.isEmpty else { return nil }
                return RoutineRun.Bubble(text: text, writer: reply.by.flatMap(ReplyWriter.init(rawValue:)))
            }
            return RoutineRun(
                id: id, routineID: routine_id, title: (title ?? "").isEmpty ? "예약" : title ?? "예약", status: status ?? "",
                ranAt: AgentTime.date(ran_at), conversationID: conversation_id.flatMap { AgentHTTPClient.isPathSafe($0) ? $0 : nil },
                replies: bubbles, taskID: task_id.flatMap { AgentHTTPClient.isPathSafe($0) ? $0 : nil },
                taskStatus: task_status,
                taskResult: (task_result ?? []).compactMap(\.value).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            )
        }
    }

    /// 읽지 못한 항목은 nil이 된다 (배열 전체가 실패하지 않는다)
    struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// 대화 응답에 붙어 오는 목록 (`routines`). 없거나 배열이 아니면 nil — 그 응답의 답은 그대로 읽는다
    struct ReplyList: Decodable {
        let routines: [AgentRoutine]?
        init(from decoder: Decoder) throws {
            let items = try? [Lossy<RoutineDTO>](from: decoder)
            routines = items.map { $0.compactMap { $0.value?.routine } }
        }
    }

    static func routines(data: Data, status: Int) throws -> [AgentRoutine] {
        struct Wrapper: Decodable { let routines: [Lossy<RoutineDTO>] }
        guard (200..<300).contains(status) else { throw AgentHTTPClient.decodeError(data: data, status: status) }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { throw AgentError.invalidResponse }
        return wrapper.routines.compactMap { $0.value?.routine }
    }

    static func runs(data: Data, status: Int) throws -> [RoutineRun] {
        struct Wrapper: Decodable { let runs: [Lossy<RunDTO>] }
        guard (200..<300).contains(status) else { throw AgentHTTPClient.decodeError(data: data, status: status) }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { throw AgentError.invalidResponse }
        return wrapper.runs.compactMap { $0.value?.run }
    }

    /// 실행 하나 (`{"run": {…}}`). 그런 기록이 없으면(404) nil
    static func run(data: Data, status: Int) throws -> RoutineRun? {
        struct Wrapper: Decodable { let run: RunDTO }
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw AgentHTTPClient.decodeError(data: data, status: status) }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { throw AgentError.invalidResponse }
        return wrapper.run.run
    }
}

/// 예약 화면의 목록. 맥이 `routines`를 알릴 때만 사이드바에 들어가는 줄이 보인다
@MainActor
@Observable
final class RoutinesModel {
    /// 예약 화면의 "+"가 대화에 보내는 말 (맥과 맞춘 문장: 맥이 할 일과 때를 되묻고 대화로 예약을 만든다)
    nonisolated static let newPrompt = "새 예약 작업을 만들고 싶어."

    private let agent: (any AgentProviding)?
    private(set) var routines: [AgentRoutine] = []
    /// 최근에 돈 기록 (최근 것부터)
    private(set) var runs: [RoutineRun] = []
    /// 맥이 예약을 할 줄 아는지
    private(set) var isOffered = false
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// 마지막으로 받으려다 실패했는지. 참이면 보이는 목록은 예전 것이다
    private(set) var loadFailed = false
    /// 켜고 끄거나 지우는 중인 예약
    private(set) var busy: Set<String> = []
    /// 예약마다 받은 기록 (상세 화면용. 최근 것부터)
    private(set) var history: [String: [RoutineRun]] = [:]
    /// 기록을 받으려다 실패한 예약
    private(set) var historyFailed: Set<String> = []
    /// 한 예약의 기록을 한 번에 받는 수
    static let historyLimit = 50
    /// 방금 한 일이 되지 않았을 때의 한마디
    var notice: String?

    init(agent: (any AgentProviding)?) {
        self.agent = agent
    }

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
        guard await agent.supports(AgentFeature.routines) else {
            isOffered = false
            routines = []
            runs = []
            loadFailed = false
            return
        }
        isOffered = true
        do {
            routines = try await agent.routines()
            // 실행 기록은 없어도 목록은 보여 준다
            runs = (try? await agent.routineRuns()) ?? runs
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// 대화로 예약을 만들거나 껐을 때, 그 응답에 붙어 온 바뀐 뒤의 목록
    func replace(with routines: [AgentRoutine]) {
        self.routines = routines
        isOffered = true
        hasLoaded = true
        loadFailed = false
    }

    func routine(id: String?) -> AgentRoutine? {
        guard let id else { return nil }
        return routines.first { $0.id == id }
    }

    /// 켜거나 끈다. 맥이 받아들인 뒤에만 화면이 바뀐다
    func setEnabled(_ enabled: Bool, id: String) async {
        guard let agent, !busy.contains(id) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            routines = try await agent.setRoutine(id: id, enabled: enabled)
            notice = nil
        } catch {
            notice = Self.failure(error, doing: enabled ? "켜지" : "끄지")
        }
    }

    /// 지침을 바꾼다 (빈 글이면 지운다). 맥이 받아들였으면 true
    func setNotes(_ notes: String, id: String) async -> Bool {
        guard let agent, !busy.contains(id) else { return false }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            routines = try await agent.setRoutineNotes(id: id, notes: String(notes.prefix(AgentRoutine.notesLimit)))
            notice = nil
            return true
        } catch {
            notice = Self.failure(error, doing: "지침을 저장하지")
            return false
        }
    }

    /// 한 예약의 기록을 받는다. 그 예약의 것만 남긴다 (예전 맥은 가려 주지 않고 모두 준다)
    func loadHistory(id: String) async {
        guard let agent else { return }
        do {
            history[id] = try await agent.routineRuns(routineID: id, limit: Self.historyLimit).filter { $0.routineID == id }
            historyFailed.remove(id)
        } catch {
            historyFailed.insert(id)
        }
    }

    func delete(id: String) async {
        guard let agent, !busy.contains(id) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            routines = try await agent.deleteRoutine(id: id)
            history[id] = nil
            notice = nil
        } catch {
            notice = Self.failure(error, doing: "지우지")
        }
    }

    static func failure(_ error: Error, doing: String) -> String {
        switch error as? AgentError {
        case .unreachable?: "맥에 연결되지 않아 \(doing) 못했어요."
        default: "\(doing) 못했어요. 목록을 아래로 당겨 새로 받은 뒤 다시 해 주세요."
        }
    }
}
