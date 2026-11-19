import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 사이트 로그인(site_login, D48): 맥의 에이전트 브라우저가 연 로그인 화면을 앱에서 채운다.
// 응답 예시는 두 세션이 합의한 형식을 가상 데이터로 쓴 것이다. 아이디·비밀번호는 모두 가짜다.

private enum SiteFixture {
    /// 가짜 아이디·비밀번호 (실제 값이 아니다)
    static let id = "minsu_demo"
    static let password = "Kq7!가상-비밀번호"

    static let sites = """
    {"sites":[{"site":"naver","name":"네이버","methods":["qr","password"],"status":"logged_out","checked_at":null},\
    {"site":"daum","name":"","methods":["qr"],"status":"something_new","checked_at":"2026-11-12T01:00:00+00:00"},\
    {"site":"","name":"빈 것","status":"logged_in"}]}
    """
    static let loggedInSites = #"{"sites":[{"site":"naver","name":"네이버","methods":["qr","password"],"status":"logged_in","checked_at":"2026-11-12T01:00:00+00:00"}]}"#
    static let starting = #"{"login":{"login_id":"l_1","site":"naver","method":"password","state":"starting","step":0,"message":"","expires_in_s":600}}"#
    static let needInput = """
    {"login":{"login_id":"l_1","site":"naver","method":"password","state":"need_input","step":1,"message":"네이버 로그인 정보를 입력해 주세요","expires_in_s":588.4,\
    "fields":[{"name":"id","label":"아이디 또는 전화번호","secret":false},{"name":"password","label":"비밀번호","secret":true}]}}
    """
    static let wrongInput = """
    {"login":{"login_id":"l_1","site":"naver","method":"password","state":"need_input","step":2,"message":"네이버 로그인 정보를 입력해 주세요","expires_in_s":540,\
    "error":"wrong_input","fields":[{"name":"id","label":"아이디 또는 전화번호","secret":false},{"name":"password","label":"비밀번호","secret":true}]}}
    """
    static let working = #"{"login":{"login_id":"l_1","site":"naver","method":"password","state":"working","step":1,"message":"확인하고 있어요","expires_in_s":570}}"#
    static let approval = """
    {"login":{"login_id":"l_1","site":"naver","method":"password","state":"need_approval","step":2,\
    "message":"휴대폰의 네이버 앱 알림에서 로그인을 승인해 주세요","expires_in_s":500}}
    """
    /// 1×1 PNG
    static let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    static func captcha(mime: String = "image/png", b64: String = pixel) -> String {
        """
        {"login":{"login_id":"l_1","site":"naver","method":"password","state":"need_input","step":2,"message":"보안문자를 입력해 주세요","expires_in_s":400,\
        "image":{"mime":"\(mime)","b64":"\(b64)"},\
        "fields":[{"name":"password","label":"비밀번호","secret":true},{"name":"captcha","label":"보안문자","secret":false}]}}
        """
    }
    static let choice = """
    {"login":{"login_id":"l_1","site":"naver","method":"password","state":"need_choice","step":3,"message":"","expires_in_s":300,\
    "text":"이 브라우저를 자주 쓰는 기기로 등록할까요?","choices":["등록","등록 안 함"]}}
    """
    static let loggedIn = #"{"login":{"login_id":"l_1","site":"naver","method":"password","state":"logged_in","step":3,"message":"로그인했어요","expires_in_s":0}}"#
    static func failed(_ reason: String) -> String {
        #"{"login":{"login_id":"l_1","site":"naver","method":"password","state":"failed","step":2,"message":"","expires_in_s":0,"reason":"\#(reason)"}}"#
    }
    static let cancelled = #"{"login":{"login_id":"l_1","site":"naver","method":"password","state":"cancelled","step":1,"message":"로그인을 취소했어요","expires_in_s":0}}"#

