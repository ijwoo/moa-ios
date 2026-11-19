import Foundation
import Testing
@testable import MeetingSummary

// 사이트 로그인의 아이디·비밀번호를 이 아이폰의 키체인에 두고 Face ID로 꺼내 쓰기 (D78).
// 시험은 메모리에만 있는 가짜 보관소를 쓴다 (얼굴 확인은 정해 둔 답으로 대신한다). 아이디·비밀번호·주소는 모두 가짜다.

private enum VaultFixture {
    static let id = "minsu_demo"
    static let password = "Kq7!가상-비밀번호"
    static let good = ["id": id, "password": password]
    /// 가짜 맥은 "wrong"이 들어 있으면 틀린 것으로 본다
    static let badPassword = "wrong-가상"

    static func saved(password: String = password, host: String? = nil) -> SavedLogin {
        SavedLogin(entries: ["id": .init(value: id, host: host), "password": .init(value: password, host: host)])
    }

    static func login(_ names: [String], host: String? = nil, step: Int = 1) -> SiteLogin {
        SiteLogin(
            id: "l_1", site: "shop", method: "password", state: .needInput, step: step, message: "",
            fields: names.map { SiteLogin.Field(name: $0, label: "", secret: $0 == "password") }, host: host
        )
    }
}

@Suite("로그인 값 보관: 무엇을 어디에 넣는가")
struct SavedLoginTests {
    @Test func hostIsReadOnlyWhenItCanBeCompared() throws {
        func login(_ host: String?) throws -> SiteLogin {
            let key = host.map { #","host":"\#($0)""# } ?? ""
            let json = #"{"login":{"login_id":"l_1","state":"need_input","step":1,"fields":[{"name":"id"}]\#(key)}}"#
            return try AgentHTTPClient.decodeSiteLogin(data: Data(json.utf8), status: 200)
        }
        // 소문자로 맞춘다
        let known = try login("Accounts.Shop.TEST")
        #expect(known.host == "accounts.shop.test")
        #expect(!known.hostUnreadable)
        // 호스트를 알려 주지 않는 로그인(네이버)
        let none = try login(nil)
        #expect(none.host == nil)
        #expect(!none.hostUnreadable)
        // 견줄 수 없는 모양이면 "모른다"가 아니라 "읽지 못했다"로 둔다 (그런 화면에는 넣지도 저장하지도 않는다)
        for odd in ["", "a b", "shop.test/login", "me@shop.test", "shop.test?x=1", String(repeating: "a", count: 254)] {
            let unreadable = try login(odd)
            #expect(unreadable.host == nil)
            #expect(unreadable.hostUnreadable)
        }
    }

    @Test func savedValuesGoOnlyToTheHostTheyCameFrom() {
        let saved = VaultFixture.saved(host: "login.shop.test")
        let same = VaultFixture.login(["id", "password"], host: "login.shop.test")
        #expect(saved.values(for: same) == VaultFixture.good)
        #expect(saved.info.names(for: same) == ["id", "password"])
        // 호스트가 저장할 때와 다르면 넣지 않는다 (비슷해 보여도, 알려 주지 않아도)
        for other in ["login.shop.test.evil.test", "shop.test", nil] as [String?] {
            let login = VaultFixture.login(["id", "password"], host: other)
            #expect(saved.values(for: login).isEmpty)
            #expect(saved.info.names(for: login).isEmpty)
        }
        // 호스트를 읽지 못한 화면에는, 호스트 없이 저장한 값도 넣지 않는다
        var unreadable = VaultFixture.login(["id", "password"])
        unreadable.hostUnreadable = true
        #expect(VaultFixture.saved().values(for: unreadable).isEmpty)
        #expect(VaultFixture.saved().info.names(for: unreadable).isEmpty)
        // 호스트를 알려 주지 않는 로그인(네이버)에서 저장한 값은 그런 로그인에만
        #expect(VaultFixture.saved().values(for: VaultFixture.login(["id", "password"])) == VaultFixture.good)
        #expect(VaultFixture.saved().values(for: same).isEmpty)
        // 화면이 묻는 칸에만: 비밀번호와 보안문자를 묻는 화면에는 비밀번호만
        let captcha = VaultFixture.login(["password", "captcha"], host: "login.shop.test")
        #expect(saved.values(for: captcha) == ["password": VaultFixture.password])
        #expect(saved.info.names(for: captcha) == ["password"])
        #expect(saved.values(for: VaultFixture.login(["code"], host: "login.shop.test")).isEmpty)
    }

    @Test func whatIsKnownWithoutTheFaceCheckHasNoValues() throws {
        let saved = VaultFixture.saved(host: "login.shop.test")
        let info = saved.info
        #expect(info.fields == [.init(name: "id", host: "login.shop.test"), .init(name: "password", host: "login.shop.test")])
        #expect(info.summary == "아이디·비밀번호")
        #expect(SavedLoginInfo(fields: [.init(name: "password", host: nil)]).summary == "비밀번호")
        let text = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        #expect(!text.contains(VaultFixture.id))
        #expect(!text.contains(VaultFixture.password))
        // 보안문자·인증 번호는 저장하는 칸이 아니다
        #expect(SavedLogin.names == ["id", "password"])
    }

    @Test func memoryVaultBehavesLikeTheRealOne() async throws {
        let vault = MemoryLoginVault()
        #expect(vault.sites().isEmpty)
        #expect(vault.info(site: "naver") == nil)
        #expect(await vault.read(site: "naver", reason: "") == .gone)
        try vault.save(VaultFixture.saved(), site: "naver")
        #expect(vault.sites() == ["naver"])
        #expect(vault.info(site: "naver")?.summary == "아이디·비밀번호")
        #expect(await vault.read(site: "naver", reason: "") == .value(VaultFixture.saved()))
        vault.remove(site: "naver")
        #expect(vault.sites().isEmpty)
        vault.saveFails = true
        #expect(throws: LoginVaultError.self) { try vault.save(VaultFixture.saved(), site: "naver") }
        #expect(vault.stored(site: "naver") == nil)
    }
}

@Suite("로그인 값 보관: 로그인 흐름")
@MainActor
struct LoginKeepingFlowTests {
    private func flow(_ agent: any AgentProviding, vault: (any LoginVault)?, site: String = "naver") -> SiteLoginFlow {
        SiteLoginFlow(site: site, agent: agent, pollInterval: .seconds(3600), vault: vault)
    }

