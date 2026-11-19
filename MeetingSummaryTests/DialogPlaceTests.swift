import Foundation
import Testing
@testable import MeetingSummary

/// 대화 판단이 어디서 되는지와, 그에 따라 바뀌는 "데이터 처리 방식" 설명 (D60)
@MainActor
@Suite("대화 판단이 어디서 되나: 설명 글")
struct DialogPlaceTests {
    /// 테스트마다 따로 쓰는 저장소 (기기의 실제 설정을 건드리지 않는다)
    private func store() -> UserDefaults {
        let name = "dialog-place-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func featureNameMatchesTheMac() {
        #expect(AgentFeature.dialogCloud == "dialog_cloud")
    }

    /// 가짜 맥은 따로 켜지 않으면 Claude에 맡긴다고 알리지 않는다 (새 서버 흉내만으로 설명이 바뀌면 안 된다)
    @Test func aNewMacDoesNotClaimClaudeUnlessTurnedOn() async {
        #expect(await MockAgentClient(v2: true).supports(AgentFeature.dialogCloud) == false)
        #expect(await MockAgentClient(v2: true, dialogCloud: MockDialogCloud()).supports(AgentFeature.dialogCloud))
    }

    @Test func aMacThatSaysClaudeGetsTheClaudeExplanation() async {
        let defaults = store()
        let model = DialogPlaceModel(agent: MockAgentClient(v2: true, dialogCloud: MockDialogCloud()), defaults: defaults)
        #expect(model.place == nil)
        await model.load()
        #expect(model.place == .cloud)
        #expect(model.isConfirmed)
        #expect(model.notice == nil)
        #expect(model.facts.place == .cloud)
        #expect(defaults.string(forKey: DialogPlaceModel.defaultsKey) == "v2 cloud context")
    }

    @Test func aMacThatDoesNotSayItKeepsTheLocalExplanation() async {
        let defaults = store()
        let model = DialogPlaceModel(agent: MockAgentClient(v2: true), defaults: defaults)
        await model.load()
        #expect(model.place == .local)
        #expect(model.isConfirmed)
        #expect(model.notice == nil)
        #expect(model.facts.place == .local)
        #expect(defaults.string(forKey: DialogPlaceModel.defaultsKey) == "v2 local")
    }

    /// 맥에 닿지 않아도, 마지막으로 Claude였다면 "외부로 보내지 않는다"고 하지 않는다
    @Test func anUnreachableMacKeepsTheLastKnownPlaceAndSaysSo() async {
        let defaults = store()
        defaults.set("cloud", forKey: DialogPlaceModel.defaultsKey)
        let model = DialogPlaceModel(agent: MockAgentClient(reachable: false, v2: true, dialogCloud: MockDialogCloud()), defaults: defaults)
        #expect(model.place == .cloud)
        // 묻기 전에는 안내를 붙이지 않는다
        #expect(model.notice == nil)
        await model.load()
        #expect(model.place == .cloud)
        #expect(model.isConfirmed == false)
        #expect(model.notice?.contains("마지막으로 연결했을 때") == true)
        #expect(model.facts.footer.contains("마지막으로 연결했을 때"))
        #expect(defaults.string(forKey: DialogPlaceModel.defaultsKey) == "cloud")
    }

    /// 한 번도 확인하지 못했으면 예전 설명을 보이되, 확인하지 못했다고 말한다
    @Test func aNeverReachedMacShowsTheLocalTextWithAWarning() async {
        let defaults = store()
        let model = DialogPlaceModel(agent: MockAgentClient(reachable: false, v2: true, dialogCloud: MockDialogCloud()), defaults: defaults)
        await model.load()
        #expect(model.place == nil)
        #expect(model.facts.place == .local)
        #expect(model.notice?.contains("확인하지 못했어요") == true)
        #expect(defaults.string(forKey: DialogPlaceModel.defaultsKey) == nil)
    }

    /// 맥에서 Claude 판단을 끄면 다음 확인 때 설명도 돌아온다
    @Test func turningItOffOnTheMacBringsTheLocalTextBack() async {
        let defaults = store()
        defaults.set("cloud", forKey: DialogPlaceModel.defaultsKey)
        let model = DialogPlaceModel(agent: MockAgentClient(v2: true), defaults: defaults)
        #expect(model.place == .cloud)
        await model.load()
        #expect(model.place == .local)
        #expect(defaults.string(forKey: DialogPlaceModel.defaultsKey) == "v2 local")
    }

    /// 맥 에이전트가 없는 앱: 예전에 적어 둔 값도 쓰지 않고, 안내도 없다
    @Test func anAppWithoutAMacAgentIgnoresWhatWasRemembered() async {
        let defaults = store()
        defaults.set("cloud", forKey: DialogPlaceModel.defaultsKey)
        let model = DialogPlaceModel(agent: nil, defaults: defaults)
        await model.load()
        #expect(model.place == nil)
        #expect(model.notice == nil)
        #expect(model.facts == MacAgentFacts(setup: .local))
    }

