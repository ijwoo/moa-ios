import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

/// 정해 둔 권한을 답하고, 무엇을 청했는지 적어 두는 가짜 시스템 (실제 권한 물음을 띄우지 않는다)
@MainActor
private final class FakePush: PushSystem {
    var state: PermissionState
    /// 권한을 물었을 때의 답
    var allows: Bool
    /// Apple이 주는 알림 주소 (nil이면 주소가 나중에 온다)
    var token: String?
    private(set) var asked = 0
    private(set) var requestedToken = 0

    init(state: PermissionState, allows: Bool = true, token: String? = PushFixture.token) {
        self.state = state
        self.allows = allows
        self.token = token
    }

    func status() async -> PermissionState { state }

    func requestPermission() async -> Bool {
        asked += 1
        state = allows ? .granted : .denied
        return allows
    }

    func registerForRemote() -> String? {
        requestedToken += 1
        return token
    }
}

enum PushFixture {
    /// 가상 알림 주소 (16진수 64자)
    static let token = String(repeating: "ab12", count: 16)
    static let other = String(repeating: "cd34", count: 16)
}

/// 맥이 보내는 알림 (D67): 실려 오는 것 읽기, 권한, 이 기기를 맥에 등록하기, 눌렀을 때 갈 대화
@MainActor
@Suite("알림: 정해진 문장과 번호만 받고, 맥이 보낼 수 있을 때만 등록한다")
struct PushTests {
    private func store() -> UserDefaults {
        let name = "push-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func center(
        _ agent: MockAgentClient?, _ system: FakePush, defaults: UserDefaults? = nil, environment: String = "production",
        now: @escaping () -> Date = { .now }
    ) -> PushCenter {
        PushCenter(
            agent: agent, system: system, defaults: defaults ?? store(), environment: environment,
            bundleID: "dev.example.app", now: now
        )
    }

    // MARK: 알림에 실려 온 것

    /// 두 쪽이 맞춘 이름과 문장 (맥이 이 문장을 그대로 보낸다)
    @Test func kindsAndSentencesMatchTheMac() {
        #expect(AgentFeature.push == "push")
        let agreed = [
            "approval_needed": "승인이 필요한 일이 있어요", "input_needed": "확인이 필요한 질문이 있어요",
            "task_done": "맡긴 일이 끝났어요", "task_failed": "맡긴 일을 끝내지 못했어요",
            "needs_login": "로그인이 필요해서 멈췄어요", "routine_result": "루틴 결과가 도착했어요",
            "login_expired": "로그인이 풀린 사이트가 있어요"
        ]
        #expect(Dictionary(uniqueKeysWithValues: PushNotice.Kind.allCases.map { ($0.rawValue, $0.body) }) == agreed)
    }

    @Test func readsTypeAndNumbers() {
        let info: [AnyHashable: Any] = [
            "aps": ["alert": ["body": "승인이 필요한 일이 있어요"], "sound": "default", "thread-id": "t_1"],
            "type": "approval_needed", "task_id": "t_1", "conversation_id": "c_1"
        ]
        #expect(PushNotice(userInfo: info) == PushNotice(kind: .approvalNeeded, taskID: "t_1", conversationID: "c_1"))
        // 번호가 없으면 앱만 연다
        #expect(PushNotice(userInfo: ["type": "task_done"]) == PushNotice(kind: .taskDone))
    }

    /// 모르는 종류는 읽지 않는다 (눌러도 앱만 열린다). 주소에 넣을 수 없는 번호는 버린다
    @Test func ignoresUnknownTypesAndUnsafeNumbers() {
        #expect(PushNotice(userInfo: ["type": "promo", "task_id": "t_1"]) == nil)
        #expect(PushNotice(userInfo: ["task_id": "t_1"]) == nil)
        let odd = PushNotice(userInfo: ["type": "task_done", "task_id": "../v1/sites", "conversation_id": 7])
        #expect(odd == PushNotice(kind: .taskDone))
    }

    @Test func tokenBecomesLowercaseHex() {
        #expect(PushToken.hex(Data([0x00, 0x0f, 0xa1, 0xff])) == "000fa1ff")
        #expect(PushToken.isValid(PushFixture.token))
        #expect(PushToken.isValid(String(repeating: "a", count: 200)))
        #expect(!PushToken.isValid(String(repeating: "a", count: 63)))
        #expect(!PushToken.isValid(String(repeating: "a", count: 201)))
        #expect(!PushToken.isValid(String(repeating: "AB12", count: 16)))
        #expect(!PushToken.isValid(String(repeating: "a", count: 60) + "/../"))
    }

    // MARK: 권한과 등록

