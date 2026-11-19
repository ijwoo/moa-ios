import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

/// 알림 권한과 기기의 알림 주소를 시스템에 묻는 곳. 테스트와 데모에서는 가짜로 바꾼다
@MainActor
protocol PushSystem {
    func status() async -> PermissionState
    /// 시스템의 권한 물음을 띄운다 (한 번만 뜬다). 허용했는지를 돌려준다
    func requestPermission() async -> Bool
    /// Apple에 이 기기의 알림 주소를 달라고 한다. 실제 기기에서는 주소가 나중에 앱 대리자로 온다 (nil). 가짜는 바로 돌려준다
    func registerForRemote() -> String?
}

struct SystemPush: PushSystem {
    func status() async -> PermissionState {
        switch await Self.authorization() {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }

    private nonisolated static func authorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 배지는 쓰지 않는다 (맥이 보내는 알림에 숫자가 없다)
    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func registerForRemote() -> String? {
        UIApplication.shared.registerForRemoteNotifications()
        return nil
    }
}

/// 맥이 보내는 알림 (D67): 권한, 이 기기를 맥에 등록하기, 알림을 눌렀을 때 갈 곳.
///
/// - 맥이 알림을 보낼 수 있다고 알릴 때(`features`의 `push`)만 움직인다. 그 전에는 권한도 묻지 않고 아무것도 보내지 않는다
/// - 권한은 처음 일을 맡겼을 때, 또는 권한 화면의 단추로 묻는다 (앱을 켜자마자 묻지 않는다)
/// - 등록에 실패하면 조용히 넘어가고 다음에 앱을 열 때 다시 한다. 알림을 꺼 두었으면 등록을 지운다
/// - 알림에는 정해진 문장과 번호만 실린다 (`PushNotice`). 내용은 앱이 그 대화를 열어 맥에서 직접 받는다
@MainActor
@Observable
final class PushCenter {
    static let shared = makeShared()

    /// 맥에 등록해 둔 알림 주소를 적어 두는 자리 (알림을 끄면 이 주소로 등록을 지운다)
    static let registeredKey = "push.registeredToken"
    /// 같은 주소를 다시 등록하기까지 두는 간격. 맥이 다시 켜지며 등록을 잃었을 수 있어 가끔 다시 보낸다
    static let reregisterAfter: TimeInterval = 3600

    private let agent: (any AgentProviding)?
    @ObservationIgnored private let system: any PushSystem
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    /// Apple의 어느 알림 서버로 갈 주소인지. TestFlight·배포 빌드는 "production", Xcode로 넣은 빌드는 "sandbox"
    let environment: String
    let bundleID: String

    /// 알림 권한 (마지막으로 확인한 값)
    private(set) var permission: PermissionState = .notDetermined
    /// 맥이 알림을 보낼 수 있다고 알렸는지 (마지막으로 연결을 확인했을 때)
    private(set) var isOffered = false
    /// 눌러서 들어온 알림. 화면이 그 대화를 연 뒤 비운다
    var pending: PushNotice?
    /// 지금 화면에 보이는 대화의 맥 쪽 번호 (질문 탭에서 그 대화를 보고 있을 때만)
    @ObservationIgnored var visibleConversationID: String?

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var lastRegistered: (token: String, at: Date)?
    @ObservationIgnored private var isRegistering = false
    @ObservationIgnored private var isAsking = false

    init(
        agent: (any AgentProviding)? = AgentClient.fromEnvironment(), system: any PushSystem = SystemPush(),
        defaults: UserDefaults = .standard, environment: String = PushCenter.buildEnvironment,
        bundleID: String = Bundle.main.bundleIdentifier ?? "", now: @escaping () -> Date = { .now }
    ) {
        self.agent = agent
        self.system = system
        self.defaults = defaults
        self.environment = environment
        self.bundleID = bundleID
        self.now = now
    }

    static var buildEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private static func makeShared() -> PushCenter {
        #if DEBUG
        // -demoPush ask|on|denied: 알림을 보낼 수 있는 가짜 맥과 가짜 권한. real이면 권한만 실제 시스템에 묻는다 (배너 확인용)
        if DemoData.arguments.contains("-demoAgent"), let demo = DemoData.value(after: "-demoPush"), demo != "real" {
            return PushCenter(system: DemoPush(state: demo == "on" ? .granted : demo == "denied" ? .denied : .notDetermined))
        }
        #endif
        // 테스트를 돌릴 때 뜨는 앱은 실제 맥에 이 시뮬레이터를 등록하러 가지 않는다 (맥의 기록에 거절된 등록이 쌓였다)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return PushCenter(agent: nil) }
        return PushCenter()
    }

