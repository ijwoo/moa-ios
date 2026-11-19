import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 내 공간 (D94): 맥이 준 구성 읽기, 화면의 줄, 말로 고치기, 카드 새로 받기. 카드도 내용도 모두 지어낸 것이다.

@Suite("내 공간: 맥이 준 것 읽기")
struct SpaceDecodingTests {
    @Test func cardsAreReadInOrderAndUnknownKindsAreSkipped() throws {
        let json = """
        {"space":{"v":1,"can_undo":true,"cards":[
          {"id":"c_1","type":"meeting_todos","size":"large","title":"어제 회의에서 내가 할 일","source":"app"},
          {"id":"c_2","type":"stock_chart","size":"small","title":"모르는 카드","source":"mac"},
          {"id":"c_3","type":"weather","size":"small","title":"날씨","source":"app"},
          {"id":"c_4","type":"custom","size":"huge","title":"  ","source":"mac","state":"empty"},
          {"id":"나쁜 번호","type":"weather","size":"small"},
          {"id":"c_3","type":"weather","size":"small","title":"같은 번호"},
          7
        ]}}
        """
        let space = try SpaceDecoding.space(data: Data(json.utf8), status: 200)
        #expect(space.canUndo)
        #expect(space.cards.map(\.id) == ["c_1", "c_3", "c_4"])
        #expect(space.cards[0].kind == .meetingTodos && space.cards[0].size == .large)
        // 앱이 채우는 카드에는 맥의 상태가 없다
        #expect(space.cards[0].state == nil)
        // 모르는 크기는 한 줄짜리로, 빈 이름은 종류의 이름으로
        #expect(space.cards[2].size == .medium && space.cards[2].title == "카드")
        #expect(space.cards[2].needsRefresh)
    }

    @Test func blocksAreReadAndUnknownOnesAreDropped() throws {
        let json = """
        {"space":{"cards":[
          {"id":"c_a","type":"custom","size":"small","title":"원달러 환율","source":"mac","state":"ok","data":{"blocks":[
            {"kind":"stat","label":"원달러 환율","value":1382,"note":"어제보다 내림"},
            {"kind":"chart","points":[1,2]},
            {"kind":"list","items":[{"title":"하나","subtitle":"둘","trailing":3},{"subtitle":"이름 없음"},
              {"title":"a"},{"title":"b"},{"title":"c"},{"title":"d"},{"title":"e"},{"title":"f"}]},
            {"kind":"progress","label":"쓴 양","ratio":1.7},
            {"kind":"text","text":"  글  "},
            {"kind":"text","text":"다섯 번째"}
          ]}}
        ]}}
        """
        let card = try #require(try SpaceDecoding.space(data: Data(json.utf8), status: 200).cards.first)
        #expect(card.blocks.count == SpaceBlock.limit)
        #expect(card.blocks[0] == .stat(label: "원달러 환율", value: "1382", note: "어제보다 내림"))
        guard case .list(let items) = card.blocks[1] else { Issue.record("목록이 아니다"); return }
        #expect(items.count == SpaceBlock.itemLimit)
        #expect(items[0] == SpaceBlock.Item(title: "하나", subtitle: "둘", trailing: "3"))
        #expect(card.blocks[2] == .progress(label: "쓴 양", ratio: 1))
        #expect(card.blocks[3] == .text("글"))
    }

    @Test func mailCardCarriesCountServicesAndLines() throws {
        let json = """
        {"space":{"cards":[
          {"id":"c_m","type":"mail_today","size":"medium","title":"오늘 온 메일","source":"mac","state":"stale","data":{
            "count":5,"services":["네이버","지메일"],"failed":[],
            "items":[{"time":"오전 9:10","from":"한빛 보안센터","subject":"새 기기에서 로그인했어요","service":"지메일"},{"time":"오전 8:00"}],
            "blocks":[{"kind":"text","text":"확인할 메일이 한 통 있어요."}]}},
          {"id":"c_r","type":"routine_result","size":"medium","title":"아침 브리핑","source":"mac","state":"unavailable","why":"이 예약은 아직 돈 적이 없어요."}
        ]}}
        """
        let cards = try SpaceDecoding.space(data: Data(json.utf8), status: 200).cards
        #expect(cards[0].mailSummary == "네이버·지메일 · 5통")
        // 제목이 없는 줄은 버린다
        #expect(cards[0].mails.map(\.subject) == ["새 기기에서 로그인했어요"])
        #expect(cards[0].state == .stale && cards[0].needsRefresh)
        #expect(cards[1].state == .unavailable && cards[1].why == "이 예약은 아직 돈 적이 없어요.")
        // 채울 수 없는 카드는 새로 받지 않는다
        #expect(!cards[1].needsRefresh)
    }

