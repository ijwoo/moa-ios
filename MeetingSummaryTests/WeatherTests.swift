import Foundation
import SwiftData
import Testing
import WeatherKit
@testable import MeetingSummary

/// 물은 곳을 적어 두고 정해 둔 날씨를 돌려준다
private actor StubWeather: WeatherProviding {
    private(set) var asked: [String?] = []
    private let result: Result<WeatherSource, WeatherFailure>

    init(_ result: Result<WeatherSource, WeatherFailure>) {
        self.result = result
    }

    func weather(place: String?) async -> Result<WeatherSource, WeatherFailure> {
        asked.append(place)
        return result
    }
}

/// 날씨 카드 (D66): 맥은 "날씨를 물었다, 어디·언제"만 정하고, 앱이 날씨를 받아 카드로 그린다.
/// 여기의 날씨는 모두 앱이 만든 가상 값이다 (위치를 묻지 않고 밖으로 나가지 않는다)
@MainActor
@Suite("날씨 카드: 맥은 어디·언제만 정하고 앱이 그린다")
struct WeatherTests {
    let context: ModelContext
    /// 2026-11-13 (금) 14:20 서울 = 05:20 UTC = 11-12 (목) 21:20 로스앤젤레스
    private let noon = Date(timeIntervalSince1970: 1_794_547_200)
    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func source(_ place: String? = "부산", warmer: Int = 0, timeZone: TimeZone? = nil) -> WeatherSource {
        MockWeatherService.source(place: place, warmer: warmer, now: noon, timeZone: timeZone)
    }

    private func card(_ when: WeatherWhen, asked: String? = "부산", source: WeatherSource? = nil) -> WeatherCard {
        WeatherCard.make(asked: asked, when: when, result: .success(source ?? self.source()), now: noon)
    }

    private func cloud(weather: Bool = true) -> MockAgentClient {
        MockAgentClient(v2: true, dialogCloud: MockDialogCloud(webLookup: true, marksWriter: true, showsWeather: weather))
    }