    static func login(_ json: String) throws -> SiteLogin {
        try AgentHTTPClient.decodeSiteLogin(data: Data(json.utf8), status: 200)
    }
    static func error(_ status: Int, _ code: String) -> AgentError {
        AgentHTTPClient.decodeError(data: Data(#"{"error":{"code":"\#(code)","message":"m"}}"#.utf8), status: status)
    }
}

@Suite("사이트 로그인 응답 해석")
struct SiteLoginDecodingTests {
    @Test func sitesListKeepsUnknownStatusAsUnknown() throws {
        let sites = try AgentHTTPClient.decodeSites(data: Data(SiteFixture.sites.utf8), status: 200)
        // 사이트 이름이 빈 것은 버린다
        #expect(sites.map(\.site) == ["naver", "daum"])
        #expect(sites[0].name == "네이버")
        #expect(sites[0].status == .loggedOut)
        #expect(sites[0].checkedAt == nil)
        #expect(sites[0].canLogInFromApp)
        // 이름이 없으면 앱이 아는 이름으로 (D107. 전에는 사이트 값 그대로), 모르는 상태는 "확인 필요"로
        #expect(sites[1].name == "다음")
        #expect(sites[1].status == .unknown)
        #expect(sites[1].checkedAt != nil)
        // 앱은 아이디·비밀번호 방식만 쓴다
        #expect(!sites[1].canLogInFromApp)
    }

    @Test func inputScreenCarriesFieldsAndRemainingTime() throws {
        let login = try SiteFixture.login(SiteFixture.needInput)
        #expect(login.id == "l_1")
        #expect(login.state == .needInput)
        #expect(login.step == 1)
        #expect(login.expiresIn == 588)
        #expect(login.fields.map(\.name) == ["id", "password"])
        #expect(login.fields.map(\.secret) == [false, true])
        #expect(login.canRenderInput)
        #expect(!login.wasWrongInput)
        #expect(!login.state.isFinished)
    }

    @Test func everyStateIsRead() throws {
        #expect(try SiteFixture.login(SiteFixture.starting).state == .starting)
        #expect(try SiteFixture.login(SiteFixture.working).state == .working)
        #expect(try SiteFixture.login(SiteFixture.wrongInput).wasWrongInput)
        let approval = try SiteFixture.login(SiteFixture.approval)
        #expect(approval.state == .needApproval)
        #expect(approval.message == "휴대폰의 네이버 앱 알림에서 로그인을 승인해 주세요")
        let choice = try SiteFixture.login(SiteFixture.choice)
        #expect(choice.state == .needChoice)
        #expect(choice.text == "이 브라우저를 자주 쓰는 기기로 등록할까요?")
        #expect(choice.choices == ["등록", "등록 안 함"])
        let done = try SiteFixture.login(SiteFixture.loggedIn)
        #expect(done.state == .loggedIn && done.state.isFinished && done.expiresIn == 0)
        let failed = try SiteFixture.login(SiteFixture.failed("unsupported_page"))
        #expect(failed.state == .failed && failed.reason == "unsupported_page")
        #expect(try SiteFixture.login(SiteFixture.cancelled).state == .cancelled)
        // 앱이 모르는 상태는 끝난 것으로 보지 않고 기다린다
        let unknown = try SiteFixture.login(#"{"login":{"login_id":"l_1","state":"something_new"}}"#)
        #expect(unknown.state == .unknown && !unknown.state.isFinished)
    }

    @Test func captchaImageIsAcceptedOnlyInKnownFormats() throws {
        let captcha = try SiteFixture.login(SiteFixture.captcha())
        #expect(captcha.image?.isEmpty == false)
        #expect(captcha.fields.map(\.name) == ["password", "captcha"])
        #expect(captcha.canRenderInput)
        // 그림이 아닌 것, 읽을 수 없는 것은 그림으로 보지 않는다
        #expect(try SiteFixture.login(SiteFixture.captcha(mime: "image/svg+xml")).image == nil)
        #expect(try SiteFixture.login(SiteFixture.captcha(mime: "text/html")).image == nil)
        #expect(try SiteFixture.login(SiteFixture.captcha(b64: "%%%")).image == nil)
        // 영수증 같은 큰 화면 캡처(1MB를 넘는 것)도 받는다
        let large = Data(repeating: 0x41, count: 1_500_000).base64EncodedString()
        #expect(try SiteFixture.login(SiteFixture.captcha(b64: large)).image?.count == 1_500_000)
        let huge = String(repeating: "A", count: SiteLogin.maxImageBytes * 2)
        #expect(try SiteFixture.login(SiteFixture.captcha(b64: huge)).image == nil)
    }

    @Test func unknownFieldNamesCannotBeRendered() throws {
        let odd = try SiteFixture.login("""
        {"login":{"login_id":"l_1","state":"need_input","step":1,"fields":[{"name":"password","label":"비밀번호","secret":true},{"name":"card_number","label":"카드 번호"}]}}
        """)
        #expect(!odd.canRenderInput)
        let none = try SiteFixture.login(#"{"login":{"login_id":"l_1","state":"need_input","step":1,"fields":[]}}"#)
        #expect(!none.canRenderInput)
        let twice = try SiteFixture.login("""
        {"login":{"login_id":"l_1","state":"need_input","step":1,"fields":[{"name":"password"},{"name":"password"}]}}
        """)
        #expect(!twice.canRenderInput)
    }

    @Test func errorsAreToldApart() {
        #expect(SiteFixture.error(409, "stale_step") == .staleStep)
        #expect(SiteFixture.error(409, "busy") == .busy)
        #expect(SiteFixture.error(404, "unknown_login") == .loginLost)
        #expect(SiteFixture.error(404, "unknown_site") == .unknownSite)
        #expect(SiteFixture.error(429, "rate_limited") == .rateLimited)
        #expect(SiteFixture.error(401, "unauthorized") == .unauthorized)
        #expect(throws: AgentError.staleStep) {
            try AgentHTTPClient.decodeSiteLogin(data: Data(#"{"error":{"code":"stale_step","message":"m"}}"#.utf8), status: 409)
        }
        #expect(throws: AgentError.invalidResponse) { try AgentHTTPClient.decodeSiteLogin(data: Data("{}".utf8), status: 200) }
        #expect(throws: AgentError.invalidResponse) { try AgentHTTPClient.decodeSites(data: Data("[]".utf8), status: 200) }
    }

    @Test func loginScreenReplyIsRead() throws {
        let json = #"{"conversation_id":"c_1","replies":[{"text":"네이버 로그인 화면을 열게요."}],"action":{"type":"site_login","site":"naver"}}"#
        let reply = try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200)
        #expect(reply.replies == ["네이버 로그인 화면을 열게요."])
        guard case .siteLogin(let site) = reply.action else {
            Issue.record("site_login으로 읽혀야 한다")
            return
        }
        #expect(site == "naver")
        // 주소에 넣을 수 없는 사이트 값이면 로그인 화면을 열지 않고 답만 보여 준다
        let odd = #"{"conversation_id":"c_1","replies":[{"text":"로그인 화면을 열게요."}],"action":{"type":"site_login","site":"../admin"}}"#
        let plain = try AgentHTTPClient.decodeReply(data: Data(odd.utf8), status: 200)
        guard case .none = plain.action else {
            Issue.record("답만 보여 줘야 한다")
            return
        }
    }

    @Test func pathPartsAreLimitedToPlainCharacters() {
        #expect(AgentHTTPClient.isPathSafe("naver"))
        #expect(AgentHTTPClient.isPathSafe("l_9fK2-x"))
        #expect(!AgentHTTPClient.isPathSafe(""))
        #expect(!AgentHTTPClient.isPathSafe("../tasks"))
        #expect(!AgentHTTPClient.isPathSafe("a/b"))
        #expect(!AgentHTTPClient.isPathSafe("a?b=1"))
        #expect(!AgentHTTPClient.isPathSafe("네이버"))
        #expect(!AgentHTTPClient.isPathSafe(String(repeating: "a", count: 81)))
    }

    @Test @MainActor func valuesAreCleanedBeforeSending() throws {
        let login = try SiteFixture.login(SiteFixture.needInput)
        // 아이디는 앞뒤 공백을 떼고, 비밀번호는 넣은 그대로 보낸다
        let cleaned = SiteLoginSheet.cleaned(["id": "  \(SiteFixture.id) \n", "password": " pw with space "], for: login)
        #expect(cleaned == ["id": SiteFixture.id, "password": " pw with space "])
        // 화면에 없는 칸의 값은 보내지 않는다
        #expect(SiteLoginSheet.cleaned(["id": "a", "password": "b", "extra": "c"], for: login).keys.sorted() == ["id", "password"])
        #expect(SiteLoginSheet.remainingText(588) == "남은 시간 약 9분")
        #expect(SiteLoginSheet.remainingText(42) == "남은 시간 42초")
        #expect(SiteLoginSheet.remainingText(0) == nil)
        #expect(SiteLoginSheet.remainingText(nil) == nil)
    }

    @Test @MainActor func askingThePasswordAgainWithACaptchaSaysWhy() throws {
        func login(_ names: [String]) -> SiteLogin {
            SiteLogin(id: "l_1", site: "naver", method: "password", state: .needInput, step: 2, message: "",
                      fields: names.map { SiteLogin.Field(name: $0, label: "", secret: $0 == "password") })
        }
        // 보안문자와 함께 비밀번호를 또 물으면, 앞의 값을 남기지 않아서 다시 넣는다고 알린다
        #expect(SiteLoginSheet.repeatHint(for: login(["password", "captcha"]))?.contains("화면에 남기지 않아서") == true)
        #expect(SiteLoginSheet.repeatHint(for: login(["id", "password", "captcha"])) != nil)
        // 보안문자만 묻거나 처음 로그인 칸이면 말하지 않는다
        #expect(SiteLoginSheet.repeatHint(for: login(["captcha"])) == nil)
        #expect(SiteLoginSheet.repeatHint(for: login(["id", "password"])) == nil)
    }
}

// MARK: - 요청

/// 이 파일만 쓰는 가짜 응답 (다른 묶음의 것과 섞이지 않게 따로 둔다)
final class SiteStubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: String
    }

    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var respond: @Sendable (String, String) -> (Int, String) = { _, _ in (200, "{}") }
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path() ?? ""
        let (status, text) = Self.lock.withLock {
            Self.seen.append(Seen(method: method, path: path, headers: request.allHTTPHeaderFields ?? [:], body: String(decoding: body, as: UTF8.self)))
            return Self.respond(method, path)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("사이트 로그인 요청", .serialized)
struct SiteLoginRequestTests {
    private static let siteFeatures = #","features":["messages","client_message_id","task_questions","send_self","mail_connect","site_login"]"#
    private static let oldFeatures = #","features":["messages","client_message_id","task_questions","send_self","mail_connect"]"#
    private static let siteReply = #"{"conversation_id":"c_1","replies":[{"text":"네이버 로그인 화면을 열게요."}],"action":{"type":"site_login","site":"naver"}}"#

    private func client(features: String) -> AgentHTTPClient {
        SiteStubProtocol.lock.withLock {
            SiteStubProtocol.seen = []
            SiteStubProtocol.respond = { method, path in
                if path.hasSuffix("/health") { return (200, #"{"status":"ok"\#(features)}"#) }
                if path.hasSuffix("/v1/sites") { return (200, SiteFixture.sites) }
                if path.hasSuffix("/logout") || path.hasSuffix("/check") { return (200, SiteFixture.loggedInSites) }
                if path.hasSuffix("/input") { return (200, SiteFixture.working) }
                if path.hasSuffix("/cancel") { return (200, SiteFixture.cancelled) }
                if path.hasSuffix("/login") { return (200, SiteFixture.starting) }
                if path.contains("/login/") { return (200, SiteFixture.needInput) }
                return (200, Self.siteReply)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiteStubProtocol.self]
        return AgentHTTPClient(baseURL: URL(string: "http://mac.test:8765")!, token: "t", session: URLSession(configuration: configuration))
    }

    private var seen: [SiteStubProtocol.Seen] {
        SiteStubProtocol.lock.withLock { SiteStubProtocol.seen }
    }

    @Test func wholeLoginUsesTheAgreedPaths() async throws {
        let client = client(features: Self.siteFeatures)
        #expect(await client.isReachable())
        #expect(await client.supports(AgentFeature.siteLogin))

        #expect(try await client.sites().map(\.site) == ["naver", "daum"])
        let started = try await client.startSiteLogin(site: "naver", method: SiteLogin.passwordMethod)
        #expect(started.state == .starting)
        let asking = try await client.siteLogin(site: "naver", id: started.id)
        #expect(asking.state == .needInput)
        let sent = try await client.sendSiteLoginInput(
            site: "naver", id: started.id, step: asking.step, values: ["id": SiteFixture.id, "password": SiteFixture.password]
        )
        #expect(sent.state == .working)
        #expect(try await client.cancelSiteLogin(site: "naver", id: started.id).state == .cancelled)
        #expect(try await client.checkSite(site: "naver").first?.status == .loggedIn)
        #expect(try await client.siteLogout(site: "naver").first?.status == .loggedIn)

        let calls = seen.filter { !$0.path.hasSuffix("/health") }.map { "\($0.method) \($0.path)" }
        #expect(calls == [
            "GET /v1/sites",
            "POST /v1/sites/naver/login",
            "GET /v1/sites/naver/login/l_1",
            "POST /v1/sites/naver/login/l_1/input",
            "POST /v1/sites/naver/login/l_1/cancel",
            "POST /v1/sites/naver/check",
            "POST /v1/sites/naver/logout",
        ])
        let start = try #require(seen.first { $0.path.hasSuffix("/naver/login") })
        #expect(start.body == #"{"method":"password"}"#)
        #expect(start.headers["X-App-Token"] == "t")

        // 아이디·비밀번호가 실리는 요청은 입력 요청 하나뿐이다
        let input = try #require(seen.first { $0.path.hasSuffix("/input") })
        let body = try #require(try JSONSerialization.jsonObject(with: Data(input.body.utf8)) as? [String: Any])
        #expect(body["step"] as? Int == 1)
        #expect(body["values"] as? [String: String] == ["id": SiteFixture.id, "password": SiteFixture.password])
        #expect(Set(body.keys) == ["step", "values"])
        for other in seen where !other.path.hasSuffix("/input") {
            #expect(!other.body.contains(SiteFixture.password))
            #expect(!other.path.contains(SiteFixture.password))
            #expect(!other.headers.values.contains { $0.contains(SiteFixture.password) })
        }
    }

    @Test func messagesCarryVersionFourOnlyForServersThatKnowSiteLogin() async throws {
        let new = client(features: Self.siteFeatures)
        #expect(await new.isReachable())
        let reply = try await new.message("네이버 로그인해줘", conversationID: nil, context: nil, messageID: "0B3F6E1A-AAAA-BBBB-CCCC-000000000004")
        guard case .siteLogin(let site) = reply.action else {
            Issue.record("site_login으로 읽혀야 한다")
            return
        }
        #expect(site == "naver")
        #expect(seen.last { $0.path.hasSuffix("/v1/messages") }?.headers["X-Api-Version"] == "4")
        // 로그인 요청 자체에는 버전 표시를 붙이지 않는다
        _ = try await new.startSiteLogin(site: "naver", method: SiteLogin.passwordMethod)
        #expect(seen.last { $0.path.hasSuffix("/naver/login") }?.headers["X-Api-Version"] == nil)

        let old = client(features: Self.oldFeatures)
        #expect(await old.isReachable())
        _ = try await old.message("네이버 로그인해줘", conversationID: nil, context: nil, messageID: "0B3F6E1A-AAAA-BBBB-CCCC-000000000005")
        #expect(seen.last { $0.path.hasSuffix("/v1/messages") }?.headers["X-Api-Version"] == "3")
    }

    @Test func nothingIsSentToAServerThatDoesNotKnowSiteLogin() async throws {
        let old = client(features: Self.oldFeatures)
        #expect(await old.isReachable())
        #expect(!(await old.supports(AgentFeature.siteLogin)))
        #expect(try await old.sites().isEmpty)
        await #expect(throws: AgentError.conflict) { try await old.startSiteLogin(site: "naver", method: SiteLogin.passwordMethod) }
        await #expect(throws: AgentError.conflict) {
            try await old.sendSiteLoginInput(site: "naver", id: "l_1", step: 1, values: ["id": SiteFixture.id, "password": SiteFixture.password])
        }
        // 지원을 확인하기 전(연결 확인 전)에도 보내지 않는다
        let unchecked = client(features: Self.siteFeatures)
        await #expect(throws: AgentError.conflict) {
            try await unchecked.sendSiteLoginInput(site: "naver", id: "l_1", step: 1, values: ["id": SiteFixture.id, "password": SiteFixture.password])
        }
        #expect(seen.allSatisfy { !$0.path.contains("/sites") })
        #expect(seen.allSatisfy { !$0.body.contains(SiteFixture.password) })
    }

    @Test func oddSiteOrLoginIDNeverReachesTheServer() async throws {
        let client = client(features: Self.siteFeatures)
        #expect(await client.isReachable())
        await #expect(throws: AgentError.unknownSite) { try await client.startSiteLogin(site: "../v1/tasks", method: SiteLogin.passwordMethod) }
        await #expect(throws: AgentError.loginLost) {
            try await client.sendSiteLoginInput(site: "naver", id: "l_1/../../x", step: 1, values: ["password": SiteFixture.password])
        }
        #expect(seen.allSatisfy { $0.path.hasSuffix("/health") })
    }
}

// MARK: - 진행

/// 가짜 맥을 감싸, 응답이 끊기거나 로그인 기록이 사라지는 상황을 만든다. 대화 담당에게 간 말도 적어 둔다
actor ScriptedSiteAgent: AgentProviding {
    let inner: MockAgentClient
    /// 다음 입력 요청에서 던질 오류
    var inputFailure: AgentError?
    /// 그 입력이 맥에는 들어간 뒤에 응답만 끊긴 것인지
    var inputArrivesAnyway = false
    /// 조회·취소가 "모르는 로그인"으로 답한다 (서버가 다시 시작된 것처럼)
    var forgotten = false
    /// 조회가 끊긴다
    var pollFailure: AgentError?
    var startFailure: AgentError?
    private(set) var inputCalls = 0
    /// 대화 담당(모델)에게 간 말과 발췌
    private(set) var spoken: [String] = []

    init(_ sites: MockSites = MockSites()) { inner = MockAgentClient(v2: true, sites: sites) }

    func failNextInput(_ error: AgentError, arrives: Bool = false) {
        inputFailure = error
        inputArrivesAnyway = arrives
    }
    func forget() { forgotten = true }
    func failPolls(_ error: AgentError?) { pollFailure = error }
    func failStart(_ error: AgentError?) { startFailure = error }

    func isReachable() async -> Bool { true }
    func supports(_ feature: String) async -> Bool { await inner.supports(feature) }
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        spoken.append(text + "\n" + (context ?? ""))
        return try await inner.message(text, conversationID: conversationID, context: context)
    }
    func message(_ text: String, conversationID: String?, context: String?, messageID: String?) async throws -> AgentReply {
        spoken.append(text + "\n" + (context ?? ""))
        return try await inner.message(text, conversationID: conversationID, context: context, messageID: messageID)
    }
    func start(task: String, context: String?) async throws -> AgentTaskState { try await inner.start(task: task, context: context) }
    func state(of id: String) async throws -> AgentTaskState { try await inner.state(of: id) }
    func cancel(_ id: String) async throws -> AgentTaskState { try await inner.cancel(id) }
    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        try await inner.decide(id, approvalID: approvalID, approve: approve, reason: reason, sha256: sha256)
    }