    @Test func mailCardCarriesPicksHeadlineAndRest() throws {
        let json = """
        {"space":{"cards":[
          {"id":"c_m","type":"mail_today","size":"medium","title":"오늘 온 메일","source":"mac","state":"ok","data":{
            "count":8,"services":["네이버","지메일"],"headline":"챙길 메일 1통","rest":"배포 안내 3통",
            "picks":[{"title":"보안 알림","note":"직접 한 것인지 확인","service":"지메일"},{"note":"제목 없음"},
                     {"title":"둘"},{"title":"셋"},{"title":"넷"}],
            "items":[{"service":"지메일","subject":"보안 알림 — 직접 한 것인지 확인","from":"","time":""}],
            "blocks":[{"kind":"text","text":"챙길 메일 1통 · 배포 안내 3통"}]}},
          {"id":"c_n","type":"mail_today","size":"medium","title":"오늘 온 메일","source":"mac","state":"ok","data":{
            "count":0,"headline":"오늘 온 메일이 없어요","picks":[],"rest":"","items":[]}}
        ]}}
        """
        let cards = try SpaceDecoding.space(data: Data(json.utf8), status: 200).cards
        #expect(cards[0].mailHeadline == "챙길 메일 1통" && cards[0].mailRest == "배포 안내 3통")
        // 제목이 없는 것은 버리고, 셋까지만
        #expect(cards[0].mailPicks.map(\.title) == ["보안 알림", "둘", "셋"])
        #expect(cards[0].mailPicks[0].note == "직접 한 것인지 확인")
        // 빈 글로 온 보낸 사람·시각은 없는 것으로 읽는다
        #expect(cards[0].mails.first?.from == nil && cards[0].mails.first?.time == nil)
        #expect(cards[1].mailPicks.isEmpty && cards[1].mailRest == nil && cards[1].mailHeadline == "오늘 온 메일이 없어요")
    }

    @Test func aCardThatCannotBeFilledMayCarryOneAction() throws {
        let json = """
        {"space":{"cards":[
          {"id":"c_a","type":"custom","size":"medium","title":"결제 내역","source":"mac","state":"unavailable","why":"사이트 확인이 필요해요",
           "action":{"label":"매일 아침에 모아보기","say":"매일 아침 9시에 결제 내역 알려줘"}},
          {"id":"c_b","type":"custom","size":"medium","title":"알림 목록","source":"mac","state":"unavailable","why":"연동 필요"},
          {"id":"c_c","type":"custom","size":"medium","title":"말이 없는 단추","source":"mac","state":"unavailable","action":{"label":"켜기"}},
          {"id":"c_d","type":"custom","size":"medium","title":"꼴이 다른 단추","source":"mac","state":"unavailable","action":"켜기"},
          {"id":"c_e","type":"custom","size":"medium","title":"긴 단추","source":"mac","state":"unavailable",
           "action":{"label":"매일 아침 아홉 시에 한 번씩 모아서 보여 주기","say":"x"}}
        ]}}
        """
        let cards = try SpaceDecoding.space(data: Data(json.utf8), status: 200).cards
        #expect(cards.count == 5)
        #expect(cards[0].action == SpaceCard.Action(label: "매일 아침에 모아보기", say: "매일 아침 9시에 결제 내역 알려줘"))
        // 단추가 없거나 꼴이 어긋나면 카드는 그대로, 단추만 없다
        #expect(cards.dropFirst().allSatisfy { $0.action == nil })
    }