    private func session(_ agent: MockAgentClient, weather: any WeatherProviding = MockWeatherService()) -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero, weather: weather)
        session.attach(context)
        return session
    }

    private func decode(_ json: String) throws -> AgentReply {
        try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200)
    }

    private func object(_ body: AgentHTTPClient.MessageBody) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    // MARK: - 언제

    @Test func whenIsReadFromTheAgreedWords() {
        #expect(WeatherWhen("now") == .now)
        #expect(WeatherWhen("today") == .today)
        #expect(WeatherWhen("tomorrow") == .tomorrow)
        #expect(WeatherWhen("week") == .week)
        #expect(WeatherWhen("2026-11-15") == .date(year: 2026, month: 11, day: 15))
    }

    /// 모르는 말, 없는 날짜, 꼴이 다른 날짜는 오늘로 읽는다
    @Test func anythingElseIsToday() {
        for raw in [nil, "", "someday", "2026-02-30", "2026-13-01", "11-15", "2026-1-5", "2026/11/15", "20261115", "tomorrow "] {
            #expect(WeatherWhen(raw) == .today, "\(raw ?? "nil")")
        }
    }

    // MARK: - 카드 만들기

    @Test func todayAndTomorrowPickThatDay() {
        let today = card(.today)
        #expect(today.kind == .day)
        #expect(today.period == "오늘")
        #expect(today.days == [WeatherCard.Day(label: "오늘", condition: "구름 조금", symbol: "cloud.sun.fill", high: 17, low: 8, rainChance: 10, wind: 2, uvIndex: 4)])
        #expect(today.now == nil)
        #expect(today.failure == nil)

        let tomorrow = card(.tomorrow)
        #expect(tomorrow.period == "내일")
        #expect(tomorrow.days.map(\.label) == ["내일"])
        #expect(tomorrow.days.first?.condition == "비")
        #expect(tomorrow.days.first?.rainChance == 70)
    }

    @Test func nowShowsTheCurrentWeatherWithTodaysRange() {
        let now = card(.now)
        #expect(now.kind == .now)
        #expect(now.period == "지금")
        #expect(now.now == WeatherCard.Now(temperature: 14, feelsLike: 12, condition: "구름 조금", symbol: "cloud.sun.fill"))
        #expect(now.days.map(\.label) == ["오늘"])
    }

    /// 지금 날씨를 받지 못했으면 오늘 예보로 답한다
    @Test func nowFallsBackToTodaysForecast() {
        var source = source()
        source.now = nil
        let card = card(.now, source: source)
        #expect(card.kind == .day)
        #expect(card.period == "오늘")
        #expect(card.days.map(\.label) == ["오늘"])
    }

    @Test func weekShowsSevenDaysFromToday() {
        let week = card(.week)
        #expect(week.kind == .week)
        #expect(week.period == "이번 주")
        #expect(week.days.map(\.label) == ["오늘", "내일", "15일 (일)", "16일 (월)", "17일 (화)", "18일 (수)", "19일 (목)"])
    }

    @Test func aNamedDateIsMatchedByItsDay() {
        let sunday = card(.date(year: 2026, month: 11, day: 15))
        #expect(sunday.kind == .day)
        #expect(sunday.period == "11월 15일 (일)")
        #expect(sunday.days.map(\.label) == ["15일 (일)"])
        #expect(sunday.days.first?.condition == "흐림")
        // 짚은 날짜가 오늘·내일이면 그렇게 부른다
        #expect(card(.date(year: 2026, month: 11, day: 13)).days.map(\.label) == ["오늘"])
        #expect(card(.date(year: 2026, month: 11, day: 14)).days.map(\.label) == ["내일"])
    }

    /// 지난 날과 예보가 닿지 않는 먼 날은 지어내지 않고 "볼 수 없다"고 한다
    @Test func datesOutsideTheForecastAreNotInvented() {
        for when in [WeatherWhen.date(year: 2026, month: 11, day: 12), .date(year: 2026, month: 12, day: 25)] {
            let card = card(when)
            #expect(card.failure == .noForecast)
            #expect(card.days.isEmpty)
            #expect(card.place == "부산")
        }
        var empty = source()
        empty.days = []
        #expect(card(.week, source: empty).failure == .noForecast)
        #expect(card(.tomorrow, source: empty).failure == .noForecast)
    }

    /// "오늘·내일"은 그곳의 달력으로 센다: 서울이 13일 낮일 때 로스앤젤레스는 12일 밤이다
    @Test func todayIsCountedInThePlacesCalendar() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let there = source("로스앤젤레스", timeZone: losAngeles)
        #expect(card(.today, asked: "LA", source: there).days.first?.condition == "구름 조금")
        // 그곳의 13일은 그곳의 내일이다
        let thirteenth = card(.date(year: 2026, month: 11, day: 13), asked: "LA", source: there)
        #expect(thirteenth.days.map(\.label) == ["내일"])
        #expect(thirteenth.days.first?.condition == "비")
        #expect(card(.date(year: 2026, month: 11, day: 12), asked: "LA", source: there).days.map(\.label) == ["오늘"])
    }

    @Test func valuesAreKeptInRange() {
        var source = source()
        source.days[0].rainChance = 1.4
        source.days[0].wind = -3
        source.days[0].uvIndex = -1
        let day = card(.today, source: source).days[0]
        #expect(day.rainChance == 100)
        #expect(day.wind == 0)
        #expect(day.uvIndex == 0)
    }

    // MARK: - 이 기기의 위치는 글로도 나가지 않는다

    /// 지금 위치를 물은 카드에는 지역 이름을 두지 않는다 (받아온 쪽이 이름을 줘도)
    @Test func theCurrentLocationIsNeverNamed() {
        let card = card(.today, asked: nil, source: source("가상동"))
        #expect(card.isCurrentLocation)
        #expect(card.place == nil)
        #expect(card.summary == "지금 위치 오늘: 구름 조금, 8~17도, 강수확률 10%")
        #expect(!card.summary.contains("가상동"))
        let stored = String(decoding: (try? JSONEncoder().encode(card)) ?? Data(), as: UTF8.self)
        #expect(!stored.contains("가상동"))
    }

    /// 맥에 알리는 줄에는 내가 말한 지역을 쓴다. 찾은 이름은 카드 머리에만 쓴다
    @Test func theSummaryNamesThePlaceAsISaidIt() {
        let card = card(.tomorrow, asked: " 부산 ", source: source("부산광역시", warmer: 2))
        #expect(card.asked == "부산")
        #expect(card.place == "부산광역시")
        #expect(card.summary == "부산 내일: 비, 13~18도, 강수확률 70%")
    }

    @Test func summariesForNowAndWeek() {
        #expect(card(.now).summary == "부산 지금: 구름 조금, 14도 (체감 12도), 오늘 8~17도, 강수확률 10%")
        let week = card(.week).summary
        #expect(week.hasPrefix("부산 이번 주: 오늘 구름 조금 8~17도 비 10%, 내일 비 11~16도 비 70%, "))
        #expect(week.count <= WeatherCard.summaryLimit)
    }

    @Test func aFailureIsAlsoToldInOneLine() {
        let denied = WeatherCard.make(asked: nil, when: .today, result: .failure(.locationDenied), now: noon)
        #expect(denied.failure == .locationDenied)
        #expect(denied.isCurrentLocation)
        #expect(denied.summary == "지금 위치 오늘: 날씨를 보여 주지 못함 (위치 권한 없음)")

        let lost = WeatherCard.make(asked: "없는마을", when: .date(year: 2026, month: 11, day: 15), result: .failure(.placeNotFound), now: noon)
        #expect(lost.place == "없는마을")
        #expect(lost.summary == "없는마을 11월 15일 (일): 날씨를 보여 주지 못함 (지역을 찾지 못함)")
        #expect(WeatherCardView.message(for: .placeNotFound, asked: "없는마을").contains("없는마을"))
    }

    @Test func aLongSummaryIsCut() {
        let long = WeatherCard.make(asked: String(repeating: "가", count: 400), when: .week, result: .success(source()), now: noon)
        #expect(long.summary.count == WeatherCard.summaryLimit)
    }

    // MARK: - 맥의 응답 읽기

    @Test func featureNamesMatchTheMac() {
        #expect(AgentFeature.weatherAction == "weather_action")
        #expect(MessageExtras.weatherFeature == "weather")
        #expect(MessageExtras.eventLimit == 3)
    }

    @Test func theWeatherActionCarriesWhereAndWhen() throws {
        let reply = try decode("""
        {"conversation_id":"c_1","replies":[{"text":"부산 내일 날씨 바로 볼게요!","by":"claude"}],
         "action":{"type":"weather","place":"부산","when":"tomorrow"}}
        """)
        #expect(reply.action == .weather(place: "부산", when: .tomorrow))
        #expect(reply.replies == ["부산 내일 날씨 바로 볼게요!"])
        #expect(reply.writers == [.claude])
    }

    /// 지역이 없으면 지금 위치, 때를 모르면 오늘. 꼴이 다른 값이 와도 답을 버리지 않는다
    @Test func missingOrOddValuesAreReadSafely() throws {
        func action(_ fields: String) throws -> AgentReply.Action {
            try decode(#"{"conversation_id":"c_1","replies":[],"action":{"type":"weather"\#(fields)}}"#).action
        }
        #expect(try action("") == .weather(place: nil, when: .today))
        #expect(try action(#","when":"week""#) == .weather(place: nil, when: .week))
        #expect(try action(#","place":null,"when":null"#) == .weather(place: nil, when: .today))
        #expect(try action(#","place":7,"when":3"#) == .weather(place: nil, when: .today))
        #expect(try action(#","place":"  ","when":"next year""#) == .weather(place: nil, when: .today))
        #expect(try action(#","place":" 제주 ","when":"2026-11-15""#) == .weather(place: "제주", when: .date(year: 2026, month: 11, day: 15)))
    }

    // MARK: - 맥에 보내는 것

    /// 모르는 키를 받은 맥은 요청을 거절한다: `weather_action`을 알리지 않은 맥에는 예전과 같은 요청이 간다
    @Test func extrasGoOnlyToAMacThatKnowsWeather() throws {
        let extras = MessageExtras(clientFeatures: ["weather"], weatherEvents: ["부산 내일: 비, 12~18도, 강수확률 70%"])
        let old = AgentHTTPClient.MessageBody(
            text: "그럼 우산 챙길까?", conversationID: "c_1", context: nil, messageID: "m_1", replyTaskID: nil,
            tone: "friendly", features: [AgentFeature.messageReplay], extras: extras
        )
        #expect(try Set(object(old).keys) == ["text", "conversation_id", "client_message_id"])

        let new = AgentHTTPClient.MessageBody(
            text: "그럼 우산 챙길까?", conversationID: "c_1", context: nil, messageID: "m_1", replyTaskID: nil,
            tone: "friendly", features: [AgentFeature.messageReplay, AgentFeature.weatherAction], extras: extras
        )
        let sent = try object(new)
        #expect(Set(sent.keys) == ["text", "conversation_id", "client_message_id", "client_features", "events"])
        #expect(sent["client_features"] as? [String] == ["weather"])
        #expect(sent["events"] as? [[String: String]] == [["type": "weather", "text": "부산 내일: 비, 12~18도, 강수확률 70%"]])
    }

    /// 보여 준 것은 메시지 번호가 갈 때만 알린다 (번호가 없으면 다시 보낸 요청에서 맥이 같은 내용을 두 번 적는다)
    @Test func eventsNeedAMessageNumber() throws {
        let extras = MessageExtras(clientFeatures: ["weather"], weatherEvents: ["지금 위치 오늘: 흐림, 8~17도, 강수확률 30%"])
        for (features, messageID) in [([AgentFeature.weatherAction], "m_1"), ([AgentFeature.weatherAction, AgentFeature.messageReplay], nil)] as [([String], String?)] {
            let body = AgentHTTPClient.MessageBody(
                text: "고마워", conversationID: nil, context: nil, messageID: messageID, replyTaskID: nil,
                tone: "friendly", features: Set(features), extras: extras
            )
            #expect(try Set(object(body).keys) == ["text", "client_features"])
        }
    }

    /// 맥과 맞춘 한도: 최대 3개, 한 줄 300자, 줄바꿈 없이. 보낼 것이 없으면 키도 없다
    @Test func eventsAreKeptWithinTheAgreedLimits() throws {
        let features: Set<String> = [AgentFeature.weatherAction, AgentFeature.messageReplay]
        func body(_ extras: MessageExtras) -> AgentHTTPClient.MessageBody {
            AgentHTTPClient.MessageBody(
                text: "안녕", conversationID: nil, context: nil, messageID: "m_1", replyTaskID: nil, tone: "friendly", features: features, extras: extras
            )
        }
        let many = body(MessageExtras(clientFeatures: ["weather"], weatherEvents: ["하나\n둘", "", String(repeating: "가", count: 400), "셋", "넷"]))
        #expect(many.events?.map(\.text) == ["하나 둘", String(repeating: "가", count: 300), "셋"])
        #expect(many.events?.allSatisfy { $0.type == "weather" } == true)

        #expect(try Set(object(body(.none)).keys) == ["text", "client_message_id"])
        #expect(try Set(object(body(MessageExtras(clientFeatures: ["weather"]))).keys) == ["text", "client_message_id", "client_features"])
    }

    // MARK: - 대화에서

    @Test func aWeatherQuestionGetsTheMacsLineAndACard() async throws {
        let agent = cloud()
        let weather = StubWeather(.success(MockWeatherService.source(place: "부산", warmer: 2, now: .now)))
        let session = session(agent, weather: weather)
        await session.send("부산 내일 날씨 어때", meetings: [])

        #expect(session.messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(session.messages[1].text == "부산 내일 날씨 바로 볼게요!")
        #expect(session.messages[1].weather == nil)
        let card = try #require(session.messages[2].weather)
        #expect(card.kind == .day)
        #expect(card.asked == "부산")
        #expect(card.place == "부산")
        #expect(card.period == "내일")
        #expect(card.days.map(\.label) == ["내일"])
        #expect(card.reported == false)
        #expect(session.messages[2].text == card.summary)
        #expect(session.messages[2].engine == .local)
        // 맥이 준 지역을 그대로 물었다
        #expect(await weather.asked == ["부산"])
        // 앱이 카드를 그릴 수 있다고 알렸고, 아직 보여 준 것은 없었다
        #expect(await agent.receivedExtras == [MessageExtras(clientFeatures: ["weather"])])
        // "Claude 사용"은 Claude가 쓴 한마디 아래에 붙는다. 카드는 앱이 그린 것이다
        #expect(session.messages.indices.filter { AskSession.marksClaude(at: $0, in: session.messages) } == [1])
    }

    /// 지역을 말하지 않으면 지금 위치를 묻는다. 맥에는 "지금 위치"라고만 알린다
    @Test func aQuestionWithoutAPlaceAsksForTheCurrentLocation() async throws {
        let agent = cloud()
        let weather = StubWeather(.success(MockWeatherService.source(place: nil, warmer: 0, now: .now)))
        let session = session(agent, weather: weather)
        await session.send("오늘 날씨 어때", meetings: [])
        let card = try #require(session.messages.last?.weather)
        #expect(await weather.asked == [nil])
        #expect(card.isCurrentLocation)
        #expect(card.place == nil)
        #expect(card.summary.hasPrefix("지금 위치 오늘: "))
    }

    /// 카드에 보인 내용은 다음 말과 함께 한 번만 알린다
    @Test func whatTheCardShowedIsToldOnceWithTheNextMessage() async throws {
        let agent = cloud()
        let session = session(agent)
        await session.send("부산 내일 날씨 어때", meetings: [])
        let summary = try #require(session.messages.last?.weather?.summary)
        #expect(await agent.recordedWeather.isEmpty)

        await session.send("고마워", meetings: [])
        #expect(await agent.receivedExtras.last == MessageExtras(clientFeatures: ["weather"], weatherEvents: [summary]))
        #expect(await agent.recordedWeather == [summary])
        #expect(session.messages.compactMap(\.weather).map(\.reported) == [true])

        await session.send("안녕", meetings: [])
        #expect(await agent.receivedExtras.last == MessageExtras(clientFeatures: ["weather"]))
        #expect(await agent.recordedWeather == [summary])
    }

    /// 이어지는 말: 맥은 앱이 알린 한 줄을 보고 답한다 (가짜 맥도 그 줄만 본다)
    @Test func aFollowUpIsAnsweredFromWhatTheCardShowed() async {
        let session = session(cloud())
        await session.send("부산 내일 날씨 어때", meetings: [])
        await session.send("그럼 우산 챙길까?", meetings: [])
        #expect(session.messages.last?.text == "비 소식이 있으니까 우산 챙기는 게 좋겠어요!")
        #expect(session.messages.last?.weather == nil)
    }

    /// 답을 받지 못했으면 알린 것으로 치지 않는다: 다음 말과 함께 다시 알린다
    @Test func anUnansweredMessageDoesNotMarkTheCard() async throws {
        let agent = cloud()
        let session = session(agent)
        await session.send("서울 날씨 어때", meetings: [])
        let summary = try #require(session.messages.last?.weather?.summary)

        await agent.failNextMessage(.busy)
        await session.send("고마워", meetings: [])
        #expect(session.messages.last?.role == .error)
        #expect(session.messages.compactMap(\.weather).map(\.reported) == [false])
        #expect(await agent.recordedWeather.isEmpty)

        await session.send("안녕", meetings: [])
        #expect(await agent.receivedExtras.last?.weatherEvents == [summary])
        #expect(await agent.recordedWeather == [summary])
        #expect(session.messages.compactMap(\.weather).map(\.reported) == [true])
    }

    /// 위치 권한이 없으면 카드가 그 까닭을 말하고, 맥에도 "보여 주지 못했다"고 알린다
    @Test func withoutLocationPermissionTheCardSaysSo() async throws {
        let agent = cloud()
        let session = session(agent, weather: MockWeatherService(locationDenied: true))
        await session.send("날씨 어때", meetings: [])
        let card = try #require(session.messages.last?.weather)
        #expect(card.failure == .locationDenied)
        #expect(card.days.isEmpty)

        await session.send("안녕", meetings: [])
        #expect(await agent.recordedWeather == ["지금 위치 오늘: 날씨를 보여 주지 못함 (위치 권한 없음)"])
        // 지역을 말하면 위치 없이 볼 수 있다
        await session.send("제주 날씨 어때", meetings: [])
        #expect(session.messages.last?.weather?.failure == nil)
        #expect(session.messages.last?.weather?.place == "제주")
    }

    @Test func anUnknownPlaceIsNotGuessed() async throws {
        let session = session(cloud())
        await session.send("없는마을 날씨 어때", meetings: [])
        let card = try #require(session.messages.last?.weather)
        #expect(card.failure == .placeNotFound)
        #expect(card.place == "없는마을")
    }

    /// 날씨 카드를 모르는 맥에는 아무것도 덧붙이지 않는다: 지금처럼 웹 검색 답이 온다
    @Test func aMacWithoutWeatherIsAskedAsBefore() async {
        let agent = cloud(weather: false)
        let weather = StubWeather(.failure(.unavailable))
        let session = session(agent, weather: weather)
        await session.send("서울 날씨 어때", meetings: [])
        #expect(await agent.receivedExtras == [.none])
        #expect(session.messages.allSatisfy { $0.weather == nil })
        #expect(session.messages.last?.text == "출처: 가상날씨, 가상기상청")
        #expect(await weather.asked.isEmpty)
    }

    /// 미세먼지는 날씨 카드가 아니라 맥의 답이다
    @Test func fineDustStaysWithTheMac() async {
        let weather = StubWeather(.failure(.unavailable))
        let session = session(cloud(), weather: weather)
        await session.send("서울 날씨 미세먼지 어때", meetings: [])
        #expect(session.messages.allSatisfy { $0.weather == nil })
        #expect(await weather.asked.isEmpty)
    }

    @Test func theCardSurvivesReopening() async throws {
        let agent = cloud()
        let session = session(agent)
        await session.send("부산 이번 주 날씨 어때", meetings: [])
        let card = try #require(session.messages.last?.weather)
        #expect(card.kind == .week)
        try context.save()

        func reopen() -> AskSession {
            let reopened = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero, weather: MockWeatherService())
            reopened.attach(context)
            if reopened.messages.isEmpty, let conversation = session.conversation { reopened.open(conversation) }
            return reopened
        }
        #expect(reopen().messages.last?.weather == card)

        // 알렸다는 것도 기록에 남는다 (앱을 다시 열어도 같은 내용을 또 알리지 않는다)
        await session.send("고마워", meetings: [])
        let again = reopen()
        #expect(again.messages.compactMap(\.weather).map(\.reported) == [true])
        await again.send("안녕", meetings: [])
        #expect(await agent.recordedWeather == [card.summary])
    }

    // MARK: - 데이터 처리 방식의 설명

    @Test func theSetupRemembersWeather() async {
        let setup = await DialogSetup(agent: cloud())
        #expect(setup.showsWeather)
        #expect(setup.stored.split(separator: " ").contains("weather"))
        #expect(DialogSetup(stored: setup.stored) == setup)
        #expect(DialogSetup(stored: "v2 cloud context")?.showsWeather == false)
        // 로컬 판단이면 날씨 카드도 없다
        #expect(DialogSetup(place: .local, showsWeather: true) == .local)
        #expect(await DialogSetup(agent: cloud(weather: false)).showsWeather == false)
    }

    @Test func theExplanationSaysWhatGoesWhere() throws {
        let with = MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true, webLookup: true, showsWeather: true)).rows
        let row = try #require(with.first { $0.text.contains("Apple 날씨") })
        let note = try #require(row.note)
        #expect(note.contains("Apple로 가는 것"))
        #expect(note.contains("약 1km"))
        #expect(note.contains("맥으로도 Claude로도 가지 않고"))
        #expect(note.contains("다음 말을 보낼 때 맥에 알리고"))
        #expect(with.contains { $0.text.hasPrefix("가격·뉴스·미세먼지 같은 공개 정보") })

        let without = MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true, webLookup: true)).rows
        #expect(!without.contains { $0.text.contains("Apple 날씨") })
        #expect(without.contains { $0.text.hasPrefix("날씨·가격·뉴스 같은 공개 정보") })
    }

    /// 맥이 "연 공개 페이지의 글을 Claude가 읽는다"고 알리면 그렇게 말한다 (`web_find_reads_cloud`. 맥의 기본은 꺼짐)
    @Test func openedPagesReadByClaudeAreSaidSo() async {
        #expect(AgentFeature.webFindReadsCloud == "web_find_reads_cloud")
        func note(_ setup: DialogSetup) -> String {
            MacAgentFacts(setup: setup).rows.first { $0.text.hasPrefix("무엇을 찾아 달라고 하면") }?.note ?? ""
        }
        let kept = DialogSetup(place: .cloud, findsPages: true)
        #expect(note(kept).contains("맥의 브라우저가 연 페이지의 글은 Claude로 가지 않아요."))
        let read = DialogSetup(place: .cloud, findsPages: true, pagesReadByCloud: true)
        #expect(note(read).contains("맥의 브라우저가 연 공개 페이지의 글은 Claude가 읽어요."))
        #expect(!note(read).contains("Claude로 가지 않아요"))
        #expect(read.stored == "v2 cloud find reads")
        #expect(DialogSetup(stored: read.stored) == read)
        // 찾는 작업이 없으면 읽을 페이지도 없다
        #expect(DialogSetup(place: .cloud, pagesReadByCloud: true) == DialogSetup(place: .cloud))
        let mac = MockAgentClient(v2: true, dialogCloud: MockDialogCloud(findsPages: true, pagesReadByCloud: true))
        #expect(await DialogSetup(agent: mac).pagesReadByCloud)
        #expect(await DialogSetup(agent: MockAgentClient(v2: true, dialogCloud: MockDialogCloud(findsPages: true))).pagesReadByCloud == false)
    }

    // MARK: - 실제 날씨를 받을 때

    /// 지금 위치는 소수 둘째 자리(약 1km)까지만 Apple로 보낸다
    @Test func theCurrentLocationIsCoarsened() {
        #expect(AppleWeatherService.coarse(37.56789) == 37.57)
        #expect(AppleWeatherService.coarse(-122.41941) == -122.42)
        #expect(AppleWeatherService.coarse(0.004) == 0)
    }

    @Test func conditionsAreSaidInKorean() {
        #expect(AppleWeatherService.text(for: .clear) == "맑음")
        #expect(AppleWeatherService.text(for: .rain) == "비")
        #expect(AppleWeatherService.text(for: .mostlyCloudy) == "구름 많음")
        #expect(AppleWeatherService.text(for: .snow) == "눈")
    }

    // MARK: - 카드의 글

    @Test func theCardSaysWhenItWasFetched() {
        #expect(WeatherCardView.stamp(noon, timeZone: seoul) == "11월 13일 오후 2:20")
        #expect(WeatherCardView.legalURL?.absoluteString == "https://weatherkit.apple.com/legal-attribution.html")
    }

    @Test func uvIndexIsNamed() {
        #expect([0, 2, 3, 5, 6, 7, 8, 10, 11].map(WeatherCardView.uvLabel) == ["낮음", "낮음", "보통", "보통", "높음", "높음", "매우 높음", "매우 높음", "위험"])
    }
}
