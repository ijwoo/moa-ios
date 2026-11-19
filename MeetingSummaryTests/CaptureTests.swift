import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 보고에 붙은 화면 캡처 (D56): 받은 값 읽기, 그림 받기, 가려 두기, 메모리에만 두기.
// 사이트·가게·금액은 모두 지어낸 것이다. 그림은 앱이 그린 가상 화면만 쓴다.

private enum CaptureFixture {
    static func task(status: String = "completed", attachments: String) -> String {
        """
        {"id":"t_read1","status":"\(status)","task":"결제내역 알려줘","title":"결제내역 확인",\
        "created_at":"2026-11-12T12:30:00+00:00","updated_at":"2026-11-12T12:30:28+00:00","steps":[],\
        "result":{"outcome":"\(status)","summary":"결제내역을 읽었어요","approved_drafts":[],\
        "report":{"done":["최근 결제 3건이에요."],"blocked":[],"sources":["https://pay.shop.test/history"],"attachments":\(attachments)}}}
        """
    }

    static let one = """
    {"id":"a1","type":"screenshot","mime":"image/jpeg","width":1280,"height":720,"bytes":62280,"page_host":"pay.shop.test",\
    "caption":"가상페이 결제내역 화면","sensitive":true,"expires_at":"2026-11-13T12:30:00+00:00","path":"/v1/tasks/t_read1/attachments/a1"}
    """

    static func decode(_ attachments: String, status: String = "completed") throws -> AgentTaskState {
        try AgentHTTPClient.decodeTask(data: Data(task(status: status, attachments: attachments).utf8), status: 200)
    }

    static func attachment(_ id: String = "a1", sensitive: Bool = true, expiresAt: String? = nil) -> AgentAttachment {
        AgentAttachment(id: id, width: 1280, height: 720, pageHost: "pay.shop.test", caption: "가상페이 결제내역 화면", isSensitive: sensitive, expiresAt: expiresAt)
    }
}

@Suite("보고의 화면 캡처: 받은 값 읽기")
struct CaptureDecodingTests {
    @Test func attachmentIsReadFromTheReport() throws {
        let state = try CaptureFixture.decode("[\(CaptureFixture.one)]")
        let attachment = try #require(state.report?.attachments?.first)
        #expect(state.report?.attachments?.count == 1)
        #expect(attachment.id == "a1")
        #expect(attachment.width == 1280 && attachment.height == 720)
        #expect(attachment.pageHost == "pay.shop.test")
        #expect(attachment.caption == "가상페이 결제내역 화면")
        #expect(attachment.isSensitive)
        #expect(attachment.label == "가상페이 결제내역 화면 · pay.shop.test")
        // 바로 아래 "열기" 줄에 같은 사이트가 보이면 주소를 되풀이하지 않는다 (D83). 다른 사이트의 줄은 상관없다
        #expect(attachment.label(besides: ["pay.shop.test"]) == "가상페이 결제내역 화면")
        #expect(attachment.label(besides: ["shop.test"]) == "가상페이 결제내역 화면 · pay.shop.test")
        var www = attachment
        www.pageHost = "WWW.Pay.Shop.test"
        #expect(www.label(besides: ["pay.shop.test"]) == "가상페이 결제내역 화면")
        #expect(www.label(besides: []) == "가상페이 결제내역 화면 · WWW.Pay.Shop.test")
        // 설명이 없는 캡처는 주소를 빼면 빈 글이 된다 (화면은 "화면 캡처"라고 쓴다)
        www.caption = nil
        #expect(www.label(besides: ["pay.shop.test"]).isEmpty)
        #expect(AgentLink.site("www.Shop.example.org") == "shop.example.org")
        // 답은 그대로 온다
        #expect(state.phase == .done)
        #expect(state.report?.done == ["최근 결제 3건이에요."])
    }