    @Test func changesSinceLastTimeAndQuickActionsAreRead() throws {
        let json = """
        {"space":{"cards":[
          {"id":"c_r","type":"custom","size":"medium","title":"원달러 환율","source":"mac","state":"ok","changed_at":"2026-11-16T18:00:00+09:00",
           "actions":[{"label":"자세히 묻기","say":"환율 자세히 알려줘"},{"label":"지금 가져오기","run":"rt_rate"},{"label":"셋째","say":"x"}],
           "data":{"delta":{"diff":-2.5,"text":"−2.5"},"blocks":[
             {"kind":"stat","value":"1,338.0원"},
             {"kind":"trend","points":[1336.0,"x",1340.5,1338.0]}
           ]}},
          {"id":"c_l","type":"custom","size":"medium","title":"주문","source":"mac","state":"ok",
           "actions":[{"label":"말도 예약도 없음"},{"label":"이름이 너무 긴 단추라서 그리지 않는 것","say":"x"},{"label":"나쁜 번호","run":"../x"}],
           "data":{"new_count":1,"delta":{"diff":0,"text":"0"},"blocks":[
             {"kind":"list","items":[{"title":"새 책","new":true},{"title":"옛 책"}]},
             {"kind":"trend","points":[5]}
           ]}}
        ]}}
        """
        let cards = try SpaceDecoding.space(data: Data(json.utf8), status: 200).cards
        #expect(cards[0].delta == "−2.5" && !cards[0].deltaUp && cards[0].changedAt != nil)
        // 추세선은 덩어리 수에 들지 않고, 읽지 못한 값은 건너뛴다
        #expect(cards[0].trend == [1336.0, 1340.5, 1338.0] && cards[0].blocks.count == 1)
        #expect(cards[0].quicks == [
            SpaceCard.Quick(label: "자세히 묻기", kind: .say("환율 자세히 알려줘")),
            SpaceCard.Quick(label: "지금 가져오기", kind: .run("rt_rate")),
        ])
        #expect(cards[1].newCount == 1)
        guard case .list(let items) = cards[1].blocks[0] else { Issue.record("목록이 아니다"); return }
        #expect(items.map(\.isNew) == [true, false])
        // 차이가 0이면 보이지 않고, 값 하나로는 선이 되지 않고, 꼴이 어긋난 단추는 그리지 않는다
        #expect(cards[1].delta == nil && cards[1].trend.isEmpty && cards[1].quicks.isEmpty)
    }

    @Test func theTrendLineSpansTheBoxFromLowToHigh() {
        let spots = SpaceTrendLine.spots([10, 20, 15], in: CGSize(width: 108, height: 28))
        #expect(spots.map(\.x) == [4, 54, 104])
        #expect(spots.map(\.y) == [24, 4, 14])
        #expect(SpaceTrendLine.spots([7, 7], in: CGSize(width: 108, height: 28)).map(\.y) == [14, 14])
        #expect(SpaceTrendLine.spots([7], in: CGSize(width: 108, height: 28)).isEmpty)
        #expect(SpaceTrendLine.summary([3, 2, 1]) == "지난 3번의 흐름, 내림")
    }

    @Test func editCarriesChangesAndSay() throws {
        let json = """
        {"space":{"cards":[]},"changes":["'날씨' 카드를 뺐어요","",4],"say":"  "}
        """
        let edit = try SpaceDecoding.edit(data: Data(json.utf8), status: 200)
        #expect(edit.changes == ["'날씨' 카드를 뺐어요"])
        #expect(edit.say == nil)
        #expect(throws: AgentError.self) { try SpaceDecoding.edit(data: Data("{}".utf8), status: 200) }
        #expect(throws: AgentError.self) { try SpaceDecoding.edit(data: Data(json.utf8), status: 500) }
    }

    @Test func twoSmallCardsShareARow() {
        func card(_ id: String, _ size: SpaceCard.Size) -> SpaceCard { SpaceCard(id: id, kind: .custom, size: size, title: id) }
        let space = AgentSpace(cards: [card("a", .small), card("b", .small), card("c", .small), card("d", .large), card("e", .small), card("f", .small)])
        #expect(space.rows.map { $0.map(\.id) } == [["a", "b"], ["c"], ["d"], ["e", "f"]])
    }
}

@MainActor
@Suite("내 공간: 말로 고치고 새로 받기")
struct SpaceModelTests {
    @Test func aMacWithoutSpaceOffersNothing() async {
        let model = SpaceModel(agent: MockAgentClient())
        await model.load()
        #expect(model.hasLoaded && !model.isOffered && !model.loadFailed)
        let offline = SpaceModel(agent: MockAgentClient(reachable: false, space: MockSpace()))
        await offline.load()
        #expect(offline.loadFailed)
    }

    @Test func editingChangesTheScreenAndFillsNewCards() async throws {
        let agent = MockAgentClient(space: MockSpace())
        let model = SpaceModel(agent: agent)
        await model.load()
        #expect(model.isOffered && model.space.cards.isEmpty)
        await model.edit("  오늘 온 메일이랑 날씨를 한 화면에 보여 줘  ")
        #expect(await agent.spaceEdits == ["오늘 온 메일이랑 날씨를 한 화면에 보여 줘"])
        #expect(model.space.cards.map(\.kind) == [.mailToday, .weather])
        #expect(model.turns.last?.changes == ["'오늘 온 메일' 카드를 더했어요", "'날씨' 카드를 더했어요"])
        #expect(model.lastSummary == "'오늘 온 메일' 카드를 더했어요 외 1건" && model.lastChanged)
        // 맥이 채우는 카드만 새로 받는다 (날씨는 앱이 채운다)
        let mail = try #require(model.space.cards.first)
        #expect(await agent.spaceRefreshes == [mail.id])
        #expect(mail.state == .ok && mail.mailCount == 5)
        #expect(model.space.cards.allSatisfy(model.changed))
        // 모든 카드가 새 카드면 미리 보기에 표시를 붙이지 않는다 (전부에 붙으면 가려지는 것이 없다)
        #expect(!model.marksChanges)
        // 고치기 화면을 닫고 다시 열어 하나를 더하면, 그 카드에만 "새로"가 붙는다
        model.finishEditing()
        await model.edit("환율도 같이 보고 싶어")
        #expect(model.marksChanges)
        #expect(model.space.cards.map(model.change) == [nil, nil, "새로"])
    }

