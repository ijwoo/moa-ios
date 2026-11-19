import Foundation
import Testing
@testable import MeetingSummary

/// 오래 가는 기억 (D151, 맥의 D129)
@MainActor
struct MemoryTests {
    // MARK: 읽기

    @Test func readsTheMemoryLikeTheMacSendsIt() throws {
        let json = ###"{"profile":"## 나\n- 답은 짧게","turns":12,"since":"2026-11-11","profile_updated_at":"2026-11-18T07:10:00Z","profile_by":"digest"}"###
        let memory = try MemoryDecoding.memory(data: Data(json.utf8), status: 200)
        #expect(memory.profile == "## 나\n- 답은 짧게")
        #expect(memory.turns == 12)
        #expect(memory.since == "2026-11-11")
        #expect(memory.source == .digest)
        #expect(memory.updatedAt != nil)
    }

    @Test func anEmptyMemoryHasNoDatesOrSource() throws {
        let json = #"{"profile":"","turns":0,"since":null,"profile_updated_at":null,"profile_by":null}"#
        let memory = try MemoryDecoding.memory(data: Data(json.utf8), status: 200)
        #expect(memory.isEmpty)
        #expect(memory.since == nil && memory.updatedAt == nil && memory.source == nil)
    }

    @Test func aSwitchedOffMemoryIsAnError() {
        let body = Data(#"{"error":{"code":"not_found","message":"없는 경로"}}"#.utf8)
        #expect(throws: (any Error).self) { try MemoryDecoding.memory(data: body, status: 404) }
    }

    @Test func readsSearchHitsAndDropsEmptyOnes() throws {
        let json = #"{"hits":[{"when":"2026-11-11 20:10","role":"user","text":"시안은 금요일까지","next":"네"},{"when":"x","role":"assistant","text":"  ","next":""},{"when":"2026-11-12 09:30","role":"assistant","text":"회의는 목요일","next":""}]}"#
        let hits = try MemoryDecoding.hits(data: Data(json.utf8), status: 200)
        #expect(hits.map(\.text) == ["시안은 금요일까지", "회의는 목요일"])
        #expect(hits[0].isMine && !hits[1].isMine)
        #expect(hits[0].next == "네" && hits[1].next == nil)
    }

    @Test func clearingNeedsAnOkFromTheMac() throws {
        try MemoryDecoding.cleared(data: Data(#"{"ok":true}"#.utf8), status: 200)
        #expect(throws: (any Error).self) { try MemoryDecoding.cleared(data: Data(#"{}"#.utf8), status: 200) }
    }

    // MARK: 묶음

    @Test func splitsTheProfileIntoTitledSections() {
        let sections = MemorySection.sections("""
        머리말
        ## 나
        - 답은 짧게
        * 아침엔 알림 없이
        ## 사람

        ## 하지 말 것
        • 메일은 승인 없이 보내지 않는다
        """)
        #expect(sections.map(\.title) == [nil, "나", "하지 말 것"])
        #expect(sections[1].lines == ["답은 짧게", "아침엔 알림 없이"])
        #expect(sections.map(\.id) == [0, 1, 2])
    }

    @Test func theFooterSaysHowAndWhen() {
        let memory = AgentMemory(profile: "## 나\n- a", turns: 3, since: "2026-11-11", updatedAt: nil, source: .user)
        let footer = MemoryView.footer(memory)
        #expect(footer.contains("직접 고침"))
        #expect(footer.contains("11월 11일부터 대화 3개"))
        #expect(MemoryView.dayText("2026-11-05") == "11월 5일")
    }

    // MARK: 화면 상태 (가짜 맥)

    private func model() async -> (MockAgentClient, MemoryModel) {
        let agent = MockAgentClient(v2: true)
        await agent.enableMemory()
        let model = MemoryModel(agent: agent)
        await model.load()
        return (agent, model)
    }

    @Test func notOfferedWithoutTheFeature() async {
        let model = MemoryModel(agent: MockAgentClient(v2: true))
        await model.load()
        #expect(!model.isOffered)
        #expect(model.memory == nil)
    }

    @Test func savingShowsWhatTheMacKeptAndSaysWhenItTrimmed() async {
        let (agent, model) = await model()
        #expect(model.isOffered)
        #expect(model.memory?.source == .digest)
        #expect(await model.save("## 나\n- 답은 짧게"))
        #expect(model.memory?.profile == "## 나\n- 답은 짧게")
        #expect(model.memory?.source == .user)
        #expect(model.notice == nil)
        // 비밀 꼴은 맥이 지운다: 앱은 맥이 저장한 글을 보이고 알린다
        #expect(await model.save("## 나\n- 계좌 123-456-789012"))
        #expect(model.memory?.profile.contains("[지움]") == true)
        #expect(model.notice != nil)
        #expect(await agent.memoryProfile == model.memory?.profile)
    }

    @Test func tooLongTextIsNotSent() async {
        let (agent, model) = await model()
        let before = await agent.memoryProfile
        #expect(!(await model.save(String(repeating: "가", count: AgentMemory.sendLimit + 1))))
        #expect(await agent.memoryProfile == before)
    }

    @Test func undoSwapsBetweenTwoVersions() async {
        let (_, model) = await model()
        let original = model.memory?.profile
        _ = await model.save("## 나\n- 바꾼 글")
        await model.undo()
        #expect(model.memory?.profile == original)
        #expect(model.memory?.source == .undo)
        // 한 단계뿐이라 다시 누르면 방금 것으로 돌아간다 (맥의 D129)
        await model.undo()
        #expect(model.memory?.profile == "## 나\n- 바꾼 글")
    }

    @Test func nothingToUndoIsToldApart() async {
        // 맨 처음 쓴 요약본에는 전 판이 없다: 맥이 409(nothing_to_undo)를 준다
        let (_, model) = await model()
        await model.undo()
        #expect(model.notice == "되돌릴 전 요약이 없어요.")
        let error = AgentHTTPClient.decodeError(data: Data(#"{"error":{"code":"nothing_to_undo","message":"m"}}"#.utf8), status: 409)
        #expect(error == .conflict)
    }

    @Test func searchFindsPastTalk() async {
        let (_, model) = await model()
        await model.search("  시안  ")
        #expect(model.searched == "시안")
        #expect(model.hits.count == 2)
        await model.search("없는 말")
        #expect(model.hits.isEmpty && model.searched == "없는 말")
        model.clearSearch()
        #expect(model.searched == nil)
    }

    @Test func clearingEmptiesEverything() async {
        let (agent, model) = await model()
        await model.search("시안")
        #expect(await model.clearAll())
        #expect(model.memory?.isEmpty == true)
        #expect(model.hits.isEmpty)
        #expect(await agent.memoryClears == 1)
        await model.load()
        #expect(model.memory?.isEmpty == true)
    }
}

/// 이 파일만 쓰는 가짜 맥 (받은 요청을 적어 둔다)
final class MemoryStubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let path: String
        let query: String?
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
        let method = request.httpMethod ?? ""
        let path = request.url?.path() ?? ""
        let (status, text) = Self.lock.withLock {
            Self.seen.append(Seen(method: method, path: path, query: request.url?.query(), body: String(decoding: body, as: UTF8.self)))
            return Self.respond(method, path)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("기억: 맥에 보내는 요청", .serialized)
struct MemoryRequestTests {
    private func client() async -> AgentHTTPClient {
        MemoryStubProtocol.lock.withLock {
            MemoryStubProtocol.seen = []
            MemoryStubProtocol.respond = { method, path in
                switch (method, path) {
                case (_, "/v1/health"): (200, #"{"status":"ok","features":["messages","memory"]}"#)
                case ("GET", "/v1/memory"): (200, #"{"profile":"","turns":0}"#)
                case ("PUT", "/v1/memory/profile"), ("POST", "/v1/memory/undo"): (200, #"{"profile":"저장된 글"}"#)
                case ("GET", "/v1/memory/search"): (200, #"{"hits":[]}"#)
                case ("DELETE", "/v1/memory"): (200, #"{"ok":true}"#)
                default: (404, #"{"error":{"code":"not_found","message":"없는 경로"}}"#)
                }
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemoryStubProtocol.self]
        let client = AgentHTTPClient(baseURL: URL(string: "http://mac.test:8765")!, token: "t", session: URLSession(configuration: configuration))
        // 맥이 알린 기능을 먼저 받아 둔다 (실제 앱도 닿는지 본 뒤에 부른다)
        _ = await client.isReachable()
        _ = await client.supports(AgentFeature.memory)
        return client
    }

    private var seen: [MemoryStubProtocol.Seen] {
        MemoryStubProtocol.lock.withLock { MemoryStubProtocol.seen }.filter { $0.path != "/v1/health" }
    }

    @Test func eachCallGoesToItsPath() async throws {
        let client = await client()
        _ = try await client.memory()
        #expect(try await client.setMemoryProfile("## 나\n- 짧게") == "저장된 글")
        #expect(try await client.undoMemory() == "저장된 글")
        _ = try await client.searchMemory("시안 & 회의")
        try await client.clearMemory()
        #expect(seen.map { "\($0.method) \($0.path)" } == [
            "GET /v1/memory", "PUT /v1/memory/profile", "POST /v1/memory/undo", "GET /v1/memory/search", "DELETE /v1/memory",
        ])
        // 고친 글은 profile 하나로 보낸다
        let put = try #require(seen.first { $0.method == "PUT" })
        let sent = try JSONDecoder().decode([String: String].self, from: Data(put.body.utf8))
        #expect(sent == ["profile": "## 나\n- 짧게"])
        // 찾는 말은 주소에 섞지 않고 q로 붙인다
        let search = try #require(seen.first { $0.path == "/v1/memory/search" })
        #expect(URLComponents(string: "x?\(search.query ?? "")")?.queryItems?.first?.value == "시안 & 회의")
    }

    @Test func tooLongTextIsRefusedBeforeSending() async {
        let client = await client()
        await #expect(throws: AgentError.self) { try await client.setMemoryProfile(String(repeating: "가", count: AgentMemory.sendLimit + 1)) }
        #expect(seen.isEmpty)
    }
}