    func sites() async throws -> [SiteStatus] { try await inner.sites() }
    func startSiteLogin(site: String, method: String) async throws -> SiteLogin {
        if let startFailure { throw startFailure }
        return try await inner.startSiteLogin(site: site, method: method)
    }
    func siteLogin(site: String, id: String) async throws -> SiteLogin {
        if forgotten { throw AgentError.loginLost }
        if let pollFailure { throw pollFailure }
        return try await inner.siteLogin(site: site, id: id)
    }
    func sendSiteLoginInput(site: String, id: String, step: Int, values: [String: String]) async throws -> SiteLogin {
        inputCalls += 1
        if forgotten { throw AgentError.loginLost }
        if let failure = inputFailure {
            inputFailure = nil
            if inputArrivesAnyway { _ = try await inner.sendSiteLoginInput(site: site, id: id, step: step, values: values) }
            throw failure
        }
        return try await inner.sendSiteLoginInput(site: site, id: id, step: step, values: values)
    }
    func cancelSiteLogin(site: String, id: String) async throws -> SiteLogin {
        if forgotten { throw AgentError.loginLost }
        return try await inner.cancelSiteLogin(site: site, id: id)
    }
    func siteLogout(site: String) async throws -> [SiteStatus] { try await inner.siteLogout(site: site) }
    func checkSite(site: String) async throws -> [SiteStatus] { try await inner.checkSite(site: site) }
}