    @Test func removingAndMovingAreShownInThePreview() async {
        let model = SpaceModel(agent: MockAgentClient(space: MockSpace(cards: MockSpace.demoCards)))
        await model.load()
        await model.edit("메일을 맨 위에 크게 보여 주고, 날씨는 빼 줘")
        #expect(model.space.cards.first?.kind == .mailToday && model.space.cards.first?.size == .large)
        #expect(model.removed.map(\.kind) == [.weather])
        // 옮긴 카드만 바뀐 것으로 가린다 (밀려난 카드는 아니다)
        #expect(model.space.cards.filter(model.changed).map(\.kind) == [.mailToday])
        #expect(model.change(model.space.cards[0]) == "위로 · 크게")
        #expect(model.marksChanges)
        await model.undo()
        #expect(model.space.cards.map(\.id) == MockSpace.demoCards.map(\.id))
        #expect(model.removed.isEmpty)
        model.finishEditing()
        #expect(model.turns.isEmpty)
    }

    @Test func nothingChangesWhenTheMacDidNotUnderstand() async {
        let model = SpaceModel(agent: MockAgentClient(space: MockSpace(cards: MockSpace.demoCards)))
        await model.load()
        await model.edit("음")
        #expect(model.turns.last?.changes == [])
        #expect(model.turns.last?.say != nil)
        // 바뀐 것이 없으면 맥이 덧붙인 말을 알림에 쓰고, 되돌리기는 보이지 않는다
        #expect(model.lastSummary == model.turns.last?.say && !model.lastChanged)
        #expect(model.space.cards.map(\.id) == MockSpace.demoCards.map(\.id))
        // 빈 말은 보내지 않는다
        await model.edit("   ")
        #expect(model.turns.count == 1)
    }