    /// 알림을 보낼 수 없는 맥에는 권한도 묻지 않고 아무것도 보내지 않는다. 권한 화면에도 줄이 없다
    @Test func aMacWithoutPushGetsNothing() async {
        let agent = MockAgentClient(v2: true)
        let system = FakePush(state: .notDetermined)
        let center = center(agent, system)
        await center.refresh()
        await center.askPermission()
        #expect(!center.isOffered)
        #expect(system.asked == 0)
        #expect(system.requestedToken == 0)
        #expect(await agent.pushCalls.isEmpty)
        #expect(center.permissionItem == nil)
        #expect(!center.canAsk)
    }

    /// 앱을 켠 것만으로는 묻지 않는다. 알림을 받겠다고 하면 묻고, 허용하면 등록한다
    @Test func asksOnlyWhenWantedThenRegisters() async {
        let agent = MockAgentClient(v2: true, offersPush: true)
        let system = FakePush(state: .notDetermined)
        let defaults = store()
        let center = center(agent, system, defaults: defaults)
        await center.refresh()
        #expect(center.isOffered)
        #expect(system.asked == 0)
        #expect(await agent.pushCalls.isEmpty)
        #expect(center.canAsk)
        #expect(center.permissionItem?.state == .notDetermined)

        await center.askPermission()
        #expect(system.asked == 1)
        #expect(center.permission == .granted)
        #expect(await agent.pushDevices == [PushFixture.token: "production"])
        #expect(defaults.string(forKey: PushCenter.registeredKey) == PushFixture.token)
        #expect(!center.canAsk)
        // 이미 정했으면 다시 묻지 않는다
        await center.askPermission()
        #expect(system.asked == 1)
    }

    @Test func refusingMeansNoRegistration() async {
        let agent = MockAgentClient(v2: true, offersPush: true)
        let system = FakePush(state: .notDetermined, allows: false)
        let center = center(agent, system)
        await center.refresh()
        await center.askPermission()
        #expect(center.permission == .denied)
        #expect(system.requestedToken == 0)
        #expect(await agent.pushCalls.isEmpty)
        #expect(center.permissionItem?.state == .denied)
    }

    /// 실제 기기에서는 주소가 나중에 온다. 온 뒤에 등록한다. 같은 주소는 한동안 다시 보내지 않는다
    @Test func registersWhenTheTokenArrivesAndNotTwice() async {
        let agent = MockAgentClient(v2: true, offersPush: true)
        let system = FakePush(state: .granted, token: nil)
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_794_547_200)
        let center = center(agent, system, environment: "sandbox", now: { clock })
        await center.refresh()
        #expect(system.requestedToken == 1)
        #expect(await agent.pushCalls.isEmpty)