    /// 입력 화면이 나올 때까지 연다
    private func opened(_ agent: any AgentProviding, vault: (any LoginVault)?) async throws -> (SiteLoginFlow, SiteLogin) {
        let flow = flow(agent, vault: vault)
        await flow.start()
        await flow.refresh()
        return (flow, try input(flow))
    }

    private func input(_ flow: SiteLoginFlow) throws -> SiteLogin {
        guard case .input(let login) = flow.screen else {
            Issue.record("입력 화면이 나와야 한다: \(flow.screen)")
            throw AgentError.invalidResponse
        }
        return login
    }

    /// 조회를 되풀이해 끝까지 간다
    private func finish(_ flow: SiteLoginFlow) async {
        for _ in 0..<6 where !flow.isFinished { await flow.refresh() }
    }

    @Test func nothingIsKeptUnlessTheUserTurnsItOn() async throws {
        let vault = MemoryLoginVault()
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1))
        let (flow, login) = try await opened(agent, vault: vault)
        // 저장할 수 있는 기기라 스위치는 보이지만, 꺼진 채로 시작한다
        #expect(flow.canKeep)
        #expect(flow.offersKeeping(for: login))
        #expect(!flow.keeps)
        #expect(flow.savedNames(for: login).isEmpty)
        #expect(flow.copy.inputFooter(for: login, keeps: flow.keeps, saved: flow.savedInfo != nil).contains("이 아이폰에도 맥에도 저장하지 않고"))
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(flow.screen == .done)
        #expect(vault.sites().isEmpty)
        #expect(flow.phoneKeeping == .nothing)
        #expect(flow.copy.doneDetail(phone: flow.phoneKeeping).hasSuffix("아이디와 비밀번호는 저장하지 않았어요."))
    }

    @Test func turnedOnItIsKeptOnlyAfterTheLoginSucceeds() async throws {
        let vault = MemoryLoginVault()
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1))
        let (flow, login) = try await opened(agent, vault: vault)
        flow.keeps = true
        #expect(flow.copy.inputFooter(for: login, keeps: flow.keeps).contains("로그인되면 이 아이폰의 키체인에만 보관하고, Face ID로 확인한 뒤에만 꺼내요"))
        await flow.submit(VaultFixture.good)
        await flow.refresh()
        // 휴대폰 승인을 기다리는 동안에는 아직 넣지 않는다
        guard case .approval = flow.screen else {
            Issue.record("휴대폰 승인을 기다려야 한다: \(flow.screen)")
            return
        }
        #expect(vault.sites().isEmpty)
        await finish(flow)
        #expect(flow.screen == .done)
        // 네이버 로그인은 호스트를 알려 주지 않으므로 호스트 없이 저장된다
        #expect(vault.stored(site: "naver") == VaultFixture.saved())
        #expect(flow.phoneKeeping == .saved)
        #expect(flow.savedInfo?.summary == "아이디·비밀번호")
        #expect(flow.copy.doneDetail(phone: flow.phoneKeeping).contains("이 아이폰의 키체인에 보관했고, Face ID로 확인한 뒤에만 꺼내요. 맥에는 저장하지 않았어요."))
        // 맥에는 여느 때처럼 한 번만 갔다
        #expect(await agent.loginInputs.map(\.names) == [["id", "password"]])
    }

    @Test func turningItOnAtALaterScreenKeepsWhatWasSentBefore() async throws {
        // 로그인 칸 → 그림 확인 → 로그인 칸이 한 번 더: 두 번째 로그인 칸에서 스위치를 켜도 저장된다
        let vault = MemoryLoginVault()
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .relogin, approvalPolls: 1))
        let (flow, _) = try await opened(agent, vault: vault)
        await flow.submit(VaultFixture.good)
        await flow.refresh()
        // 그림을 보고 답하는 화면에는 스위치가 없다 (아이디도 비밀번호도 묻지 않는다)
        let picture = try input(flow)
        #expect(!flow.offersKeeping(for: picture))
        await flow.submit(["captcha": "지우개"])
        await flow.refresh()
        let again = try input(flow)
        #expect(flow.offersKeeping(for: again))
        flow.keeps = true
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(flow.screen == .done)
        #expect(vault.stored(site: "naver") == VaultFixture.saved())
    }

    @Test func turningItOffBeforeTheEndKeepsNothing() async throws {
        let vault = MemoryLoginVault()
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .relogin, approvalPolls: 1))
        let (flow, _) = try await opened(agent, vault: vault)
        flow.keeps = true
        await flow.submit(VaultFixture.good)
        await flow.refresh()
        await flow.submit(["captcha": "지우개"])
        await flow.refresh()
        flow.keeps = false
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(flow.screen == .done)
        #expect(vault.sites().isEmpty)
        #expect(flow.phoneKeeping == .nothing)
    }

    @Test func aLoginThatDidNotSucceedKeepsNothing() async throws {
        // 사이트가 막았다
        let vault = MemoryLoginVault()
        let (blocked, _) = try await opened(MockAgentClient(v2: true, sites: MockSites(script: .blocked)), vault: vault)
        blocked.keeps = true
        await blocked.submit(VaultFixture.good)
        await finish(blocked)
        #expect(blocked.isFinished)
        #expect(blocked.screen != .done)
        #expect(vault.sites().isEmpty)

        // 승인을 기다리다 닫았다
        let (closed, _) = try await opened(MockAgentClient(v2: true, sites: MockSites(script: .hold)), vault: vault)
        closed.keeps = true
        await closed.submit(VaultFixture.good)
        await closed.refresh()
        closed.close()
        #expect(vault.sites().isEmpty)

        // 세 번 틀려 멈췄다
        let (wrong, _) = try await opened(MockAgentClient(v2: true, sites: MockSites()), vault: vault)
        wrong.keeps = true
        for _ in 0..<3 {
            await wrong.submit(["id": VaultFixture.id, "password": VaultFixture.badPassword])
            await wrong.refresh()
        }
        #expect(wrong.isFinished)
        #expect(vault.sites().isEmpty)

        // 맥이 로그인을 잊었는데 사이트는 로그인된 것으로 나온다: 보낸 값으로 된 것인지 모르니 저장하지 않는다
        let agent = ScriptedSiteAgent(MockSites(loggedIn: true))
        let (lost, _) = try await opened(agent, vault: vault)
        lost.keeps = true
        await agent.forget()
        await lost.submit(VaultFixture.good)
        #expect(lost.screen == .done)
        #expect(vault.sites().isEmpty)
    }

    @Test func theValuesThatWorkedAreTheOnesKept() async throws {
        let vault = MemoryLoginVault()
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1))
        let (flow, _) = try await opened(agent, vault: vault)
        flow.keeps = true
        await flow.submit(["id": VaultFixture.id, "password": VaultFixture.badPassword])
        await flow.refresh()
        #expect(try input(flow).wasWrongInput)
        #expect(vault.sites().isEmpty)
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(flow.screen == .done)
        #expect(vault.stored(site: "naver") == VaultFixture.saved())
    }

    @Test func savedValuesLogInAfterOneFaceCheck() async throws {
        let vault = MemoryLoginVault()
        try vault.save(VaultFixture.saved(), site: "naver")
        // 로그인 칸 → 그림 확인 → 로그인 칸이 한 번 더 → 승인 → 로그인
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .relogin, approvalPolls: 1))
        let (flow, login) = try await opened(agent, vault: vault)
        // 저장해 둔 것이 있으면 스위치는 켜진 채로 시작한다
        #expect(flow.keeps)
        #expect(flow.savedNames(for: login) == ["id", "password"])
        #expect(flow.savedFillsAll(login))
        #expect(flow.copy.savedButton(fillsAll: true) == "저장해 둔 값으로 로그인")
        // 얼굴 확인 전에는 아무 값도 읽지 않았다
        #expect(vault.reads == 0)
        let values = await flow.savedValues(for: login)
        #expect(values == VaultFixture.good)
        #expect(vault.reads == 1)
        await flow.submit(values)
        await flow.refresh()
        // 그림 확인에는 넣을 것이 없다
        let picture = try input(flow)
        #expect(flow.savedNames(for: picture).isEmpty)
        #expect(await flow.savedValues(for: picture).isEmpty)
        await flow.submit(["captcha": "지우개"])
        await flow.refresh()
        // 로그인 칸이 한 번 더 나오면 다시 넣을 수 있고, 얼굴은 다시 묻지 않는다
        let again = try input(flow)
        #expect(flow.savedFillsAll(again))
        let second = await flow.savedValues(for: again)
        #expect(second == VaultFixture.good)
        #expect(vault.reads == 1)
        await flow.submit(second)
        await finish(flow)
        #expect(flow.screen == .done)
        // 그대로 쓴 것이라 다시 쓰지 않았고, 전에 저장한 것이 그대로 있다
        #expect(flow.phoneKeeping == .unchanged)
        #expect(vault.stored(site: "naver") == VaultFixture.saved())
        #expect(flow.copy.doneDetail(phone: flow.phoneKeeping).contains("전에 저장해 둔 아이디와 비밀번호는 이 아이폰의 키체인에 그대로 있어요"))
        #expect(await agent.loginInputs.map(\.names) == [["id", "password"], ["captcha"], ["id", "password"]])
    }

    @Test func savedValuesAreNotPutIntoAScreenThatHasGoneBy() async throws {
        let vault = MemoryLoginVault()
        try vault.save(VaultFixture.saved(), site: "naver")
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .relogin, approvalPolls: 1))
        let (flow, first) = try await opened(agent, vault: vault)
        await flow.submit(VaultFixture.good)
        await flow.refresh()
        // 얼굴 확인을 하는 사이에 화면이 넘어갔다: 앞 화면에 넣으려던 값은 돌려주지 않는다
        #expect(await flow.savedValues(for: first).isEmpty)
        #expect(await agent.loginInputs.count == 1)
    }

    @Test func aFaceCheckThatDidNotPassSendsNothing() async throws {
        let vault = MemoryLoginVault()
        try vault.save(VaultFixture.saved(), site: "naver")
        let agent = MockAgentClient(v2: true, sites: MockSites())
        let (flow, login) = try await opened(agent, vault: vault)

        // 취소: 아무 말 없이 그대로 둔다
        vault.answer = .cancelled
        #expect(await flow.savedValues(for: login).isEmpty)
        #expect(flow.vaultNotice == nil)
        #expect(!flow.savedNames(for: login).isEmpty)

        // 꺼내지 못함: 알리고, 다시 해 볼 수 있다
        vault.answer = .failed
        #expect(await flow.savedValues(for: login).isEmpty)
        #expect(flow.vaultNotice == flow.copy.savedUnreadable)
        #expect(!flow.savedNames(for: login).isEmpty)

        // 더 꺼낼 수 없음 (등록된 얼굴이 바뀌었다): 지워졌다고 알리고, 버튼은 사라진다
        vault.answer = .gone
        #expect(await flow.savedValues(for: login).isEmpty)
        #expect(flow.vaultNotice == "저장해 둔 값을 더 꺼낼 수 없어서 지웠어요. Face ID 등록이 바뀌면 그래요. 직접 입력해 주세요.")
        #expect(flow.savedNames(for: login).isEmpty)
        #expect(flow.savedInfo == nil)
        #expect(await agent.loginInputs.isEmpty)

        // 스위치는 켜진 채라, 직접 입력해 로그인하면 다시 저장된다
        vault.answer = nil
        #expect(flow.keeps)
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(vault.stored(site: "naver") == VaultFixture.saved())
        #expect(flow.phoneKeeping == .saved)
    }

    @Test func savedValuesThatWereWrongAreNotOfferedAgain() async throws {
        // 사이트에서 비밀번호를 바꾼 뒤처럼: 저장해 둔 값이 더는 맞지 않는다
        let vault = MemoryLoginVault()
        try vault.save(VaultFixture.saved(password: VaultFixture.badPassword), site: "naver")
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1))
        let (flow, login) = try await opened(agent, vault: vault)
        await flow.submit(await flow.savedValues(for: login))
        #expect(!flow.savedRejected)
        await flow.refresh()
        let again = try input(flow)
        #expect(again.wasWrongInput)
        // 같은 값을 또 넣어 계정이 잠기지 않게, 이 로그인에서는 더 권하지 않는다
        #expect(flow.savedRejected)
        #expect(flow.savedNames(for: again).isEmpty)
        #expect(await flow.savedValues(for: again).isEmpty)
        #expect(flow.vaultNotice == "저장해 둔 값을 넣어 보낸 입력이 맞지 않았어요. 이번에는 직접 입력해 주세요.")
        // 저장해 둔 것을 멋대로 지우지는 않는다
        #expect(vault.stored(site: "naver") == VaultFixture.saved(password: VaultFixture.badPassword))
        // 직접 넣어 로그인되면 그 값으로 바꿔 넣는다
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(flow.screen == .done)
        #expect(vault.stored(site: "naver") == VaultFixture.saved())
        #expect(flow.phoneKeeping == .saved)
        #expect(vault.reads == 1)
    }

    @Test func aWrongAnswerSentTogetherWithASavedValueAlsoStopsTheOffer() async throws {
        // 로그인 칸 → 비밀번호와 보안문자를 함께 묻는 화면
        let vault = MemoryLoginVault()
        try vault.save(VaultFixture.saved(), site: "naver")
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .captcha, approvalPolls: 1))
        let (flow, login) = try await opened(agent, vault: vault)
        await flow.submit(await flow.savedValues(for: login))
        await flow.refresh()
        let captcha = try input(flow)
        #expect(captcha.fields.map(\.name) == ["password", "captcha"])
        // 비밀번호만 채워 주고, 보안문자는 직접 넣는다
        #expect(flow.savedNames(for: captcha) == ["password"])
        #expect(!flow.savedFillsAll(captcha))
        #expect(flow.copy.savedButton(fillsAll: false) == "저장해 둔 값 넣기")
        let filled = await flow.savedValues(for: captcha)
        #expect(filled == ["password": VaultFixture.password])
        #expect(vault.reads == 1)
        await flow.submit(["password": VaultFixture.password, "captcha": "wrong"])
        await flow.refresh()
        #expect(try input(flow).wasWrongInput)
        #expect(flow.savedRejected)
        #expect(flow.savedNames(for: try input(flow)).isEmpty)
    }

    @Test func aScreenOnAnotherHostIsNotFilled() async throws {
        // 호스트를 알려 주는 로그인: 저장할 때와 다른 호스트의 화면에는 넣지 않는다 (가상 주소)
        let vault = MemoryLoginVault()
        try vault.save(VaultFixture.saved(host: "login.shop.test"), site: "naver")
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1, host: "login.shop-help.test"))
        let (flow, login) = try await opened(agent, vault: vault)
        #expect(login.host == "login.shop-help.test")
        #expect(flow.savedNames(for: login).isEmpty)
        #expect(await flow.savedValues(for: login).isEmpty)
        #expect(vault.reads == 0)
        // 직접 넣어 로그인하면, 그 화면의 호스트와 함께 바꿔 넣는다
        #expect(flow.keeps)
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(vault.stored(site: "naver") == VaultFixture.saved(host: "login.shop-help.test"))

        // 같은 호스트면 넣는다
        let same = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1, host: "login.shop-help.test"))
        let (next, asked) = try await opened(same, vault: vault)
        #expect(next.savedFillsAll(asked))
        #expect(await next.savedValues(for: asked) == VaultFixture.good)
    }

    @Test func aDeviceWithoutFaceCheckOffersNothing() async throws {
        let vault = MemoryLoginVault(isAvailable: false)
        try vault.save(VaultFixture.saved(), site: "naver")
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1))
        let (flow, login) = try await opened(agent, vault: vault)
        #expect(!flow.canKeep)
        #expect(!flow.keeps)
        #expect(!flow.offersKeeping(for: login))
        #expect(flow.savedNames(for: login).isEmpty)
        #expect(await flow.savedValues(for: login).isEmpty)
        #expect(vault.reads == 0)
        // 스위치가 어떻게든 켜져도 넣지 않는다
        vault.remove(site: "naver")
        flow.keeps = true
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(flow.screen == .done)
        #expect(vault.sites().isEmpty)

        // 보관소가 없을 때(테스트의 기본값)도 같다
        let (plain, asked) = try await opened(MockAgentClient(v2: true, sites: MockSites()), vault: nil)
        #expect(!plain.canKeep && !plain.offersKeeping(for: asked))
        #expect(LoginVaults.current == nil)
    }

    @Test func mailSetupNeverKeepsAnything() async throws {
        let vault = MemoryLoginVault()
        let agent = MockAgentClient(v2: true, sites: MockSites(loggedIn: true, mailSetup: .normal))
        let flow = flow(agent, vault: vault, site: MockSites.mailSetupSite)
        #expect(!flow.canKeep)
        flow.keeps = true
        await flow.start()
        await flow.refresh()
        let address = try input(flow)
        #expect(!flow.offersKeeping(for: address))
        await flow.submit(["id": MockSites.mailSetupAddress])
        await flow.refresh()
        let password = try input(flow)
        #expect(password.fields.map(\.name) == ["password"])
        #expect(!flow.offersKeeping(for: password))
        await flow.submit(["password": VaultFixture.password])
        for _ in 0..<8 where !flow.isFinished {
            await flow.refresh()
            if case .choice(let login) = flow.screen, let first = login.choices.first { await flow.choose(first) }
        }
        #expect(flow.screen == .done)
        #expect(vault.sites().isEmpty)
        // 말도 그대로다
        #expect(flow.copy.doneDetail(phone: flow.phoneKeeping) == flow.copy.doneDetail)
    }

    @Test func aFailedSaveIsSaidPlainly() async throws {
        let vault = MemoryLoginVault()
        vault.saveFails = true
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1))
        let (flow, _) = try await opened(agent, vault: vault)
        flow.keeps = true
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(flow.screen == .done)
        #expect(flow.phoneKeeping == .failed)
        #expect(flow.copy.doneDetail(phone: .failed).contains("이 아이폰에 저장하지 못했어요"))
        #expect(vault.sites().isEmpty)
    }

    @Test func wordingSaysWhereTheValuesAre() {
        let copy = SiteLoginCopy(site: "naver")
        let login = VaultFixture.login(["id", "password"])
        // 켜지 않았고 저장해 둔 것도 없을 때는 전과 같은 말이다
        #expect(copy.inputFooter(for: login) == "아이디와 비밀번호는 맥의 브라우저에 한 번 입력하는 데만 써요. 이 아이폰에도 맥에도 저장하지 않고, 대화 기록이나 AI에게도 전달되지 않아요. 맥에 남는 것은 로그인 상태뿐이에요.")
        // 켰을 때
        let keeping = copy.inputFooter(for: login, keeps: true, saved: true, unlock: "Touch ID")
        #expect(keeping.contains("Touch ID로 확인한 뒤에만 꺼내요"))
        #expect(keeping.contains("다른 기기로 옮겨지지 않아요"))
        #expect(keeping.contains("맥에는 저장하지 않고, 대화 기록이나 AI에게도 전달되지 않아요"))
        #expect(!keeping.contains("이 아이폰에도"))
        // 껐지만 전에 저장해 둔 것이 있을 때: "이 아이폰에 없다"고 하지 않는다
        let old = copy.inputFooter(for: login, keeps: false, saved: true)
        #expect(old.hasPrefix("지금 넣는 값은 저장하지 않아요. 전에 저장해 둔 값은 이 아이폰의 키체인에만 있고"))
        // 대화에 남는 말과 카드는 이 아이폰에 저장했는지 모르는 자리라, 맥에 대해서만 말한다
        #expect(copy.chatDone == "네이버에 로그인했어요. 맥의 에이전트 브라우저에 로그인 상태만 남아 있고, 아이디와 비밀번호는 맥에 저장하지 않았어요.")
        #expect(copy.doneDetail == "맥의 에이전트 브라우저에 로그인 상태만 남아 있어요. 아이디와 비밀번호는 맥에 저장하지 않았어요.")
        #expect(copy.cardFooter == "아이디와 비밀번호는 채팅이 아니라 따로 뜨는 화면에서 넣어요. 대화 기록에는 남지 않고, 저장은 내가 켰을 때만 이 아이폰의 키체인에 해요.")
        for text in [copy.chatDone, copy.doneDetail, copy.cardFooter] {
            #expect(!text.contains("어디에도 저장하지"))
            #expect(!text.contains("비밀번호는 저장하지 않았어요"))
        }
        // 메일 연결의 말은 그대로다
        let mail = SiteLoginCopy(site: MockSites.mailSetupSite)
        #expect(mail.inputFooter(for: VaultFixture.login(["password"]), keeps: true, saved: true).contains("이 아이폰에도 맥에도 저장하지 않고"))
        #expect(mail.cardFooter.contains("비밀번호는 어디에도 저장하지 않고"))
    }

    @Test func savedSitesAreListedAndCanBeForgotten() async throws {
        let vault = MemoryLoginVault()
        try vault.save(VaultFixture.saved(), site: "naver")
        try vault.save(SavedLogin(entries: ["password": .init(value: VaultFixture.password, host: "login.shop.test")]), site: "shop")
        // 맥에 연결되지 않아도 보인다
        let model = SiteAccountsModel(agent: nil, vault: vault)
        #expect(model.savedSites == [.init(site: "naver", summary: "아이디·비밀번호"), .init(site: "shop", summary: "비밀번호")])
        #expect(model.name(for: "naver") == "네이버")
        // 맥이 모르는 사이트는 번호 그대로 보인다
        #expect(model.name(for: "shop") == "shop")
        model.forgetSaved("naver")
        #expect(model.savedSites.map(\.site) == ["shop"])
        #expect(vault.stored(site: "naver") == nil)
        #expect(vault.stored(site: "shop") != nil)

        // 연동 센터에서 연 로그인 화면도 같은 보관소를 쓰고, 로그인되면 목록에 나타난다
        let agent = MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1))
        let connected = SiteAccountsModel(agent: agent, vault: vault)
        await connected.load()
        let flow = try #require(connected.flow(for: "naver"))
        #expect(flow.canKeep)
        // 저장해 둔 것이 없는 모델은 비어 있다
        #expect(SiteAccountsModel(agent: agent, vault: nil).savedSites.isEmpty)
    }
}