    @Test func theMacCanAskBackAndReadTheNextWordsAsTheAnswer() async throws {
        let agent = MockAgentClient(space: MockSpace(cards: MockSpace.demoCards))
        let model = SpaceModel(agent: agent)
        await model.load()
        await model.edit("주식 보여줘")
        // 되물으면 화면은 그대로이고, 알림에 묻는 말이 나온다
        #expect(model.isAsked && model.lastSummary == "어느 종목 주가를 보여 드릴까요?" && !model.lastChanged)
        #expect(model.space.cards.count == MockSpace.demoCards.count)
        await model.edit("한빛전자")
        #expect(!model.isAsked && model.space.cards.last?.title == "한빛전자 주가")
        // 응답을 읽을 때: 묻는 말이 없으면 되묻기로 보지 않는다
        let empty = try SpaceDecoding.edit(data: Data(#"{"space":{"cards":[]},"changes":[],"asking":true}"#.utf8), status: 200)
        #expect(!empty.asking)
        let asked = try SpaceDecoding.edit(data: Data(#"{"space":{"cards":[]},"changes":[],"say":"어느 종목인가요?","asking":true}"#.utf8), status: 200)
        #expect(asked.asking && asked.say == "어느 종목인가요?")
    }

    @Test func reloadingDoesNotOverwriteWhatIsBeingArrangedByHand() async {
        let agent = MockAgentClient(space: MockSpace(cards: MockSpace.demoCards))
        let model = SpaceModel(agent: agent)
        await model.load()
        let ids = MockSpace.demoCards.map(\.id)
        model.previewMove(ids[3], onto: ids[0])
        // 다른 탭에 다녀와 다시 받아도, 아직 보내지 않은 차례는 그대로다
        await model.load()
        #expect(model.space.cards.first?.id == ids[3] && model.hasPendingArrange)
        await model.commitArrange()
        await model.load()
        #expect(model.space.cards.first?.id == ids[3])
    }

    @Test func undoWithNothingToUndoSaysSo() async {
        let model = SpaceModel(agent: MockAgentClient(space: MockSpace(cards: MockSpace.demoCards)))
        await model.load()
        await model.undo()
        #expect(model.notice == "되돌릴 것이 없어요.")
        await model.clear()
        #expect(model.space.cards.isEmpty && model.space.canUndo && model.notice == nil)
    }

    @Test func aCardThatCannotBeFilledIsNotAskedAgain() async {
        let stuck = SpaceCard(id: "c_stuck", kind: .custom, size: .medium, title: "주문·배송", state: .unavailable, why: "로그인이 필요해요.")
        let agent = MockAgentClient(space: MockSpace(cards: [stuck]))
        let model = SpaceModel(agent: agent)
        await model.load()
        await model.refreshStale()
        #expect(await agent.spaceRefreshes.isEmpty)
        #expect(model.space.cards.first?.why == "로그인이 필요해요.")
    }

    @Test func cardsCanBeMovedResizedAndRemovedByHand() async {
        let agent = MockAgentClient(space: MockSpace(cards: MockSpace.demoCards))
        let model = SpaceModel(agent: agent)
        await model.load()
        #expect(model.canArrange)
        let ids = MockSpace.demoCards.map(\.id)
        // 끌어 옮기는 중에는 화면만 바뀌고, 놓아야 맥에 간다
        model.previewMove(ids[3], onto: ids[0])
        #expect(model.space.cards.map(\.id).prefix(2) == [ids[3], ids[0]])
        #expect(await agent.spaceArrangements.isEmpty && model.hasPendingArrange)
        await model.commitArrange()
        #expect(await agent.spaceArrangements.last?.map(\.id).first == ids[3])
        #expect(!model.hasPendingArrange && model.lastChanged)
        await model.resize(ids[0], to: .small)
        #expect(model.space.cards.first { $0.id == ids[0] }?.size == .small)
        #expect(await agent.spaceArrangements.last?.first { $0.id == ids[0] }?.size == "small")
        await model.remove(ids[1])
        #expect(!model.space.cards.contains { $0.id == ids[1] })
        #expect(model.removed.map(\.id) == [ids[1]])
        await model.move(ids[3], by: 1)
        #expect(model.space.cards.map(\.id).prefix(2) == [ids[0], ids[3]])
        // 되돌리기는 말로 고친 것과 같은 길이다
        await model.undo()
        #expect(model.space.cards.map(\.id).prefix(2) == [ids[3], ids[0]])
    }

    @Test func aRejectedArrangementGoesBackToHowItWas() async {
        let agent = MockAgentClient(space: MockSpace(cards: MockSpace.demoCards))
        let model = SpaceModel(agent: agent)
        await model.load()
        await agent.failNextArrange()
        await model.remove(MockSpace.demoCards[0].id)
        #expect(model.space.cards.map(\.id) == MockSpace.demoCards.map(\.id))
        #expect(model.lastSummary?.contains("못했어요") == true && !model.lastChanged)
        // 손으로 고치기를 모르는 맥이면 아무것도 하지 않는다
        let old = SpaceModel(agent: MockAgentClient(space: MockSpace(cards: MockSpace.demoCards), spaceArranges: false))
        await old.load()
        #expect(!old.canArrange)
        await old.remove(MockSpace.demoCards[0].id)
        #expect(old.space.cards.count == MockSpace.demoCards.count)
    }

    @Test func draggingTheHandleChangesTheCardRightAwayAndSendsItOnRelease() async {
        let agent = MockAgentClient(space: MockSpace(cards: MockSpace.demoCards))
        let model = SpaceModel(agent: agent)
        await model.load()
        let id = MockSpace.demoCards[2].id
        // 끄는 동안: 화면의 카드는 바로 그 크기가 되고, 맥에는 아직 가지 않는다
        model.previewResize(id, to: .medium)
        model.previewResize(id, to: .large)
        #expect(model.space.cards.first { $0.id == id }?.size == .large)
        #expect(await agent.spaceArrangements.isEmpty && model.hasPendingArrange)
        // 놓으면 마지막 크기 한 번만 간다
        await model.commitArrange()
        #expect(await agent.spaceArrangements.count == 1)
        #expect(await agent.spaceArrangements.last?.first { $0.id == id }?.size == "large")
        // 끌다가 처음 크기로 돌아와 놓으면 맥에 보내지 않는다
        model.previewResize(id, to: .small)
        model.previewResize(id, to: .large)
        await model.commitArrange()
        #expect(await agent.spaceArrangements.count == 1)
    }

    @Test func theGridPairsHalfCardsThatFollowEachOther() {
        #expect(SpaceGrid.rows([false, true, true, true, false, true]) == [[0], [1, 2], [3], [4], [5]])
        #expect(SpaceGrid.rows([true, true, true, true]) == [[0, 1], [2, 3]])
        #expect(SpaceGrid.rows([]).isEmpty)
    }

    @Test func weatherHoursAndDaysAreNamedInKorean() {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 19))!
        #expect(SpaceWeatherBody.hourText(evening, timeZone: seoul) == "오후 7시")
        #expect(SpaceWeatherBody.hourText(evening.addingTimeInterval(5 * 3600), timeZone: seoul) == "오전 12시")
        #expect(SpaceWeatherBody.hourText(evening.addingTimeInterval(-7 * 3600), timeZone: seoul) == "오후 12시")
        #expect(SpaceWeatherBody.dayText(evening, timeZone: seoul) == "월요일")
    }

    @Test func theResizeHandleStepsThroughSizes() {
        #expect(SpaceResize.size(from: .small, dragged: CGSize(width: 40, height: 30)) == .medium)
        #expect(SpaceResize.size(from: .small, dragged: CGSize(width: 90, height: 60)) == .large)
        #expect(SpaceResize.size(from: .large, dragged: CGSize(width: -70, height: -10)) == .medium)
        #expect(SpaceResize.size(from: .medium, dragged: CGSize(width: 10, height: 5)) == .medium)
        #expect(SpaceResize.size(from: .large, dragged: CGSize(width: 300, height: 300)) == .large)
        #expect(SpaceResize.next(.large) == .small && SpaceResize.next(.small) == .medium)
    }

    @Test func runningARoutineNowAsksTheMacAndKeepsRefreshingTheCard() async {
        let agent = MockAgentClient(space: MockSpace(cards: MockSpace.demoCards))
        let model = SpaceModel(agent: agent)
        model.runPoll = .milliseconds(1)
        model.runPollLimit = 3
        await model.load()
        await model.runNow(card: "c_orders", routine: "rt_demo_orders")
        #expect(await agent.routinesRun == ["rt_demo_orders"])
        // 새 내용이 올 때까지 그 카드를 틈틈이 새로 받는다 (가짜 맥은 받을 때마다 지금 채운 것으로 준다 — 첫 번에 끝난다)
        #expect(await agent.spaceRefreshes.contains("c_orders"))
        #expect(model.running.isEmpty && model.notice == nil)
        // 없는 예약이면 알리고, 카드는 그대로다
        await model.runNow(card: "c_orders", routine: "rt_missing")
        #expect(model.notice?.contains("가져오지 못했어요") == true)
    }

    @Test func openTodosComeFromTheLatestMeetingFirst() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        func meeting(_ title: String, daysAgo: Double, _ items: [ActionItem]) {
            let meeting = Meeting(title: title, date: .now.addingTimeInterval(-86400 * daysAgo), duration: 60)
            context.insert(meeting)
            meeting.summary = Summary(topic: title, body: "", decisions: [], actionItems: items, openQuestions: [])
        }
        let done = ActionItem(task: "끝낸 일", order: 0)
        done.isCompleted = true
        meeting("지난주", daysAgo: 7, [ActionItem(task: "오래된 일", owner: "가람", dueText: "금요일", order: 0)])
        meeting("어제", daysAgo: 1, [done, ActionItem(task: "둘째", order: 2), ActionItem(task: "첫째", order: 1)])
        let orphan = ActionItem(task: "회의가 지워진 일")
        context.insert(orphan)
        let items = try context.fetch(FetchDescriptor<ActionItem>())
        let open = SpaceTodos.open(items)
        #expect(open.map(\.task) == ["첫째", "둘째", "오래된 일"])
        #expect(SpaceTodos.detail(open[2]) == "가람 님 · 금요일")
        #expect(SpaceTodos.detail(open[0]) == nil)
    }

    @Test func bigValuesAreSplitIntoNumberAndUnit() {
        #expect(SpaceTime.split("1,336.0원") == ("1,336.0", "원"))
        #expect(SpaceTime.split("8통") == ("8", "통"))
        #expect(SpaceTime.split("62 %") == ("62", "%"))
        #expect(SpaceTime.split("-3.5") == ("-3.5", ""))
        // 숫자로 시작하지 않거나 뒤가 긴 글이면 가르지 않는다
        #expect(SpaceTime.split("맑음") == ("맑음", ""))
        #expect(SpaceTime.split("3일 뒤 도착") == ("3일 뒤 도착", ""))
    }

    @Test func timesAreSaidInWords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SpaceTime.ago(now.addingTimeInterval(-20), now: now) == "방금")
        #expect(SpaceTime.ago(now.addingTimeInterval(-40 * 60), now: now) == "40분 전")
        #expect(SpaceTime.ago(now.addingTimeInterval(-3 * 3600), now: now) == "3시간 전")
        #expect(SpaceTime.until(now.addingTimeInterval(4.5 * 60), now: now) == "5분 뒤")
        #expect(SpaceTime.until(now.addingTimeInterval(2 * 3600 + 60), now: now) == "2시간 뒤")
        #expect(SpaceTime.until(now.addingTimeInterval(-60), now: now) == "지금")
    }

    @Test func particlesFollowTheWordBefore() {
        #expect(Josa.fix("'날씨'을(를) 보통 크기로 바꿨어요") == "'날씨'를 보통 크기로 바꿨어요")
        #expect(Josa.fix("'오늘 일정'을(를) 맨 위로 옮겼어요") == "'오늘 일정'을 맨 위로 옮겼어요")
        #expect(Josa.fix("메일이(가) 왔고 환율은(는) 그대로예요") == "메일이 왔고 환율은 그대로예요")
        #expect(Josa.fix("날씨와(과) 일정과(와) 메일") == "날씨와 일정과 메일")
        #expect(Josa.fix("서울(으)로, 부산(으)로, 제주(으)로") == "서울로, 부산으로, 제주로")
        // 숫자는 읽는 소리로, 조사가 없는 글은 그대로
        #expect(Josa.fix("카드 3을(를) 뺐어요") == "카드 3을 뺐어요")
        #expect(Josa.fix("바뀐 것이 없어요") == "바뀐 것이 없어요")
    }

    @Test func aLongReasonBecomesOnePhrase() {
        #expect(SpaceQuiet.short("로그인이 필요해요. 폰 알림은 제가 직접 볼 수 없어서 여기서 채울 수 없어요.") == "로그인이 필요해요")
        #expect(SpaceQuiet.short("내일 오전 8:00에 처음 돌아요") == "내일 오전 8:00에 처음 돌아요")
        #expect(SpaceQuiet.short("사이트에 들어가 봐야 알 수 있는 내용이라 여기서 바로 채울 수 없어요")?.count == 24)
        #expect(SpaceQuiet.short("  ") == nil && SpaceQuiet.short(nil) == nil)
    }

    @Test func theRestLineNeverLeavesBracketsOpen() {
        var card = SpaceCard(id: "c_m", kind: .mailToday, size: .medium, title: "오늘 온 메일")
        card.mailCount = 10
        card.mailRest = "회의 요약 테스트 배포 안내 8통 (54~61), 영수증 1통"
        #expect(SpaceMailHero.restLine(card, shown: 1) == "외 9통 · 회의 요약 테스트 배포 안내 8통, 영수증 1통")
        card.mailRest = "배포 안내 8통 (54~"
        #expect(SpaceMailHero.restLine(card, shown: 1) == "외 9통 · 배포 안내 8통")
        card.mailRest = "(덧말뿐)"
        #expect(SpaceMailHero.restLine(card, shown: 1) == "외 9통")
        card.mailCount = 1
        card.mailRest = nil
        card.mailServices = ["지메일"]
        #expect(SpaceMailHero.restLine(card, shown: 1) == "지메일")
    }

    @Test func pairsDatesAndSuggestionsAreRead() throws {
        let json = """
        {"space":{"cards":[
          {"id":"c_g","type":"custom","size":"small","title":"금 시세","source":"mac","state":"ok","data":{"blocks":[
            {"kind":"pairs","items":[{"label":"살 때","value":"52만 원"},{"label":"팔 때","value":470000},{"label":"값 없음"}]},
            {"kind":"pairs","items":[{"label":"하나뿐","value":"1"}]},
            {"kind":"date","label":"성탄절","date":"2026-12-25","note":"금요일"},
            {"kind":"date","label":"꼴이 다름","date":"12월 25일"}
          ]}}
        ],
        "suggestions":[{"label":"오늘 온 메일","say":"오늘 온 메일 카드 넣어줘"},{"label":"말 없음"},{"label":"오늘 온 메일","say":"두 번째"},
                       {"label":"글이 너무 길어서 칩에 들어가지 않는 추천","say":"x"}]}}
        """
        let space = try SpaceDecoding.space(data: Data(json.utf8), status: 200)
        let blocks = try #require(space.cards.first).blocks
        #expect(blocks.count == 2)
        #expect(blocks[0] == .pairs([SpaceBlock.Pair(label: "살 때", value: "52만 원"), SpaceBlock.Pair(label: "팔 때", value: "470000")]))
        #expect(blocks[1] == .date(label: "성탄절", day: DateComponents(year: 2026, month: 12, day: 25), note: "금요일"))
        // 추천: 말이 있고, 글이 짧고, 처음 나온 것만
        #expect(space.suggestions == [AgentSpace.Suggestion(label: "오늘 온 메일", say: "오늘 온 메일 카드 넣어줘")])
    }

    @Test func daysLeftAreCountedFromToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 23, minute: 30))!
        let christmas = DateComponents(year: 2026, month: 12, day: 25)
        #expect(SpaceDay.left(until: christmas, now: now, calendar: calendar) == 39)
        #expect(SpaceDay.badge(39) == "D-39" && SpaceDay.badge(0) == "오늘" && SpaceDay.badge(-1) == "D+1")
        #expect(SpaceDay.left(until: DateComponents(year: 2026, month: 11, day: 16), now: now, calendar: calendar) == 0)
        #expect(SpaceDay.text(christmas) == "12월 25일")
    }

    @Test func siteKeysBecomeNames() {
        #expect(SiteName.display("coupang-com") == "쿠팡")
        #expect(SiteName.display("vworld-kr") == "브이월드")
        #expect(SiteName.display("www.saramin.co.kr") == "사람인")
        #expect(SiteName.display("naver") == "네이버")
        // 모르는 사이트는 도메인 꼬리만 뗀다
        #expect(SiteName.display("hanbit-shop-com") == "hanbit")
        // 맥이 알려 준 이름이 먼저다
        SiteName.remember(["garam-test": "가람 상점", "same": "same"])
        #expect(SiteName.display("garam-test") == "가람 상점")
        #expect(SiteName.display("same") == "same")
    }

    @Test func theAppTellsTheMacWhichCardsItCanFill() {
        #expect(SpaceCard.Kind.appCards == ["calendar_today", "weather", "meeting_todos"])
    }
}