        await center.received(token: PushFixture.token)
        #expect(await agent.pushDevices == [PushFixture.token: "sandbox"])
        await center.refresh()
        await center.received(token: PushFixture.token)
        #expect(await agent.pushCalls == ["register sandbox"])
        // 한 시간이 지나면 다시 보낸다 (맥이 다시 켜지며 등록을 잃었을 수 있다)
        clock += PushCenter.reregisterAfter + 1
        await center.refresh()
        await center.received(token: PushFixture.token)
        #expect(await agent.pushCalls == ["register sandbox", "register sandbox"])
    }

    /// 주소가 바뀌면 새 주소를 등록하고 예전 주소는 지운다
    @Test func aNewTokenReplacesTheOldOne() async {
        let agent = MockAgentClient(v2: true, offersPush: true)
        let system = FakePush(state: .granted, token: nil)
        let defaults = store()
        let center = center(agent, system, defaults: defaults)
        await center.refresh()
        await center.received(token: PushFixture.token)
        await center.received(token: PushFixture.other)
        #expect(await agent.pushDevices == [PushFixture.other: "production"])
        #expect(defaults.string(forKey: PushCenter.registeredKey) == PushFixture.other)
    }

    /// 등록에 실패하면 조용히 넘어가고, 다음에 다시 한다
    @Test func aFailedRegistrationIsRetriedNextTime() async {
        let agent = MockAgentClient(v2: true, offersPush: true)
        await agent.setRejectsPush(true)
        let defaults = store()
        let center = center(agent, FakePush(state: .granted), defaults: defaults)
        await center.refresh()
        #expect(await agent.pushDevices.isEmpty)
        #expect(defaults.string(forKey: PushCenter.registeredKey) == nil)

        await agent.setRejectsPush(false)
        await center.refresh()
        #expect(await agent.pushDevices == [PushFixture.token: "production"])
        #expect(await agent.pushCalls == ["register production", "register production"])
    }

    /// 맥에 닿지 않으면 아무것도 하지 않는다 (권한 줄은 물은 적이 있을 때만 남는다)
    @Test func anUnreachableMacIsLeftAlone() async {
        let agent = MockAgentClient(reachable: false, v2: true, offersPush: true)
        let system = FakePush(state: .granted)
        let center = center(agent, system)
        await center.refresh()
        #expect(!center.isOffered)
        #expect(system.requestedToken == 0)
        #expect(center.permissionItem?.state == .granted)
    }

    /// 아이폰 설정에서 알림을 껐으면, 다음에 앱을 열 때 맥의 등록을 지운다
    @Test func turningNotificationsOffRemovesTheRegistration() async {
        let agent = MockAgentClient(v2: true, offersPush: true)
        let system = FakePush(state: .granted)
        let defaults = store()
        let center = center(agent, system, defaults: defaults)
        await center.refresh()
        #expect(await agent.pushDevices.count == 1)

        system.state = .denied
        await center.refresh()
        #expect(await agent.pushDevices.isEmpty)
        #expect(defaults.string(forKey: PushCenter.registeredKey) == nil)
        #expect(await agent.pushCalls == ["register production", "unregister"])
        // 지운 뒤에는 다시 보내지 않는다
        await center.refresh()
        #expect(await agent.pushCalls.count == 2)
        // 다시 켜면 다시 등록한다
        system.state = .granted
        await center.refresh()
        #expect(await agent.pushDevices == [PushFixture.token: "production"])
    }

    @Test func noAgentMeansNoPush() async {
        let system = FakePush(state: .granted)
        let center = center(nil, system)
        await center.refresh()
        await center.askPermission()
        #expect(system.requestedToken == 0)
        #expect(center.permissionItem == nil)
    }

    // MARK: 받은 알림

    /// 그 대화를 보고 있으면 배너를 띄우지 않는다. 다른 대화, 다른 화면이면 띄운다
    @Test func hidesTheBannerOnlyForTheConversationOnScreen() {
        let center = center(MockAgentClient(v2: true, offersPush: true), FakePush(state: .granted))
        let notice = PushNotice(kind: .approvalNeeded, taskID: "t_1", conversationID: "c_1")
        #expect(center.shouldPresent(notice))
        center.visibleConversationID = "c_1"
        #expect(!center.shouldPresent(notice))
        #expect(center.shouldPresent(PushNotice(kind: .taskDone, taskID: "t_2", conversationID: "c_2")))
        // 어느 대화인지 모르는 알림과 모르는 종류의 알림은 띄운다
        #expect(center.shouldPresent(PushNotice(kind: .taskDone)))
        #expect(center.shouldPresent(nil))
    }

    @Test func tappingKeepsTheNoticeForTheScreen() {
        let center = center(MockAgentClient(v2: true, offersPush: true), FakePush(state: .granted))
        center.opened(nil)
        #expect(center.pending == nil)
        let notice = PushNotice(kind: .taskDone, taskID: "t_1", conversationID: "c_1")
        center.opened(notice)
        #expect(center.pending == notice)
    }

    /// 알림의 대화 번호로 기록의 대화를 찾는다. 없으면 nil (그때는 질문 탭만 연다)
    @Test func findsTheConversationByTheMacsNumber() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let first = Conversation(title: "메일 요약")
        first.agentConversationID = "c_1"
        let second = Conversation(title: "결제 내역")
        second.agentConversationID = "c_2"
        context.insert(first)
        context.insert(second)
        try context.save()

        let found = PushCenter.conversation(for: PushNotice(kind: .taskDone, taskID: "t_9", conversationID: "c_2"), in: context)
        #expect(found?.id == second.id)
        #expect(PushCenter.conversation(for: PushNotice(kind: .taskDone, conversationID: "c_404"), in: context) == nil)
        #expect(PushCenter.conversation(for: PushNotice(kind: .taskDone), in: context) == nil)
    }

    // MARK: 설명 글

    /// 알림을 보내는 맥일 때만 "데이터 처리 방식"에 알림 줄이 생긴다. 대화 판단이 어디서 되는지와는 상관없다
    @Test func privacyRowAppearsOnlyForAMacThatSendsPush() async {
        #expect(!MacAgentFacts(setup: .local).rows.contains { $0.icon == .bell })
        #expect(!MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true)).rows.contains { $0.icon == .bell })

        for setup in [DialogSetup(place: .local, sendsPush: true), DialogSetup(place: .cloud, sendsPush: true)] {
            let rows = MacAgentFacts(setup: setup).rows
            let row = rows.first { $0.icon == .bell }
            #expect(row?.text.contains("Apple의 알림 서버") == true)
            #expect(row?.note?.contains("정해진 문장 하나") == true)
            #expect(row?.note?.contains("기기 토큰") == true)
            // 맨 끝은 그대로 "맥은 저장하지 않는다" 줄이다
            #expect(rows.last?.icon == .inbox)
        }

        let local = await DialogSetup(agent: MockAgentClient(v2: true, offersPush: true))
        #expect(local.place == .local && local.sendsPush)
        let cloud = await DialogSetup(agent: MockAgentClient(v2: true, dialogCloud: MockDialogCloud(), offersPush: true))
        #expect(cloud.place == .cloud && cloud.sendsPush)
        #expect(await DialogSetup(agent: MockAgentClient(v2: true)).sendsPush == false)
    }

    @Test func setupRemembersPush() {
        #expect(DialogSetup(place: .local, sendsPush: true).stored == "v2 local push")
        #expect(DialogSetup(stored: "v2 local push") == DialogSetup(place: .local, sendsPush: true))
        #expect(DialogSetup(stored: "v2 cloud context push")?.sendsPush == true)
        // 예전에 적어 둔 값에는 알림이 없다
        #expect(DialogSetup(stored: "v2 cloud context web")?.sendsPush == false)
        #expect(DialogSetup(stored: "cloud")?.sendsPush == false)
    }

    @Test func bellIconIsInTheApp() {
        #expect(Lucide.bell.assetName == "Lucide/bell")
    }
}