// 로그인이 풀린 사이트에 저장해 둔 값으로 다시 로그인 (D122). 값은 모두 지어낸 것이다
@Suite("로그인 값 보관: 다시 로그인 (D122)")
@MainActor
struct QuickReloginTests {
    private func opened(_ agent: any AgentProviding, vault: any LoginVault, auto: Bool) async throws -> (SiteLoginFlow, SiteLogin) {
        let flow = SiteLoginFlow(site: "naver", agent: agent, pollInterval: .seconds(3600), vault: vault)
        flow.autoUsesSaved = auto
        await flow.start()
        await flow.refresh()
        guard case .input(let login) = flow.screen else {
            Issue.record("입력 화면이 나와야 한다: \(flow.screen)")
            throw AgentError.invalidResponse
        }
        return (flow, login)
    }

    private func finish(_ flow: SiteLoginFlow) async {
        for _ in 0..<6 where !flow.isFinished { await flow.refresh() }
    }

    @Test func theButtonAppearsOnlyWhenSomethingIsSaved() throws {
        let vault = MemoryLoginVault()
        #expect(SiteLoginFlow.quickUnlock(for: "naver", vault: vault) == nil)
        try vault.save(VaultFixture.saved(), site: "naver")
        #expect(SiteLoginFlow.quickUnlock(for: "naver", vault: vault) == "Face ID")
        // 얼굴 확인을 쓸 수 없는 기기, 보관소가 없는 실행에서는 없다
        #expect(SiteLoginFlow.quickUnlock(for: "naver", vault: MemoryLoginVault(isAvailable: false)) == nil)
        #expect(SiteLoginFlow.quickUnlock(for: "naver", vault: nil) == nil)
        #expect(SiteLoginCopy(site: "naver").quickRelogin(unlock: "Face ID") == "Face ID로 다시 로그인")
    }

