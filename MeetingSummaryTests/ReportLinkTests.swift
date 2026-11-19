import Foundation
import SwiftData
import Testing
import UIKit
@testable import MeetingSummary

// 찾은 페이지 카드 (`report.links`, D64): 받은 값 읽기와 거르기, 대표 그림 받기, 대화에서, 설명.
// 답을 쓴 곳 (`report.by`)과 네이버 검색으로 찾는 맥 (`web_find_naver`, D65).
// 물건·가게·가격·사이트는 모두 지어낸 것이다. 그림은 앱이 그린 것만 쓴다 (테스트는 밖으로 나가지 않는다).

private enum LinkFixture {
    /// `by`: `report.by`에 넣을 JSON 값 (없으면 그 이름을 넣지 않는다)
    static func task(links: String, by: String? = nil) -> String {
        """
        {"id":"t_find1","status":"completed","task":"소리콩 2 가격 찾아줘","title":"웹에서 찾기",\
        "created_at":"2026-11-13T09:30:00+00:00","updated_at":"2026-11-13T09:30:41+00:00","steps":[],\
        "result":{"outcome":"completed","summary":"가격을 찾았어요","approved_drafts":[],\
        "report":{"done":["가상몰에서 89,000원이에요."],"blocked":[],"sources":["https://shop.example.com/earbuds"],"links":\(links)\(by.map { ",\"by\":\($0)" } ?? "")}}}
        """
    }

    /// `report.by` 값을 넣어 읽은 보고
    static func report(by: String?) throws -> AgentReport {
        let page = #"[{"title":"가상몰","url":"https://shop.example.com/earbuds"}]"#
        return try #require(try AgentHTTPClient.decodeTask(data: Data(task(links: page, by: by).utf8), status: 200).report)
    }

    /// `report.links` 값을 넣어 읽은 결과
    static func decode(_ links: String) throws -> AgentTaskState {
        try AgentHTTPClient.decodeTask(data: Data(task(links: links).utf8), status: 200)
    }

    static func links(_ value: String) throws -> [AgentLink] {
        try decode(value).report?.links ?? []
    }

    static func link(_ title: String, _ url: String, image: String? = nil) -> AgentLink {
        AgentLink(title: title, url: URL(string: url)!, image: image.flatMap(URL.init(string:)))
    }
}

/// 받은 횟수를 세는 가짜 그림 서버
private actor FakeImages {
    private(set) var requests: [URL] = []
    var answer: Data?

    init(answer: Data?) {
        self.answer = answer
    }

    func get(_ url: URL) -> Data? {
        requests.append(url)
        return answer
    }

    func set(_ answer: Data?) {
        self.answer = answer
    }
}

@Suite("찾은 페이지: 받은 값 읽기")
struct ReportLinkDecodingTests {
    @Test func featureNamesMatchTheMac() {
        #expect(AgentFeature.webFind == "web_find")
        #expect(AgentFeature.reportLinks == "report_links")
        #expect(AgentFeature.webFindNaver == "web_find_naver")
        #expect(AgentLink.reportLimit == 5)
    }

    /// 답을 쓴 곳 (`report.by`): 맥이 적는 두 값만 받는다. 다른 값이나 글자가 아닌 값이면 없는 것으로 읽고, 보고는 그대로 읽는다
    @Test func theWriterOfTheAnswerIsReadOnlyWhenItIsAKnownValue() throws {
        #expect(try LinkFixture.report(by: #""claude""#).by == "claude")
        #expect(try LinkFixture.report(by: #""local""#).by == "local")
        #expect(AgentReport.writers == ["claude", "local"])
        for odd in [nil, #""mac""#, #""gpt""#, #""Claude""#, #""  ""#, "3", "true", "null", "{}", #"["claude"]"#] {
            let report = try LinkFixture.report(by: odd)
            #expect(report.by == nil, "받아들였다: \(odd ?? "없음")")
            #expect(report.done == ["가상몰에서 89,000원이에요."])
            #expect(report.links?.count == 1)
        }
    }

