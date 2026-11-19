import Foundation
import Testing
import UIKit
@testable import MeetingSummary

// 로그인 카드의 간편인증 (D90): 이름·생년월일·휴대폰 번호 칸. 값은 모두 지어낸 것이다.

// 화면(`SiteLoginSheet`)의 계산은 메인 액터에 묶여 있다: 밖에서 부르면 실행 중에 멈춘다
@MainActor
@Suite("간편인증: 본인 확인 칸")
struct SimpleAuthFieldTests {
    private func login(_ names: [String]) -> SiteLogin {
        var login = SiteLogin(id: "l1", site: "naver", method: "simple", state: .needInput, step: 1, message: "")
        login.fields = names.map { .init(name: $0, label: "", secret: false) }
        return login
    }

    @Test func theThreeIdentityFieldsCanBeAsked() {
        #expect(login(["name", "birth", "phone"]).canRenderInput)
        // 그 밖의 이름은 전과 같이 받지 않는다 (서버가 무엇이든 물어볼 수 있게 두지 않는다)
        #expect(!login(["name", "birthday"]).canRenderInput)
        #expect(!login(["name", "address"]).canRenderInput)
    }

    @Test func numbersGetTheNumberPadAndLabelsHaveFallbacks() {
        #expect(SiteLoginSheet.keyboard(for: "birth") == .numberPad)
        #expect(SiteLoginSheet.keyboard(for: "phone") == .numberPad)
        // 이름은 한글로 쓴다
        #expect(SiteLoginSheet.keyboard(for: "name") == .default)
        #expect(SiteLoginSheet.fallbackLabel("name") == "이름")
        #expect(SiteLoginSheet.fallbackLabel("birth") == "생년월일 (8자리)")
        #expect(SiteLoginSheet.fallbackLabel("phone") == "휴대폰 번호")
    }

    @Test func onlyDigitsAreSentForBirthAndPhone() {
        let sent = SiteLoginSheet.cleaned(
            ["name": " 김하늘 ", "birth": "1990-01-02", "phone": "010 1234 5678"], for: login(["name", "birth", "phone"])
        )
        #expect(sent == ["name": "김하늘", "birth": "19900102", "phone": "01012345678"])
    }

    @Test func theseValuesAreNeverAmongTheOnesKeptOnThePhone() {
        #expect(SavedLogin.names.isDisjoint(with: SiteLogin.identityNames))
    }
}

@Suite("간편인증: 흐름")
@MainActor
struct SimpleAuthFlowTests {
    private static let identity = ["name": "김하늘", "birth": "19900102", "phone": "01012345678"]

    private func choice(_ flow: SiteLoginFlow) throws -> SiteLogin {
        guard case .choice(let login) = flow.screen else {
            Issue.record("고르는 화면이 나와야 한다: \(flow.screen)")
            throw AgentError.invalidResponse
        }
        return login
    }

    @Test func theWholeFlowRunsAndNothingIsKept() async throws {
        let vault = MemoryLoginVault()
        let agent = MockAgentClient(v2: true, sites: MockSites(script: .simple))
        let flow = SiteLoginFlow(site: "naver", agent: agent, pollInterval: .seconds(3600), vault: vault)
        await flow.start()
        await flow.refresh()

        // 인증 앱 13곳과 "그만하기"
        let apps = try choice(flow)
        #expect(apps.choices.count == 14)
        await flow.choose(apps.choices[0])
        await flow.refresh()

        guard case .input(let asking) = flow.screen else {
            Issue.record("본인 확인 칸이 나와야 한다: \(flow.screen)")
            return
        }
        #expect(asking.fields.map(\.name) == ["name", "birth", "phone"])
        // 저장할 수 있는 기기여도 이 화면에는 저장 스위치가 없고, 켜 두었어도 저장하지 않는다
        #expect(flow.canKeep)
        #expect(!flow.offersKeeping(for: asking))
        flow.keeps = true
        let footer = flow.copy.inputFooter(for: asking, keeps: flow.keeps)
        #expect(footer.contains("이 아이폰에 저장하지 않고"))
        #expect(!footer.contains("키체인"))
        await flow.submit(Self.identity)
        await flow.refresh()

        // 줄바꿈이 든 동의 목록
        let consent = try choice(flow)
        #expect(consent.text?.contains("\n· 개인정보 수집ㆍ이용 동의") == true)
        #expect(consent.choices == ["동의하고 인증 요청", "그만하기"])
        await flow.choose("동의하고 인증 요청")
        await flow.refresh()

        let waiting = try choice(flow)
        #expect(waiting.choices == ["인증 완료", "그만하기"])
        await flow.choose("인증 완료")
        for _ in 0..<6 where !flow.isFinished { await flow.refresh() }

        #expect(flow.screen == .done)
        #expect(vault.sites().isEmpty)
        // 맥에는 칸 이름대로 한 번 갔다
        #expect(await agent.loginInputs.map(\.names).contains(["birth", "name", "phone"]))
    }
}