// MARK: - 요청

/// 이 파일만 쓰는 가짜 응답 (다른 묶음의 것과 섞이지 않게 따로 둔다)
final class PushStubProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("알림 등록 요청", .serialized)
struct PushRequestTests {
    private func client(push: Bool, register: (Int, String) = (200, #"{"registered":true}"#)) -> AgentHTTPClient {
        let features = push ? #"["messages","task_questions","push"]"# : #"["messages","task_questions"]"#
        PushStubProtocol.lock.withLock {
            PushStubProtocol.seen = []
            PushStubProtocol.respond = { method, path in
                if path.hasSuffix("/health") { return (200, #"{"status":"ok","features":\#(features)}"#) }
                if method == "DELETE" { return (200, #"{"registered":false}"#) }
                return register
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushStubProtocol.self]
        return AgentHTTPClient(baseURL: URL(string: "http://mac.test:8765")!, token: "t", session: URLSession(configuration: configuration))
    }

    private var seen: [PushStubProtocol.Seen] {
        PushStubProtocol.lock.withLock { PushStubProtocol.seen }.filter { !$0.path.hasSuffix("/health") }
    }

    @Test func registersWithTheAgreedBody() async throws {
        let client = client(push: true)
        #expect(await client.isReachable())
        try await client.registerPush(token: PushFixture.token, environment: "production", bundleID: "dev.example.app")
        let request = try #require(seen.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/push/devices")
        #expect(request.headers["X-App-Token"] == "t")
        let body = try #require(JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: String])
        #expect(body == ["token": PushFixture.token, "environment": "production", "bundle_id": "dev.example.app"])
    }

    @Test func removesByToken() async throws {
        let client = client(push: true)
        #expect(await client.isReachable())
        try await client.unregisterPush(token: PushFixture.token)
        #expect(seen.map(\.method) == ["DELETE"])
        #expect(seen.first?.path == "/v1/push/devices/\(PushFixture.token)")
    }

    /// 알림을 알리지 않은 맥에는 주소를 보내지 않는다. 주소 꼴이 아닌 것도 보내지 않는다
    @Test func sendsNothingToAMacWithoutPushOrWithAnOddToken() async {
        let old = client(push: false)
        #expect(await old.isReachable())
        await #expect(throws: AgentError.self) {
            try await old.registerPush(token: PushFixture.token, environment: "production", bundleID: "dev.example.app")
        }
        await #expect(throws: AgentError.self) { try await old.unregisterPush(token: PushFixture.token) }
        #expect(seen.isEmpty)

        let new = client(push: true)
        #expect(await new.isReachable())
        await #expect(throws: AgentError.self) {
            try await new.registerPush(token: "not-a-token", environment: "production", bundleID: "dev.example.app")
        }
        await #expect(throws: AgentError.self) { try await new.unregisterPush(token: "../tasks") }
        #expect(seen.isEmpty)
    }

    /// 맥이 거절하면(예: 아직 받지 않는 환경) 오류로 돌려준다. 부르는 쪽이 조용히 넘긴다
    @Test func aRejectionIsAnError() async {
        let client = client(push: true, register: (400, #"{"error":{"code":"invalid_request","message":"sandbox is not supported"}}"#))
        #expect(await client.isReachable())
        await #expect(throws: AgentError.self) {
            try await client.registerPush(token: PushFixture.token, environment: "sandbox", bundleID: "dev.example.app")
        }
        #expect(seen.count == 1)
    }
}
