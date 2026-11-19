import Foundation

// 사이트 로그인 (`site_login`, D48): 맥의 에이전트 브라우저가 연 로그인 화면을 앱에서 대신 채운다.
// 앱은 서버가 알려 준 입력칸에 사용자가 넣은 값을 한 번 보내고, 다음 상태를 조회로 받는다.
// 아이디·비밀번호는 이 요청으로만 지나간다. 서버 응답에는 돌아오지 않고, 맥에 남는 것은 브라우저의 로그인 상태뿐이다.
// (사용자가 켰을 때 이 아이폰의 키체인에 두는 것은 `LoginVault`, D78)

/// 에이전트 브라우저의 사이트별 로그인 상태 (`GET /v1/sites`)
struct SiteStatus: Equatable, Sendable, Identifiable {
    enum Status: String, Sendable {
        case loggedIn = "logged_in"
        case loggedOut = "logged_out"
        /// 앱이 모르는 값
        case unknown
    }

    /// "naver"
    var site: String
    /// "네이버"
    var name: String
    var status: Status
    var checkedAt: Date?
    /// 서버가 할 수 있는 로그인 방식 ("qr"·"password")
    var methods: [String]
    /// 처음에 어떻게 로그인했는지 (D122, 맥의 D105): "password"(아이디·비밀번호), 소셜 회사 키("naver" 등 — 맥이 스스로 다시 들어간다). 모르는 맥은 nil
    var via: String? = nil
    /// "chrome": 전용 크롬 사이트 (맥 화면에서 사람이 로그인한다). 모르는 맥은 nil
    var backend: String? = nil
    /// 그 사이트의 호스트 (D132, 맥의 D110. 소문자). 아이콘을 찾을 때 쓴다. 모르는 맥은 nil
    var host: String? = nil

    /// 맥이 주는 사이트 아이콘의 크기 한도
    static let iconLimit = 300_000

    var id: String { site }
    /// 앱이 저장해 둔 아이디·비밀번호로 다시 로그인해도 되는 사이트인지 (모르는 맥이면 막지 않는다 — 저장한 값이 있다는 것은 아이디·비밀번호로 들어갔다는 뜻이다)
    var reloginsWithPassword: Bool { backend != "chrome" && (via == nil || via == SiteLogin.passwordMethod) }
    /// 앱은 아이디·비밀번호 방식만 쓴다
    var canLogInFromApp: Bool { methods.contains(SiteLogin.passwordMethod) }
}

/// 진행 중인 로그인 하나 (`{"login": …}`)
struct SiteLogin: Equatable, Sendable {
    static let passwordMethod = "password"

    enum State: String, Sendable {
        case starting, working
        case needInput = "need_input"
        case needApproval = "need_approval"
        case needChoice = "need_choice"
        case loggedIn = "logged_in"
        case failed, expired, cancelled
        /// 앱이 모르는 상태
        case unknown

        var isFinished: Bool {
            switch self {
            case .loggedIn, .failed, .expired, .cancelled: true
            default: false
            }
        }
    }

    /// 사용자가 채울 입력칸 하나
    struct Field: Equatable, Sendable, Identifiable {
        let name: String
        /// 서버가 준 칸 이름. 글자로만 보여 준다
        let label: String
        let secret: Bool
        var id: String { name }
    }

    /// 앱이 그릴 줄 아는 입력칸. 이 밖의 이름이 오면 값을 받지 않는다 (서버가 무엇이든 물어볼 수 있게 두지 않는다).
    /// `name`·`birth`·`phone`은 간편인증의 본인 확인 칸이다 (D90)
    static let inputNames: Set<String> = Set(["id", "password", "captcha", "code"]).union(identityNames)
    /// 본인 확인에 쓰는 칸 (이름, 생년월일, 휴대폰 번호). 로그인 정보가 아니라서 이 아이폰에 저장하지 않는다
    static let identityNames: Set<String> = ["name", "birth", "phone"]
    /// 숫자만 받는 칸
    static let digitNames: Set<String> = ["birth", "phone"]
    static let choiceName = "choice"
    /// 보안 확인 그림 한도 (이보다 크면 그림으로 보지 않는다). 영수증 같은 큰 화면 캡처도 들어오게 넉넉히 둔다
    static let maxImageBytes = 4_000_000