    @Test func openedByTheButtonItTakesTheSavedValuesOnce() async throws {
        let vault = MemoryLoginVault()
        try vault.save(VaultFixture.saved(), site: "naver")
        let (flow, login) = try await opened(MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1)), vault: vault, auto: true)
        #expect(flow.takesSavedAutomatically(login))
        // 같은 흐름에서 두 번은 아니다
        #expect(!flow.takesSavedAutomatically(login))
    }

    @Test func openedOnItsOwnItWaitsForTheUser() async throws {
        // 맥의 답으로 저절로 연 로그인 화면: 얼굴 확인을 먼저 띄우지 않는다 (단추는 그대로 있다)
        let vault = MemoryLoginVault()
        try vault.save(VaultFixture.saved(), site: "naver")
        let (flow, login) = try await opened(MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1)), vault: vault, auto: false)
        #expect(!flow.takesSavedAutomatically(login))
        #expect(flow.savedFillsAll(login))
    }

    @Test func nothingSavedMeansNothingAutomatic() async throws {
        let (flow, login) = try await opened(MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1)), vault: MemoryLoginVault(), auto: true)
        #expect(!flow.takesSavedAutomatically(login))
    }

    @Test func afterALoginWithoutTheSwitchItAsksToKeep() async throws {
        let vault = MemoryLoginVault()
        let (flow, _) = try await opened(MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1)), vault: vault, auto: false)
        #expect(!flow.keeps)
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(flow.screen == .done)
        // 로그인됐다: 묻기만 하고 아직 넣지 않았다
        #expect(flow.asksToKeep)
        #expect(vault.sites().isEmpty)
        #expect(flow.copy.keepAskTitle == "이 사이트 로그인 정보를 폰에 저장할까요?")
        flow.keepOffered()
        #expect(!flow.asksToKeep)
        #expect(vault.stored(site: "naver") == VaultFixture.saved())
        #expect(flow.phoneKeeping == .saved)
    }

    @Test func declinedOrClosedItKeepsNothing() async throws {
        for closes in [false, true] {
            let vault = MemoryLoginVault()
            let (flow, _) = try await opened(MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1)), vault: vault, auto: false)
            await flow.submit(VaultFixture.good)
            await finish(flow)
            #expect(flow.asksToKeep)
            if closes { flow.close() } else { flow.declineKeeping() }
            #expect(!flow.asksToKeep)
            // 답한 뒤에 "저장"을 불러도 넣을 것이 없다
            flow.keepOffered()
            #expect(vault.sites().isEmpty)
        }
    }

    @Test func aFailedLoginDoesNotAsk() async throws {
        let vault = MemoryLoginVault()
        let (flow, _) = try await opened(MockAgentClient(v2: true, sites: MockSites(script: .blocked)), vault: vault, auto: false)
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(!flow.asksToKeep)
        #expect(vault.sites().isEmpty)
    }

    @Test func theSwitchOnMeansNoQuestion() async throws {
        let vault = MemoryLoginVault()
        let (flow, _) = try await opened(MockAgentClient(v2: true, sites: MockSites(approvalPolls: 1)), vault: vault, auto: false)
        flow.keeps = true
        await flow.submit(VaultFixture.good)
        await finish(flow)
        #expect(!flow.asksToKeep)
        #expect(vault.stored(site: "naver") == VaultFixture.saved())
    }

    @Test func theExpiredNoticeCarriesOnlyASafeSiteKey() {
        let notice = PushNotice(userInfo: ["type": "login_expired", "task_id": "site:naver", "site": "naver"])
        #expect(notice?.kind == .loginExpired && notice?.site == "naver")
        // 번호는 작업이 아니라 읽지 않는다
        #expect(notice?.taskID == nil)
        #expect(PushNotice(userInfo: ["type": "login_expired", "site": "../x"])?.site == nil)
        // 다른 알림에 실린 사이트는 읽지 않는다
        #expect(PushNotice(userInfo: ["type": "task_done", "task_id": "t_1", "site": "naver"])?.site == nil)
    }

    @Test func sitesTellHowTheyFirstLoggedIn() throws {
        let sites = try AgentHTTPClient.decodeSites(data: Data("""
        {"sites":[{"site":"shop","name":"가상몰","status":"logged_out","methods":["password"],"via":"password"},
                  {"site":"blog","name":"가상블로그","status":"logged_out","methods":["password"],"via":"naver"},
                  {"site":"desk","name":"가상데스크","status":"logged_out","methods":[],"backend":"chrome"},
                  {"site":"old","name":"예전","status":"logged_out","methods":["password"]}]}
        """.utf8), status: 200)
        #expect(sites.map(\.via) == ["password", "naver", nil, nil])
        #expect(sites.map(\.reloginsWithPassword) == [true, false, false, true])
    }
}
