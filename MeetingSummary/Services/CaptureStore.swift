import Foundation
import Observation

/// 보고에 붙은 화면 캡처를 받아 잠깐 들고 있는 곳 (D56).
///
/// 캡처는 맥이 본 실제 화면이라 내 정보가 찍혀 있을 수 있다. 그래서
/// - 그림은 메모리에만 둔다 (대화 기록·파일·기기 캐시에 남기지 않는다). 앱이 뒤로 가면 버린다
/// - 캡처는 작은 그림으로 바로 보여 준다 (D84. 전에는 로그인한 화면의 캡처를 가려 두고 눌러야 보여 줬다, D56).
///   보고 싶지 않은 것은 크게 보기에서 "가리기"로 접어 둘 수 있다. 접어 둔 것은 앱을 켜 둔 동안 그대로다
/// - Claude로 가는 요청에는 넣지 않는다 (이 그림은 맥과 이 화면 사이에서만 오간다)
@MainActor
@Observable
final class CaptureStore {
    enum Loaded: Equatable {
        case image(Data)
        /// 맥이 이미 지웠다 (24시간이 지났거나 맥이 다시 시작됨). 다시 받을 수 없다
        case gone
        /// 지금은 받지 못했다. 다시 시도할 수 있다
        case failed
    }

    /// 한 번에 들고 있는 그림 수 (넘으면 오래된 것부터 버린다. 다시 보면 다시 받는다)
    static let limit = 4

    private let agent: (any AgentProviding)?
    /// 손 넘기기 화면(D123)도 같은 맥에 묻는다 (화면 그림은 그 화면의 메모리에만 든다. 여기에 모으지 않는다)
    var handoverAgent: (any AgentProviding)? { agent }
    /// 사용자가 "가리기"로 접어 둔 캡처 (작업 번호/캡처 번호). 앱을 켜 둔 동안만 기억한다 (저장하지 않는다)
    private(set) var hidden: Set<String> = []
    /// 모두 버린 횟수. 화면은 이 값이 바뀌면 들고 있던 그림을 버린다
    private(set) var generation = 0
    @ObservationIgnored private var images: [String: Data] = [:]
    @ObservationIgnored private var order: [String] = []
    /// 맥이 지웠다고 답한 캡처. 같은 번호라도 지워질 시각이 다르면 다른 캡처다 (그것까지 지워졌다고 하지 않는다)
    @ObservationIgnored private var gone: Set<String> = []

    init(agent: (any AgentProviding)?) {
        self.agent = agent
    }

    static func key(_ taskID: String, _ attachment: AgentAttachment) -> String { "\(taskID)/\(attachment.id)" }

    /// 지금 그림으로 보여 주는지: 사용자가 접어 두지 않은 것은 모두 보여 준다 (D84)
    func isShown(_ taskID: String, _ attachment: AgentAttachment) -> Bool {
        !hidden.contains(Self.key(taskID, attachment))
    }

    /// 접어 둔 것을 다시 보여 준다
    func reveal(_ taskID: String, _ attachment: AgentAttachment) {
        hidden.remove(Self.key(taskID, attachment))
    }

    /// 접어 둔다. 들고 있던 그림도 버린다
    func hide(_ taskID: String, _ attachment: AgentAttachment) {
        let key = Self.key(taskID, attachment)
        hidden.insert(key)
        drop(key)
    }

    /// 그림을 받는다. 이미 들고 있으면 그것을 준다.
    func load(_ taskID: String, _ attachment: AgentAttachment, now: Date = .now) async -> Loaded {
        let key = Self.key(taskID, attachment)
        // 맥이 지웠을 시각이 지났으면 묻지 않는다. 들고 있던 것도 버린다
        if attachment.isExpired(at: now) || gone.contains(Self.goneKey(key, attachment)) {
            drop(key)
            return .gone
        }
        if let data = images[key] { return .image(data) }
        guard let agent else { return .failed }
        do {
            let data = try await agent.attachment(taskID: taskID, id: attachment.id)
            keep(data, for: key)
            return .image(data)
        } catch AgentError.attachmentGone, AgentError.taskLost {
            // 작업 기록이 사라진 것도 그림이 사라진 것이다 (맥이 다시 시작됨)
            gone.insert(Self.goneKey(key, attachment))
            return .gone
        } catch {
            return .failed
        }
    }

    /// 들고 있던 그림을 모두 버린다 (앱이 뒤로 갈 때, 다른 대화로 갈 때). 돌아오면 화면에 보일 때 다시 받는다.
    /// 접어 둔 것은 그대로 접혀 있다 (가린 것이 저절로 다시 보이지 않게)
    func clear() {
        images = [:]
        order = []
        generation += 1
        dropVideos()
    }

    // MARK: 작업실이 만든 영상 (D112)

    enum VideoLoaded: Equatable {
        /// 재생할 수 있는 파일 (앱의 임시 폴더. 앱이 뒤로 가면 지운다)
        case file(URL)
        case gone
        case failed
    }

    /// 받아 둔 영상 파일. 재생기는 파일로 읽어야 해서 메모리가 아니라 임시 폴더에 둔다 (잠금 중에는 읽히지 않게)
    @ObservationIgnored private var videos: [String: URL] = [:]

    /// 영상을 받는다 (누를 때만). 이미 받아 두었으면 그 파일을 준다
    func video(_ taskID: String, _ attachment: AgentAttachment, now: Date = .now) async -> VideoLoaded {
        let key = Self.key(taskID, attachment)
        if attachment.isExpired(at: now) || gone.contains(Self.goneKey(key, attachment)) { return .gone }
        if let file = videos[key], FileManager.default.fileExists(atPath: file.path) { return .file(file) }
        guard let agent else { return .failed }
        do {
            let data = try await agent.video(taskID: taskID, id: attachment.id)
            let file = URL.temporaryDirectory.appending(path: "moa-video-\(UUID().uuidString).mp4")
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            videos[key] = file
            return .file(file)
        } catch AgentError.attachmentGone, AgentError.taskLost {
            gone.insert(Self.goneKey(key, attachment))
            return .gone
        } catch {
            return .failed
        }
    }

    /// 받아 둔 영상 파일을 지운다
    func dropVideos() {
        for file in videos.values { try? FileManager.default.removeItem(at: file) }
        videos = [:]
    }

    /// 받아 둔 영상 수 (테스트 확인용)
    var heldVideoCount: Int { videos.count }

    private static func goneKey(_ key: String, _ attachment: AgentAttachment) -> String {
        "\(key)@\(attachment.expiresAt ?? "")"
    }

    /// 지금 들고 있는 그림 수 (테스트 확인용)
    var heldCount: Int { images.count }

    private func keep(_ data: Data, for key: String) {
        images[key] = data
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.limit {
            images[order.removeFirst()] = nil
        }
    }

    private func drop(_ key: String) {
        images[key] = nil
        order.removeAll { $0 == key }
    }
}