@Suite("내 공간: 오늘 일정")
struct SpaceCalendarTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ title: String, from: Double, to: Double, allDay: Bool = false) -> DayEvent {
        DayEvent(id: title, title: title, start: now.addingTimeInterval(from * 3600), end: now.addingTimeInterval(to * 3600), isAllDay: allDay)
    }

    @Test func finishedEventsAreLeftOutAndAllDayComesFirst() {
        let events = [
            event("저녁", from: 5, to: 6), event("끝난 회의", from: -3, to: -2), event("하는 중", from: -1, to: 1),
            event("휴가", from: -10, to: 14, allDay: true), event("점심", from: 2, to: 3),
        ]
        #expect(DayEvents.remaining(events, now: now).map(\.title) == ["휴가", "하는 중", "점심", "저녁"])
    }

    @Test func timeIsShownAsHourAndMinute() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 5))!
        #expect(DayEvent(id: "a", title: "a", start: start, end: start).timeText(calendar: calendar) == "9:05")
        #expect(DayEvent(id: "b", title: "b", start: start, end: start, isAllDay: true).timeText(calendar: calendar) == "종일")
    }

    @Test func nothingIsReadUntilAllowed() async {
        let asking = MockDayEvents(access: .notAsked)
        #expect(asking.today(now: now).isEmpty)
        #expect(await asking.request())
        #expect(asking.access() == .allowed && asking.today(now: now).count == 3)
        let refusing = MockDayEvents(access: .notAsked, grants: false)
        #expect(await refusing.request() == false)
        #expect(refusing.access() == .denied && refusing.today(now: now).isEmpty)
    }

    @Test func theCalendarRowAppearsOnlyAfterAsking() {
        #expect(PermissionItem.calendar(.notDetermined) == nil)
        #expect(PermissionItem.calendar(.granted)?.title == "캘린더")
        #expect(PermissionItem.calendar(.denied)?.state == .denied)
    }
}

