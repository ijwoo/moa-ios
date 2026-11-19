import Foundation

// 오래 가는 기억 (D151, 맥의 D129): 맥이 대화에서 정리해 둔 요약본(마크다운)과 지난 대화 보관함.
// 요약본은 맥이 대화를 판단할 때마다 함께 보고, 대화가 15분 잠잠하면 맥이 다시 고쳐 쓴다. 앱은 화면을 열 때 받는다 (알림 없음).
// 앱 쪽 명세: local-ai-agent docs/API.md "오래 가는 기억 — /v1/memory".
//
// - 요약본과 찾은 대화는 화면에만 그린다. 앱에 저장하지도, 로그에 남기지도 않는다
// - 고친 글은 맥이 비밀 꼴(비밀번호·카드·계좌·주민번호·인증 코드)을 지우고 3000자로 잘라 저장한다. 앱은 맥이 돌려준 글을 보인다
// - 모두 지우기는 되돌릴 수 없다. 앱이 확인을 받은 뒤에만 부른다

/// 맥의 요약본과 그 상태 (`GET /v1/memory`)
struct AgentMemory: Equatable, Sendable {
    /// 요약본이 마지막으로 어떻게 바뀌었는지
    enum Source: String, Sendable {
        /// 맥이 대화에서 정리했다
        case digest
        /// 사용자가 고쳤다
        case user
        /// 되돌렸다
        case undo
    }

    var profile: String
    /// 보관한 지난 대화의 말 수
    var turns: Int
    /// 보관함이 시작된 날 ("2026-11-18")
    var since: String?
    var updatedAt: Date?
    var source: Source?

    /// 맥에 보낼 수 있는 길이
    static let sendLimit = 6000
    /// 맥이 저장하는 길이 (넘으면 잘린다)
    static let savedLimit = 3000

    var isEmpty: Bool { profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// 지난 대화에서 찾은 말 하나 (`GET /v1/memory/search`)
struct MemoryHit: Equatable, Sendable, Identifiable {
    let id: Int
    /// 맥이 적은 때 ("2026-11-11 20:10")
    let when: String
    /// 내가 한 말인지 (아니면 모아의 말)
    let isMine: Bool
    let text: String
    /// 바로 뒤 상대의 말 (없으면 nil)
    let next: String?

    static let textLimit = 400
}

/// 요약본을 묶음으로 나눈 것. "## 나" 같은 줄이 묶음의 제목, "- "로 시작하는 줄이 항목이다
struct MemorySection: Equatable, Sendable, Identifiable {
    var id: Int
    var title: String?
    var lines: [String]

    /// 요약본을 묶음으로 나눈다. 제목 앞의 글은 제목 없는 묶음이 되고, 항목이 없는 묶음은 뺀다
    static func sections(_ profile: String) -> [MemorySection] {
        var result: [MemorySection] = []
        var current = MemorySection(id: 0, title: nil, lines: [])
        func flush() {
            if !current.lines.isEmpty { result.append(current) }
        }
        for raw in profile.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                flush()
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                current = MemorySection(id: result.count + 1, title: title.isEmpty ? nil : title, lines: [])
            } else if !line.isEmpty {
                var item = line
                for mark in ["- ", "* ", "• "] where item.hasPrefix(mark) {
                    item = String(item.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
                }
                if !item.isEmpty { current.lines.append(item) }
            }
        }
        flush()
        return result.enumerated().map { index, section in
            var section = section
            section.id = index
            return section
        }
    }
}

enum MemoryDecoding {
    static func memory(data: Data, status: Int) throws -> AgentMemory {
        struct DTO: Decodable {
            let profile: String?
            let turns: Int?
            let since: String?
            let profile_updated_at: String?
            let profile_by: String?
        }
        guard (200..<300).contains(status) else { throw AgentHTTPClient.decodeError(data: data, status: status) }
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data) else { throw AgentError.invalidResponse }
        return AgentMemory(
            profile: dto.profile ?? "", turns: max(0, dto.turns ?? 0),
            since: dto.since?.isEmpty == false ? dto.since : nil,
            updatedAt: ActivityDecoding.date(dto.profile_updated_at),
            source: dto.profile_by.flatMap(AgentMemory.Source.init(rawValue:))
        )
    }