    @Test func missingSensitiveMeansHidden() throws {
        // 맥이 "공개 화면"이라고 분명히 말한 것만 바로 보여 준다
        let hidden = try CaptureFixture.decode(#"[{"id":"a1","type":"screenshot","mime":"image/jpeg","width":1280,"height":720}]"#)
        #expect(hidden.report?.attachments?.first?.isSensitive == true)
        let odd = try CaptureFixture.decode(#"[{"id":"a1","type":"screenshot","mime":"image/jpeg","sensitive":null}]"#)
        #expect(odd.report?.attachments?.first?.isSensitive == true)
        let open = try CaptureFixture.decode(#"[{"id":"a1","type":"screenshot","mime":"image/jpeg","sensitive":false}]"#)
        #expect(open.report?.attachments?.first?.isSensitive == false)
    }

    @Test func unknownOrUnsafeItemsAreSkippedWithoutLosingTheReport() throws {
        let state = try CaptureFixture.decode("""
        [{"id":"v1","type":"audio","mime":"audio/mpeg"},\
        {"id":"../../secrets","type":"screenshot","mime":"image/jpeg"},\
        {"id":"a2","type":"screenshot","mime":"image/svg+xml"},\
        {"id":"a3","type":"screenshot"},\
        "not an object", 7, null,\
        {"id":"a4","type":"screenshot","mime":"image/jpeg","width":"wide"},\
        \(CaptureFixture.one),\
        {"id":"a1","type":"screenshot","mime":"image/png"},\
        {"id":"a5","type":"screenshot","mime":"IMAGE/PNG"}]
        """)
        // 모르는 종류, 주소에 넣을 수 없는 번호, 받지 않는 형식, 모양이 틀린 것, 같은 번호는 빼고 나머지만 남는다
        #expect(state.report?.attachments?.map(\.id) == ["a1", "a5"])
        #expect(state.report?.done == ["최근 결제 3건이에요."])
    }

    @Test func brokenAttachmentsNeverBreakTheTask() throws {
        for broken in [#""none""#, "7", "null", "{}", "[]"] {
            let state = try CaptureFixture.decode(broken)
            #expect(state.phase == .done)
            #expect(state.report?.attachments == nil)
            #expect(state.report?.done == ["최근 결제 3건이에요."])
        }
    }

    @Test func captionAndHostAreCleaned() throws {
        let long = String(repeating: "가", count: 200)
        let state = try CaptureFixture.decode("""
        [{"id":"a1","type":"screenshot","mime":"image/jpeg","caption":"  \(long)  ","page_host":"https://pay.shop.test/history?id=1"},\
        {"id":"a2","type":"screenshot","mime":"image/jpeg","caption":"   ","page_host":"pay.shop.test"}]
        """)
        let attachments = try #require(state.report?.attachments)
        // 설명은 60자까지, 사이트 이름은 호스트 꼴일 때만 (주소가 통째로 오면 버린다)
        #expect(attachments[0].caption?.count == AgentAttachment.maxCaption)
        #expect(attachments[0].pageHost == nil)
        #expect(attachments[1].caption == nil)
        #expect(attachments[1].label == "pay.shop.test")
    }

    @Test func onlyAFewAreKept() throws {
        let many = (1...9).map { #"{"id":"a\#($0)","type":"screenshot","mime":"image/jpeg"}"# }.joined(separator: ",")
        let state = try CaptureFixture.decode("[\(many)]")
        #expect(state.report?.attachments?.map(\.id) == ["a1", "a2", "a3", "a4"])
    }

    @Test func failedTaskKeepsItsCapture() throws {
        // 멈춘 화면의 캡처는 실패한 작업의 보고에 붙어 온다
        let state = try CaptureFixture.decode("[\(CaptureFixture.one)]", status: "failed")
        #expect(state.phase == .failed)
        #expect(state.report?.attachments?.count == 1)
    }

    @Test func recordsSavedBeforeCapturesStillOpen() throws {
        // 캡처가 생기기 전에 저장한 대화 기록(attachments 없음)도 그대로 읽힌다
        let old = #"{"done":["초안을 임시 저장했어요"],"blocked":[],"sources":["http://mail.test/compose"]}"#
        let report = try JSONDecoder().decode(AgentReport.self, from: Data(old.utf8))
        #expect(report.attachments == nil)
        #expect(!report.isEmpty)

        // 저장했다 다시 읽어도 같은 값이다. 저장되는 것은 그림이 아니라 그림을 받는 데 필요한 값뿐이다
        let state = try CaptureFixture.decode("[\(CaptureFixture.one)]")
        let stored = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(AgentTaskState.self, from: stored) == state)
        #expect(stored.count < 4000)
    }

    @Test func expiryAndImageChecks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let before = now.addingTimeInterval(-60).formatted(.iso8601)
        let after = now.addingTimeInterval(60).formatted(.iso8601)
        #expect(CaptureFixture.attachment(expiresAt: before).isExpired(at: now))
        #expect(!CaptureFixture.attachment(expiresAt: after).isExpired(at: now))
        // 시각을 모르면 지나지 않은 것으로 본다 (받아 보면 안다)
        #expect(!CaptureFixture.attachment(expiresAt: nil).isExpired(at: now))
        #expect(!CaptureFixture.attachment(expiresAt: "soon").isExpired(at: now))

        #expect(AgentAttachment.isImage(MockCaptures.pageImage(loginPage: false)))
        #expect(AgentAttachment.isImage(MockSites.receiptImage()))
        #expect(!AgentAttachment.isImage(Data(#"{"error":{"code":"attachment_gone","message":"캡처가 지워졌어요"}}"#.utf8)))
        #expect(!AgentAttachment.isImage(Data("<html><body>login</body></html>".utf8)))
        #expect(!AgentAttachment.isImage(Data([0xFF, 0xD8, 0xFF])))
        #expect(!AgentAttachment.isImage(Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: AgentAttachment.maxBytes))))
    }
}

/// 그림(바이트)을 돌려주는 가짜 서버
final class CaptureStubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let cachePolicy: URLRequest.CachePolicy
    }

    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var respond: @Sendable (String) -> (Int, Data) = { _ in (200, Data()) }
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path() ?? ""
        let (status, data) = Self.lock.withLock {
            Self.seen.append(Seen(
                method: request.httpMethod ?? "", path: path, headers: request.allHTTPHeaderFields ?? [:], cachePolicy: request.cachePolicy
            ))
            return Self.respond(path)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("보고의 화면 캡처: 그림 받기", .serialized)
struct CaptureRequestTests {
    private func client(_ respond: @escaping @Sendable (String) -> (Int, Data)) -> AgentHTTPClient {
        CaptureStubProtocol.lock.withLock {
            CaptureStubProtocol.seen = []
            CaptureStubProtocol.respond = respond
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureStubProtocol.self]
        return AgentHTTPClient(baseURL: URL(string: "http://mac.test:8765")!, token: "t", session: URLSession(configuration: configuration))
    }

    private var seen: [CaptureStubProtocol.Seen] {
        CaptureStubProtocol.lock.withLock { CaptureStubProtocol.seen }
    }

    @Test func imageIsFetchedByTaskAndAttachmentID() async throws {
        let image = MockCaptures.pageImage(loginPage: false)
        let client = client { _ in (200, image) }
        let data = try await client.attachment(taskID: "t_read1", id: "a1")
        #expect(data == image)
        // 주소는 앱이 번호로 직접 만든다 (서버가 준 path는 쓰지 않는다). 기기 캐시에 남기지 않는다
        let request = try #require(seen.last)
        #expect(request.method == "GET")
        #expect(request.path == "/v1/tasks/t_read1/attachments/a1")
        #expect(request.headers["X-App-Token"] == "t")
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test func unsafeIDsNeverReachTheServer() async {
        let client = client { _ in (200, MockCaptures.pageImage(loginPage: false)) }
        for (task, id) in [("t_read1", "../../v1/sites"), ("../x", "a1"), ("t_read1", ""), ("t read", "a1"), ("t_read1", "a1?x=1")] {
            await #expect(throws: AgentError.invalidResponse) { try await client.attachment(taskID: task, id: id) }
        }
        #expect(seen.isEmpty)
    }

    @Test func goneAndLostAreToldApart() async {
        let gone = client { _ in (404, Data(#"{"error":{"code":"attachment_gone","message":"캡처가 지워졌어요"}}"#.utf8)) }
        await #expect(throws: AgentError.attachmentGone) { try await gone.attachment(taskID: "t_read1", id: "a1") }
        let lost = client { _ in (404, Data(#"{"error":{"code":"task_not_found","message":"작업을 찾을 수 없어요"}}"#.utf8)) }
        await #expect(throws: AgentError.taskLost) { try await lost.attachment(taskID: "t_read1", id: "a1") }
        let denied = client { _ in (401, Data(#"{"error":{"code":"unauthorized","message":"토큰이 맞지 않아요"}}"#.utf8)) }
        await #expect(throws: AgentError.unauthorized) { try await denied.attachment(taskID: "t_read1", id: "a1") }
    }

    @Test func somethingThatIsNotAnImageIsRejected() async {
        // 200으로 왔어도 그림이 아니면 받지 않는다
        let page = client { _ in (200, Data("<html><body>login</body></html>".utf8)) }
        await #expect(throws: AgentError.invalidResponse) { try await page.attachment(taskID: "t_read1", id: "a1") }
        let empty = client { _ in (200, Data()) }
        await #expect(throws: AgentError.invalidResponse) { try await empty.attachment(taskID: "t_read1", id: "a1") }
    }
}

/// 정해 둔 대로 그림을 주거나 실패하는 가짜 맥 (요청 횟수를 센다)
private actor CaptureAgent: AgentProviding {
    enum Mode { case image, gone, lost, down }
    var mode: Mode
    private(set) var requests: [String] = []

    init(_ mode: Mode = .image) {
        self.mode = mode
    }

    func set(_ mode: Mode) {
        self.mode = mode
    }

    func attachment(taskID: String, id: String) async throws -> Data {
        requests.append("\(taskID)/\(id)")
        switch mode {
        case .image: return MockCaptures.pageImage(loginPage: false)
        case .gone: throw AgentError.attachmentGone
        case .lost: throw AgentError.taskLost
        case .down: throw AgentError.unreachable
        }
    }

    func isReachable() async -> Bool { true }
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply { throw AgentError.unreachable }
    func start(task: String, context: String?) async throws -> AgentTaskState { throw AgentError.unreachable }
    func state(of id: String) async throws -> AgentTaskState { throw AgentError.taskLost }
    func cancel(_ id: String) async throws -> AgentTaskState { throw AgentError.taskLost }
    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        throw AgentError.taskLost
    }
}

@MainActor
@Suite("보고의 화면 캡처: 가려 두기와 메모리")
struct CaptureStoreTests {
    @Test func captureIsShownUntilTheUserFoldsIt() async {
        let agent = CaptureAgent()
        let store = CaptureStore(agent: agent)
        let secret = CaptureFixture.attachment("a1")
        let open = CaptureFixture.attachment("a2", sensitive: false)

        // 로그인한 화면이든 공개 화면이든 바로 보여 준다 (D84)
        #expect(store.isShown("t1", secret))
        #expect(store.isShown("t1", open))

        guard case .image = await store.load("t1", secret) else {
            Issue.record("그림을 받지 못했다")
            return
        }
        #expect(store.heldCount == 1)

        // 가리면 들고 있던 그림도 버린다
        store.hide("t1", secret)
        #expect(!store.isShown("t1", secret))
        #expect(store.heldCount == 0)
        // 같은 번호라도 다른 작업의 캡처, 같은 작업의 다른 캡처는 그대로 보인다
        #expect(store.isShown("t2", secret))
        #expect(store.isShown("t1", open))

        // "보기"로 다시 편다
        store.reveal("t1", secret)
        #expect(store.isShown("t1", secret))
    }

    @Test func imageIsFetchedOnceAndForgottenOnClear() async {
        let agent = CaptureAgent()
        let store = CaptureStore(agent: agent)
        let secret = CaptureFixture.attachment("a1")
        let folded = CaptureFixture.attachment("a2")
        _ = await store.load("t1", secret)
        _ = await store.load("t1", secret)
        #expect(await agent.requests == ["t1/a1"])
        store.hide("t1", folded)

        // 앱이 뒤로 가거나 다른 대화로 가면: 그림을 버린다
        let before = store.generation
        store.clear()
        #expect(store.heldCount == 0)
        #expect(store.generation == before + 1)
        // 보이던 것은 돌아와도 보이고, 사용자가 가린 것은 저절로 다시 보이지 않는다 (D84)
        #expect(store.isShown("t1", secret))
        #expect(!store.isShown("t1", folded))

        // 다시 보면 다시 받는다
        _ = await store.load("t1", secret)
        #expect(await agent.requests.count == 2)
    }

    @Test func onlyAFewImagesAreHeld() async {
        let agent = CaptureAgent()
        let store = CaptureStore(agent: agent)
        for index in 1...6 {
            _ = await store.load("t\(index)", CaptureFixture.attachment("a1", sensitive: false))
        }
        #expect(store.heldCount == CaptureStore.limit)
        // 오래된 것부터 버렸다: 처음 것은 다시 받아야 하고, 마지막 것은 들고 있다
        _ = await store.load("t6", CaptureFixture.attachment("a1", sensitive: false))
        #expect(await agent.requests.count == 6)
        _ = await store.load("t1", CaptureFixture.attachment("a1", sensitive: false))
        #expect(await agent.requests.count == 7)
    }

    @Test func expiredCaptureIsNotRequested() async {
        let agent = CaptureAgent()
        let store = CaptureStore(agent: agent)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let attachment = CaptureFixture.attachment("a1", sensitive: false, expiresAt: now.addingTimeInterval(60).formatted(.iso8601))

        #expect(await store.load("t1", attachment, now: now) != .gone)
        #expect(store.heldCount == 1)
        // 맥이 지웠을 시각이 지나면 묻지 않고, 들고 있던 것도 버린다
        #expect(await store.load("t1", attachment, now: now.addingTimeInterval(120)) == .gone)
        #expect(store.heldCount == 0)
        #expect(await agent.requests.count == 1)
    }

    @Test func goneIsRememberedAndFailureCanBeRetried() async {
        let agent = CaptureAgent(.down)
        let store = CaptureStore(agent: agent)
        let attachment = CaptureFixture.attachment("a1", sensitive: false)

        // 지금 못 받은 것은 다시 받을 수 있다
        #expect(await store.load("t1", attachment) == .failed)
        await agent.set(.image)
        guard case .image = await store.load("t1", attachment) else {
            Issue.record("다시 받지 못했다")
            return
        }

        // 맥이 지운 것은 다시 묻지 않는다 (작업 기록이 사라진 것도 같다)
        await agent.set(.gone)
        #expect(await store.load("t2", attachment) == .gone)
        await agent.set(.lost)
        #expect(await store.load("t3", attachment) == .gone)
        let asked = await agent.requests.count
        await agent.set(.image)
        #expect(await store.load("t2", attachment) == .gone)
        #expect(await store.load("t3", attachment) == .gone)
        #expect(await agent.requests.count == asked)
    }

    /// 지워진 캡처와 번호가 같아도 지워질 시각이 다르면 다른 캡처다 (화면 확인용 가짜 맥은 켤 때마다 번호가 다시 1부터다)
    @Test func aNewCaptureWithTheSameIDsIsNotTakenForTheDeletedOne() async {
        let agent = CaptureAgent(.lost)
        let store = CaptureStore(agent: agent)
        let old = CaptureFixture.attachment("a1", sensitive: false, expiresAt: "2999-01-01T00:00:00Z")
        let new = CaptureFixture.attachment("a1", sensitive: false, expiresAt: "2999-01-02T00:00:00Z")

        #expect(await store.load("t1", old) == .gone)
        await agent.set(.image)
        #expect(await store.load("t1", old) == .gone)
        guard case .image = await store.load("t1", new) else {
            Issue.record("새 캡처를 받지 못했다")
            return
        }
    }

    @Test func noAgentMeansNothingToShow() async {
        let store = CaptureStore(agent: nil)
        #expect(await store.load("t1", CaptureFixture.attachment("a1", sensitive: false)) == .failed)
        #expect(store.heldCount == 0)
    }
}

@MainActor
@Suite("보고의 화면 캡처: 대화에서")
struct CaptureFlowTests {
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

    @Test func readTaskEndsWithAnswerAndCapture() async throws {
        let agent = MockAgentClient(v2: true, captures: MockCaptures())
        let session = session(agent)
        await session.send("결제내역 알려줘", meetings: [])

        // 승인 없이 끝나고, 답과 그 답을 읽은 화면의 캡처가 붙는다
        let state = try #require(session.messages.last?.agent)
        #expect(state.phase == .done)
        #expect(state.report?.done == [MockCaptures.answer])
        let attachment = try #require(state.report?.attachments?.first)
        #expect(attachment.isSensitive)

        // 캡처는 바로 보여 주는 것이지만 (D84), 그림은 화면에 그릴 때 받는다: 작업이 끝난 것만으로는 받지 않는다
        #expect(session.captures.isShown(state.id, attachment))
        #expect(await agent.captureRequests == 0)

        guard case .image(let data) = await session.captures.load(state.id, attachment) else {
            Issue.record("그림을 받지 못했다")
            return
        }
        #expect(AgentAttachment.isImage(data))

        // 대화 기록에는 그림이 없다: 저장된 값은 그림을 받는 데 필요한 값뿐이다
        let records = try context.fetch(FetchDescriptor<ChatRecord>())
        let stored = try #require(records.first { $0.roleRaw == "agent" }?.agentData)
        #expect(stored.count < data.count)
        #expect(try JSONDecoder().decode(AgentTaskState.self, from: stored).report?.attachments == [attachment])

        // 새 대화를 시작하면 받은 그림을 버린다
        session.reset()
        #expect(session.captures.heldCount == 0)
    }

    @Test func twoCapturesComeWithAnAnswerInParagraphs() async throws {
        let agent = MockAgentClient(v2: true, captures: MockCaptures(script: .pair))
        let session = session(agent)
        await session.send("결제내역 알려줘", meetings: [])

        let state = try #require(session.messages.last?.agent)
        #expect(state.phase == .done)
        let attachments = try #require(state.report?.attachments)
        #expect(attachments.map(\.id) == ["a1", "a2"])
        #expect(attachments.allSatisfy { session.captures.isShown(state.id, $0) })

        // 두 캡처는 서로 다른 그림이다
        guard case .image(let first) = await session.captures.load(state.id, attachments[0]),
              case .image(let second) = await session.captures.load(state.id, attachments[1]) else {
            Issue.record("그림을 받지 못했다")
            return
        }
        #expect(AgentAttachment.isImage(first) && AgentAttachment.isImage(second))
        #expect(first != second)

        // 답은 문단 셋: 말풍선 셋으로 나뉜다. 한 장을 가려도 다른 한 장은 그대로다
        let answer = try #require(state.report?.done.first)
        #expect(AnswerText.bubbles(answer).count == 3)
        session.captures.hide(state.id, attachments[1])
        #expect(session.captures.isShown(state.id, attachments[0]))
        #expect(!session.captures.isShown(state.id, attachments[1]))
    }

    @Test func blockedTaskShowsWhereItStopped() async throws {
        let agent = MockAgentClient(v2: true, captures: MockCaptures(script: .blocked))
        let session = session(agent)
        await session.send("결제내역 알려줘", meetings: [])

        let state = try #require(session.messages.last?.agent)
        #expect(state.phase == .failed)
        #expect(state.report?.blocked.first?.contains("로그인이 풀렸어요") == true)
        // 멈춘 화면(로그인 화면)도 다른 캡처처럼 바로 보여 준다 (D84)
        let attachment = try #require(state.report?.attachments?.first)
        #expect(state.report?.attachments?.count == 1)
        #expect(session.captures.isShown(state.id, attachment))
    }

    @Test func openCaptureIsShownRightAway() async throws {
        let agent = MockAgentClient(v2: true, captures: MockCaptures(script: .open))
        let session = session(agent)
        await session.send("결제내역 알려줘", meetings: [])

        let state = try #require(session.messages.last?.agent)
        let attachment = try #require(state.report?.attachments?.first)
        #expect(session.captures.isShown(state.id, attachment))
    }

    @Test func captureTheMacAlreadyDeletedIsGone() async throws {
        let agent = MockAgentClient(v2: true, captures: MockCaptures(script: .gone))
        let session = session(agent)
        await session.send("결제내역 알려줘", meetings: [])

        let state = try #require(session.messages.last?.agent)
        let attachment = try #require(state.report?.attachments?.first)
        session.captures.reveal(state.id, attachment)
        #expect(await session.captures.load(state.id, attachment) == .gone)
    }

    @Test func macWithoutCapturesBehavesAsBefore() async throws {
        // 캡처를 모르는 맥: 같은 말은 작업이 되지 않고 회의 질문으로 넘어간다
        let agent = MockAgentClient(v2: true)
        #expect(try await agent.message("결제내역 알려줘", conversationID: nil, context: nil).action == .routeClaude)
    }
}