    // MARK: - 권한과 등록

    /// 앱을 열 때, 앞으로 돌아올 때: 권한과 맥의 설정을 다시 보고, 등록하거나 지운다
    func refresh() async {
        guard let agent else { return }
        permission = await system.status()
        guard await agent.isReachable() else { return }
        isOffered = await agent.supports(AgentFeature.push)
        guard isOffered else { return }
        switch permission {
        case .granted:
            if let immediate = system.registerForRemote() { token = immediate }
            await register()
        case .denied:
            await unregister()
        case .notDetermined:
            break
        }
    }

    /// 알림을 받겠다고 했을 때 (권한 화면의 단추, 처음 일을 맡겼을 때). 이미 정했으면 다시 묻지 않는다
    func askPermission() async {
        guard agent != nil, isOffered, !isAsking else { return }
        isAsking = true
        defer { isAsking = false }
        permission = await system.status()
        guard permission == .notDetermined else { return }
        permission = await system.requestPermission() ? .granted : .denied
        guard permission == .granted else { return }
        if let immediate = system.registerForRemote() { token = immediate }
        await register()
    }

    /// Apple이 이 기기의 알림 주소를 주었다 (앱 대리자가 받는다)
    func received(token: String) async {
        self.token = token
        await register()
    }

    private func register() async {
        guard let agent, isOffered, permission == .granted, let token, !isRegistering else { return }
        if let last = lastRegistered, last.token == token, now().timeIntervalSince(last.at) < Self.reregisterAfter { return }
        isRegistering = true
        defer { isRegistering = false }
        do {
            try await agent.registerPush(token: token, environment: environment, bundleID: bundleID)
        } catch {
            // 조용히 넘어간다 (맥이 꺼져 있거나 아직 받지 않는 환경). 다음에 앱을 열 때 다시 한다
            return
        }
        lastRegistered = (token, now())
        // 주소가 바뀌었으면 예전 주소의 등록은 지운다
        if let old = defaults.string(forKey: Self.registeredKey), old != token { try? await agent.unregisterPush(token: old) }
        defaults.set(token, forKey: Self.registeredKey)
    }

    /// 알림을 꺼 두었다: 맥에 등록해 둔 주소를 지운다. 지우지 못하면 적어 둔 것을 남겨 다음에 다시 한다
    private func unregister() async {
        guard let agent, let old = defaults.string(forKey: Self.registeredKey) else { return }
        guard (try? await agent.unregisterPush(token: old)) != nil else { return }
        defaults.removeObject(forKey: Self.registeredKey)
        lastRegistered = nil
    }

    // MARK: - 화면

    /// 권한 화면의 "알림" 줄. 맥이 알림을 보낼 수 없고 물은 적도 없으면 없다 (쓸 수 없는 권한을 늘어놓지 않는다)
    var permissionItem: PermissionItem? {
        guard agent != nil, isOffered || permission != .notDetermined else { return nil }
        return PermissionItem(
            id: "notifications", title: "알림", reason: "맡긴 일이 끝나거나 멈추면 알려요", icon: .bell, state: permission
        )
    }

    /// 지금 권한을 물을 수 있는지 (권한 화면의 "알림 받기" 단추)
    var canAsk: Bool { agent != nil && isOffered && permission == .notDetermined }

    // MARK: - 받은 알림

    /// 앱이 앞에 있을 때 온 알림을 배너로 보일지. 그 대화를 보고 있으면 화면이 이미 바뀌므로 보이지 않는다
    func shouldPresent(_ notice: PushNotice?) -> Bool {
        guard let id = notice?.conversationID, let visible = visibleConversationID else { return true }
        return id != visible
    }

    /// 알림을 눌렀다. 모르는 종류면 앱만 열린다
    func opened(_ notice: PushNotice?) {
        guard let notice else { return }
        pending = notice
    }

    /// 알림이 가리키는 대화 (맥의 대화 번호로 찾는다). 없으면 nil
    static func conversation(for notice: PushNotice, in context: ModelContext) -> Conversation? {
        guard let id = notice.conversationID else { return nil }
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.agentConversationID == id }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

#if DEBUG
/// 가짜 알림 권한 (`-demoPush`). 시스템의 물음을 띄우지 않고, 허용한 것으로 바뀐다
@MainActor
final class DemoPush: PushSystem {
    /// 가상 알림 주소 (16진수 64자)
    static let token = String(repeating: "0a1b2c3d", count: 8)
    private var state: PermissionState

    init(state: PermissionState) { self.state = state }

    func status() async -> PermissionState { state }

    func requestPermission() async -> Bool {
        state = .granted
        return true
    }

    func registerForRemote() -> String? { Self.token }
}
#endif