    var id: String
    var site: String
    var method: String
    var state: State
    /// 화면 번호. 입력을 보낼 때 함께 보내, 지나간 화면에 값이 들어가지 않게 한다
    var step: Int
    var message: String
    /// 남은 시간(초). 끝난 상태는 0
    var expiresIn: Int?
    var fields: [Field] = []
    /// 방금 낸 입력이 틀렸을 때 "wrong_input"
    var error: String?
    /// 보안문자 그림
    var image: Data?
    /// 사이트가 물어본 말 (`need_choice`)
    var text: String?
    var choices: [String] = []
    /// 실패한 까닭 ("wrong_input"·"blocked"·"unsupported_page"·"timeout"·"browser_error")
    var reason: String?
    /// 지금 입력·선택을 받는 화면의 호스트 (네이버가 아닌 사이트의 로그인에서만 온다. 소문자).
    /// 저장해 둔 값을 넣어도 되는 화면인지 가를 때 쓴다: 저장할 때와 다르면 넣지 않는다
    var host: String?
    /// 호스트가 왔는데 읽을 수 없는 모양이었다. 이런 화면에는 저장해 둔 값을 넣지도, 넣은 값을 저장하지도 않는다
    var hostUnreadable = false
    /// 글자로 답할 수 없는 확인 문제(그림을 눌러 고르는 퍼즐)라 사람이 맥의 브라우저에서 직접 푼다 (`need_choice`에만, D149).
    /// 있으면 카드에 "브라우저 열기"가 붙는다. 다 풀면 첫 선택지("다 했어요")로 답한다
    var handover: AgentHandover?

    /// 입력칸을 앱이 모두 그릴 수 있는지. 아니면 이 화면은 앱에서 처리하지 않는다
    var canRenderInput: Bool {
        !fields.isEmpty && fields.allSatisfy { Self.inputNames.contains($0.name) } && Set(fields.map(\.name)).count == fields.count
    }

    var wasWrongInput: Bool { error == "wrong_input" }
}

extension AgentHTTPClient {
    static func decodeSites(data: Data, status: Int) throws -> [SiteStatus] {
        struct Wrapper: Decodable {
            struct Site: Decodable {
                let site: String
                let name: String?
                let status: String?
                let checked_at: String?
                let methods: [String]?
                let via: String?
                let backend: String?
                let host: String?
            }
            let sites: [Site]
        }
        guard (200..<300).contains(status) else { throw decodeError(data: data, status: status) }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { throw AgentError.invalidResponse }
        let sites = wrapper.sites.filter { !$0.site.isEmpty }
        // 맥이 이름 자리에 주소를 보내면 아는 서비스는 서비스 이름으로 (D142)
        func name(_ site: Wrapper.Site) -> String? { site.name.flatMap { $0.isEmpty ? nil : SiteName.service($0) } }
        // 맥이 적어 준 이름을 기억해 둔다: 사이트 키만 오는 곳(작업 카드, 로그인 카드)에서도 이름으로 보이게 (D107)
        SiteName.remember(Dictionary(sites.compactMap { site in name(site).map { (site.site, $0) } }, uniquingKeysWith: { first, _ in first }))
        return sites.map {
            // 이름이 주소였으면 그 주소로 아이콘을 찾는다 (서비스 이름으로 바꾼 뒤에도)
            let nameHost = $0.name.flatMap(cleanHost).flatMap { SiteHost.isDomain($0) ? $0 : nil }
            return SiteStatus(
                site: $0.site, name: name($0) ?? SiteName.display($0.site),
                status: SiteStatus.Status(rawValue: $0.status ?? "") ?? .unknown,
                checkedAt: AgentTime.date($0.checked_at), methods: $0.methods ?? [],
                via: $0.via?.isEmpty == false ? $0.via : nil, backend: $0.backend?.isEmpty == false ? $0.backend : nil,
                host: $0.host.flatMap(cleanHost).flatMap { SiteHost.isDomain($0) ? $0 : nil } ?? nameHost
            )
        }
    }