@MainActor
@Suite("사이트 로그인 진행")
struct SiteLoginFlowTests {
    private static let good = ["id": SiteFixture.id, "password": SiteFixture.password]
    /// 가짜 맥은 "wrong"이 들어 있으면 틀린 것으로 본다
    private static let bad = ["id": SiteFixture.id, "password": "wrong-가상"]

    /// 조회는 시험이 직접 한다 (주기 조회가 끼어들지 않게 간격을 길게 둔다)
    private func flow(_ agent: any AgentProviding) -> SiteLoginFlow {
        SiteLoginFlow(site: "naver", agent: agent, pollInterval: .seconds(3600))
    }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<5000 where !condition() { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }

    /// 입력 화면이 나올 때까지 연다
    private func opened(_ agent: any AgentProviding) async throws -> SiteLoginFlow {
        let flow = flow(agent)
        await flow.start()
        #expect(flow.screen == .opening)
        await flow.refresh()
        guard case .input(let login) = flow.screen else {
            Issue.record("입력 화면이 나와야 한다: \(flow.screen)")
            throw AgentError.invalidResponse
        }
        #expect(login.fields.map(\.name) == ["id", "password"])
        return flow
    }

    @Test func passwordThenPhoneApprovalLogsIn() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 2))
        let flow = try await opened(agent)
        var notified = 0
        flow.onLoggedIn = { notified += 1 }
        #expect(flow.isActive)

        await flow.submit(Self.good)
        #expect(flow.screen == .working("확인하고 있어요"))
        await flow.refresh()
        guard case .approval(let waiting) = flow.screen else {
            Issue.record("휴대폰 승인을 기다려야 한다: \(flow.screen)")
            return
        }
        #expect(waiting.message == "휴대폰의 네이버 앱 알림에서 로그인을 승인해 주세요")
        // 승인은 사용자가 휴대폰에서 한다. 앱은 기다리기만 한다
        await flow.refresh()
        #expect(flow.screen == .approval(try #require(flow.login)))
        await flow.refresh()
        #expect(flow.screen == .done)
        #expect(flow.isFinished && !flow.isActive)
        #expect(notified == 1)
        #expect(try await agent.sites().first?.status == .loggedIn)
        // 맥이 받은 것은 그 화면의 칸 이름대로 한 번뿐이다
        let inputs = await agent.loginInputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.step == 1)
        #expect(inputs.first?.names == ["id", "password"])
        // 끝난 뒤 닫아도 취소를 보내지 않는다
        flow.close()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await agent.loginCancels == 0)
    }

    @Test func pollingAloneCarriesTheLoginToTheEnd() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites())
        let flow = SiteLoginFlow(site: "naver", agent: agent, pollInterval: .milliseconds(1))
        await flow.start()
        try await wait { if case .input = flow.screen { true } else { false } }
        await flow.submit(Self.good)
        try await wait { flow.screen == .done }
        #expect(await agent.loginInputs.count == 1)
    }

    @Test func wrongPasswordAsksAgainOnANewScreen() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1))
        let flow = try await opened(agent)
        await flow.submit(Self.bad)
        await flow.refresh()
        guard case .input(let again) = flow.screen else {
            Issue.record("다시 입력을 받아야 한다: \(flow.screen)")
            return
        }
        #expect(again.wasWrongInput)
        #expect(again.step == 2)
        await flow.submit(Self.good)
        await flow.refresh()
        guard case .approval = flow.screen else {
            Issue.record("휴대폰 승인을 기다려야 한다: \(flow.screen)")
            return
        }
        await flow.refresh()
        #expect(flow.screen == .done)
        #expect(await agent.loginInputs.map(\.step) == [1, 2])
    }

    @Test func thirdWrongInputStopsTheLogin() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites())
        let flow = try await opened(agent)
        for _ in 0..<3 {
            await flow.submit(Self.bad)
            await flow.refresh()
        }
        guard case .stopped(let title, let detail, let canRetry) = flow.screen else {
            Issue.record("멈춰야 한다: \(flow.screen)")
            return
        }
        #expect(title == "로그인하지 못했어요")
        #expect(detail.contains("여러 번 맞지 않아"))
        #expect(canRetry)
        #expect(flow.stoppedAt != nil)
        #expect(flow.isFinished)
        // 멈춘 뒤에는 더 보내지 않는다
        await flow.submit(Self.good)
        #expect(await agent.loginInputs.count == 3)
    }

    @Test func captchaIsShownForTheUserToSolve() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .captcha, approvalPolls: 1))
        let flow = try await opened(agent)
        await flow.submit(Self.good)
        await flow.refresh()
        guard case .input(let captcha) = flow.screen else {
            Issue.record("보안문자 화면이 나와야 한다: \(flow.screen)")
            return
        }
        #expect(captcha.image != nil)
        #expect(captcha.fields.map(\.name) == ["password", "captcha"])
        // 앞 화면의 칸 이름으로는 보내지 않는다
        await flow.submit(Self.good)
        #expect(await agent.loginInputs.count == 1)
        await flow.submit(["password": SiteFixture.password, "captcha": "7kDm4x"])
        await flow.refresh()
        await flow.refresh()
        #expect(flow.screen == .done)
        #expect(await agent.loginInputs.map(\.names) == [["id", "password"], ["captcha", "password"]])
    }

    @Test func pictureQuestionAsksOnlyForTheAnswer() async throws {
        // 실제 네이버의 "추가 확인" 화면 모양: 그림 한 장, 답 칸 하나, 물음은 message에. 비밀번호는 다시 묻지 않는다
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .receipt, approvalPolls: 1))
        let flow = try await opened(agent)
        await flow.submit(Self.good)
        await flow.refresh()
        guard case .input(let question) = flow.screen else {
            Issue.record("그림을 보고 답하는 화면이 나와야 한다: \(flow.screen)")
            return
        }
        #expect(question.image != nil)
        #expect(question.fields.map(\.name) == ["captcha"])
        #expect(question.message.contains("뒤 4자리는 무엇입니까?"))
        // 답 칸 자판은 묶지 않는다 (한글 자판으로 바꿀 수 있어야 한다). 숫자 자판은 인증 번호만
        #expect(SiteLoginSheet.keyboard(for: "captcha") == .default)
        #expect(SiteLoginSheet.keyboard(for: "code") == .numberPad)
        #expect(SiteLoginSheet.keyboard(for: "id") == .emailAddress)
        #expect(question.canRenderInput)
        #expect(SiteLoginSheet.repeatHint(for: question) == nil)
        // 답은 한글일 수도 있다 (그대로 보낸다)
        #expect(SiteLoginSheet.cleaned(["captcha": " 가상 문구점 "], for: question) == ["captcha": "가상 문구점"])
        await flow.submit(["captcha": "4821"])
        await flow.refresh()
        await flow.refresh()
        #expect(flow.screen == .done)
        #expect(await agent.loginInputs.map(\.names) == [["id", "password"], ["captcha"]])
    }

    @Test func loginFormShownAgainAfterThePictureSaysItIsNotAnError() async throws {
        // 실제 네이버에서 본 순서 (2026-11-12): 로그인 칸 → 그림 확인 → 로그인 칸이 한 번 더(틀렸다는 표시 없음) → 승인 → 로그인
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .relogin, approvalPolls: 1))
        let flow = try await opened(agent)
        guard case .input(let first) = flow.screen else {
            Issue.record("로그인 칸이 나와야 한다: \(flow.screen)")
            return
        }
        // 처음 화면에서는 말하지 않는다
        #expect(!flow.passwordSent)
        #expect(SiteLoginSheet.againHint(for: first, passwordSent: flow.passwordSent, siteName: "네이버") == nil)
        await flow.submit(Self.good)
        await flow.refresh()
        #expect(flow.passwordSent)
        guard case .input(let question) = flow.screen else {
            Issue.record("그림을 보고 답하는 화면이 나와야 한다: \(flow.screen)")
            return
        }
        // 그림 화면은 비밀번호를 묻지 않으니 말하지 않는다
        #expect(SiteLoginSheet.againHint(for: question, passwordSent: flow.passwordSent, siteName: "네이버") == nil)
        await flow.submit(["captcha": "지우개"])
        await flow.refresh()
        guard case .input(let again) = flow.screen else {
            Issue.record("로그인 칸이 한 번 더 나와야 한다: \(flow.screen)")
            return
        }
        #expect(again.fields.map(\.name) == ["id", "password"])
        #expect(!again.wasWrongInput)
        #expect(again.step > first.step)
        let hint = SiteLoginSheet.againHint(for: again, passwordSent: flow.passwordSent, siteName: "네이버")
        #expect(hint?.contains("오류가 아니에요") == true)
        #expect(hint?.contains("화면에 남기지 않아서") == true)
        // 틀려서 다시 묻는 화면에는 이 말을 하지 않는다 (틀렸다는 안내가 따로 있다)
        var wrong = again
        wrong.error = "wrong_input"
        #expect(SiteLoginSheet.againHint(for: wrong, passwordSent: true, siteName: "네이버") == nil)
        await flow.submit(Self.good)
        await flow.refresh()
        await flow.refresh()
        #expect(flow.screen == .done)
        #expect(await agent.loginInputs.map(\.names) == [["id", "password"], ["captcha"], ["id", "password"]])
    }

    @Test func siteQuestionIsAnsweredOnlyWithOfferedChoices() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .choice, approvalPolls: 1))
        let flow = try await opened(agent)
        await flow.submit(Self.good)
        await flow.refresh()
        await flow.refresh()
        guard case .choice(let asking) = flow.screen else {
            Issue.record("선택 화면이 나와야 한다: \(flow.screen)")
            return
        }
        #expect(asking.choices == ["등록", "등록 안 함"])
        await flow.choose("아무 말")
        #expect(await agent.loginInputs.count == 1)
        await flow.choose("등록 안 함")
        await flow.refresh()
        #expect(flow.screen == .done)
        #expect(await agent.loginInputs.last?.names == ["choice"])
    }

    // MARK: 손 넘기기 (D149)

    @Test func loginQuestionCarriesAHandoverLikeTaskQuestions() throws {
        let json = """
        {"login":{"login_id":"l_1","site":"claude","method":"password","state":"need_choice","step":4,"message":"","expires_in_s":300,\
        "text":"확인 문제를 직접 풀어 주세요","choices":["다 했어요","그만하기"],\
        "handover":{"id":"h_1","reason":"사람 확인 퍼즐","host":"Login.Example.test","frame":"/v1/handover/h_1/frame","input":"/v1/handover/h_1/input","idle_close_s":300}}}
        """
        let login = try SiteFixture.login(json)
        #expect(login.handover == AgentHandover(id: "h_1", reason: "사람 확인 퍼즐", host: "login.example.test", idleClose: 300))
        #expect(login.choices == ["다 했어요", "그만하기"])
    }

    @Test func aBrokenHandoverIsDroppedButTheLoginStays() throws {
        let bad = """
        {"login":{"login_id":"l_1","site":"claude","method":"password","state":"need_choice","step":4,"message":"",\
        "text":"t","choices":["다 했어요","그만하기"],"handover":{"id":"../x"}}}
        """
        let login = try SiteFixture.login(bad)
        #expect(login.handover == nil)
        #expect(login.state == .needChoice)
        let notAString = #"{"login":{"login_id":"l_1","state":"need_choice","step":1,"choices":["a"],"handover":"h_1"}}"#
        #expect(try SiteFixture.login(notAString).handover == nil)
        // 고르는 화면이 아니면 쓰지 않는다
        let input = #"{"login":{"login_id":"l_1","state":"need_input","step":1,"fields":[{"name":"id"}],"handover":{"id":"h_1"}}}"#
        #expect(try SiteFixture.login(input).handover == nil)
        // 예전 꼴(handover 없음)은 그대로
        #expect(try SiteFixture.login(SiteFixture.choice).handover == nil)
    }

    @Test func solvingTheHandoverAnswersTheLoginWithTheFirstChoice() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .handover))
        let flow = try await opened(agent)
        await flow.submit(Self.good)
        await flow.refresh()
        guard case .choice(let asking) = flow.screen, let handover = asking.handover else {
            Issue.record("손 넘기기가 붙은 선택 화면이 나와야 한다: \(flow.screen)")
            return
        }
        // 작업 질문과 같은 화면 길(frame·input)을 쓴다
        _ = try await flow.handoverAgent.handoverFrame(id: handover.id)
        try await flow.handoverAgent.handoverInput(id: handover.id, .tap(x: 10, y: 20))
        #expect(flow.isHandoverStop("그만하기", in: asking))
        #expect(!flow.isHandoverStop("다 했어요", in: asking))
        await flow.choose("다 했어요")
        #expect(await agent.loginInputs.last?.names == ["choice"])
        await flow.refresh()
        #expect(flow.screen == .done)
        // 답한 뒤에는 그 화면이 닫힌다
        await #expect(throws: AgentError.handoverClosed) { try await agent.handoverFrame(id: handover.id) }
    }

    @Test func stoppingIsOnlyForHandoverQuestions() throws {
        let flow = SiteLoginFlow(site: "naver", agent: MockAgentClient(v2: true, sites: MockSites()), pollInterval: .seconds(3600))
        let plain = try SiteFixture.login(SiteFixture.choice)
        // 손 넘기기가 없는 물음의 두 번째 선택지는 그대로 답이다
        #expect(!flow.isHandoverStop("등록 안 함", in: plain))
    }

    @Test func verificationCodeIsAskedOnItsOwnScreen() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .code))
        let flow = try await opened(agent)
        await flow.submit(Self.good)
        await flow.refresh()
        guard case .input(let asking) = flow.screen else {
            Issue.record("인증 번호 화면이 나와야 한다: \(flow.screen)")
            return
        }
        #expect(asking.fields.map(\.name) == ["code"])
        await flow.submit(["code": "123456"])
        await flow.refresh()
        #expect(flow.screen == .done)
    }

    @Test func emptyOrOverlongValuesAreNotSent() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites())
        let flow = try await opened(agent)
        await flow.submit(["id": SiteFixture.id, "password": ""])
        await flow.submit(["id": SiteFixture.id])
        await flow.submit(["id": SiteFixture.id, "password": String(repeating: "a", count: 257)])
        await flow.submit(["id": SiteFixture.id, "password": SiteFixture.password, "extra": "x"])
        #expect(await agent.loginInputs.isEmpty)
        guard case .input = flow.screen else {
            Issue.record("입력 화면에 머물러야 한다: \(flow.screen)")
            return
        }
    }

    @Test func unknownFieldStopsAndCancelsOnTheMac() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .unknownField))
        let flow = flow(agent)
        await flow.start()
        await flow.refresh()
        guard case .stopped(let title, _, _) = flow.screen else {
            Issue.record("멈춰야 한다: \(flow.screen)")
            return
        }
        #expect(title == "이 화면은 앱에서 처리할 수 없어요")
        #expect(flow.isFinished)
        // 모르는 칸에는 아무것도 보내지 않고, 맥의 로그인도 그만두게 한다
        await flow.submit(["birthday": "19900101"])
        try await wait { flow.stoppedAt != nil }
        for _ in 0..<200 where await agent.loginCancels == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await agent.loginCancels == 1)
        #expect(await agent.loginInputs.isEmpty)
    }

    @Test func blockedLoginDoesNotOfferRetry() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .blocked))
        let flow = try await opened(agent)
        await flow.submit(Self.good)
        await flow.refresh()
        guard case .stopped(let title, let detail, let canRetry) = flow.screen else {
            Issue.record("멈춰야 한다: \(flow.screen)")
            return
        }
        // 누가 어떻게 막았는지는 맥의 말에만 있다 (D83)
        #expect(title == "로그인이 막혔어요")
        #expect(detail == MockSites.blockedMessage)
        #expect(!canRetry)
    }

    @Test func loginThatCannotBeKeptShowsTheMacsWordsAndNoRetry() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .unsupportedLogin))
        let flow = try await opened(agent)
        await flow.submit(Self.good)
        await flow.refresh()
        guard case .stopped(let title, let detail, let canRetry) = flow.screen else {
            Issue.record("멈춰야 한다: \(flow.screen)")
            return
        }
        #expect(title == "이 사이트는 아직 로그인해 둘 수 없어요")
        #expect(detail == MockSites.unsupportedLoginMessage)
        #expect(!canRetry)
    }

    /// 실패의 말: 까닭이 맥의 말에만 있는 종류는 그 말을, 앱이 아는 종류는 앱의 말을 쓴다 (D83)
    @Test func failureWordsComeFromTheMacOnlyWhereTheAppCannotKnow() {
        let said = "가상사이트가 이 브라우저의 접속을 막았어요. 여기서 멈출게요 — 다시 해도 같아요."
        func words(_ reason: String?, _ message: String = said) -> (title: String, detail: String, canRetry: Bool) {
            SiteLoginFlow.failure(reason, siteName: "가상사이트", message: message)
        }
        // 맥의 말을 그대로
        #expect(words("blocked").detail == said)
        #expect(!words("blocked").canRetry)
        #expect(words("unsupported_login").detail == said)
        #expect(!words("unsupported_login").canRetry)
        for reason in ["host_refused", "not_https", "앱이_모르는_종류"] {
            #expect(words(reason).title == "로그인하지 못했어요")
            #expect(words(reason).detail == said)
            #expect(words(reason).canRetry)
        }
        #expect(words(nil).detail == said)
        // 앞뒤 빈칸은 떼고, 빈 말은 없는 것으로 본다
        #expect(words("blocked", "  \(said)\n").detail == said)
        #expect(words("blocked", "  \n").title == "가상사이트가 로그인을 막았어요")
        // 앱이 아는 종류는 앱의 말로
        for reason in ["wrong_input", "unsupported_page", "timeout", "browser_error"] {
            #expect(!words(reason).detail.contains(said))
            #expect(words(reason).canRetry)
            #expect(words(reason).title == SiteLoginFlow.failure(reason, siteName: "가상사이트").title)
        }
        // 맥의 말이 비면 전과 같은 말
        #expect(words("blocked", "").detail.contains("계정 보호 안내"))
        #expect(words("unsupported_login", "").detail == "가상사이트의 로그인 화면은 에이전트가 아직 다루지 못해요. 로그인은 되지 않았어요.")
        #expect(!words("unsupported_login", "").canRetry)
        #expect(words("host_refused", "").detail == "로그인은 되지 않았어요. 잠시 뒤에 다시 시도해 주세요.")
    }

    @Test func unsupportedPageKeepsTheTimeItStopped() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .unsupported))
        let flow = try await opened(agent)
        let before = Date.now
        await flow.submit(Self.good)
        await flow.refresh()
        guard case .stopped(let title, _, let canRetry) = flow.screen else {
            Issue.record("멈춰야 한다: \(flow.screen)")
            return
        }
        #expect(title == "처리할 줄 모르는 화면이 나왔어요")
        #expect(canRetry)
        #expect(try #require(flow.stoppedAt) >= before)
    }

    @Test func lostAnswerIsNeverSentTwice() async throws {
        // 입력은 맥에 들어갔는데 응답만 끊겼다: 다시 보내지 않고 지금 상태를 물어 이어 간다
        let agent = ScriptedSiteAgent(MockSites(approvalPolls: 1))
        let flow = try await opened(agent)
        await agent.failNextInput(.unreachable, arrives: true)
        await flow.submit(Self.good)
        guard case .approval = flow.screen else {
            Issue.record("휴대폰 승인으로 이어져야 한다: \(flow.screen)")
            return
        }
        #expect(flow.inputNotice == nil)
        #expect(await agent.inputCalls == 1)
        #expect(await agent.inner.loginInputs.count == 1)
    }

    @Test func undeliveredInputIsAskedAgainFromTheUser() async throws {
        // 입력이 맥에 닿지 않았다: 앱이 값을 들고 있다가 다시 보내지 않는다. 사용자가 다시 넣는다
        let agent = ScriptedSiteAgent()
        let flow = try await opened(agent)
        await agent.failNextInput(.slow)
        await flow.submit(Self.good)
        guard case .input(let same) = flow.screen else {
            Issue.record("같은 입력 화면으로 돌아와야 한다: \(flow.screen)")
            return
        }
        #expect(same.step == 1)
        #expect(flow.inputNotice == "입력이 맥에 닿지 않았어요. 다시 입력해 주세요.")
        #expect(await agent.inputCalls == 1)
        #expect(await agent.inner.loginInputs.isEmpty)
        await flow.submit(Self.good)
        #expect(flow.inputNotice == nil)
        #expect(await agent.inner.loginInputs.count == 1)
    }

    @Test func unknownDeliveryWaitsWhileTheMacIsUnreachable() async throws {
        let agent = ScriptedSiteAgent(MockSites(approvalPolls: 1))
        let flow = try await opened(agent)
        await agent.failNextInput(.unreachable, arrives: true)
        await agent.failPolls(.unreachable)
        await flow.submit(Self.good)
        // 들어갔는지 모르는 동안에는 입력칸을 다시 내밀지 않는다
        #expect(flow.screen == .working("확인하고 있어요"))
        await flow.submit(Self.good)
        #expect(await agent.inputCalls == 1)
        await flow.refresh()
        await flow.refresh()
        #expect(flow.isOffline)
        await agent.failPolls(nil)
        await flow.refresh()
        #expect(!flow.isOffline)
        guard case .approval = flow.screen else {
            Issue.record("휴대폰 승인으로 이어져야 한다: \(flow.screen)")
            return
        }
    }

    @Test func staleStepShowsTheCurrentScreenInstead() async throws {
        let agent = ScriptedSiteAgent()
        let flow = try await opened(agent)
        await agent.failNextInput(.staleStep)
        await flow.submit(Self.good)
        guard case .input = flow.screen else {
            Issue.record("지금 화면을 다시 보여 줘야 한다: \(flow.screen)")
            return
        }
        #expect(await agent.inner.loginInputs.isEmpty)
    }

    @Test func rejectedInputIsReportedWithoutEchoingIt() async throws {
        let agent = ScriptedSiteAgent()
        let flow = try await opened(agent)
        await agent.failNextInput(.server("invalid_request: \(SiteFixture.password)"))
        await flow.submit(Self.good)
        // 서버가 무엇을 돌려주든 화면에는 정해진 말만 나온다
        #expect(flow.inputNotice == "입력을 보내지 못했어요. 다시 입력해 주세요.")
        guard case .input = flow.screen else {
            Issue.record("입력 화면에 머물러야 한다: \(flow.screen)")
            return
        }
    }

    @Test func forgottenLoginIsCheckedAgainstTheSiteStatus() async throws {
        // 서버가 로그인 번호를 잊었다: 로그인된 것이 아니면 다시 시도하게 한다
        let agent = ScriptedSiteAgent()
        let flow = try await opened(agent)
        await agent.forget()
        await flow.refresh()
        guard case .stopped(let title, _, let canRetry) = flow.screen else {
            Issue.record("멈춰야 한다: \(flow.screen)")
            return
        }
        #expect(title == "로그인 기록이 사라졌어요")
        #expect(canRetry)

        // 이미 로그인된 것으로 확인되면 로그인된 것으로 본다
        let done = ScriptedSiteAgent(MockSites(loggedIn: true))
        let second = try await opened(done)
        var notified = 0
        second.onLoggedIn = { notified += 1 }
        await done.forget()
        await second.submit(Self.good)
        #expect(second.screen == .done)
        #expect(notified == 1)
    }

    @Test func closingCancelsAnUnfinishedLoginOnTheMac() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites())
        let flow = try await opened(agent)
        flow.close()
        #expect(!flow.isActive)
        for _ in 0..<200 where await agent.loginCancels == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await agent.loginCancels == 1)
        // 두 번 닫아도 한 번만 그만두게 한다 (화면이 사라질 때 한 번 더 불린다)
        flow.close()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await agent.loginCancels == 1)
        // 닫은 뒤에는 입력도 조회도 하지 않는다
        await flow.submit(Self.good)
        await flow.refresh()
        #expect(await agent.loginInputs.isEmpty)
    }

    @Test func startProblemsAreExplainedAndCanBeRetried() async throws {
        let agent = ScriptedSiteAgent()
        await agent.failStart(.rateLimited)
        let flow = flow(agent)
        await flow.start()
        guard case .stopped(let title, let detail, let canRetry) = flow.screen else {
            Issue.record("멈춰야 한다: \(flow.screen)")
            return
        }
        #expect(title == "로그인을 시작하지 못했어요")
        #expect(detail.contains("10분쯤 뒤"))
        #expect(canRetry)
        #expect(!flow.isActive)
        await agent.failStart(nil)
        await flow.start()
        #expect(flow.screen == .opening)
        #expect(flow.isActive)

        #expect(SiteLoginFlow.startProblem(for: AgentError.unreachable).contains("맥에 연결할 수 없어요"))
        #expect(SiteLoginFlow.startProblem(for: AgentError.busy).contains("다른 일을 하고 있어요"))
        #expect(SiteLoginFlow.startProblem(for: AgentError.conflict).contains("아직 쓸 수 없어요"))
    }

    @Test func retryAfterFailureStartsANewLogin() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .unsupported))
        let flow = try await opened(agent)
        await flow.submit(Self.good)
        await flow.refresh()
        #expect(flow.isFinished)
        await flow.start()
        #expect(flow.screen == .opening)
        #expect(flow.stoppedAt == nil)
        #expect(await agent.loginStarts == 2)
    }

    @Test func accountListShowsStatusAndLogsOut() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites(loggedIn: true))
        let model = SiteAccountsModel(agent: agent)
        await model.load()
        #expect(model.isSupported)
        #expect(model.sites.map(\.status) == [.loggedIn])
        #expect(model.sites.first?.status.badge.text == "로그인됨")
        await model.check("naver")
        #expect(model.sites.first?.checkedAt != nil)
        await model.logout("naver")
        #expect(model.sites.map(\.status) == [.loggedOut])
        #expect(model.problem == nil)

        // 사이트 로그인을 모르는 맥이면 카드를 두지 않는다
        let old = SiteAccountsModel(agent: MockAgentClient(v2: true))
        await old.load()
        #expect(!old.isSupported)
        #expect(old.sites.isEmpty)
    }
}