    /// 쓴 곳만 있고 답도 페이지도 없으면 보고가 아니다. 적어 둔 값은 다시 읽어도 같다
    @Test func theWriterAloneIsNotAReportAndSurvivesStoring() throws {
        #expect(AgentReport(by: "claude").isEmpty)
        let report = AgentReport(done: ["가상몰에서 89,000원이에요."], by: "claude")
        let stored = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(AgentReport.self, from: stored) == report)
        // 예전 앱이 적어 둔 보고에는 이 값이 없다
        let old = try JSONDecoder().decode(AgentReport.self, from: Data(#"{"done":["끝"],"blocked":[],"sources":[]}"#.utf8))
        #expect(old.by == nil && old.done == ["끝"])
    }

    @Test func linksAreReadFromTheReport() throws {
        let state = try LinkFixture.decode("""
        [{"title":"소리콩 2 무선 이어폰 - 가상몰","url":"https://shop.example.com/earbuds/sorikong-2","site":"shop.example.com",
          "image":"https://img.example.com/sorikong-2.jpg"},
         {"title":"소리콩 2 가격 비교","url":"https://www.price.example.org/compare?item=7","site":"price.example.org"}]
        """)
        #expect(state.report?.links == [
            LinkFixture.link("소리콩 2 무선 이어폰 - 가상몰", "https://shop.example.com/earbuds/sorikong-2", image: "https://img.example.com/sorikong-2.jpg"),
            LinkFixture.link("소리콩 2 가격 비교", "https://www.price.example.org/compare?item=7")
        ])
        #expect(state.report?.links?.map(\.host) == ["shop.example.com", "price.example.org"])
        // 답과 출처는 그대로 온다
        #expect(state.phase == .done)
        #expect(state.report?.done == ["가상몰에서 89,000원이에요."])
        #expect(state.report?.sources == ["https://shop.example.com/earbuds"])
    }

    /// 화면의 사이트 주소는 맥이 준 `site`가 아니라 실제로 열리는 주소에서 뽑는다
    @Test func theShownSiteComesFromTheAddressNotFromTheSiteValue() throws {
        let found = try LinkFixture.links(#"[{"title":"가상은행 로그인","url":"https://other.example.net/login","site":"bank.example.com"}]"#)
        #expect(found.map(\.host) == ["other.example.net"])
    }

    /// 키가 없는 보고(지금까지의 서버)는 지금처럼
    @Test func aReportWithoutLinksChangesNothing() throws {
        let json = LinkFixture.task(links: "[]").replacingOccurrences(of: #","links":[]"#, with: "")
        #expect(!json.contains("links"))
        let state = try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
        #expect(state.report?.links == nil)
        #expect(state.report?.done == ["가상몰에서 89,000원이에요."])
        #expect(try LinkFixture.decode("[]").report?.links == nil)
    }

    /// 링크만 있는 보고도 버리지 않는다
    @Test func linksAloneKeepTheReport() {
        #expect(AgentReport().isEmpty)
        #expect(!AgentReport(links: [LinkFixture.link("가상몰", "https://shop.example.com/")]).isEmpty)
    }

    /// 열 만한 주소가 아니면 그리지 않는다. 답은 그대로 보여 준다
    @Test(arguments: [
        "http://shop.example.com/earbuds",          // https가 아님
        "https://192.168.0.10/admin",               // 숫자 주소
        "https://[fe80::1]/",                       // 숫자 주소 (IPv6)
        "https://mac-mini.tailnet-name.ts.net/v1",  // 테일넷
        "https://printer.local/",                   // 내부 이름
        "https://intranet/",                        // 점이 없는 이름
        "https://wiki.corp.internal/page",          // 내부 이름
        "https://user:secret@shop.example.com/",    // 아이디·비밀번호가 든 주소
        "https://user@shop.example.com/",
        "https://shop.example.com.123/",            // 숫자로 끝나는 이름
        "https://shop.test/earbuds",                // 시험용 이름
        "javascript:alert(1)", "file:///etc/hosts", "shop.example.com", ""
    ])
    func addressesThatShouldNotBeOpenedAreDropped(_ url: String) throws {
        #expect(AgentLink.publicURL(url) == nil)
        #expect(AgentLink.page(title: "가상몰", url: url, image: nil) == nil)
        let state = try LinkFixture.decode(#"[{"title":"가상몰","url":"\#(url)"}]"#)
        #expect(state.report?.links == nil)
        #expect(state.report?.done == ["가상몰에서 89,000원이에요."])
    }

    @Test func tooLongAnAddressIsDropped() {
        let base = "https://shop.example.com/"
        let fits = base + String(repeating: "a", count: 500 - base.count)
        #expect(AgentLink.publicURL(fits) != nil)
        #expect(AgentLink.publicURL(fits + "a") == nil)
        #expect(AgentLink.publicURL(nil) == nil)
    }

    /// 한글 도메인(퓨니코드)과 포트가 붙은 공개 주소는 연다
    @Test func publicAddressesInOtherShapesAreKept() {
        #expect(AgentLink.page(title: "가상", url: "https://xn--9n2bp8q.xn--3e0b707e/", image: nil)?.host == "xn--9n2bp8q.xn--3e0b707e")
        #expect(AgentLink.publicURL("https://shop.example.com:8443/earbuds") != nil)
        #expect(AgentLink.page(title: "가상", url: "https://WWW.Example.COM/Path", image: nil)?.host == "example.com")
    }

    /// 그림 주소가 맞지 않으면 그림만 버리고 링크는 그린다
    @Test(arguments: [
        "http://img.example.com/a.jpg", "https://10.0.0.7/a.jpg", "https://img.local/a.jpg", "https://u:p@img.example.com/a.jpg",
        "data:image/png;base64,AAAA", "//img.example.com/a.jpg", "/og/a.jpg", ""
    ])
    func aBadImageAddressOnlyDropsTheImage(_ image: String) throws {
        let found = try LinkFixture.links(#"[{"title":"가상몰","url":"https://shop.example.com/earbuds","image":"\#(image)"}]"#)
        #expect(found == [LinkFixture.link("가상몰", "https://shop.example.com/earbuds")])
    }

    @Test func anImageValueOfTheWrongShapeIsIgnored() throws {
        let found = try LinkFixture.links("""
        [{"title":"하나","url":"https://shop.example.com/a","image":7}, {"title":"둘","url":"https://shop.example.com/b","image":null},
         {"title":"셋","url":"https://shop.example.com/c","image":["https://img.example.com/c.jpg"]}]
        """)
        #expect(found.map(\.title) == ["하나", "둘", "셋"])
        #expect(found.allSatisfy { $0.image == nil })
    }

    /// 꼴이 다른 요소는 그것만 버리고 나머지는 그린다
    @Test func oddElementsAreSkippedOneByOne() throws {
        let found = try LinkFixture.links("""
        ["https://shop.example.com/a", 7, null, {"title":"주소 없음"}, {"title":"숫자 주소","url":42},
         {"title":"가상몰","url":"https://shop.example.com/earbuds"}, {"url":"http://shop.example.com/plain"}]
        """)
        #expect(found == [LinkFixture.link("가상몰", "https://shop.example.com/earbuds")])
    }

    /// `links`가 배열이 아니어도 보고는 그대로 읽는다
    @Test(arguments: [#""https://shop.example.com/""#, "7", "null", "{}", "true"])
    func aValueOfTheWrongShapeIsReadAsNoLinks(_ value: String) throws {
        let state = try LinkFixture.decode(value)
        #expect(state.report?.links == nil)
        #expect(state.report?.done == ["가상몰에서 89,000원이에요."])
    }

    /// 제목: 앞뒤 빈칸과 줄바꿈을 정리하고 80자에서 자른다. 없으면 사이트 주소를 쓴다
    @Test func theTitleIsTidiedAndFallsBackToTheSite() throws {
        let found = try LinkFixture.links("""
        [{"title":"  소리콩 2\\n가격  ","url":"https://shop.example.com/a"}, {"url":"https://www.price.example.org/b"},
         {"title":"   ","url":"https://news.example.net/c"}, {"title":7,"url":"https://blog.example.co.kr/d"},
         {"title":"\(String(repeating: "가", count: 120))","url":"https://long.example.com/e"}]
        """)
        #expect(found.map(\.title) == [
            "소리콩 2 가격", "price.example.org", "news.example.net", "blog.example.co.kr", String(repeating: "가", count: 80)
        ])
    }

    /// 같은 주소는 한 번만, 많이 와도 다섯 개까지만 그린다
    @Test func repeatedAddressesAreMergedAndTheListIsCapped() throws {
        let same = try LinkFixture.links("""
        [{"title":"하나","url":"https://shop.example.com/a"}, {"title":"하나 다시","url":"https://shop.example.com/a"},
         {"title":"둘","url":"https://shop.example.com/b"}]
        """)
        #expect(same.map(\.title) == ["하나", "둘"])

        let many = (1...9).map { #"{"title":"쪽 \#($0)","url":"https://shop.example.com/p\#($0)"}"# }.joined(separator: ",")
        #expect(try LinkFixture.links("[\(many)]").map(\.title) == ["쪽 1", "쪽 2", "쪽 3", "쪽 4", "쪽 5"])
        // 걸러진 것은 다섯 개에 들지 않는다
        let mixed = #"{"title":"안 됨","url":"http://shop.example.com/x"},"# + many
        #expect(try LinkFixture.links("[\(mixed)]").count == 5)
    }

    /// 예전에 저장한 링크(그림 주소가 없던 때)와 보고도 그대로 읽힌다
    @Test func olderStoredValuesStillDecode() throws {
        let link = try JSONDecoder().decode(AgentLink.self, from: Data(#"{"title":"shop.example.com","url":"https://shop.example.com/"}"#.utf8))
        #expect(link == LinkFixture.link("shop.example.com", "https://shop.example.com/"))
        let report = try JSONDecoder().decode(AgentReport.self, from: Data(#"{"done":["읽었어요."],"blocked":[],"sources":[]}"#.utf8))
        #expect(report.links == nil)
    }
}

@MainActor
@Suite("찾은 페이지: 대표 그림 받기")
struct LinkThumbnailTests {
    private let url = URL(string: "https://img.example.com/a.jpg")!

    private func picture() async -> Data {
        await MockFind.thumbnail(MockFind.links[0].image!)!
    }

    private func store(_ images: FakeImages) -> LinkThumbnailStore {
        LinkThumbnailStore { await images.get($0) }
    }

    @Test func aPictureIsFetchedOnceAndKeptSmall() async {
        let images = FakeImages(answer: await picture())
        let store = store(images)
        let first = await store.image(for: url)
        let again = await store.image(for: url)
        #expect(first != nil && again != nil)
        #expect(await images.requests == [url])
        #expect(store.heldCount == 1)
        let side = max(first?.size.width ?? 0, first?.size.height ?? 0) * (first?.scale ?? 1)
        #expect(side > 0 && side <= CGFloat(LinkThumbnailStore.maxPixel))
    }

    /// 받지 못했거나 그림이 아니면 그림 없이 그린다. 버릴 때까지 같은 주소를 다시 묻지 않는다
    @Test func whatIsNotAPictureIsNotAskedAgain() async {
        for answer in [nil, Data("<html>없는 그림</html>".utf8), Data()] {
            let images = FakeImages(answer: answer)
            let store = store(images)
            #expect(await store.image(for: url) == nil)
            #expect(await store.image(for: url) == nil)
            #expect(await images.requests.count == 1)
            #expect(store.heldCount == 0)
        }
    }

    /// 앱이 뒤로 가면 모두 버린다. 돌아오면 다시 받는다 (못 받았던 것도 다시 묻는다)
    @Test func clearingDropsEverythingAndAllowsAnotherTry() async {
        let images = FakeImages(answer: nil)
        let store = store(images)
        #expect(await store.image(for: url) == nil)
        let before = store.generation
        store.clear()
        #expect(store.generation == before + 1)
        await images.set(await picture())
        #expect(await store.image(for: url) != nil)
        #expect(store.heldCount == 1)
        store.clear()
        #expect(store.heldCount == 0)
        #expect(await images.requests.count == 2)
    }

    @Test func onlyAFewPicturesAreHeld() async {
        let images = FakeImages(answer: await picture())
        let store = store(images)
        for index in 0..<(LinkThumbnailStore.limit + 6) {
            _ = await store.image(for: URL(string: "https://img.example.com/\(index).jpg")!)
        }
        #expect(store.heldCount == LinkThumbnailStore.limit)
    }

    @Test func aThumbnailIsMadeOnlyFromAPicture() async {
        #expect(LinkThumbnailStore.thumbnail(from: await picture()) != nil)
        #expect(LinkThumbnailStore.thumbnail(from: Data("%PDF-1.7".utf8)) == nil)
        #expect(LinkThumbnailStore.thumbnail(from: Data()) == nil)
    }

    // MARK: - 실제로 받는 연결의 규칙 (연결하지 않고 확인한다)

    private func response(_ status: Int, type: String?, length: Int? = nil) -> URLResponse {
        var headers: [String: String] = [:]
        if let type { headers["Content-Type"] = type }
        if let length { headers["Content-Length"] = String(length) }
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test func onlySmallSuccessfulPicturesAreAccepted() {
        #expect(LinkThumbnailLoader.accepts(response(200, type: "image/jpeg", length: 40_000)))
        #expect(LinkThumbnailLoader.accepts(response(200, type: "IMAGE/WebP")))
        #expect(!LinkThumbnailLoader.accepts(response(200, type: "text/html", length: 40_000)))
        #expect(!LinkThumbnailLoader.accepts(response(200, type: nil)))
        #expect(!LinkThumbnailLoader.accepts(response(404, type: "image/png")))
        #expect(!LinkThumbnailLoader.accepts(response(302, type: "image/png")))
        #expect(!LinkThumbnailLoader.accepts(response(200, type: "image/png", length: LinkThumbnailLoader.maxBytes + 1)))
        #expect(!LinkThumbnailLoader.accepts(URLResponse(url: url, mimeType: "image/png", expectedContentLength: 10, textEncodingName: nil)))
    }

    /// 다른 곳으로 넘기는 응답은 공개 https 주소일 때만 따라간다
    @Test func redirectsAreFollowedOnlyToPublicAddresses() {
        #expect(LinkThumbnailLoader.follows(URL(string: "https://cdn.example.net/a.jpg")))
        #expect(!LinkThumbnailLoader.follows(URL(string: "http://cdn.example.net/a.jpg")))
        #expect(!LinkThumbnailLoader.follows(URL(string: "https://192.168.0.1/a.jpg")))
        #expect(!LinkThumbnailLoader.follows(URL(string: "https://nas.local/a.jpg")))
        #expect(!LinkThumbnailLoader.follows(URL(string: "https://mac.tailnet-name.ts.net/a.jpg")))
        #expect(!LinkThumbnailLoader.follows(nil))
    }

    /// 열 만하지 않은 주소는 연결하지 않고 끝낸다 (가짜 맥의 `.example` 주소도 밖으로 나가지 않는다)
    @Test func theLoaderRefusesAddressesItShouldNotOpen() async {
        #expect(await LinkThumbnailLoader.fetch(URL(string: "https://img.shop.example/sorikong-2.jpg")!) == nil)
        #expect(await LinkThumbnailLoader.fetch(URL(string: "http://img.example.com/a.jpg")!) == nil)
        #expect(await LinkThumbnailLoader.fetch(URL(string: "https://127.0.0.1/a.jpg")!) == nil)
    }
}

@MainActor
@Suite("찾은 페이지: 대화에서, 설명")
struct ReportLinkFlowTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func session(_ agent: MockAgentClient) -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        session.attach(context)
        return session
    }

    @Test func aFindTaskEndsWithTheAnswerAndThePagesItRead() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: MockDialogCloud(demo: "find"))
        let session = session(agent)
        await session.send("소리콩 2 가격 찾아줘", meetings: [])

        // 승인 없이 끝나고, 답과 읽은 페이지가 붙는다
        let state = try #require(session.messages.last?.agent)
        #expect(state.phase == .done)
        #expect(state.report?.done == MockFind.answer)
        #expect(state.report?.links == MockFind.links)
        #expect(state.report?.attachments == nil)
        // 실제 맥처럼: 제목은 늘 같고, 답은 줄바꿈이 있는 글 한 덩어리이고, 웹 검색으로 찾은 답은 Claude가 쓴 것이다
        #expect(state.title == "웹에서 찾기")
        #expect(MockFind.answer.count == 1 && MockFind.answer[0].contains("\n") && !MockFind.answer[0].contains("http"))
        #expect(state.report?.by == ReplyWriter.claude.rawValue)

        // 그림은 카드가 그려질 때 받는다. 가짜 맥의 그림은 앱이 그린 것이다 (밖으로 나가지 않는다)
        #expect(session.thumbnails.heldCount == 0)
        #expect(await session.thumbnails.image(for: try #require(MockFind.links[0].image)) != nil)
        #expect(session.thumbnails.heldCount == 1)

        // 대화 기록에는 제목·주소·그림 주소만 남는다. 다시 열어도 카드가 보인다
        try context.save()
        let records = try context.fetch(FetchDescriptor<ChatRecord>())
        let stored = try #require(records.first { $0.roleRaw == "agent" }?.agentData)
        #expect(try JSONDecoder().decode(AgentTaskState.self, from: stored).report?.links == MockFind.links)
        #expect(try JSONDecoder().decode(AgentTaskState.self, from: stored).report?.by == "claude")
        #expect(stored.count < 4000)

        let reopened = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        reopened.attach(context)
        if reopened.messages.isEmpty, let conversation = session.conversation { reopened.open(conversation) }
        #expect(reopened.messages.last?.agent?.report?.links == MockFind.links)
        #expect(reopened.messages.last?.agent?.report?.by == "claude")

        // 새 대화를 시작하면 받은 그림을 버린다
        session.reset()
        #expect(session.thumbnails.heldCount == 0)
    }

    /// 네이버 검색으로 찾는 맥: 검색은 페이지만 찾아 주므로 답은 맥의 로컬 모델이 쓴다
    @Test func aMacThatFindsWithNaverSaysTheLocalModelWroteTheAnswer() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: MockDialogCloud(demo: "naver"))
        #expect(await agent.supports(AgentFeature.webFind))
        #expect(await agent.supports(AgentFeature.webFindNaver))
        #expect(await MockAgentClient(v2: true, dialogCloud: MockDialogCloud(demo: "find")).supports(AgentFeature.webFindNaver) == false)
        // 찾는 작업이 없으면 어디서 찾는지도 알리지 않는다
        #expect(await MockAgentClient(v2: true, dialogCloud: MockDialogCloud(findsWithNaver: true)).supports(AgentFeature.webFindNaver) == false)

        let session = session(agent)
        await session.send("소리콩 2 가격 찾아줘", meetings: [])
        let state = try #require(session.messages.last?.agent)
        #expect(state.phase == .done)
        #expect(state.report?.by == ReplyWriter.local.rawValue)
        #expect(state.report?.links == MockFind.links)
    }

    @Test func theMockFindsPagesOnlyWhenTurnedOn() async throws {
        let plain = MockAgentClient(v2: true, dialogCloud: MockDialogCloud(demo: "by"))
        #expect(await plain.supports(AgentFeature.webFind) == false)
        #expect(await plain.supports(AgentFeature.reportLinks) == false)

        let finding = MockAgentClient(v2: true, dialogCloud: MockDialogCloud(demo: "find"))
        #expect(await finding.supports(AgentFeature.webFind))
        #expect(await finding.supports(AgentFeature.reportLinks))
        #expect(await finding.supports(AgentFeature.replyBy))
        let reply = try await finding.message("소리콩 2 가격 찾아줘", conversationID: nil, context: nil)
        guard case .task = reply.action else {
            Issue.record("작업이 되지 않았다")
            return
        }
        #expect(reply.replies == ["네, 찾아볼게요."])
        // 값만 묻는 말은 지금처럼 말풍선으로 답한다
        let weather = try await finding.message("오늘 서울 날씨 어때?", conversationID: nil, context: nil)
        #expect(weather.replies.count == 3)
        #expect(weather.action == .none)
        // 가짜 페이지는 실제로 없는 주소다
        #expect(MockFind.links.allSatisfy { $0.url.host()?.hasSuffix(".example") == true })
        #expect(MockFind.links.compactMap(\.image).allSatisfy { $0.host()?.hasSuffix(".example") == true })
    }

    @Test func theSetupRemembersWhatTheMacDoes() async {
        let setup = await DialogSetup(agent: MockAgentClient(v2: true, dialogCloud: MockDialogCloud(demo: "find")))
        #expect(setup == DialogSetup(place: .cloud, sendsContext: true, webLookup: true, marksWriter: true, findsPages: true, showsLinks: true))
        #expect(setup.stored == "v2 cloud context web by find links")
        #expect(DialogSetup(stored: setup.stored) == setup)
        for other in [
            DialogSetup(place: .cloud, findsPages: true), DialogSetup(place: .cloud, sendsContext: true, webLookup: true, showsLinks: true)
        ] {
            #expect(DialogSetup(stored: other.stored) == other)
        }
        // 찾지 않는 맥, 예전 앱이 적어 둔 값
        let plain = await DialogSetup(agent: MockAgentClient(v2: true, dialogCloud: MockDialogCloud(demo: "by")))
        #expect(!plain.findsPages && !plain.showsLinks)
        #expect(DialogSetup(stored: "v2 cloud context web by") == plain)
        // 로컬 판단이면 나머지 이름을 보지 않는다
        #expect(DialogSetup(place: .local, findsPages: true, showsLinks: true) == .local)

        // 네이버 검색으로 찾는 맥 (D65): 낱말 하나가 더 붙는다. 찾는 작업이 없으면 그 값도 없다
        let naver = await DialogSetup(agent: MockAgentClient(v2: true, dialogCloud: MockDialogCloud(demo: "naver")))
        #expect(naver.findsPages && naver.findsWithNaver)
        #expect(!setup.findsWithNaver)
        #expect(naver.stored == "v2 cloud context web by find links naver")
        #expect(DialogSetup(stored: naver.stored) == naver)
        #expect(DialogSetup(place: .cloud, findsWithNaver: true) == DialogSetup(place: .cloud))
        #expect(DialogSetup(stored: "v2 cloud naver") == DialogSetup(place: .cloud))
        #expect(DialogSetup(place: .local, findsPages: true, findsWithNaver: true) == .local)
    }

    /// 맥이 알릴 때만 쓴다: 무엇이 검색으로 가는지, 페이지의 글은 가지 않는 것, 그림과 링크는 아이폰이 직접 받는 것
    @Test func theTextSaysWhatGoesWhereOnlyWhenTheMacDoesIt() {
        func text(_ setup: DialogSetup) -> String {
            MacAgentFacts(setup: setup).rows.map { $0.text + ($0.note ?? "") }.joined()
        }
        let plain = text(DialogSetup(place: .cloud, sendsContext: true, webLookup: true, marksWriter: true))
        let finding = text(DialogSetup(place: .cloud, sendsContext: true, webLookup: true, marksWriter: true, findsPages: true))
        let linked = text(DialogSetup(place: .cloud, sendsContext: true, webLookup: true, marksWriter: true, findsPages: true, showsLinks: true))

        #expect(!plain.contains("찾아 달라고") && !plain.contains("카드"))
        for sentence in [
            "검색으로 답을 찾고 맥의 브라우저가 공개 페이지를 직접 열어 봐요",
            "검색할 물음 한 문장이 Anthropic의 웹 검색으로 가고, 그 검색 결과로 Claude가 답을 써요",
            "맥의 브라우저는 그 답에 나온 페이지를 열어 제목과 대표 그림의 주소를 가져와요",
            "찾아 달라는 작업의 답 말고는 모두 맥에서 만들어요",
            "맥의 브라우저가 연 페이지의 글은 Claude로 가지 않아요",
            "이 브라우저는 로그인 없이 뜨고",
            "대화 기록에 남아서 다음 말을 판단할 때 Claude가 다시 봐요"
        ] {
            #expect(finding.contains(sentence), "빠졌다: \(sentence)")
        }
        #expect(!finding.contains("카드"))
        // 답 아래의 'Claude 사용' 표시는 보이지 않게 했다 (D107)
        #expect(!finding.contains("'Claude 사용'"))
        // 빌드 37까지의 틀린 말: 웹 검색으로 찾을 때 답을 쓰는 것은 맥의 로컬 모델이 아니다 (D65)
        #expect(!finding.contains("로컬 모델이 답을 써요") && !finding.contains("로컬 모델이 읽어서") && !finding.contains("네이버 검색"))
        // 찾지 않는 맥에서는 보고가 모두 맥에서 만들어진다
        #expect(plain.contains("맡긴 일의 보고·초안·질문은 모두 맥에서 만들어요"))

        // 네이버 검색으로 찾는 맥: 물음은 네이버로 가고, 연 페이지는 맥의 로컬 모델이 읽는다. 나머지 약속은 같다
        let naver = text(DialogSetup(
            place: .cloud, sendsContext: true, webLookup: true, marksWriter: true, findsPages: true, showsLinks: true, findsWithNaver: true
        ))
        for sentence in [
            "검색할 물음 한 문장이 네이버 검색으로 가요",
            "맥의 브라우저가 그렇게 찾은 페이지를 열고, 맥의 로컬 모델이 읽어서 답을 써요",
            "맥의 브라우저가 연 페이지의 글은 Claude로 가지 않아요",
            "대화 기록에 남아서 다음 말을 판단할 때 Claude가 다시 봐요",
            "링크는 눌렀을 때만 열어요"
        ] {
            #expect(naver.contains(sentence), "빠졌다: \(sentence)")
        }
        #expect(!naver.contains("그 검색 결과로 Claude가 답을 써요"))
        for sentence in ["링크는 눌렀을 때만 열어요", "이 아이폰이 그 사이트에서 직접 받아 오고(쿠키 없이), 저장하지 않아요", "이 아이폰이 그 사이트에 직접 접속해요"] {
            #expect(linked.contains(sentence), "빠졌다: \(sentence)")
        }
        #expect(!text(.local).contains("찾아 달라고"))
        // 줄의 이름은 겹치지 않는다 (화면이 줄을 이름으로 구분한다)
        let rows = MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true, webLookup: true, marksWriter: true, findsPages: true, showsLinks: true)).rows
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}