    /// 모르는 값이 적혀 있으면 없는 것으로 본다
    @Test func anUnknownRememberedValueIsIgnored() {
        let defaults = store()
        defaults.set("moon", forKey: DialogPlaceModel.defaultsKey)
        #expect(DialogPlaceModel(agent: MockAgentClient(v2: true), defaults: defaults).place == nil)
    }

    // MARK: - 함께 켜진 것 (D61)

    /// 맥이 알린 이름 그대로: 회의 자료의 내용이 가는지, 웹 검색을 하는지
    @Test func theSetupFollowsWhatTheMacAdvertises() async {
        func setup(_ cloud: MockDialogCloud?) async -> DialogSetup {
            await DialogSetup(agent: MockAgentClient(v2: true, dialogCloud: cloud))
        }
        #expect(await setup(nil) == .local)
        #expect(await setup(MockDialogCloud()) == DialogSetup(place: .cloud, sendsContext: true))
        #expect(await setup(MockDialogCloud(sendsContext: false)) == DialogSetup(place: .cloud))
        #expect(await setup(MockDialogCloud(webLookup: true)) == DialogSetup(place: .cloud, sendsContext: true, webLookup: true))
    }

    /// 로컬 판단인 맥에서는 나머지 이름을 보지 않는다 (Claude로 가는 것이 없다)
    @Test func aLocalSetupNeverCarriesCloudOptions() {
        #expect(DialogSetup(place: .local, sendsContext: true, webLookup: true) == .local)
    }

    @Test func theSetupSurvivesBeingWrittenDown() {
        let setups = [
            DialogSetup.local, DialogSetup(place: .cloud), DialogSetup(place: .cloud, sendsContext: true),
            DialogSetup(place: .cloud, webLookup: true), DialogSetup(place: .cloud, sendsContext: true, webLookup: true),
            DialogSetup(place: .cloud, marksWriter: true), DialogSetup(place: .cloud, sendsContext: true, webLookup: true, marksWriter: true)
        ]
        for setup in setups {
            #expect(DialogSetup(stored: setup.stored) == setup)
        }
        #expect(DialogSetup(stored: nil) == nil)
        #expect(DialogSetup(stored: "") == nil)
        #expect(DialogSetup(stored: "v2") == nil)
        #expect(DialogSetup(stored: "v2 moon") == nil)
    }

    /// 예전 앱(D60)이 적어 둔 한 낱말: `cloud`는 회의 자료의 내용이 가는 것으로 읽는다 (덜 말하지 않는다)
    @Test func aValueWrittenByTheOlderAppIsReadOnTheSafeSide() {
        #expect(DialogSetup(stored: "local") == .local)
        #expect(DialogSetup(stored: "cloud") == DialogSetup(place: .cloud, sendsContext: true))
        #expect(DialogSetup(stored: "cloud web") == nil)
    }

    /// 맥에 닿지 않을 때도 웹 검색 줄이 남는다
    @Test func theLastKnownOptionsAreKeptWhileUnreachable() async {
        let defaults = store()
        let cloud = MockDialogCloud(sendsContext: false, webLookup: true)
        await DialogPlaceModel(agent: MockAgentClient(v2: true, dialogCloud: cloud), defaults: defaults).load()
        #expect(defaults.string(forKey: DialogPlaceModel.defaultsKey) == "v2 cloud web")
        let later = DialogPlaceModel(agent: MockAgentClient(reachable: false, v2: true), defaults: defaults)
        await later.load()
        #expect(later.setup == DialogSetup(place: .cloud, webLookup: true))
        #expect(later.isConfirmed == false)
    }