// MARK: - 대화

@MainActor
@Suite("사이트 로그인 대화")
struct SiteLoginChatTests {
    let context: ModelContext
    let meeting: Meeting

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        meeting = Meeting(title: "주간 회의")
        context.insert(meeting)
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
    }

    private func session(_ agent: any AgentProviding, cloud: FakeAskProvider = FakeAskProvider([])) async -> AskSession {
        let session = AskSession(provider: cloud, agent: agent, pollInterval: .zero)
        session.attach(context)
        await session.checkAgent()
        return session
    }

    @Test func loginRequestShowsTheLoginCardOnTheLastMessage() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites())
        let session = await session(agent)
        #expect(session.siteLoginPrompt == nil)
        await session.send("네이버 로그인해줘", meetings: [meeting])

        let last = try #require(session.messages.last)
        #expect(last.role == .assistant)
        #expect(last.text == "네이버 로그인 화면을 열게요.")
        #expect(session.siteLoginPrompt == AskSession.SiteLoginPrompt(messageID: last.id, site: "naver"))
        #expect(!session.isLoading)
        // 맥에는 아직 아무 로그인도 시작되지 않았다 (화면을 열어야 시작한다)
        #expect(await agent.loginStarts == 0)

        // 다른 말이 오가면 카드는 사라진다
        await session.send("안녕", meetings: [meeting])
        #expect(session.siteLoginPrompt == nil)
    }

    @Test func logoutOrLongSentencesDoNotOpenTheLoginScreen() async throws {
        // 로그인 화면으로 가지 않은 말은 평소처럼 처리된다 (가짜 맥은 Claude로 넘긴다)
        func cloud() -> FakeAskProvider { FakeAskProvider([.success(.init(answer: "답", found: true, citations: []))]) }
        let session = await session(MockAgentClient(v2: true, sites: MockSites()), cloud: cloud())
        await session.send("네이버 로그아웃해줘", meetings: [meeting])
        #expect(session.siteLoginPrompt == nil)
        // 사이트 로그인을 모르는 맥은 로그인 화면을 열지 않는다
        let old = await self.session(MockAgentClient(v2: true), cloud: cloud())
        await old.send("네이버 로그인해줘", meetings: [meeting])
        #expect(old.siteLoginPrompt == nil)
    }

    @Test func passwordNeverEntersTheConversationOrAnyModelRequest() async throws {
        let agent = ScriptedSiteAgent(MockSites(approvalPolls: 1))
        let cloud = FakeAskProvider([.success(.init(answer: "출시일은 12월 3일입니다.", found: true, citations: []))])
        let session = await session(agent, cloud: cloud)
        await session.send("네이버 로그인해줘", meetings: [meeting])
        let prompt = try #require(session.siteLoginPrompt)

        // 로그인 화면이 하는 일: 열고, 입력을 보내고, 승인을 기다린다
        let flow = try #require(session.siteLoginFlow(for: prompt.site))
        await flow.start()
        await flow.refresh()
        await flow.submit(["id": SiteFixture.id, "password": SiteFixture.password])
        await flow.refresh()
        await flow.refresh()
        #expect(flow.screen == .done)

        // 대화에는 결과 한 줄만 남고, 카드는 사라진다
        #expect(session.siteLoginPrompt == nil)
        #expect(session.messages.last?.text == AskSession.siteLoggedInText("naver"))
        #expect(session.messages.last?.text.contains("아이디와 비밀번호는 맥에 저장하지 않았어요") == true)
        // 그 한 줄은 완료 카드로 그린다 (사이트 이름만 표시로 남는다)
        #expect(session.messages.last?.siteLoggedIn == "naver")

        // 그 뒤의 말이 맥의 대화 담당과 Claude로 갈 때도 실리지 않는다
        await session.send("안녕", meetings: [meeting])
        await session.send("출시일이 언제야?", meetings: [meeting], engine: .cloud)

        let secrets = [SiteFixture.password, SiteFixture.id]
        for message in session.messages {
            for secret in secrets { #expect(!message.text.contains(secret)) }
        }
        for record in try context.fetch(FetchDescriptor<ChatRecord>()) {
            for secret in secrets {
                #expect(!record.text.contains(secret))
                #expect(record.siteLoggedIn?.contains(secret) != true)
                for data in [record.agentData, record.citationsData, record.replyData].compactMap({ $0 }) {
                    #expect(!String(decoding: data, as: UTF8.self).contains(secret))
                }
            }
        }
        let spoken = await agent.spoken
        #expect(spoken.count >= 2)
        for line in spoken {
            for secret in secrets { #expect(!line.contains(secret)) }
        }
        #expect(!cloud.requests.isEmpty)
        let sentToCloud = String(decoding: try JSONEncoder().encode(cloud.requests), as: UTF8.self)
        for secret in secrets { #expect(!sentToCloud.contains(secret)) }
        // 흐름 객체에도 남아 있지 않다 (상태에는 값이 돌아오지 않는다)
        #expect(!String(describing: flow.login).contains(SiteFixture.password))
    }

    @Test func loginResultIsWrittenOnlyOnce() async throws {
        let session = await session(MockAgentClient(v2: true, sites: MockSites()))
        await session.send("네이버 로그인해줘", meetings: [meeting])
        let count = session.messages.count
        session.siteLoggedIn("naver")
        session.siteLoggedIn("naver")
        #expect(session.messages.count == count + 1)
    }

    @Test func loginDoneCardReplacesTheLoginCardAndSurvivesReopening() async throws {
        let agent = MockAgentClient(v2: true, sites: MockSites())
        let session = await session(agent)
        await session.send("네이버 로그인해줘", meetings: [meeting])
        let asked = try #require(session.messages.last)
        #expect(asked.siteLogin == "naver")
        #expect(asked.siteLoggedIn == nil)

        session.siteLoggedIn("naver")
        // 로그인 카드는 사라지고, 바로 아래에 완료 카드가 붙는다
        #expect(session.siteLoginPrompt == nil)
        let done = try #require(session.messages.last)
        #expect(done.role == .assistant)
        #expect(done.siteLoggedIn == "naver")
        #expect(done.siteLogin == nil)
        #expect(session.messages.filter { $0.siteLoggedIn != nil }.count == 1)

        // 앱을 다시 열어도 완료 카드로 보인다. 로그인 카드는 되살아나지 않는다
        try context.save()
        let reopened = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        reopened.attach(context)
        #expect(reopened.messages.last?.siteLoggedIn == "naver")
        #expect(reopened.messages.last?.text == AskSession.siteLoggedInText("naver"))
        #expect(reopened.messages.filter { $0.siteLogin != nil }.isEmpty)
        #expect(reopened.siteLoginPrompt == nil)
    }

    @Test func loginDoneCardIsOnlyForAFinishedLogin() async throws {
        // 로그인을 부탁하지 않았거나, 그 뒤로 다른 말이 오갔으면 완료 카드를 붙이지 않는다
        let session = await session(MockAgentClient(v2: true, sites: MockSites()))
        session.siteLoggedIn("naver")
        #expect(session.messages.isEmpty)
        await session.send("네이버 로그인해줘", meetings: [meeting])
        await session.send("안녕", meetings: [meeting])
        session.siteLoggedIn("naver")
        #expect(session.messages.filter { $0.siteLoggedIn != nil }.isEmpty)
    }

    // MARK: - 내 정보의 연결 상태 (D49·D51)

    @Test func connectionSummarySaysWhatIsConnected() {
        let naver = SiteStatus(site: "naver", name: "네이버", status: .loggedIn, checkedAt: nil, methods: ["password"])
        let out = SiteStatus(site: "naver", name: "네이버", status: .loggedOut, checkedAt: nil, methods: ["password"])
        let ready = MailAccount(provider: "naver", address: "me@naver.test", status: .ready, isDefault: true, checkedAt: nil)
        let failed = MailAccount(provider: "gmail", address: "me@gmail.test", status: .authFailed, isDefault: false, checkedAt: nil)

        // 브라우저 로그인과 메일 계정은 따로 말한다
        #expect(ConnectionSummary.browser(supported: true, sites: [naver]) == "네이버")
        #expect(ConnectionSummary.browser(supported: true, sites: [out]) == "로그인 안 됨")
        #expect(ConnectionSummary.browser(supported: true, sites: []) == "로그인 안 됨")
        #expect(ConnectionSummary.mail(supported: true, accounts: [ready, failed]) == "1개 연결됨")
        #expect(ConnectionSummary.mail(supported: true, accounts: [failed]) == "연결 안 됨")
        // 사이트가 많으면 이름 대신 수로
        let many = ["a", "b", "c"].map { SiteStatus(site: $0, name: $0, status: .loggedIn, checkedAt: nil, methods: []) }
        #expect(ConnectionSummary.browser(supported: true, sites: many) == "3곳 로그인됨")
        // 맥에 연결되지 않았거나 맥이 알리지 않은 것은 연결된 것처럼 말하지 않는다
        #expect(ConnectionSummary.browser(supported: false, sites: [naver]) == "맥 연결 필요")
        #expect(ConnectionSummary.mail(supported: false, accounts: [ready]) == "맥 연결 필요")
        // 주소는 넣지 않는다
        #expect(!ConnectionSummary.mail(supported: true, accounts: [ready]).contains("@"))
    }
}

// 연동 센터의 사이트 이름 (D142): 맥이 이름 자리에 주소를 보내도 아는 서비스는 서비스 이름으로
@Suite("연동 센터: 사이트 이름")
@MainActor
struct SiteServiceNameTests {
    @Test func knownDomainsBecomeServiceNames() {
        #expect(SiteName.service("saramin.co.kr") == "사람인")
        #expect(SiteName.service("www.youtube.com") == "유튜브")
        #expect(SiteName.service("claude.ai") == "Claude")
        // 모르는 주소는 그대로, 이미 이름이면 그대로
        #expect(SiteName.service("example.com") == "example.com")
        #expect(SiteName.service("네이버") == "네이버")
        #expect(SiteName.service("My Site") == "My Site")
    }

    @Test func aDomainNameStillFindsItsIcon() throws {
        let json = """
        {"sites":[{"site":"saramin","name":"saramin.co.kr","status":"logged_out","methods":["password"]},
                  {"site":"naver","name":"네이버","status":"logged_in","host":"nid.naver.com"}]}
        """
        let sites = try AgentHTTPClient.decodeSites(data: Data(json.utf8), status: 200)
        #expect(sites[0].name == "사람인")
        // 이름을 바꿔도 아이콘은 그 주소로 찾는다
        #expect(sites[0].host == "saramin.co.kr")
        #expect(sites[1].name == "네이버" && sites[1].host == "nid.naver.com")
    }
}