    /// 고치기·되돌리기의 답: 맥이 저장한 요약본
    static func profile(data: Data, status: Int) throws -> String {
        struct DTO: Decodable { let profile: String }
        guard (200..<300).contains(status) else { throw AgentHTTPClient.decodeError(data: data, status: status) }
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data) else { throw AgentError.invalidResponse }
        return dto.profile
    }

    static func hits(data: Data, status: Int) throws -> [MemoryHit] {
        struct DTO: Decodable {
            struct Hit: Decodable {
                let when: String?
                let role: String?
                let text: String?
                let next: String?
            }
            let hits: [Hit]
        }
        guard (200..<300).contains(status) else { throw AgentHTTPClient.decodeError(data: data, status: status) }
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data) else { throw AgentError.invalidResponse }
        return dto.hits.enumerated().compactMap { index, hit in
            guard let text = ActivityDecoding.clean(hit.text, limit: MemoryHit.textLimit) else { return nil }
            return MemoryHit(
                id: index, when: hit.when ?? "", isMine: hit.role == "user", text: text,
                next: ActivityDecoding.clean(hit.next, limit: MemoryHit.textLimit)
            )
        }
    }

    static func cleared(data: Data, status: Int) throws {
        struct DTO: Decodable { let ok: Bool? }
        guard (200..<300).contains(status) else { throw AgentHTTPClient.decodeError(data: data, status: status) }
        guard (try? JSONDecoder().decode(DTO.self, from: data))?.ok == true else { throw AgentError.invalidResponse }
    }
}

/// 기억 화면의 상태. 맥이 `memory`를 알릴 때만 내 정보에 "기억" 줄이 생긴다
@MainActor
@Observable
final class MemoryModel {
    private let agent: (any AgentProviding)?
    private(set) var memory: AgentMemory?
    /// 맥이 기억을 할 줄 아는지
    private(set) var isOffered = false
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var loadFailed = false
    /// 고치기·되돌리기·지우기 중
    private(set) var isChanging = false
    /// 방금 한 일의 한마디 (되지 않았을 때, 맥이 글을 줄였을 때)
    var notice: String?

    private(set) var hits: [MemoryHit] = []
    /// 마지막으로 찾은 말 (찾은 적이 없으면 nil)
    private(set) var searched: String?
    private(set) var isSearching = false
    private(set) var searchFailed = false

    /// 찾을 수 있는 말의 길이
    nonisolated static let queryLimit = 100

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
        guard await agent.supports(AgentFeature.memory) else {
            isOffered = false
            memory = nil
            loadFailed = false
            return
        }
        isOffered = true
        do {
            memory = try await agent.memory()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// 고친 요약본을 맥에 저장한다. 맥이 저장한 글로 화면을 바꾼다. 되면 true
    func save(_ text: String) async -> Bool {
        guard let agent, !isChanging, text.count <= AgentMemory.sendLimit else { return false }
        isChanging = true
        notice = nil
        defer { isChanging = false }
        do {
            let saved = try await agent.setMemoryProfile(text)
            apply(saved, source: .user)
            if Self.normalized(saved) != Self.normalized(text) {
                notice = "맥이 비밀번호 같은 값을 지우거나 \(AgentMemory.savedLimit)자로 줄여서 저장했어요."
            }
            return true
        } catch {
            notice = "저장하지 못했어요. 맥 연결을 확인한 뒤 다시 해 주세요."
            return false
        }
    }

    /// 요약본을 바로 전 판으로 되돌린다. 한 단계뿐이라 다시 누르면 두 판 사이를 오간다 (맥의 D129).
    /// 맨 처음 쓴 요약본처럼 전 판이 없으면 맥이 409(`nothing_to_undo`)를 준다
    func undo() async {
        guard let agent, !isChanging else { return }
        isChanging = true
        notice = nil
        defer { isChanging = false }
        do {
            apply(try await agent.undoMemory(), source: .undo)
            notice = "바로 전 요약으로 바꿨어요. 한 번 더 누르면 방금 것으로 돌아가요."
        } catch let error as AgentError where error == .conflict {
            notice = "되돌릴 전 요약이 없어요."
        } catch {
            notice = "되돌리지 못했어요. 맥 연결을 확인한 뒤 다시 해 주세요."
        }
    }

    /// 지난 대화에서 찾는다
    func search(_ query: String) async {
        let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.queryLimit))
        guard let agent, !query.isEmpty, !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            hits = try await agent.searchMemory(query)
            searched = query
            searchFailed = false
        } catch {
            searchFailed = true
        }
    }

    func clearSearch() {
        hits = []
        searched = nil
        searchFailed = false
    }

    /// 요약본과 지난 대화를 맥에서 모두 지운다 (되돌릴 수 없다. 화면이 먼저 확인을 받는다). 되면 true
    func clearAll() async -> Bool {
        guard let agent, !isChanging else { return false }
        isChanging = true
        notice = nil
        defer { isChanging = false }
        do {
            try await agent.clearMemory()
            memory = AgentMemory(profile: "", turns: 0, since: nil, updatedAt: nil, source: nil)
            clearSearch()
            notice = "기억을 모두 지웠어요."
            return true
        } catch {
            notice = "지우지 못했어요. 맥 연결을 확인한 뒤 다시 해 주세요."
            return false
        }
    }

    private func apply(_ profile: String, source: AgentMemory.Source) {
        var memory = memory ?? AgentMemory(profile: "", turns: 0, since: nil, updatedAt: nil, source: nil)
        memory.profile = profile
        memory.source = source
        memory.updatedAt = .now
        self.memory = memory
    }

    /// 끝의 빈칸·줄바꿈만 다른 것은 같은 글로 본다
    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