    /// 회의 자료: 내용이 갈 때만 "가는 것"에 넣고, 아니면 "가지 않는 것"에 넣는다
    @Test func meetingMaterialIsListedWhereItActuallyGoes() {
        let with = MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true)).rows
        let without = MacAgentFacts(setup: DialogSetup(place: .cloud)).rows
        #expect(with[1].note?.contains("함께 보낸 회의 발췌, ") == true)
        #expect(with[2].note?.contains("회의 발췌") == false)
        #expect(without[1].note?.contains("회의 발췌가 붙어 있다는 사실(내용은 아니에요)") == true)
        #expect(without[2].note?.contains("함께 보낸 회의 발췌의 내용") == true)
    }

    /// 웹 검색 줄은 맥이 웹 검색을 알릴 때만 있다. 무엇이 가는지, 코드로 막지 못하는 것, 찾은 답이 남는 것을 말한다
    @Test func theWebSearchRowAppearsOnlyWhenTheMacSearches() {
        let off = allText(MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true)))
        #expect(!off.contains("웹 검색"))
        let on = allText(MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true, webLookup: true)))
        for phrase in [
            "Anthropic의 웹 검색", "그 한 문장과 지금 시각만 가요", "대화 기록, 회의 발췌, 읽은 결과, 메일 주소는 가지 않아요",
            "코드로 막지는 못해요", "다음 말을 판단할 때 Claude가 다시 봐요"
        ] {
            #expect(on.contains(phrase), "웹 검색 설명에 빠졌다: \(phrase)")
        }
        #expect(!allText(MacAgentFacts(setup: .local)).contains("웹 검색"))
    }

    // MARK: - 글

    private func allText(_ facts: MacAgentFacts) -> String {
        (facts.rows.flatMap { [$0.text, $0.note ?? ""] } + [facts.footer]).joined(separator: "\n")
    }

    /// 로컬 판단일 때의 글은 Claude 판단 이야기를 하지 않는다
    @Test func theLocalTextPromisesNothingLeavesTheMac() {
        let text = allText(MacAgentFacts(setup: .local))
        #expect(text.contains("외부 서비스로 보내지 않아요"))
        #expect(text.contains("맥이 답한 말과 맥에서 만든 초안은 Claude로 보내지 않아요"))
        #expect(!text.contains("Claude로 가는 것"))
    }

    /// Claude 판단일 때의 글: "외부로 보내지 않는다"는 약속이 남아 있으면 안 되고, 가는 것·가지 않는 것·막지 못하는 것을 모두 말한다
    @Test func theClaudeTextSaysWhatGoesWhatDoesNotAndWhatCannotBeStopped() {
        let facts = MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true))
        let text = allText(facts)
        #expect(!text.contains("외부 서비스로 보내지 않아요"))
        #expect(!text.contains("맥이 답한 말과 맥에서 만든 초안은 Claude로 보내지 않아요"))
        // 가는 것
        for word in ["내가 쓴 글", "Claude가 쓴 답", "맡긴 일의 제목", "연락처의 이름", "회의 발췌", "날짜와 시각", "사이트 로그인 여부", "메일 계정 연결 여부"] {
            #expect(text.contains(word), "가는 것에 빠졌다: \(word)")
        }
        // 가지 않는 것
        for word in ["사이트에서 읽은 결과", "캡처", "받은 메일의 제목·보낸 사람·본문", "메일 주소", "아이디·비밀번호", "진행 과정과 승인 내용"] {
            #expect(text.contains(word), "가지 않는 것에 빠졌다: \(word)")
        }
        #expect(text.contains("가리지 못하고 그대로 가요"))
        #expect(text.contains("그 말 한 번만 맥의 로컬 모델이 판단해요"))
        // 맥을 거친 답에는 'Claude 사용' 표시가 없다는 것도 말한다
        #expect(text.contains("따로 표시하지 않아요"))
    }

    /// 어느 쪽이든 같은 것: 맥에 먼저 보내는 것, 맥에 남는 것, 승인과 보내는 범위
    /// 답 아래의 'Claude 사용' 표시는 보이지 않게 했다 (D107). 맥이 누가 썼는지 알려 주어도 "표시한다"고 쓰지 않는다
    @Test func theTextSaysRepliesAreMarkedOnlyWhenTheMacTellsWhoWrote() async {
        let plain = MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true, webLookup: true))
        let marked = MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true, webLookup: true, marksWriter: true))
        let plainText = plain.rows.map { $0.text + ($0.note ?? "") }.joined()
        let markedText = marked.rows.map { $0.text + ($0.note ?? "") }.joined()
        #expect(plainText.contains("따로 표시하지 않아요"))
        #expect(markedText.contains("누가 썼는지는 화면에 따로 표시하지 않아요"))
        #expect(!plainText.contains("'Claude 사용'") && !markedText.contains("'Claude 사용'"))
        #expect(markedText.contains("맡긴 일의 보고·초안·질문은 모두 맥에서 만들어요"))
        #expect(plain.rows.count == marked.rows.count)

        // 맥이 알린 대로 정해지고, 적어 둔 값에도 남는다
        let setup = await DialogSetup(agent: MockAgentClient(v2: true, dialogCloud: MockDialogCloud(demo: "by")))
        #expect(setup == DialogSetup(place: .cloud, sendsContext: true, webLookup: true, marksWriter: true))
        #expect(setup.stored == "v2 cloud context web by")
        // 로컬 판단이면 Claude가 쓰는 답이 없다: 켜져 있어도 설명은 그대로다
        #expect(DialogSetup(place: .local, marksWriter: true) == .local)
    }

    @Test func bothTextsKeepTheSharedFacts() {
        let setups = [
            DialogSetup.local, DialogSetup(place: .cloud), DialogSetup(place: .cloud, sendsContext: true),
            DialogSetup(place: .cloud, sendsContext: true, webLookup: true)
        ]
        for setup in setups {
            let facts = MacAgentFacts(setup: setup)
            #expect(facts.rows.first?.text.contains("Tailscale로 내 맥에 먼저 보내요") == true)
            #expect(facts.rows.last?.text.contains("맥의 메모리에만") == true)
            #expect(facts.footer.contains("메일은 승인하면 내 주소로만 보내요"))
            #expect(facts.footer.contains("다른 사람에게 보내기·삭제는 하지 않아요"))
            #expect(Set(facts.rows.map(\.id)).count == facts.rows.count)
        }
    }
}