    static func decodeSiteLogin(data: Data, status: Int) throws -> SiteLogin {
        struct Wrapper: Decodable {
            struct Field: Decodable {
                let name: String
                let label: String?
                let secret: Bool?
            }
            struct Image: Decodable {
                let mime: String?
                let b64: String?
            }
            struct Login: Decodable {
                let login_id: String
                let site: String?
                let method: String?
                let state: String
                let step: Int?
                let message: String?
                let expires_in_s: Double?
                let fields: [Field]?
                let error: String?
                let image: Image?
                let text: String?
                let choices: [String]?
                let reason: String?
                let host: String?
                let handover: LooseHandover?
            }
            let login: Login
        }
        guard (200..<300).contains(status) else { throw decodeError(data: data, status: status) }
        guard let dto = try? JSONDecoder().decode(Wrapper.self, from: data).login, !dto.login_id.isEmpty else {
            throw AgentError.invalidResponse
        }
        let host = dto.host.flatMap(cleanHost)
        return SiteLogin(
            id: dto.login_id, site: dto.site ?? "", method: dto.method ?? "",
            state: SiteLogin.State(rawValue: dto.state) ?? .unknown,
            step: dto.step ?? 0, message: dto.message ?? "",
            expiresIn: dto.expires_in_s.map { Int(max(0, $0)) },
            fields: (dto.fields ?? []).map { SiteLogin.Field(name: $0.name, label: $0.label ?? "", secret: $0.secret ?? false) },
            error: dto.error?.isEmpty == false ? dto.error : nil,
            image: decodeImage(mime: dto.image?.mime, b64: dto.image?.b64),
            text: dto.text?.isEmpty == false ? dto.text : nil,
            choices: (dto.choices ?? []).filter { !$0.isEmpty },
            reason: dto.reason?.isEmpty == false ? dto.reason : nil,
            host: host, hostUnreadable: dto.host != nil && host == nil,
            // 고르는 화면에서만 받는다 (입력칸 화면에 붙어 와도 쓰지 않는다)
            handover: dto.state == SiteLogin.State.needChoice.rawValue ? dto.handover?.value : nil
        )
    }

    /// 호스트는 견줄 수 있는 모양일 때만 받는다: 소문자로 맞추고, 빈칸·제어 문자·주소의 다른 부분(`/ @ ? # \`)이 섞였으면 받지 않는다
    static func cleanHost(_ raw: String) -> String? {
        let host = raw.lowercased()
        guard !host.isEmpty, host.count <= 253 else { return nil }
        let refused = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "/@?#\\"))
        guard host.unicodeScalars.allSatisfy({ !refused.contains($0) }) else { return nil }
        return host
    }

    /// 그림은 정해진 형식과 크기일 때만 받는다
    private static func decodeImage(mime: String?, b64: String?) -> Data? {
        guard let mime, ["image/png", "image/jpeg", "image/gif"].contains(mime.lowercased()),
              let b64, b64.utf8.count <= SiteLogin.maxImageBytes * 4 / 3 + 4,
              let data = Data(base64Encoded: b64), !data.isEmpty, data.count <= SiteLogin.maxImageBytes else { return nil }
        return data
    }

    /// 주소에 넣는 사이트·로그인 번호는 글자·숫자·밑줄·붙임표만 받는다 (다른 경로로 새지 않게)
    static func isPathSafe(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }
}