@Suite("처음 한 번 보이는 화면")
struct OnboardingTests {
    @Test func itIsShownOnceAndNotDuringDemoRuns() {
        #expect(Onboarding.shouldShow(done: false, arguments: ["app"]))
        #expect(!Onboarding.shouldShow(done: true, arguments: ["app"]))
        // 개발용 실행에서는 따로 청할 때만
        #expect(!Onboarding.shouldShow(done: false, arguments: ["app", "-demo", "-demoAgent"]))
        #expect(Onboarding.shouldShow(done: true, arguments: ["app", "-demo", "-demoOnboarding"]))
    }
}

@Suite("홈 화면 위젯")
struct SpaceWidgetTests {
    @Test func onlyCardsTheMacFillsAreShown() throws {
        let json = """
        {"widget":{"v":1,"updated_at":"2026-11-16T21:00:00+09:00","items":[
          {"id":"c_w","type":"weather","title":"날씨","source":"app"},
          {"id":"c_m","type":"mail_today","title":"오늘 온 메일","source":"mac","state":"ok","value":"8통","line":"챙길 메일 1통","new_count":2},
          {"id":"c_e","type":"custom","title":"비어 있는 카드","source":"mac","state":"empty"},
          {"id":"c_u","type":"custom","title":"결제 내역","source":"mac","state":"unavailable","value":"x","line":"매일 모아 와야 해요"},
          {"id":"c_d","type":"custom","title":"다음 공휴일","source":"mac","state":"ok","value":"2026-12-25","date":"2026-12-25","line":"성탄절"},
          {"id":"c_n","type":"custom","title":"보일 것 없음","source":"mac","state":"ok"},
          {"title":"번호 없음","source":"mac"}
        ]}}
        """
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try #require(SpaceWidgetDecoding.snapshot(data: Data(json.utf8), status: 200, now: now))
        #expect(snapshot.items.map(\.id) == ["c_m", "c_u", "c_d"])
        #expect(snapshot.items[0].newCount == 2 && snapshot.items[0].value == "8통")
        // 채울 수 없는 카드는 값을 보이지 않고 까닭만
        #expect(snapshot.items[1].unavailable && snapshot.items[1].value == nil && snapshot.items[1].line == "매일 모아 와야 해요")
        #expect(snapshot.fetchedAt == now)
        #expect(SpaceWidgetDecoding.snapshot(data: Data(json.utf8), status: 500) == nil)
        #expect(SpaceWidgetDecoding.snapshot(data: Data("{}".utf8), status: 200) == nil)
    }

    @Test func theLastSnapshotIsKeptForWhenTheMacIsAway() throws {
        let file = URL.temporaryDirectory.appending(path: "widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(SpaceWidgetCache.load(from: file) == nil)
        let snapshot = SpaceWidgetSnapshot(
            items: [SpaceWidgetItem(id: "c_1", title: "환율", value: "1,382.0원", line: nil, unavailable: false)],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        SpaceWidgetCache.save(snapshot, to: file)
        #expect(SpaceWidgetCache.load(from: file) == snapshot)
    }

    @Test func dateCardsCountTheDaysLeft() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 21))!
        #expect(SpaceWidgetDays.badge("2026-12-25", now: now, calendar: calendar) == "D-39")
        #expect(SpaceWidgetDays.badge("2026-11-16", now: now, calendar: calendar) == "오늘")
        #expect(SpaceWidgetDays.badge("12월 25일", now: now, calendar: calendar) == nil)
        #expect(SpaceWidgetSnapshot.limit(small: true, large: false) == 1 && SpaceWidgetSnapshot.limit(small: false, large: false) == 4)
    }
}
