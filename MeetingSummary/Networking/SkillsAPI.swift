import Foundation

// 맡길 수 있는 일 (`skills`, D53): 맥이 "지금 할 수 있는 일"을 카드 목록으로 알려 준다 (`GET /v1/skills`).
// 카드의 `prompt`를 사용자의 말로 대화에 보내면 그 일이 시작된다. 새 요청 형식은 없다.
// 무엇이 올라오는지, 준비가 되었는지는 맥이 정한다. 앱은 받은 그대로 그린다.

/// 맥이 할 수 있는 일 하나 (카드 한 장)
struct AgentSkill: Equatable, Sendable, Identifiable {
    /// 이 일을 하려면 먼저 되어 있어야 하는 것 (아직 안 된 것만 온다)
    struct Need: Equatable, Sendable {
        /// "mail_account", "site:naver"
        let kind: String
        /// "네이버 로그인이 필요해요"
        let message: String
        /// 준비를 시작하는 말 ("네이버 로그인해줘"). 비어 있으면 앱에서 시작할 방법이 없다
        let prompt: String

        /// 준비를 시작하는 단추의 글. 종류를 모르면 뭉뚱그려 말한다
        var buttonTitle: String {
            if kind.hasPrefix("site:") { return "로그인하기" }
            if kind == "mail_account" { return "메일 연결하기" }
            return "먼저 준비하기"
        }
    }

    let id: String
    var title: String
    var description: String
    /// 묶음 이름 ("메일", "연결"). 없으면 빈 글
    var category: String
    /// 대화에 보낼 말
    var prompt: String
    /// 일부만 확인된 일 (`status: beta`). 작게 "시험 중"을 붙인다
    var isBeta = false
    /// 지금 바로 맡길 수 있는지
    var isAvailable = true
    var needs: [Need] = []

    /// 맡길 수 없을 때 보여 줄 준비 하나 (맥이 준 첫 번째)
    var blocker: Need? { isAvailable ? nil : needs.first }

    /// 묶음 이름으로 나눈다. 묶음과 카드 모두 맥이 준 순서 그대로다
    static func grouped(_ skills: [AgentSkill]) -> [(category: String, skills: [AgentSkill])] {
        var order: [String] = []
        var groups: [String: [AgentSkill]] = [:]
        for skill in skills {
            if groups[skill.category] == nil { order.append(skill.category) }
            groups[skill.category, default: []].append(skill)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

extension AgentHTTPClient {
    /// 대화에 보낼 말이 없는 카드는 누를 수 없으니 뺀다. 모르는 값이 섞여 있어도 나머지 카드는 살린다
    static func decodeSkills(data: Data, status: Int) throws -> [AgentSkill] {
        struct Wrapper: Decodable {
            struct Need: Decodable {
                let kind: String?
                let message: String?
                let prompt: String?
            }
            struct Skill: Decodable {
                let id: String?
                let title: String?
                let description: String?
                let category: String?
                let prompt: String?
                let status: String?
                let available: Bool?
                let needs: [Need]?
            }
            let skills: [Skill]
        }
        guard (200..<300).contains(status) else { throw decodeError(data: data, status: status) }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { throw AgentError.invalidResponse }
        return wrapper.skills.compactMap { item in
            guard let id = item.id, !id.isEmpty, let title = item.title?.trimmed, !title.isEmpty,
                  let prompt = item.prompt?.trimmed, !prompt.isEmpty else { return nil }
            let needs = (item.needs ?? []).compactMap { need -> AgentSkill.Need? in
                guard let message = need.message?.trimmed, !message.isEmpty else { return nil }
                return AgentSkill.Need(kind: need.kind ?? "", message: message, prompt: need.prompt?.trimmed ?? "")
            }
            return AgentSkill(
                id: id, title: title, description: item.description?.trimmed ?? "", category: item.category?.trimmed ?? "",
                prompt: prompt, isBeta: item.status == "beta",
                // 맥이 말해 주지 않으면 남은 준비가 없을 때만 맡길 수 있는 것으로 본다
                isAvailable: item.available ?? needs.isEmpty, needs: needs
            )
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// "맡길 수 있는 일" 목록. 맥이 `skills`를 알리고 카드가 하나라도 있을 때만 들어가는 줄이 보인다
@MainActor
@Observable
final class SkillsModel {
    private let agent: (any AgentProviding)?
    private(set) var skills: [AgentSkill] = []
    /// 한 번이라도 받아 봤는지 (받기 전에는 빈 목록과 "없음"을 구분할 수 없다)
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// 마지막으로 받으려다 실패했는지 (맥에 연결되지 않음 포함). 참이면 보이는 목록은 예전 것이고, 맡기는 단추를 막는다
    private(set) var loadFailed = false

    init(agent: (any AgentProviding)? = AgentClient.fromEnvironment()) {
        self.agent = agent
    }

    /// 사이드바에 들어가는 줄을 보일지
    var isOffered: Bool { !skills.isEmpty }

    func load() async {
        guard let agent, !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        guard await agent.isReachable() else {
            // 맥이 꺼져 있으면 예전 목록을 그대로 둔다 (다시 켜지면 새로 받는다)
            loadFailed = true
            return
        }
        guard await agent.supports(AgentFeature.skills) else {
            skills = []
            loadFailed = false
            return
        }
        do {
            skills = try await agent.skills()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }
}
