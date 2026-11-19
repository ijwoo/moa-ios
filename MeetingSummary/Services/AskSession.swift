import Foundation
import Observation
import SwiftData

/// 질문 탭의 대화.
///
/// 질문과 답은 `Conversation`/`ChatRecord`로 저장해 앱을 다시 열어도 남는다.
/// "새 대화"는 지금 대화를 기록에 남겨 두고 빈 화면에서 시작한다.
///
/// 입력창은 하나다. 맥 에이전트가 설정되어 있으면 모든 메시지를 먼저 맥의 대화 담당에게 보내고(`converse`),
/// 맥이 넷 중 하나를 고른다: 바로 답하기 / 되묻기(선택지) / 작업 만들기 / 회의 질문이라 Claude로 넘기기.
/// - 맥(local): Tailscale로 사용자의 맥에서 처리. 초안은 승인을 받아야 진행된다.
/// - Claude(cloud): 중계 서버 → Claude. 근거 카드가 붙고, 화면에 "Claude 사용"으로 표시한다.
/// 맥이 꺼져 있거나 에이전트 설정이 없으면 회의 질문(Claude)만 된다.
/// 이전 대화(history)는 Claude가 처리한 것만 Claude로 보낸다. 맥에서 만든 초안이 Claude로 가지 않게 하기 위해서다.
@MainActor
@Observable
final class AskSession {
    struct Citation: Identifiable, Hashable, Codable, Sendable {
        let id: String          // 말풍선 번호 (m1-u3)
        let meetingID: UUID
        let utteranceID: UUID?
        let meetingTitle: String
        let start: TimeInterval?
        let text: String
    }

    enum Engine: String, Equatable, Sendable { case cloud, local }

    /// 답장할 때 인용한 말. 원래 말이 지워져도 보이도록 발췌를 함께 둔다
    struct Quote: Codable, Equatable, Sendable {
        let messageID: UUID
        /// 내가 한 말을 인용했는지 (아니면 받은 답)
        let fromUser: Bool
        let text: String
        /// 맥에 맡긴 일을 인용했는지 (D59). 그때 `text`는 그 일의 제목뿐이다 (결과 내용은 인용에 넣지 않는다).
        /// 이 값이 없던 때 저장한 인용에는 없다
        var isTask: Bool?
        /// 그 일의 상품 목록에서 고른 상품의 번호 (D72). 고른 말에만 있다. 맥에는 작업 번호와 이 번호만 간다
        var itemID: String?

        static let maxLength = 100

        /// 인용 위에 붙는 이름
        var label: String { isTask == true ? "맡긴 일" : fromUser ? "내가 한 말" : "받은 답" }

        /// 줄바꿈을 한 칸으로 줄이고 길면 자른다
        static func excerpt(_ text: String) -> String {
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return flat.count > maxLength ? flat.prefix(maxLength - 1).trimmingCharacters(in: .whitespaces) + "…" : flat
        }
    }

    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, agent, error }
        var id = UUID()
        let role: Role
        let text: String
        var found = true
        var citations: [Citation] = []
        /// 오류 메시지일 때 다시 보낼 질문
        var retryQuestion: String?
        /// 다시 보낼 때 처리할 곳 (nil이면 처음처럼 맥이 정한다)
        var retryEngine: Engine?
        /// 처리한 곳. 사용자 메시지는 맥이 Claude로 넘기면 cloud로 바뀐다
        var engine: Engine = .cloud
        /// 맥이 정보가 부족해 되물은 말인지 (저장하지 않는다)
        var asksBack = false
        /// 맥이 되물으며 준 선택지 (버튼으로 보여 준다. 저장하지 않는다)
        var choices: [String] = []
        /// 맥 에이전트 작업 (role이 agent일 때)
        var agent: AgentTaskState?
        /// 오류 메시지일 때 다시 확인할 작업 (연결이 끊겨 상태를 받지 못한 경우)
        var resumeTaskID: String?
        /// 보낸 때 (답을 받지 못한 메시지를 자동으로 다시 확인할지 정할 때 쓴다)
        var date = Date.now
        /// 맥에 연결되지 않아 Claude가 대신 답한 말이면, 맥에 다시 보낼 글 (저장하지 않는다).
        /// 맥이 회의 질문이라고 판단해 넘긴 답에는 없다
        var offlineQuestion: String?
        /// 길게 눌러 붙인 반응 (이모지 하나)
        var reaction: String?
        /// 대화 담당이 내 말에 단 반응 (이모지 하나, D70). 사용자 메시지에만 붙는다.
        /// 말 없이 반응만 온 말도 이것이 있으면 답을 받은 말이다
        var agentReaction: String?
        /// 답장이면 인용한 말
        var replyTo: Quote?
        /// 맥이 로그인이 필요하다고 한 사이트 ("naver"). 이 말 아래에 로그인 화면을 여는 카드를 붙인다 (저장하지 않는다)
        var siteLogin: String?
        /// 그 로그인 안내가 "로그인이 없어서 하지 못한 부탁"에 대한 것인지, 맥이 알려 준 값 (D59. 저장하지 않는다).
        /// 맥이 알려 주지 않으면 nil이고, 그때는 앞의 말로 가린다
        var siteLoginResume: Bool?
        /// 앱에서 로그인을 마친 사이트 ("naver"). 이 말은 말풍선 대신 "로그인 완료" 카드로 보여 준다.
        /// 로그인했다는 사실만 남긴다 (아이디·비밀번호는 여기에도 기록에도 없다)
        var siteLoggedIn: String?
        /// 맥을 거친 답이면 이 말을 누가 썼는지 (맥이 알려 준 값, D62). 알려 주지 않았으면 nil
        var writer: ReplyWriter?
        /// 한 줄로 끝난 일이라 말풍선 대신 상태 줄로 보인다 (D110. 저장하지 않는다 — 다시 열면 말풍선이다)
        var isStatus = false
        /// 통화 중에 받은 답이면 소리로 읽을 글 (`replies[].speak`, D134. 저장하지 않는다)
        var speak: String?
        /// 통화 중에 받은 답이면 맥이 만들기 시작한 내 목소리의 번호 (`replies[].voice_id`, D136. 저장하지 않는다)
        var voiceID: String?
        /// 통화 중에 주고받은 말이면 그 통화의 번호 (D137). 대화에서는 통화 카드 하나로 접힌다
        var callID: UUID?
        /// 되물으며 맥이 권하는 후보 (D110. 저장하지 않는다)
        var recommended: String?
        /// 되물은 후보를 여러 개 함께 고르는지, 후보마다의 그림 (D111. 저장하지 않는다)
        var multi = false
        var choiceImages: [String: URL] = [:]
        /// 답 뒤에 이어 할 말과 그 가운데 권하는 것 (D111. 저장하지 않는다)
        var followUps: [String] = []
        var followUpRecommended: String?
        /// 날씨 카드 (D66). 이 말은 말풍선 대신 카드로 보여 준다. `text`에는 카드에 보인 내용 한 줄이 들어 있다
        var weather: WeatherCard?
        /// 맥이 "쇼핑 화면에서 같이 보자"고 한 말이면 그 검색어 (D74). 이 말 아래에 쇼핑 화면을 여는 카드를 붙인다.
        /// 검색어뿐이다: 주소는 열 때 앱이 만든다
        var shopQuery: String?
        /// 쇼핑 화면에서 "확인해 줘"를 눌러 보낸 말이면, 그때 화면에서 읽어 함께 보낸 것 (D74). 내 말 아래에 그대로 보여 준다
        var shopView: ShopView?
        /// 이 말에 붙여 보낸 사진·PDF (D85). 종류와 PDF의 파일 이름뿐이다: 그림과 파일은 `UploadStore`의 메모리에만 있다
        var uploads: SentUploads?
        /// 내 이 말이 이미 있던 작업으로 갔다 (D152. 저장하지 않는다): 말풍선 아래에 "진행 중인 작업에 전했어요"
        var steer: AgentSteer?
    }

    private(set) var messages: [Message] = []
    /// 통화 중인지 (D134). 켜져 있으면 맥에 보내는 말에 "voice_call"을 붙인다
    var voiceCall = false
    /// 지금 통화의 번호 (D137). 통화 중에 주고받은 말에 붙인다
    var callID: UUID?
    /// 통화 중에 맡긴 일의 확인 문장을 읽을 글 (작업 번호 → `replies[0].speak`, D134. 저장하지 않는다)
    private(set) var voiceAcks: [String: String] = [:]
    /// 그 확인 문장의 내 목소리 번호 (작업 번호 → `replies[0].voice_id`, D136)
    private(set) var voiceAckIDs: [String: String] = [:]
    /// 보낸 요청의 답을 기다리는 중 (메시지, 승인·거부, 질문의 답). 요청은 한 번에 하나만 보낸다.
    /// 맡긴 일이 진행되는 동안은 여기에 들지 않는다: 그동안에도 말을 걸 수 있다 (D71)
    private(set) var isLoading = false
    /// 상태를 따라가고 있는 작업과 따라가는 곳의 수 (D71).
    /// 한 작업을 두 곳에서 볼 수도 있다 (승인을 누른 쪽, 멈추기를 누른 쪽). 여러 작업을 함께 따라갈 수 있다
    private var followers: [String: Int] = [:]
    /// 다른 대화로 바뀔 때마다 올라간다 (새 대화, 기록에서 열기). 화면은 이 값이 바뀌면 스크롤 위치를 새로 잡는다.
    private(set) var epoch = 0

    /// 대화를 열 때 그리는 말의 수, 그리고 "이전 대화 보기"를 누를 때마다 더 그리는 수 (D69)
    static let page = 60
    /// 앞쪽에서 아직 그리지 않은 말의 수 (D69).
    /// 대화 화면은 그리는 말을 모두 한꺼번에 놓는다 (필요할 때 만드는 목록은 높이를 어림하다 대화가 비거나 떠 있었다).
    /// 그래서 긴 대화를 통째로 그리지 않게, 열 때는 최근 것만 그리고 나머지는 달라고 할 때 그린다. 새로 오는 말은 언제나 그린다
    private var hiddenCount = 0
    var earlierCount: Int { min(hiddenCount, messages.count) }

    /// 이전 말을 한 묶음 더 그린다
    func showEarlier() {
        hiddenCount = max(0, earlierCount - Self.page)
    }

    /// 이 말이 아직 그려지지 않았으면 거기까지(앞의 몇 마디도 같이) 그린다. 그리는 범위가 바뀌었으면 true
    @discardableResult
    func reveal(_ id: UUID) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }), index < earlierCount else { return false }
        hiddenCount = max(0, index - Self.revealLead)
        return true
    }

    /// 찾아간 말 앞에 같이 그리는 말의 수 (그 말이 화면 가운데에 올 만큼)
    static let revealLead = 10
    /// 지금 보고 있는 대화 (저장소를 붙이지 않았거나 새 대화면 nil)
    private(set) var conversation: Conversation?

    /// 맥 에이전트 연결 상태 (확인 전이면 nil)
    private(set) var agentReachable: Bool?
    /// 맥이 앱에서 메일 계정을 연결하는 것을 지원하는지 (마지막 연결 확인 기준)
    private(set) var canConnectMail = false
    /// 맥이 "답장으로 가리킨 작업"을 받는지 (`reply_to`, D59). 받지 않는 맥이면 맡긴 일에 답장을 두지 않는다
    /// (인용만 붙고 맥은 무엇을 가리키는지 모르면, 알아들은 것처럼 보이기만 한다)
    private(set) var canReplyToTask = false
    /// 맥이 상품 목록을 보내고 고른 번호를 받는지 (`report_items`, D72). 그때만 목록에 "고르기"를 둔다
    private(set) var canPickItems = false
    /// 맥의 작업이 이 아이폰의 쇼핑 화면에 검색과 상품 열기를 시킬 수 있는지 (`shop_drive`, D75). 쇼핑 화면의 안내에 쓴다
    private(set) var canDriveShop = false
    /// 맥이 사진·PDF를 받는지 (`uploads`, D85). 받을 때만 입력창에 "+"를 둔다
    private(set) var canAttach = false
    /// 결과를 돌려준(돌려주는 중인) 일. 같은 일을 두 번 하지 않는다
    private var browsedJobs: Set<String> = []
    /// 메일 계정 연결 안내에 쓰는 계정 목록 (받기 전이거나 받지 못했으면 nil)
    private(set) var mailAccounts: [MailAccount]?

    private let provider: (any AskProviding)?
    private let agent: (any AgentProviding)?
    /// 보고에 붙은 화면 캡처 (그림은 여기 메모리에만 있다. 대화 기록에 저장하지 않는다)
    let captures: CaptureStore
    /// 찾은 페이지 카드의 대표 그림 (그림은 여기 메모리에만 있다. 대화 기록에 저장하지 않는다, D64)
    let thumbnails: LinkThumbnailStore
    /// 붙인 사진·PDF (메모리에만 있다. 대화 기록에는 종류와 PDF의 파일 이름만 남는다, D85)
    let uploads = UploadStore()
    /// 예약해 둔 일 (D91). 목록과 실행 기록은 맥에 있고, 여기에는 받아 온 것만 잠깐 둔다
    let routines: RoutinesModel
    /// 오래 가는 기억 (D151): 내 정보의 "기억" 화면
    let memory: MemoryModel
    /// 활동 탭의 맥 쪽 목록 (D120)
    let activity: ActivityModel
    /// 맥에서 내 답을 기다리는 작업 (D113. 앱을 열 때 받는다). 지금 대화에 보이는 것은 `waitingElsewhere`에서 뺀다
    private(set) var waitingTasks: [AgentWaitingTask] = []
    /// 이번에 "나중에"로 접어 둔 기다리는 작업
    private var dismissedWaiting: Set<String> = []
    /// 연락처 (D89). 내 말에 이름이 나온 사람만 맥에 알린다. 가짜 맥과 함께일 때는 실제 연락처를 읽지 않는다
    private let contactBook: (any ContactReading)?
    /// 이 대화에서 맥에 알린 연락처 `{이름: 메일 주소}`. 메모리에만 있고 대화 기록에 남기지 않는다
    private var knownContacts: [String: String] = [:]
    /// 이 대화에서 알린, 메일 주소가 없는 사람의 이름 (D92)
    private var knownNoEmail: [String] = []
    /// 날씨 카드에 그릴 날씨를 받아오는 곳 (D66. 실제: Apple 날씨와 이 기기의 위치)
    private let weather: any WeatherProviding
    private let pollInterval: Duration
    /// 맥의 답을 받지 못했을 때 같은 메시지 번호로 다시 보내는 횟수 (맥이 지원할 때만).
    /// 맥은 처음 요청을 처리하는 중이면 끝날 때까지(최대 10분) 기다렸다가 같은 답을 준다
    private let maxResends: Int
    /// Claude에게 물을 때 함께 보내는 답변 말투 (맥에는 `AgentHTTPClient`가 붙인다)
    private let tone: () -> ReplyTone
    private var context: ModelContext?
    /// 끝나지 않은 작업의 상태를 다시 받는 중 (겹쳐서 받지 않게)
    private var isResuming = false
    /// 맥의 대화 담당이 준 대화 번호. 다음 메시지부터 함께 보내야 앞 대화를 기억한다
    private(set) var agentConversationID: String?

    init(
        provider: (any AskProviding)? = SummaryAPI.fromBundle(),
        agent: (any AgentProviding)? = AgentClient.fromEnvironment(),
        pollInterval: Duration = .milliseconds(1500),
        maxResends: Int = 3,
        tone: @escaping () -> ReplyTone = { ReplyTone.current() },
        weather: (any WeatherProviding)? = nil,
        contacts: (any ContactReading)? = nil
    ) {
        self.tone = tone
        self.provider = provider
        self.agent = agent
        self.captures = CaptureStore(agent: agent)
        self.routines = RoutinesModel(agent: agent)
        self.memory = MemoryModel(agent: agent)
        self.activity = ActivityModel(agent: agent)
        #if DEBUG
        // 가짜 맥의 페이지는 없는 주소다: 그림도 앱이 그린 것을 쓴다 (밖으로 나가지 않는다)
        self.thumbnails = agent is MockAgentClient ? LinkThumbnailStore(load: MockFind.thumbnail) : LinkThumbnailStore()
        #else
        self.thumbnails = LinkThumbnailStore()
        #endif
        #if DEBUG
        // 가짜 맥과 함께일 때는 날씨도 앱이 만든 가상 값을 쓴다 (위치를 묻지도, 밖으로 나가지도 않는다)
        self.weather = weather ?? (agent is MockAgentClient ? MockWeatherService.fromArguments() : nil) ?? AppleWeatherService()
        // 연락처도 같다: 가짜 맥에는 지어낸 주소록만 (`-demoContacts`). 실제 연락처는 실제 맥과 함께일 때만 읽는다
        contactBook = contacts ?? (agent is MockAgentClient ? MockContacts.fromArguments() : (agent is AgentHTTPClient ? SystemContacts() : nil))
        #else
        self.weather = weather ?? AppleWeatherService()
        contactBook = contacts ?? (agent is AgentHTTPClient ? SystemContacts() : nil)
        #endif
        self.pollInterval = pollInterval
        self.maxResends = maxResends
    }

    /// 맥 에이전트를 쓸 수 있게 설정되어 있는지 (아니면 회의 질문만 한다)
    var hasAgent: Bool { agent != nil }

    /// 지금 고를 수 있는 선택지: 맥이 방금 되물었고 아직 답하지 않았을 때
    var pendingChoices: [String] {
        guard !isLoading, let last = messages.last, last.role == .assistant else { return [] }
        return last.choices
    }

    /// 지금 고를 수 있는 선택지 가운데 맥이 권하는 것 (D110)
    var pendingRecommended: String? {
        pendingChoices.isEmpty ? nil : messages.last?.recommended
    }

    /// 지금 고를 수 있는 선택지를 여러 개 함께 고르는지, 후보마다의 그림 (D111)
    var pendingMulti: Bool { !pendingChoices.isEmpty && messages.last?.multi == true }
    var pendingChoiceImages: [String: URL] { pendingChoices.isEmpty ? [:] : messages.last?.choiceImages ?? [:] }

    /// 답 뒤에 이어 할 말 (D111): 마지막 말이 그것을 단 답이고, 아직 다른 말을 하지 않았고, "여기까지"를 누르지 않았을 때.
    /// 답변 카드의 다음 말은 끝난 작업이 마지막일 때만. 고르지 않아도 된다 (새 부탁을 막지 않는다)
    var pendingFollowUps: (choices: [String], recommended: String?)? {
        guard !isLoading, let last = messages.last, last.id != followUpsDismissed else { return nil }
        if last.role == .assistant, !last.followUps.isEmpty { return (last.followUps, last.followUpRecommended) }
        if last.role == .agent, let state = last.agent, state.phase.isFinished,
           let next = state.report?.card?.next, !next.isEmpty {
            return (next, nil)
        }
        return nil
    }

    /// "괜찮아요, 여기까지 볼게요"를 누른 답
    private(set) var followUpsDismissed: UUID?

    func dismissFollowUps() {
        followUpsDismissed = messages.last?.id
    }

    /// 승인을 기다리는 에이전트 작업이 있는지. 있으면 먼저 답해야 새 질문을 보낼 수 있다.
    var hasPendingApproval: Bool {
        messages.contains { $0.agent?.phase == .awaitingApproval }
    }

    /// 지금 사진·PDF를 붙여 보낼 수 있는지. 맥에 연결되지 않았거나, 승인·질문에 답해야 하는 동안에는 붙이지 못한다
    /// (그때 보낸 글은 새 말이 아니라 그 질문의 답이 되고, 답에는 붙인 것이 가지 않는다)
    var canAttachNow: Bool {
        canAttach && agentReachable != false && !hasPendingApproval && openQuestionTask == nil
    }

    /// 화면 위쪽 상태 한 줄
    enum Status: Equatable { case thinking, working, needsApproval, needsAnswer, sending }

    /// 작업 담당이 묻고 있고 아직 답하지 않은 작업. 있으면 다음 입력은 그 질문의 답이다 (같은 작업이 이어진다)
    var openQuestionTask: AgentTaskState? {
        messages.last(where: { $0.agent?.openQuestion != nil })?.agent
    }

    /// 지금 무엇을 기다리는지. 사용자가 답해야 하는 일이 먼저다.
    var status: Status? {
        if hasPendingApproval { return .needsApproval }
        if openQuestionTask != nil { return .needsAnswer }
        if messages.contains(where: { $0.agent?.phase == .sendPending }) { return .sending }
        if messages.contains(where: { $0.agent?.isWorking == true }) { return .working }
        if showsThinking { return .thinking }
        if pendingAgentQuestion != nil { return .needsAnswer }
        return nil
    }

    /// 지금 다른 대화로 옮겨도 되는지. 말의 답을 받는 중에만 막는다 (그 답이 옮겨 간 대화에 붙지 않게).
    /// 맥의 작업이 도는 중에는 옮겨도 된다 (D126): 작업은 맥에서 계속 돌고, 떠난 대화의 작업은 따라가기를 멈췄다가
    /// 그 대화로 돌아오면 맥에서 다시 받아 붙인다. 떠나 있는 동안은 사이드바에 "진행 중", 끝나면 안 읽음 점
    var canSwitchConversation: Bool { !isLoading }

    /// 이 작업의 상태를 지금 이 대화에서 따라가고 있는지 (앞서 떠난 대화에서 아직 멈추는 중인 따라가기는 세지 않는다)
    func isFollowing(_ taskID: String) -> Bool { followers[Self.followKey(epoch, taskID)] != nil }

    private static func followKey(_ epoch: Int, _ taskID: String) -> String { "\(epoch)#\(taskID)" }

    // MARK: 떠난 대화의 작업과 안 읽음 (D126)

    /// 떠난 대화에서 아직 돌고 있는 작업 → 그 대화 (기기의 기록 번호). 앱이 켜져 있는 동안만 기억한다
    private(set) var backgroundTasks: [String: UUID] = [:]

    /// 다른 대화에서 돌고 있는 작업 수 ("작업 중 N개")
    var workingElsewhere: Int { backgroundTasks.count }

    /// 지금 대화를 읽은 것으로 둔다
    private func markRead(_ target: Conversation?) {
        guard let target else { return }
        target.lastReadAt = .now
        try? context?.save()
    }

    /// 대화를 떠날 때: 끝나지 않은 작업을 적어 두고(사이드바의 "진행 중"), 읽은 것으로 둔다
    private func leaveConversation() {
        guard let current = conversation else { return }
        // 실제로 돌고 있는 것만 ("승인 필요 / 답 필요"는 맥이 알려 주는 기다리는 작업으로 따로 보인다)
        for task in messages.compactMap(\.agent) where task.phase == .running || task.phase == .sendPending {
            backgroundTasks[task.id] = current.id
        }
        markRead(current)
    }

    /// 떠난 대화의 작업과 맥의 활동을 살펴 안 읽음 표시를 바꾼다 (사이드바를 열 때·앱으로 돌아올 때)
    func refreshConversationNews() async {
        guard let agent else { return }
        for (taskID, conversationID) in backgroundTasks {
            guard conversationID != conversation?.id else {
                backgroundTasks[taskID] = nil
                continue
            }
            do {
                let state = try await agent.state(of: taskID)
                // 끝났거나 내 답을 기다리면 소식이다 (기다리는 것은 "승인 필요 / 답 필요"로도 보인다)
                if state.phase.isFinished || state.phase == .awaitingApproval || state.phase == .awaitingInput {
                    backgroundTasks[taskID] = nil
                    noteNews(conversationID: conversationID, at: .now)
                }
            } catch AgentError.taskLost {
                backgroundTasks[taskID] = nil
            } catch {
                // 지금 맥에 닿지 않는다: 다음에 다시 본다
            }
        }
        if !activity.hasLoaded || activity.isOffered { await activity.load() }
        noteActivity(activity.entries)
        try? context?.save()
    }

    /// 맥의 활동(끝난 작업·예약 실행)을 그 대화의 새 소식으로 적는다. 지금 보고 있는 대화는 빼고
    func noteActivity(_ entries: [ActivityEntry]) {
        guard let context else { return }
        let latest = Dictionary(entries.compactMap { entry in entry.conversationID.map { ($0, entry.at) } }, uniquingKeysWith: max)
        guard !latest.isEmpty else { return }
        let all = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        for target in all where target.id != conversation?.id {
            guard let id = target.agentConversationID, let at = latest[id], at > (target.newsAt ?? .distantPast) else { continue }
            target.newsAt = at
        }
    }

    private func noteNews(conversationID: UUID, at date: Date) {
        guard let context, conversationID != conversation?.id else { return }
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationID })
        descriptor.fetchLimit = 1
        guard let target = try? context.fetch(descriptor).first else { return }
        if date > (target.newsAt ?? .distantPast) { target.newsAt = date }
    }

    /// 이 말의 버튼을 잠시 막을지: 요청의 답을 기다리는 중이거나, 방금 한 승인·거부를 맥이 처리하는 중인 카드
    func isBusy(_ message: Message) -> Bool {
        if isLoading { return true }
        guard let task = message.agent else { return false }
        return task.phase == .awaitingApproval && isFollowing(task.id)
    }

    /// 지금은 새 부탁을 보낼 수 없는 까닭 (보낼 수 있으면 nil). "맡길 수 있는 일"의 단추를 막고 그 까닭을 보여 준다.
    /// 승인 대기·답 대기 중에 보낸 말은 무시되고, 작업 담당이 묻고 있을 때 보낸 말은 그 질문의 답이 되기 때문이다
    var requestBlocker: String? {
        if hasPendingApproval { return "대화에 있는 승인 요청에 먼저 답해 주세요." }
        if openQuestionTask != nil || pendingAgentQuestion != nil || !pendingChoices.isEmpty {
            return "대화에서 에이전트가 물어본 것에 먼저 답해 주세요."
        }
        if isLoading { return "답을 기다리는 중이에요. 끝나면 맡길 수 있어요." }
        return nil
    }

    /// 점 세 개 표시: 보낸 요청의 답을 기다릴 때, 그리고 따라가는 작업이 제 진행 표시 없이 기다릴 때
    /// (방금 한 승인·거부를 맥이 처리하는 중). 진행 중인 작업은 카드가 진행을 보여 주니 점을 두지 않는다.
    /// 작업이 진행 중이어도 내가 보낸 말의 답을 기다리는 동안에는 점이 보인다 (D71)
    var showsThinking: Bool {
        if isLoading { return true }
        return messages.contains { message in
            guard let task = message.agent, isFollowing(task.id), !task.phase.isFinished else { return false }
            return !task.isWorking && task.phase != .sendPending
        }
    }

    // MARK: - 저장소

    /// 저장소를 붙이고 가장 최근 대화를 불러온다. (화면이 처음 나타날 때 한 번)
    func attach(_ context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        var descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        if let latest = try? context.fetch(descriptor).first {
            open(latest)
        }
    }

    /// 내 말에 이름이 나온 연락처를 찾아, 이 대화에서 알린 것에 더한다 (D89).
    /// 주소록 전체는 기기 밖으로 나가지 않는다. 권한은 메일을 부탁하는 말을 처음 보낼 때 한 번 묻는다
    private func contacts(mentionedIn text: String) async -> [String: String] {
        guard let contactBook else { return knownContacts }
        switch contactBook.access() {
        case .allowed: break
        case .denied: return knownContacts
        case .notAsked:
            guard ContactMatch.looksLikeMail(text), await contactBook.request() else { return knownContacts }
        }
        let found = ContactMatch.found(in: text, people: await contactBook.people())
        for (name, address) in found.withEmail where knownContacts.count < ContactMatch.limit || knownContacts[name] != nil {
            knownContacts[name] = address
        }
        // 주소 없는 사람은 이름만 (D92). 주소 있는 쪽에 같은 이름이 있으면 뺀다
        for name in found.withoutEmail where !knownNoEmail.contains(name) && knownNoEmail.count < ContactMatch.limit {
            knownNoEmail.append(name)
        }
        knownNoEmail.removeAll { knownContacts[$0] != nil }
        return knownContacts
    }

    // MARK: - 예약이 돈 결과 (D91)

    enum RoutineOpening: Equatable {
        case opened
        /// 답을 받는 중이라 다른 대화로 옮길 수 없다
        case busy
        /// 맥에 그 기록이 없다 (맥을 다시 켜면 지워진다)
        case notFound
        /// 답도 작업도 없이 끝난 실행이다 (놓쳤거나 하지 못했다)
        case nothingToShow
        case unreachable

        /// 열지 못했을 때의 한마디 (열었으면 nil)
        var notice: String? {
            switch self {
            case .opened: nil
            case .busy: "답을 기다리는 동안에는 다른 대화로 옮길 수 없어요."
            case .notFound: "이 예약의 결과가 맥에 남아 있지 않아요. 맥 에이전트를 다시 켜면 지워져요."
            case .nothingToShow: "이 실행에는 보여 드릴 답이 없어요."
            case .unreachable: "맥에 연결되지 않아 예약의 결과를 받지 못했어요."
            }
        }
    }

    /// 알림으로 온 실행 번호(`rr_…`)의 결과를 대화로 연다
    func openRoutineRun(id: String) async -> RoutineOpening {
        guard let agent else { return .unreachable }
        guard canSwitchConversation else { return .busy }
        // 그 실행 하나만 묻는다 (D93. 기록이 많아도 최근 20건에 들지 않은 것까지 찾는다)
        let found: RoutineRun?
        do { found = try await agent.routineRun(id: id) } catch { return .unreachable }
        guard let run = found else { return .notFound }
        return await open(run)
    }

    /// 예약이 돈 결과를 대화로 연다: 그때 맥이 대신 건넨 말과 받은 답을 그대로 옮기고, 그 대화를 이어 갈 수 있게 한다.
    /// 이미 이 기기에 열어 둔 대화면 그 대화로 간다 (같은 답이 두 번 생기지 않는다)
    func open(_ run: RoutineRun) async -> RoutineOpening {
        guard let agent else { return .unreachable }
        guard canSwitchConversation else { return .busy }
        if let id = run.conversationID, let existing = storedConversation(agentConversationID: id) {
            if conversation?.id != existing.id { open(existing) }
            await resumeAgent()
            return .opened
        }
        guard run.canOpen else { return .nothingToShow }
        // 작업이 된 실행은 그 작업의 지금 상태부터 받는다. 받지 못했고 보여 줄 답도 없으면 빈 대화를 만들지 않는다
        var task: AgentTaskState?
        if let taskID = run.taskID {
            task = try? await agent.state(of: taskID)
            // 작업을 받지 못했어도 기록에 남은 결과 글이 있으면 그것을 보여 준다 (맥이 다시 켜지면 작업은 사라진다, D93)
            if task == nil, run.replies.isEmpty, run.taskResult.isEmpty { return .unreachable }
        }
        show(run, task: task)
        if task != nil { await resumeAgent() }
        return .opened
    }

    private func show(_ run: RoutineRun, task: AgentTaskState?) {
        reset()
        agentConversationID = run.conversationID
        let date = run.ranAt ?? .now
        // 그때 맥이 내 말로 건넨 것: 예약해 둔 말 (목록에 없으면 예약의 이름)
        let prompt = routines.routine(id: run.routineID)?.prompt ?? ""
        append(Message(role: .user, text: prompt.isEmpty ? run.title : prompt, engine: .local, date: date))
        for bubble in run.replies {
            append(Message(role: .assistant, text: bubble.text, engine: .local, date: date, writer: bubble.writer))
        }
        if var task {
            task.request = prompt.isEmpty ? run.title : prompt
            update(task)
        } else {
            // 작업 카드를 그릴 수 없으면 기록에 남은 결과 글을 말풍선으로 옮긴다
            for line in run.taskResult {
                append(Message(role: .assistant, text: line, engine: .local, date: date))
            }
        }
    }

    /// 작업의 알림이 왔는데 그 대화가 이 기기에 없을 때: 예약이 돌며 생긴 작업이면 그 실행을 찾아 연다
    func openRoutineRun(taskID: String) async -> RoutineOpening {
        guard let agent else { return .unreachable }
        guard canSwitchConversation else { return .busy }
        guard let runs = try? await agent.routineRuns() else { return .unreachable }
        guard let run = runs.first(where: { $0.taskID == taskID }) else { return .notFound }
        return await open(run)
    }

    /// 알림이 가리킨 작업을 대화로 연다: 그 대화가 이 기기에 없고 예약 실행도 아닐 때 (D112).
    /// 맥이 직접 만든 대화(작업실 등)의 작업이라도 승인·질문 카드를 볼 수 있게, 작업의 지금 상태를 받아 새 대화에 놓는다
    func openTask(id: String, conversationID: String?) async -> RoutineOpening {
        guard let agent else { return .unreachable }
        guard canSwitchConversation else { return .busy }
        let task: AgentTaskState
        do { task = try await agent.state(of: id) } catch AgentError.taskLost { return .notFound } catch { return .unreachable }
        reset()
        agentConversationID = conversationID
        let asked = task.request ?? task.task
        append(Message(role: .user, text: asked.isEmpty ? task.title : asked, engine: .local))
        update(task)
        await resumeAgent()
        return .opened
    }

    /// 지금 열린 대화에 이 작업이 없으면 맥에서 받아 끝에 붙인다 (D113).
    /// 맥이 같은 대화에 새 작업을 만들면(작업실이 만든 다음 작업 등) 기기에 저장된 기록에는 그 작업이 없다.
    /// 기록만 열면 승인 카드가 보이지 않아, 알림을 눌러도 승인할 수 없었다 (실기기 2026-11-17)
    @discardableResult
    func attachTask(id: String) async -> Bool {
        guard let agent else { return false }
        if let existing = messages.last(where: { $0.agent?.id == id })?.agent {
            // 끝났다고 저장된 작업이 맥에서는 아직 기다리는 중이면 맥의 지금 상태로 바꾼다 (D120: 활동·검색에서 연 기다리는 일)
            if existing.phase.isFinished, let fresh = try? await agent.state(of: id), fresh.phase != existing.phase {
                update(fresh)
            }
            await resumeAgent()
            return true
        }
        let started = epoch
        guard let task = try? await agent.state(of: id) else { return false }
        // 그 사이 다른 대화로 옮겼으면 붙이지 않는다. 그 사이 같은 작업이 붙었으면 그것을 쓴다
        guard epoch == started else { return false }
        if !messages.contains(where: { $0.agent?.id == id }) {
            let asked = task.request ?? task.task
            append(Message(role: .user, text: asked.isEmpty ? task.title : asked, engine: .local))
            update(task)
        }
        await resumeAgent()
        return true
    }

    /// 맥의 작업 하나를 그 대화에서 연다 (알림·"기다리는 작업" 줄, D113):
    /// 지금 대화의 것이면 거기에, 기기에 저장된 대화면 그 대화를 열어, 둘 다 아니면 새 대화에 놓는다.
    /// 어느 쪽이든 그 작업이 기록에 없으면 맥에서 받아 붙인다 (승인·질문 카드가 보이게)
    func openTaskInItsConversation(id: String, conversationID: String?) async -> RoutineOpening {
        guard agent != nil else { return .unreachable }
        let isHere = conversationID.map { $0 == agentConversationID } ?? false
        if isHere || messages.contains(where: { $0.agent?.id == id }) {
            return await attachTask(id: id) ? .opened : .unreachable
        }
        guard canSwitchConversation else { return .busy }
        if let conversationID, let stored = storedConversation(agentConversationID: conversationID) {
            open(stored)
            return await attachTask(id: id) ? .opened : .unreachable
        }
        return await openTask(id: id, conversationID: conversationID)
    }

    // MARK: 기다리는 작업 (D113)

    /// 맥에서 내 답을 기다리는 작업을 받는다 (앱을 열 때). 받지 못하면 예전 목록을 둔다
    func checkWaitingTasks() async {
        guard let agent, let fresh = try? await agent.waitingTasks() else { return }
        waitingTasks = fresh
        dismissedWaiting.formIntersection(fresh.map(\.id))
    }

    /// 지금 대화에 카드로 보이지 않는, 기다리는 작업 (접어 둔 것은 뺀다)
    var waitingElsewhere: [AgentWaitingTask] {
        waitingTasks.filter { task in
            !dismissedWaiting.contains(task.id) && !messages.contains { message in
                guard let agent = message.agent, agent.id == task.id else { return false }
                return agent.phase == .awaitingApproval || agent.phase == .awaitingInput
            }
        }
    }

    func dismissWaiting() {
        dismissedWaiting.formUnion(waitingElsewhere.map(\.id))
    }

    /// 기다리는 작업을 그 대화에서 연다
    func openWaiting(_ task: AgentWaitingTask) async -> RoutineOpening {
        let result = await openTaskInItsConversation(id: task.id, conversationID: task.conversationID)
        if result == .opened || result == .notFound { waitingTasks.removeAll { $0.id == task.id } }
        return result
    }

    private func storedConversation(agentConversationID id: String) -> Conversation? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.agentConversationID == id }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// 기록에서 대화를 연다.
    func open(_ conversation: Conversation) {
        leaveConversation()
        // 이 대화의 작업은 다시 이 대화에서 따라간다
        backgroundTasks = backgroundTasks.filter { $0.value != conversation.id }
        markRead(conversation)
        self.conversation = conversation
        agentConversationID = conversation.agentConversationID
        messages = conversation.sortedRecords.map(Self.message(from:))
        hiddenCount = max(0, messages.count - Self.page)
        captures.clear()
        thumbnails.clear()
        uploads.clear()
        knownContacts = [:]
        knownNoEmail = []
        epoch += 1
    }

    /// 새 대화: 지금 대화는 기록에 남는다.
    func reset() {
        leaveConversation()
        conversation = nil
        agentConversationID = nil
        messages = []
        hiddenCount = 0
        captures.clear()
        thumbnails.clear()
        uploads.clear()
        knownContacts = [:]
        knownNoEmail = []
        epoch += 1
    }

    /// 기록에서 대화를 지운다. 지금 보고 있는 대화면 화면도 비운다.
    func delete(_ target: Conversation) {
        if conversation?.id == target.id { reset() }
        context?.delete(target)
        try? context?.save()
    }

    // MARK: - 통화 (D134)

    #if DEBUG
    /// 화면 확인용 (`-demoCallFold`): 지난 통화 하나를 지어내 넣는다 (6분 전, 마디 6개)
    func insertDemoCall() {
        let lines: [(Message.Role, String)] = [
            (.user, "내일 오전 열한 시에 회의 알림 하나 맞춰 줘"),
            (.assistant, "네, 내일 오전 11시에 알려 드릴게요."),
            (.user, "그리고 이번 주 할 일도 알려 줘"),
            (.assistant, "이번 주 할 일은 3개예요. 자세한 건 화면의 카드에 있어요."),
            (.user, "고마워"),
            (.assistant, "네, 오늘도 고생 많으셨어요!"),
        ]
        voiceCall = true
        callID = UUID()
        for (index, line) in lines.enumerated() {
            var message = Message(role: line.0, text: line.1, engine: .local)
            message.date = Date.now.addingTimeInterval(-360 + Double(index) * 45)
            append(message)
        }
        voiceCall = false
        callID = nil
    }
    #endif

    /// 통화 답을 내 목소리로 만들어 주는 맥 (`voice_tts`, D136). 없으면 nil
    func voiceSource() async -> (any AgentProviding)? {
        guard let agent, await agent.supports(AgentFeature.voiceTTS) else { return nil }
        return agent
    }

    /// 연결된 맥이 통화를 받는지 (`voice_call`)
    func supportsVoiceCall() async -> Bool {
        guard let agent else { return false }
        return await agent.supports(AgentFeature.voiceCall)
    }

    // MARK: - 질문

    /// 메시지를 보내고 답을 받는다. 자료는 메시지마다 새로 고른다.
    /// `engine`: nil이면 자동(맥이 있으면 맥의 대화 담당이 정하고, 없으면 Claude). 값을 주면 그곳으로 바로 보낸다.
    /// `replyTo`: 답장이면 인용한 말. 말풍선에 붙고, Claude에게는 인용과 함께 간다 (맥이 처리한 말은 빼고).
    /// 맥에는 아직 인용을 보내지 않는다 (형식을 맞추기 전).
    /// `uploads`: 이 말에 붙인 사진·PDF (D85). 맥의 대화 담당에게만 간다. 붙인 것이 있으면 글은 없어도 된다
    func send(
        _ question: String, meetings: [Meeting], engine: Engine? = nil, replyTo: Quote? = nil, view: ShopView? = nil,
        uploads attached: [ChatUpload] = []
    ) async {
        var question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = Array(attached.prefix(UploadPrep.maxCount))
        // 붙인 것은 맥을 거쳐서만 간다 (회의 질문의 길로는 보내지 않는다)
        guard attached.isEmpty || (agent != nil && engine == nil) else { return }
        // 글 없이 붙인 것만 보낸 말: 대화에는 "사진 1장" 같은 한 줄로 남기고, 맥에는 빈 글을 보낸다
        let textless = question.isEmpty && !attached.isEmpty
        if textless { question = SentUploads.caption(attached) }
        guard !question.isEmpty, !isLoading, !hasPendingApproval else { return }

        // 붙인 것을 보내다 실패한 말을 다시 보내는 것인지 (그 말은 질문의 답이 아니라 붙인 것과 함께 가는 새 말이다)
        let unanswered = messages.last(where: { $0.role != .error })
        let resendsUploads = unanswered?.role == .user && unanswered?.text == question && unanswered?.uploads != nil
        // 작업 담당이 묻고 있으면 이 글은 그 질문의 답이다. 새 메시지로 보내지 않는다 (맥은 메시지를 답으로 전달하지 않는다)
        if engine == nil, view == nil, attached.isEmpty, !resendsUploads, let asking = openQuestionTask {
            await answer(asking.id, with: question)
            return
        }

        // 같은 질문을 다시 보내는 경우 이전 오류 메시지는 지운다 (작업 소식의 오류가 그 뒤에 붙었을 수도 있다)
        while messages.last?.role == .error { messages.removeLast() }
        // 자동이면 일단 맥으로 보낸 것으로 두고, 맥이 Claude로 넘기면 그때 바꾼다
        let route = engine ?? (agent == nil ? .cloud : .local)
        // 반응만 받은 말은 이미 답을 받은 말이다: 같은 글을 또 보내면 새 말이다 ("ㅇㅋ" 다음의 "ㅇㅋ")
        // 화면을 읽어 보내는 말은 언제나 새 말이다 (같은 글이라도 그 사이 화면이 바뀌었을 수 있다)
        // 붙인 것이 있는 말도 언제나 새 말이다 (같은 글에 다른 사진을 붙였을 수 있다)
        let isRepeat = messages.last?.role == .user && messages.last?.text == question && view == nil && attached.isEmpty
            && (engine == nil || messages.last?.engine == route) && messages.last?.agentReaction == nil
        if !isRepeat {
            append(Message(
                role: .user, text: question, engine: route, replyTo: replyTo, shopView: view,
                uploads: attached.isEmpty ? nil : SentUploads(items: attached, textless: textless)
            ))
        }

        switch engine {
        case .cloud?: await askCloud(question, meetings: meetings)
        case .local?: await runAgent(question, meetings: meetings, retryEngine: .local)
        case nil:
            if agent == nil {
                await askCloud(question, meetings: meetings)
            } else {
                await converse(question, meetings: meetings)
            }
        }
    }

    /// 회의 질문: 중계 서버 → Claude. 근거 카드가 붙는다.
    /// `offline`: 맥에 연결되지 않아 대신 묻는 것인지. 답에 표시해 두었다가 연결이 돌아오면 맥에 다시 보낼 수 있게 한다
    private func askCloud(_ question: String, meetings: [Meeting], offline: Bool = false) async {
        let sources = AskContextBuilder.sources(from: meetings)
        guard !sources.isEmpty else {
            append(Message(role: .assistant, text: "아직 받아쓴 회의가 없습니다. 먼저 회의를 녹음해 주세요.", found: false))
            return
        }
        guard let provider else {
            messages.append(Message(role: .error, text: SummaryAPIError.notConfigured.localizedDescription, retryQuestion: question, retryEngine: .cloud))
            return
        }

        let context = AskContextBuilder.build(question: question, history: history(for: .cloud), sources: sources)
        let titles = Dictionary(meetings.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })

        isLoading = true
        defer { isLoading = false }
        do {
            var request = context.request
            request.question = Self.questionWithQuote(question, quote: cloudQuote(for: question))
            request.tone = tone().rawValue
            let answer = try await Self.askWithRetry(provider, request)
            let citations: [Citation] = answer.citations.compactMap { ref in
                // 요청에 없던 번호는 무시한다 (서버도 거르지만 한 번 더)
                guard let reference = context.references[ref] else { return nil }
                return Citation(
                    id: ref, meetingID: reference.meetingID, utteranceID: reference.utteranceID,
                    meetingTitle: titles[reference.meetingID] ?? "회의", start: reference.start, text: reference.text
                )
            }
            append(Message(
                role: .assistant, text: answer.answer, found: answer.found, citations: citations,
                offlineQuestion: offline ? question : nil
            ))
        } catch {
            // 오류는 저장하지 않는다 (다시 시도하면 사라진다)
            // 맥이 이미 Claude로 넘긴 질문이면 다시 시도할 때 맥에 또 묻지 않는다
            messages.append(Message(role: .error, text: error.localizedDescription, retryQuestion: question, retryEngine: .cloud))
        }
    }

    // MARK: - 답장·반응

    /// 답장할 말의 인용을 만든다. 질문과 답변, 그리고 (맥이 받을 때만) 맥에 맡긴 일을 인용할 수 있다.
    /// 맡긴 일은 제목만 인용한다: 결과(사이트에서 읽은 내용 등)는 인용에도, 저장되는 답장에도 들어가지 않는다
    func quote(for id: Message.ID) -> Quote? {
        guard let message = messages.first(where: { $0.id == id }) else { return nil }
        if message.role == .agent {
            guard canReplyToTask, let state = message.agent, !state.title.isEmpty else { return nil }
            return Quote(messageID: id, fromUser: false, text: Quote.excerpt(state.title), isTask: true)
        }
        guard message.role == .user || message.role == .assistant, !message.text.isEmpty else { return nil }
        return Quote(messageID: id, fromUser: message.role == .user, text: Quote.excerpt(message.text))
    }

    // MARK: - 상품 고르기 (D72)

    /// 목록에 "고르기"를 둘지: 맥이 상품 목록과 답장으로 가리킨 작업을 모두 알 때
    var showsItemPick: Bool { canPickItems && canReplyToTask }

    /// 지금 고를 수 있는지. 보낸 말의 답을 기다리거나, 승인·질문에 답해야 하는 동안에는 고르지 못한다
    /// (그때 보낸 글은 새 말이 아니라 그 질문의 답이 된다)
    var canPickItemNow: Bool {
        showsItemPick && !isLoading && !hasPendingApproval && openQuestionTask == nil && pendingAgentQuestion == nil
    }

    /// 고를 때 보내는 말. 상품 이름은 받은 그대로 넣는다 (맥은 글이 아니라 번호로 집는다)
    nonisolated static func pickText(_ item: AgentItem) -> String { "이걸로 할게요: \(item.title)" }

    /// 상품 목록에서 하나를 고른다: 그 일에 답장하는 말로 보내고, 맥에는 작업 번호와 상품 번호가 함께 간다.
    /// 여기서는 고르기만 한다 (담거나 주문하는 것은 맥이 승인을 따로 받는 일이다)
    func pick(_ item: AgentItem, from taskID: String, meetings: [Meeting]) async {
        guard canPickItemNow, let message = messages.last(where: { $0.role == .agent && $0.agent?.id == taskID }),
              message.agent?.report?.items?.contains(item) == true, var quote = quote(for: message.id) else { return }
        quote.itemID = item.id
        await send(Self.pickText(item), meetings: meetings, replyTo: quote)
    }

    // MARK: - 쇼핑 화면 (D74)

    /// 쇼핑 화면에서 "확인해 줘"를 누를 때 보내는 말
    nonisolated static let shopCheckText = "이 화면 확인해 줘"

    /// 지금 화면을 확인해 달라고 할 수 있는지. 보낸 말의 답을 기다리거나, 승인·질문에 답해야 하는 동안에는 못 한다
    /// (그때 보낸 글은 새 말이 아니라 그 질문의 답이 된다)
    var canCheckShopNow: Bool {
        agent != nil && !isLoading && !hasPendingApproval && openQuestionTask == nil && pendingAgentQuestion == nil
    }

    /// 쇼핑 화면에서 읽은 것을 맥에 보내고 답을 받는다. 내가 버튼을 눌렀을 때만 불린다.
    /// 읽은 것은 내 말에 붙어 그대로 보이고, 맥에는 그 말과 함께 간다 (맥이 쇼핑 화면을 알 때만). 보내지 못했으면 false
    @discardableResult
    func checkShop(_ view: ShopView, meetings: [Meeting]) async -> Bool {
        guard canCheckShopNow, let agent, await agent.supports(AgentFeature.shopView), canCheckShopNow else { return false }
        await send(Self.shopCheckText, meetings: meetings, view: view)
        return true
    }

    /// 이 화면을 읽어 보낸 내 말 (가장 최근 것). `count`를 주면 대화의 그 자리 뒤에 생긴 말에서만 찾는다
    func shopCheck(of view: ShopView, after count: Int = 0) -> Message? {
        messages.dropFirst(count).last { $0.role == .user && $0.shopView == view }
    }

    /// 이 말과 함께 보낼 화면 (쇼핑 화면에서 "확인해 줘"를 눌러 보낸 말일 때만)
    private func shopView(for question: String) -> ShopView? {
        messages.last(where: { $0.role == .user && $0.text == question })?.shopView
    }

    /// 이 말에 붙여 보낸 것 (D85)
    private func sentUploads(for question: String) -> SentUploads? {
        messages.last(where: { $0.role == .user && $0.text == question })?.uploads
    }

    /// 붙인 것을 맥에 올리고 번호를 받는다. 이미 올린 것은 다시 올리지 않는다 (다시 시도할 때).
    /// 실패하면 보여 줄 말과, 다시 시도할 수 있는지를 준다. 취소됐으면 nil
    private func upload(_ items: [ChatUpload], with agent: any AgentProviding) async -> Result<[String], UploadFailure>? {
        var ids: [String] = []
        for item in items {
            if let remote = uploads.remoteID(for: item.id) {
                ids.append(remote)
                continue
            }
            // 앱을 다시 켰거나 오래 지나 이 기기에 남아 있지 않다: 붙인 것 없이 보내지 않고, 다시 붙여 달라고 한다
            guard let data = uploads.bytes(for: item.id) else {
                return .failure(UploadFailure(text: "붙인 것이 이 기기에 남아 있지 않아요. 다시 붙여서 보내 주세요.", retries: false))
            }
            uploads.setUploading(item.id, true)
            defer { uploads.setUploading(item.id, false) }
            do {
                let remote = try await BackgroundGrace.run("agent-upload") { try await agent.upload(data, name: item.name) }
                uploads.setRemote(remote, for: item.id)
                ids.append(remote)
            } catch {
                if error is CancellationError { return nil }
                if error as? AgentError == .unreachable { agentReachable = await agent.isReachable() }
                switch error as? AgentError {
                case .unreachable?, .slow?:
                    return .failure(UploadFailure(text: "붙인 것을 맥에 보내지 못했어요. 연결을 확인하고 다시 시도해 주세요.", retries: true))
                case .uploadUnsupported?, .uploadTooLarge?:
                    return .failure(UploadFailure(text: error.localizedDescription, retries: false))
                default:
                    return .failure(UploadFailure(text: "붙인 것을 맥에 보내지 못했어요. (\(error.localizedDescription))", retries: true))
                }
            }
        }
        return .success(ids)
    }

    private struct UploadFailure: Error {
        let text: String
        let retries: Bool
    }

    /// 이 말 뒤에 온 답들 (다음 내 말 전까지). 쇼핑 화면이 그 자리에서 답을 보여 줄 때 쓴다
    func answers(after id: Message.ID) -> [Message] {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return [] }
        return Array(messages[(index + 1)...].prefix { $0.role != .user })
    }

    // MARK: - 쇼핑 화면: 스스로 찾아 오기 (D75)

    /// 맥의 작업이 이 아이폰의 쇼핑 화면에 시킨 일 하나
    struct BrowseJob: Equatable, Identifiable {
        let taskID: String
        let command: AgentBrowse
        var id: String { "\(taskID)/\(command.id)" }
    }

    /// 지금 해야 할 일: 따라가고 있는 진행 중인 작업이 시켰고, 아직 결과를 돌려주지 않은 것. 쇼핑 화면이 이것을 보고 움직인다
    var browseJob: BrowseJob? {
        for message in messages {
            guard let state = message.agent, state.phase == .running, let command = state.browse else { continue }
            let job = BrowseJob(taskID: state.id, command: command)
            if !browsedJobs.contains(job.id), isFollowing(state.id) { return job }
        }
        return nil
    }

    /// 쇼핑 화면을 쓰고 있는 진행 중인 작업 (시킨 일을 하는 중이거나, 맥이 다음 일을 정하는 중). 그동안 쇼핑 화면은 "찾는 중"으로 보인다
    var browsingTaskID: String? {
        messages.first { $0.agent?.phase == .running && $0.agent?.usedShop == true }?.agent?.id
    }

    /// 이 작업이 어떻게 끝났는지 (쇼핑 화면이 닫을지 정할 때 쓴다)
    func phase(of taskID: String) -> AgentTaskState.Phase? {
        messages.first { $0.agent?.id == taskID }?.agent?.phase
    }

    /// 시킨 일의 결과를 맥에 돌려준다. 같은 작업이 이어진다 (다음 일을 시키거나 끝낸다)
    func finishBrowse(_ job: BrowseJob, result: BrowseResult) async {
        guard let agent, !browsedJobs.contains(job.id) else { return }
        // 먼저 "돌려준 일"로 적는다 (보내는 사이에 같은 일을 다시 시작하지 않게)
        browsedJobs.insert(job.id)
        let started = epoch
        var failures = 0
        while true {
            do {
                let state = try await BackgroundGrace.run("agent-browse") {
                    try await agent.browsed(job.taskID, result: result)
                }
                guard epoch == started else { return }
                // 멈추기를 눌러 이미 끝난 작업이면 그대로 둔다
                if let current = messages.first(where: { $0.agent?.id == job.taskID })?.agent, current.phase.isFinished { return }
                update(state)
                return
            } catch AgentError.unreachable where failures < 3 {
                failures += 1
                try? await Task.sleep(for: pollInterval)
            } catch AgentError.conflict {
                // 맥이 이미 다른 단계로 넘어갔다 (작업이 끝났거나 취소됐다). 따라가는 조회가 지금 상태를 받아 온다
                return
            } catch {
                // 전달하지 못했다: 다시 따라가기 시작하면 같은 결과를 다시 보낸다 (화면은 다시 열지 않는다)
                browsedJobs.remove(job.id)
                guard epoch == started else { return }
                await handle(error, question: nil, agent: agent, taskID: job.taskID)
                return
            }
        }
    }

    /// 이 말이 고른 상품의 번호 (상품 목록에서 골랐을 때만)
    private func replyItemID(for question: String) -> String? {
        messages.last(where: { $0.role == .user && $0.text == question })?.replyTo?.itemID
    }

    /// 이 말이 답장으로 가리킨 작업의 번호 (맥에 맡긴 일에 답장했을 때만).
    /// 맥에는 번호만 간다. 맥은 그 대화의 작업일 때만 쓰고, 모르는 번호는 무시한다
    private func replyTaskID(for question: String) -> String? {
        guard let quote = messages.last(where: { $0.role == .user && $0.text == question })?.replyTo else { return nil }
        return messages.first(where: { $0.id == quote.messageID })?.agent?.id
    }

    /// 이 말이 답장으로 가리킨 말풍선 (작업이 아닌 내 말이나 비서의 말일 때만, D124).
    /// 맥이 그 말을 알아야 답장의 뜻을 안다 — 인용에 보이는 앞부분이 아니라 그 말풍선의 글을 500자까지 보낸다
    private func replyQuote(for question: String) -> MessageExtras.ReplyQuote? {
        guard let quote = messages.last(where: { $0.role == .user && $0.text == question })?.replyTo, quote.isTask != true,
              let source = messages.first(where: { $0.id == quote.messageID }), source.agent == nil else { return nil }
        switch source.role {
        case .user: return MessageExtras.ReplyQuote(text: source.text, role: .user)
        case .assistant: return MessageExtras.ReplyQuote(text: source.text, role: .assistant)
        case .agent, .error: return nil
        }
    }

    /// 반응을 붙인다. 같은 반응을 다시 고르면 뗀다. 기기에만 남고 어디에도 보내지 않는다.
    /// 저장된 기록의 반응만 고친다 (대화 순서나 "최근 대화" 시각은 건드리지 않는다)
    func react(_ id: Message.ID, with emoji: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == .user || messages[index].role == .assistant else { return }
        messages[index].reaction = messages[index].reaction == emoji ? nil : emoji
        if let record = conversation?.records.first(where: { $0.id == id }) {
            record.reaction = messages[index].reaction
            try? context?.save()
        }
    }

    /// Claude에게 함께 보낼 인용. 맥이 처리한 말은 인용이라도 Claude로 보내지 않는다 (이전 대화와 같은 규칙)
    private func cloudQuote(for question: String) -> Quote? {
        guard let quote = messages.last(where: { $0.role == .user && $0.text == question })?.replyTo,
              let source = messages.first(where: { $0.id == quote.messageID }),
              source.engine == .cloud, source.role != .agent else { return nil }
        return quote
    }

    /// 인용을 질문 앞에 붙인다. 중계 서버의 질문 길이 제한(500자)을 넘으면 붙이지 않는다
    nonisolated static func questionWithQuote(_ question: String, quote: Quote?) -> String {
        guard let quote else { return question }
        let who = quote.fromUser ? "내가 앞에서 한 말" : "앞에서 받은 답"
        let combined = "(\(who) \"\(quote.text)\"에 대한 답장) \(question)"
        return combined.count <= 500 ? combined : question
    }

    // MARK: - 맥의 대화 담당 (입력창 하나)

    /// 모든 메시지를 먼저 맥의 대화 담당에게 보낸다. 맥이 답하거나, 되묻거나, 작업을 만들거나, 회의 질문이면 Claude로 넘긴다.
    private func converse(_ question: String, meetings: [Meeting]) async {
        guard let agent else { return }
        // 붙여 보낸 말 (D85): 붙인 것은 대화 담당에게만 간다
        let sent = sentUploads(for: question)
        // 작업 담당이 정보가 부족해 되물은 상태면, 원래 부탁과 답을 묶어 다시 맡긴다
        if sent == nil, let previous = messages.dropLast().last, previous.role == .agent, previous.agent?.phase == .needsInput {
            await runAgent(question, meetings: meetings, retryEngine: nil)
            return
        }

        isLoading = true
        // 작업이 만들어지면 답은 받은 것이다: 그 뒤로는 이 함수가 작업을 따라가는 동안 다른 요청이 나갈 수 있으니,
        // 끝날 때 남의 요청 표시를 끄지 않게 한다 (D71)
        var awaitsReply = true
        defer { if awaitsReply { isLoading = false } }
        // 맥이 꺼져 있으면 회의 질문으로 처리한다 (화면에는 "회의 질문만 가능" 안내가 뜨고, 답에 대신 답했다고 표시한다)
        guard await confirmReachable(agent) else {
            agentReachable = false
            // 화면을 읽어 보내는 말은 맥만 답할 수 있다: 회의 질문으로 넘기지 않는다 (읽은 것은 Claude 경로로 가지 않는다)
            if shopView(for: question) != nil {
                messages.append(Message(
                    role: .error, text: "맥에 연결되지 않아 화면을 확인하지 못했어요.", retryQuestion: question, engine: .local
                ))
                agentReachable = await agent.isReachable()
                return
            }
            // 붙인 것도 맥만 받는다: 회의 질문으로 넘기지 않는다 (붙인 것은 앱의 중계 서버로 가지 않는다)
            if sent != nil {
                messages.append(Message(
                    role: .error, text: "맥에 연결되지 않아 붙인 것을 보내지 못했어요.", retryQuestion: question, engine: .local
                ))
                agentReachable = await agent.isReachable()
                return
            }
            await handOverToCloud(question, meetings: meetings, offline: true)
            // 잠깐 끊긴 것이었으면 바로 알 수 있게 한 번 더 확인한다 (돌아왔으면 답 아래에 "맥에 다시 보내기"가 나온다)
            agentReachable = await agent.isReachable()
            return
        }
        agentReachable = true

        // 메시지 번호: 답을 받지 못해 다시 보낼 때 같은 번호를 쓴다. 맥은 같은 번호를 새로 판단하지 않고 처음 결과를 돌려준다
        // (이 번호가 없던 때에는 다시 보낸 메시지가 작업을 하나 더 만들어, 보이지 않는 앞 작업 뒤에서 기다렸다)
        let messageID = messages.last(where: { $0.role == .user && $0.text == question })?.id.uuidString
        // 붙인 것을 먼저 맥에 올리고, 받은 번호를 이 말에 붙여 보낸다 (D85)
        var uploadIDs: [String] = []
        if let sent {
            guard await agent.supports(AgentFeature.uploads) else {
                messages.append(Message(role: .error, text: "지금 연결된 맥은 사진과 파일을 받지 못해요.", engine: .local))
                return
            }
            switch await upload(sent.items, with: agent) {
            case .success(let ids)?: uploadIDs = ids
            case .failure(let failure)?:
                messages.append(Message(
                    role: .error, text: failure.text, retryQuestion: failure.retries ? question : nil, engine: .local
                ))
                return
            case nil: return
            }
        }
        // 글 없이 붙인 것만 보낸 말에는 회의 자료를 붙이지 않는다 ("사진 1장"은 내가 쓴 글이 아니다)
        let context = sent?.textless == true ? nil : agentContext(for: question, meetings: meetings)
        let replyTaskID = replyTaskID(for: question)
        // 날씨 카드 (D66): 맥이 알 때만, 앱이 카드를 그릴 수 있다는 것과 지난 말 뒤로 보여 준 카드의 내용을 함께 보낸다.
        // 보여 준 내용은 메시지 번호가 갈 때만 보낸다 (번호가 없으면 다시 보낸 요청에서 맥이 같은 내용을 두 번 적는다)
        var extras = MessageExtras.none
        if await agent.supports(AgentFeature.weatherAction) {
            extras.clientFeatures = [MessageExtras.weatherFeature]
            if messageID != nil, await agent.supports(AgentFeature.messageReplay) {
                extras.weatherEvents = messages.compactMap { $0.weather }.filter { !$0.reported }
                    .suffix(MessageExtras.eventLimit).map(\.summary)
            }
        }
        // 반응 (D70): 맥이 알 때만, 앱이 내 말에 붙는 반응을 그릴 수 있다고 알린다. 그러면 말 없이 반응만 올 수도 있다
        if await agent.supports(AgentFeature.reaction) {
            extras.clientFeatures.append(MessageExtras.reactionFeature)
        }
        // 고른 상품 (D72): 맥이 상품 목록을 알 때만, 가리킨 작업의 번호와 함께 상품 번호를 보낸다
        if replyTaskID != nil, await agent.supports(AgentFeature.reportItems) {
            extras.replyItemID = replyItemID(for: question)
        }
        // 말풍선에 답장 (D124): 작업이 아니면 그 말풍선의 글과 누구의 말인지 (맥이 `reply_to`를 알 때만 실제로 간다)
        if replyTaskID == nil { extras.replyQuote = replyQuote(for: question) }
        // 쇼핑 화면 (D74): 맥이 알 때만, 앱이 쇼핑 화면을 열 수 있다고 알린다.
        // 읽은 화면은 "확인해 줘"를 눌러 보낸 그 말에만 붙는다 (답을 못 받아 다시 보낼 때도 같은 것이 간다)
        if await agent.supports(AgentFeature.shopView) {
            extras.clientFeatures.append(MessageExtras.shopFeature)
            extras.view = shopView(for: question)
            // 스스로 찾아 오기 (D75): 맥이 알 때만, 맥의 작업이 시키는 대로 쇼핑 화면을 옮기고 읽어 줄 수 있다고 알린다
            if await agent.supports(AgentFeature.shopDrive) {
                extras.clientFeatures.append(MessageExtras.shopDriveFeature)
            }
        }
        extras.uploads = uploadIDs
        // 통화 중인 말 (D134, 맥의 D116): 맥이 귀로 듣는 말투로 답하고, 말풍선마다 읽을 글을 붙인다
        if voiceCall, await agent.supports(AgentFeature.voiceCall) {
            extras.clientFeatures.append(MessageExtras.voiceCallFeature)
        }
        // 연락처 (D89): 내 말에 이름이 나온 사람만. 글 없이 붙인 것만 보낸 말에서는 찾지 않는다
        extras.contacts = sent?.textless == true ? knownContacts : await contacts(mentionedIn: question)
        extras.contactsNoEmail = knownNoEmail
        var reply: AgentReply
        var resends = 0
        while true {
            do {
                reply = try await BackgroundGrace.run("agent-message") {
                    try await agent.message(
                        sent?.textless == true ? "" : String(question.prefix(AgentHTTPClient.messageLimit)),
                        conversationID: agentConversationID, context: context,
                        messageID: messageID, replyTaskID: replyTaskID, extras: extras
                    )
                }
                break
            } catch {
                if error is CancellationError { return }
                // 답을 받지 못한 경우(늦음, 연결 끊김 — 앱이 뒤로 가 있던 동안 포함): 맥이 지원하면 같은 번호로 다시 받는다
                let lost = error as? AgentError == .slow || error as? AgentError == .unreachable
                if lost, messageID != nil, resends < maxResends, await canResend(after: error, agent: agent) {
                    resends += 1
                    continue
                }
                if error as? AgentError == .unreachable { agentReachable = await agent.isReachable() }
                messages.append(Message(role: .error, text: error.localizedDescription, retryQuestion: question, engine: .local))
                return
            }
        }
        remember(conversationID: reply.conversationID)
        // 이 말로 예약이 바뀌었으면 바뀐 뒤의 목록이 붙어 온다 (D91): 예약 화면이 바로 따라온다
        if let changed = reply.routines { routines.replace(with: changed) }
        // 맥이 받았다: 올릴 바이트는 더 들고 있지 않는다 (대화에 보이는 작은 그림만 남는다)
        if let sent { uploads.release(sent.items.map(\.id)) }
        // 맥이 받았다: 보여 준 카드는 한 번만 알린다 (보낸 3개보다 오래된 것은 지난 일이라 알리지 않고 닫는다)
        if !extras.weatherEvents.isEmpty { markWeatherReported() }
        // 반응은 답보다 먼저 내 말에 붙인다 (무엇으로 답했든: 말, 날씨 카드, 작업)
        if extras.acceptsReaction, let reaction = AgentReaction.known(reply.reaction) {
            attach(reaction, toMessage: messageID)
        }
        // 끼어들기 (D152): 내 말이 어느 작업으로 갔는지 내 말풍선에 붙인다
        if let steer = reply.steer {
            if let index = messages.lastIndex(where: { $0.role == .user && $0.id.uuidString == messageID }) {
                messages[index].steer = steer
            }
            // 거둔 앞 작업은 승인 대기라 따라가고 있지 않을 수 있다: 지금 상태를 받아 카드를 맞춘다 (거둔 승인을 누르지 않게)
            if steer.mode == .replace, messages.contains(where: { $0.agent?.id == steer.taskID }) {
                let id = steer.taskID
                Task { if let state = try? await agent.state(of: id) { self.update(state) } }
            }
        }

        switch reply.action {
        case .none:
            for (index, text) in reply.replies.enumerated() {
                var message = Message(role: .assistant, text: text, engine: .local, writer: reply.writer(at: index))
                message.isStatus = reply.isStatus(at: index)
                message.speak = reply.speak(at: index)
                message.voiceID = reply.voiceID(at: index)
                // 다음 말은 마지막 말에 단다 (D111)
                if index == reply.replies.count - 1 {
                    message.followUps = reply.next
                    message.followUpRecommended = reply.nextRecommended
                }
                append(message)
            }
        case .weather(let place, let when):
            // 맥은 "날씨를 물었다, 어디·언제"만 정했다. 날씨는 이 기기가 받아 카드로 그린다 (이 기기의 위치는 맥으로 가지 않는다)
            for (index, text) in reply.replies.enumerated() {
                var message = Message(role: .assistant, text: text, engine: .local, writer: reply.writer(at: index))
                message.speak = reply.speak(at: index)
                message.voiceID = reply.voiceID(at: index)
                append(message)
            }
            let card = WeatherCard.make(asked: place, when: when, result: await weather.weather(place: place))
            append(Message(role: .assistant, text: card.summary, engine: .local, weather: card))
        case .ask(let choices):
            for (index, text) in reply.replies.enumerated() {
                let isLast = index == reply.replies.count - 1
                var message = Message(
                    role: .assistant, text: text, engine: .local, asksBack: true, choices: isLast ? choices : [],
                    writer: reply.writer(at: index)
                )
                message.speak = reply.speak(at: index)
                message.voiceID = reply.voiceID(at: index)
                if isLast {
                    message.recommended = reply.recommended
                    message.multi = reply.multi
                    message.choiceImages = reply.choiceImages
                }
                append(message)
            }
        case .task(var state):
            state.request = requestText(endingWith: question)
            // 확인 문장은 맥이 준 첫 말이다. 그 말을 누가 썼는지도 작업에 같이 둔다
            state.ackBy = reply.replies.isEmpty ? nil : reply.writer(at: 0)?.rawValue
            if let speak = reply.speak(at: 0) { voiceAcks[state.id] = speak }
            if let voice = reply.voiceID(at: 0) { voiceAckIDs[state.id] = voice }
            update(state, ack: reply.replies.first ?? "네, 바로 준비할게요.")
            // 맡긴 일은 따로 따라간다. 그동안 다른 말을 보낼 수 있다 (D71)
            awaitsReply = false
            isLoading = false
            await track(state, with: agent)
        case .shop(let query):
            // 맥은 "살 것을 말했다, 검색어"만 정했다. 쇼핑 화면은 이 기기가 직접 연다 (카드를 누를 때. 저절로 열지 않는다)
            let texts = reply.replies.isEmpty ? ["쇼핑 화면에서 같이 볼게요."] : reply.replies
            for (index, text) in texts.enumerated() {
                append(Message(
                    role: .assistant, text: text, engine: .local,
                    writer: reply.replies.isEmpty ? nil : reply.writer(at: index),
                    shopQuery: index == texts.count - 1 ? query : nil
                ))
            }
        case .routeClaude:
            // 붙여 보낸 말은 회의 질문의 길로 넘기지 않는다 (그 길로는 붙인 것이 가지 않아, 사진을 못 본 답이 온다)
            if sent != nil {
                messages.append(Message(
                    role: .error, text: "회의 질문에는 붙인 것을 함께 볼 수 없어요. 붙인 것 없이 다시 물어봐 주세요.", engine: .local
                ))
                return
            }
            await handOverToCloud(question, meetings: meetings)
        case .siteLogin(let site):
            // 답 아래에 로그인 카드를 붙인다. 아이디·비밀번호는 따로 뜨는 화면에서만 받는다 (이 대화에는 들어오지 않는다)
            let texts = reply.replies.isEmpty ? [SiteLoginCopy(site: site).chatOpening] : reply.replies
            for (index, text) in texts.enumerated() {
                let isLast = index == texts.count - 1
                append(Message(
                    role: .assistant, text: text, engine: .local,
                    siteLogin: isLast ? site : nil, siteLoginResume: isLast ? reply.loginResume : nil,
                    writer: reply.replies.isEmpty ? nil : reply.writer(at: index)
                ))
            }
        }
    }

    /// 대화 담당의 반응을 방금 보낸 내 말에 붙이고 기록에 남긴다 (맥의 기록에는 없다. 이 기기에만 남는다)
    private func attach(_ reaction: String, toMessage messageID: String?) {
        guard let index = messages.lastIndex(where: { $0.role == .user && $0.id.uuidString == messageID }) else { return }
        messages[index].agentReaction = reaction
        if let record = conversation?.records.first(where: { $0.id == messages[index].id }) {
            record.agentReaction = reaction
            try? context?.save()
        }
    }

    /// 맥을 거친 한 응답: 사이에 다른 말 없이 이어진 맥의 말풍선들 (로그인 완료 카드는 앱이 붙인 것이라 넣지 않는다)
    private nonisolated static func isMacBubble(_ message: Message) -> Bool {
        message.role == .assistant && message.engine == .local && message.siteLoggedIn == nil && message.weather == nil
    }

    /// 보여 준 날씨 카드를 "맥에 알렸다"고 적는다 (기록에도)
    private func markWeatherReported() {
        for index in messages.indices where messages[index].weather?.reported == false {
            messages[index].weather?.reported = true
            if let record = conversation?.records.first(where: { $0.id == messages[index].id }) {
                record.weatherData = messages[index].weather.flatMap { try? JSONEncoder().encode($0) }
            }
        }
        try? context?.save()
    }

    /// 이 말 아래에 "Claude 사용"을 붙일지 (D62).
    /// 한 응답의 말풍선 가운데 Claude가 쓴 것이 하나라도 있으면, 그 응답의 마지막 말풍선 아래에 한 번만 붙인다
    /// (웹 검색 답은 앞의 말은 Claude가 쓰고 마지막 "출처" 줄은 맥이 붙인다. 그때도 답 전체의 아래에 붙는다)
    nonisolated static func marksClaude(at index: Int, in messages: [Message]) -> Bool {
        guard messages.indices.contains(index), isMacBubble(messages[index]) else { return false }
        if index + 1 < messages.count, isMacBubble(messages[index + 1]) { return false }
        var i = index
        while i >= 0, isMacBubble(messages[i]) {
            if messages[i].writer == .claude { return true }
            i -= 1
        }
        return false
    }

    /// 같은 메시지 번호로 다시 보내도 되는지: 맥이 번호를 기억하는 버전이고, 지금 연결되어 있을 때만.
    /// 연결이 끊겼던 것이면 잠깐 기다렸다가 확인한다 (앱이 뒤에서 돌아온 직후에는 연결이 바로 잡히지 않는다)
    private func canResend(after error: Error, agent: any AgentProviding) async -> Bool {
        guard await agent.supports(AgentFeature.messageReplay) else { return false }
        guard error as? AgentError == .unreachable else { return true }
        for _ in 0..<3 {
            try? await Task.sleep(for: pollInterval)
            if await agent.isReachable() { return await agent.supports(AgentFeature.messageReplay) }
        }
        return false
    }

    /// 답을 받지 못한 채 남은 마지막 메시지를 다시 확인한다. (앱을 다시 열 때, 화면으로 돌아올 때)
    /// 앱이 꺼지거나 멈춘 사이 맥이 이미 처리했을 수 있다. 맥이 메시지 번호를 기억하면 같은 번호로 그 결과를 받고,
    /// 아니면 작업이 두 번 만들어질 수 있으니 자동으로 보내지 않고 다시 시도할 수 있게만 한다.
    func resumeMessage(meetings: [Meeting]) async {
        // 반응만 받은 말은 답을 받은 말이다 (다시 보내지 않는다)
        guard let agent, !isLoading, !isResuming, let last = messages.last,
              last.role == .user, last.engine == .local, last.agentReaction == nil else { return }
        // 작업 담당이 예전 방식으로 되물은 뒤의 답은 새 작업을 만드는 요청이라 번호로 지킬 수 없다
        let answersOldQuestion = messages.dropLast().last.map { $0.role == .agent && $0.agent?.phase == .needsInput } ?? false
        isResuming = true
        let reachable = await agent.isReachable()
        let replays = reachable ? await agent.supports(AgentFeature.messageReplay) : false
        isResuming = false
        agentReachable = reachable
        guard !isLoading, messages.last?.id == last.id else { return }
        // 방금 보낸 메시지만 자동으로 다시 확인한다. 오래된 메시지는 맥이 번호를 잊었을 수 있어(24시간, 재시작) 새 작업이 생길 수 있다
        let isRecent = Date.now.timeIntervalSince(last.date) < Self.resendWindow
        if replays, isRecent, !answersOldQuestion {
            await send(last.text, meetings: meetings)
        } else {
            messages.append(Message(
                role: .error, text: "이 메시지의 답을 받지 못했어요. 다시 보내려면 다시 시도를 눌러 주세요.",
                retryQuestion: last.text, engine: .local
            ))
        }
    }

    /// 답을 받지 못한 메시지를 자동으로 다시 확인하는 시간 (맥이 처음 요청을 기다려 주는 10분에 여유를 둔 값)
    nonisolated static let resendWindow: TimeInterval = 15 * 60

    /// 방금 보낸 메시지를 Claude가 처리한 것으로 바꾸고 회의 질문으로 보낸다.
    private func handOverToCloud(_ question: String, meetings: [Meeting], offline: Bool = false) async {
        if let index = messages.lastIndex(where: { $0.role == .user && $0.text == question }) {
            messages[index].engine = .cloud
            persist(messages[index])
        }
        await askCloud(question, meetings: meetings, offline: offline)
    }

    /// 메시지를 보내기 전의 연결 확인.
    /// 방금까지 연결되던 맥이 한 번 실패한 것은 잠깐 끊긴 것일 수 있다 (실기기에서 맥은 확인 요청에 답했는데
    /// 앱이 받지 못해, 메일 부탁이 Claude로 넘어간 일이 있었다). 그래서 두 번 더 확인한 뒤에 끊겼다고 본다.
    /// 이미 끊긴 것으로 알고 있으면 한 번만 확인한다 (맥이 꺼져 있는 동안 질문마다 오래 기다리지 않게).
    private func confirmReachable(_ agent: any AgentProviding) async -> Bool {
        if await agent.isReachable() { return true }
        guard agentReachable != false else { return false }
        for _ in 0..<2 {
            try? await Task.sleep(for: pollInterval)
            if await agent.isReachable() { return true }
        }
        return false
    }

    /// 맥에 다시 보낼 수 있는 답: 맥에 연결되지 않아 Claude가 대신 답한 마지막 말이고, 지금은 맥에 연결될 때.
    /// (끊겨 있는 동안에는 입력창 위 안내가 같은 사실을 알려 준다)
    var resendableMessageID: Message.ID? {
        guard agentReachable == true, let last = messages.last, last.role == .assistant, last.offlineQuestion != nil else { return nil }
        return last.id
    }

    /// 맥에 연결되지 않아 Claude가 대신 답한 글을 맥에 다시 보낸다. (연결이 돌아온 뒤 답 아래 버튼)
    func resendToAgent(_ id: Message.ID, meetings: [Meeting]) async {
        guard !isLoading, !hasPendingApproval,
              let index = messages.firstIndex(where: { $0.id == id }),
              let question = messages[index].offlineQuestion else { return }
        // 같은 답에서 두 번 보내지 않게 표시를 지운다
        messages[index].offlineQuestion = nil
        await send(question, meetings: meetings)
    }

    /// 작업 상세에 보여 줄 "부탁한 내용". 맥이 되물은 뒤에 만든 작업이면 처음 부탁과 답을 함께 적는다.
    private func requestText(endingWith question: String) -> String {
        guard let sent = sentIndex(of: question) else { return question }
        let earlier = requestChain(endingAt: sent).dropLast().map { messages[$0].text }
        return (earlier + [question]).joined(separator: "\n")
    }

    /// 방금 보낸 내 말의 위치. 답을 기다리는 동안 다른 작업의 소식이 뒤에 붙을 수 있어, 맨 끝이라고 보지 않는다 (D71)
    private func sentIndex(of question: String) -> Int? {
        messages.lastIndex { $0.role == .user && $0.text == question }
    }

    /// 지금 보낸 메시지로 끝나는 부탁 하나를 이루는 사용자 메시지의 위치 (처음 부탁, 되물음에 대한 답들, 지금 메시지).
    /// 맥이 되묻지 않았으면 지금 메시지 하나뿐이다. 되물음이 여러 말풍선이어도 한 번의 되물음으로 본다.
    private func requestChain(endingAt sent: Int) -> [Int] {
        guard messages.indices.contains(sent) else { return [] }
        var index = sent
        var chain = [index]
        while true {
            var asked = index - 1
            guard asked >= 0, messages[asked].role == .assistant, messages[asked].asksBack else { break }
            while asked >= 1, messages[asked - 1].role == .assistant, messages[asked - 1].asksBack { asked -= 1 }
            guard asked >= 1, messages[asked - 1].role == .user else { break }
            index = asked - 1
            chain.insert(index, at: 0)
        }
        return chain
    }

    private func remember(conversationID: String) {
        guard !conversationID.isEmpty, conversationID != agentConversationID else { return }
        agentConversationID = conversationID
        conversation?.agentConversationID = conversationID
        try? context?.save()
    }

    /// 맥에 함께 보내는 자료: 방금 Claude와 나눈 질문·답(맥은 그 답을 보지 못했다) + 질문과 관련 있는 회의 발췌.
    /// 모두 사용자의 맥으로만 간다.
    /// 인사·감사처럼 회의 자료가 필요 없는 말. 글 전체가 아래 목록과 같을 때만 해당한다.
    /// 맥은 자료가 붙은 일상 대화를 한 번 더 신중하게 판단해 10~25초가 걸리므로(서버 동작), 이런 말에는 자료를 붙이지 않는다.
    /// 부탁일 수 있는 말("응", "좋아", "감사 메일 써줘")은 일부러 넣지 않았다. 자료 없이 작업이 만들어지면 안 된다.
    nonisolated static func isSmallTalk(_ text: String) -> Bool {
        let core = text.lowercased().filter { $0.isLetter || $0.isNumber }
        return smallTalk.contains(core)
    }

    private nonisolated static let smallTalk: Set<String> = [
        "안녕", "안녕하세요", "하이", "hi", "hello",
        "고마워", "고마워요", "고맙다", "고맙습니다", "감사", "감사해요", "감사합니다", "땡큐", "thanks",
        "수고했어", "수고했어요", "수고하셨습니다", "ㅋㅋ", "ㅎㅎ",
    ]

    private func agentContext(for question: String, meetings: [Meeting]) -> String? {
        // 되물음에 대한 답은 짧아도 그 답으로 작업이 만들어지므로 자료를 붙인다
        let sent = sentIndex(of: question) ?? messages.count - 1
        let chain = requestChain(endingAt: sent)
        let answersAsk = sent > 0 && messages[sent - 1].asksBack
        if !answersAsk, Self.isSmallTalk(question) { return nil }
        let sources = AskContextBuilder.sources(from: meetings)
        // 맥이 되물어 답이 이어지는 중이면, 날짜("오늘 회의")는 처음 부탁에 있다.
        // 답에서 다른 날을 말했으면("10일 회의로 보내 줘") 나중에 말한 날을 따른다
        let asked = chain.reversed().map { messages[$0].text }
            .first { AskContextBuilder.dayReference(in: $0, now: .now) != nil }
        let request = AskContextBuilder.build(question: question, history: [], sources: sources, dayText: asked).request
        // 바로 앞(최근 메시지 몇 개 안)에서 Claude가 답한 것이 있을 때만 붙인다.
        // "바로 앞"은 처음 부탁한 메시지 기준이다: 맥이 되묻는 동안 메시지가 쌓여도, 작업을 만드는 마지막 답까지 같은 문답이 붙는다
        var recent: [AskRequest.Turn] = []
        let start = chain.first ?? sent
        let previous = Array(messages.prefix(max(0, start)).suffix(4))
        if let index = previous.lastIndex(where: { $0.role == .assistant && $0.engine == .cloud && $0.found }) {
            if index > 0, previous[index - 1].role == .user {
                recent.append(AskRequest.Turn(role: .user, text: previous[index - 1].text))
            }
            recent.append(AskRequest.Turn(role: .assistant, text: previous[index].text))
        }
        return AgentContext.text(from: request, recent: recent)
    }

    // MARK: - 맥 에이전트

    /// 맥에 연결되는지 다시 확인한다. (화면이 나타날 때, 에이전트를 고를 때)
    func checkAgent() async {
        guard let agent else { return }
        agentReachable = await agent.isReachable()
        canConnectMail = await agent.supports(AgentFeature.mailConnect)
        canReplyToTask = await agent.supports(AgentFeature.replyTo)
        canPickItems = await agent.supports(AgentFeature.reportItems)
        let opensShop = await agent.supports(AgentFeature.shopView)
        let drivesShop = await agent.supports(AgentFeature.shopDrive)
        canDriveShop = opensShop && drivesShop
        canAttach = await agent.supports(AgentFeature.uploads)
    }

    // MARK: - 사이트 로그인 (D48)

    /// 로그인이 풀렸다는 알림을 눌러 다시 로그인할 사이트 (D122). 대화 화면이 받아 로그인 화면을 열고 비운다
    var reloginSite: String?

    /// 로그인 카드를 붙일 말: 맥이 로그인이 필요하다고 했고, 그 뒤로 다른 말이 오가지 않았을 때
    var siteLoginPrompt: SiteLoginPrompt? {
        guard agent != nil, let last = messages.last, last.role == .assistant, let site = last.siteLogin else { return nil }
        return SiteLoginPrompt(messageID: last.id, site: site, request: blockedRequest(before: messages.count - 1, site: site))
    }

    struct SiteLoginPrompt: Equatable {
        let messageID: Message.ID
        let site: String
        /// 로그인이 없어서 하지 못한 부탁. 로그인하면 이 말을 다시 보낸다 (D58).
        /// 로그인만 해 달라는 말("네이버 로그인해 줘")에 답한 카드면 nil
        var request: String?
    }

    /// 로그인 안내(`index`) 바로 앞의 말이 "로그인이 없어서 하지 못한 부탁"이면 그 말.
    /// 맥은 로그인 화면을 열어 달라는 말에도, 로그인이 필요한 부탁에도 같은 카드를 낸다.
    /// 어느 쪽인지 맥이 알려 주면 그대로 따르고 (D59), 알려 주지 않는 맥이면 앱이 말로 가른다 (D58)
    private func blockedRequest(before index: Int, site: String) -> String? {
        guard index >= 1, messages[index - 1].role == .user, SiteFlowKind.of(site) == .login else { return nil }
        let text = messages[index - 1].text
        if let resume = messages[index].siteLoginResume { return resume ? text : nil }
        return Self.isLoginOnlyRequest(text) ? nil : text
    }

    /// 로그인(연결)만 해 달라는 말인지. 맥은 "네이버 … 로그인/연결"이 든 짧은 말에 로그인 화면을 연다.
    /// 그 낱말이 들어 있으면 다시 보낼 부탁으로 치지 않는다 (잘못 다시 보내는 것보다 안 보내는 쪽이 낫다)
    nonisolated static func isLoginOnlyRequest(_ text: String) -> Bool {
        let low = text.lowercased()
        return ["로그인", "로그 인", "login", "연결", "연동"].contains(where: low.contains)
    }

    /// 로그인 화면이 쓸 진행 객체. 아이디·비밀번호는 그 화면에서 맥으로 바로 가고, 이 대화에는 결과 한 줄만 남는다
    func siteLoginFlow(for site: String) -> SiteLoginFlow? {
        guard let agent else { return nil }
        let flow = SiteLoginFlow(site: site, agent: agent)
        flow.onLoggedIn = { [weak self] in self?.siteLoggedIn(site) }
        return flow
    }

    /// 로그인된 것을 대화에 남긴다 (로그인 카드는 이 말이 붙으면서 사라진다)
    func siteLoggedIn(_ site: String) {
        guard siteLoginPrompt?.site == site || siteLoginTask?.site == site else { return }
        append(Message(role: .assistant, text: Self.siteLoggedInText(site), engine: .local, siteLoggedIn: site))
    }

    /// 로그인 안내를 붙일 작업 (D57): 로그인이 없거나 풀려서 멈췄고, 그 뒤로 다른 말이 오가지 않은 작업
    var siteLoginTask: SiteLoginTask? {
        guard agent != nil, let state = messages.last?.agent, state.needsSiteLogin, let site = state.loginSite else { return nil }
        return SiteLoginTask(taskID: state.id, site: site)
    }

    struct SiteLoginTask: Equatable {
        let taskID: String
        let site: String
    }

    /// 로그인한 뒤, 로그인 때문에 멈췄던 그 부탁을 다시 맡긴다 (같은 말이 새 메시지로 한 번 더 간다).
    /// 방금 그 작업 바로 아래에 "로그인됐어요"가 붙었을 때만 한다 (그 사이 다른 말이 오갔으면 하지 않는다)
    func retryAfterSiteLogin(_ taskID: String, meetings: [Meeting]) async {
        guard let index = messages.firstIndex(where: { $0.agent?.id == taskID }), index == messages.count - 2,
              let state = messages[index].agent, state.needsSiteLogin,
              messages.last?.siteLoggedIn == state.loginSite else { return }
        await send(state.request ?? state.task, meetings: meetings)
    }

    /// 로그인한 뒤, 로그인이 없어서 하지 못한 그 부탁을 다시 보낸다 (D58. 같은 말이 새 메시지로 한 번 더 간다).
    /// 부탁 → 로그인 안내 → "로그인됐어요"가 대화의 마지막 셋일 때만 한다
    func retryAfterSiteLoginPrompt(_ messageID: Message.ID, meetings: [Meeting]) async {
        let count = messages.count
        guard count >= 3, let site = messages[count - 1].siteLoggedIn,
              messages[count - 2].id == messageID, messages[count - 2].siteLogin == site,
              let request = blockedRequest(before: count - 2, site: site) else { return }
        await send(request, meetings: meetings)
    }

    nonisolated static func siteLoggedInText(_ site: String) -> String {
        SiteLoginCopy(site: site).chatDone
    }

    /// 메일 계정 연결 안내를 붙일 작업: 계정 때문에 보내지 못했고, 그 뒤로 다른 말이 오가지 않은 작업
    var mailConnectTaskID: String? {
        guard canConnectMail, let state = messages.last?.agent, state.needsMailAccount else { return nil }
        return state.id
    }

    /// 연결 안내가 붙을 때 계정 목록을 받아 둔다: 연결할 주소를 미리 채우고,
    /// 보낼 수 있는 주소가 하나도 없으면 연결 대신 주소부터 정하라고 안내하려는 것이다
    func loadMailAccounts() async {
        guard let agent, canConnectMail else { return }
        mailAccounts = try? await agent.mailAccounts(check: false)
    }

    /// 연결 화면에 미리 채울 계정: 연결이 필요한 계정 가운데 기본 계정 먼저
    var mailConnectSuggestion: MailAccount? {
        let waiting = (mailAccounts ?? []).filter(\.status.needsConnect)
        return waiting.first(where: \.isDefault) ?? waiting.first
    }

    /// 보낼 수 있는 내 주소가 실행하는 쪽에 하나도 없는지. 주소 목록은 그쪽 설정에서만 정하므로 앱에서는 연결할 수 없다
    var mailNeedsAddressSetup: Bool { mailAccounts?.isEmpty == true }

    /// 계정을 연결한 뒤, 보내지 못했던 그 부탁을 다시 맡긴다 (같은 말이 새 메시지로 한 번 더 간다)
    func retryAfterMailConnect(_ taskID: String, meetings: [Meeting]) async {
        guard let state = messages.first(where: { $0.agent?.id == taskID })?.agent, state.needsMailAccount else { return }
        await send(state.request ?? state.task, meetings: meetings)
    }

    /// 메일 계정을 연결한다 (채팅의 "메일 계정 연결" 시트). 앱 비밀번호는 맥으로 바로 보내고 여기에는 남기지 않는다:
    /// 대화 기록·메시지·로그 어디에도 넣지 않고, 맥의 대화 담당(모델)에게 가는 요청과도 다른 길이다.
    /// 돌아오는 값은 그 계정의 로그인 확인 결과다
    func connectMail(provider: String, address: String, password: String) async throws -> MailAccount.Status {
        guard let agent else { throw AgentError.unreachable }
        let accounts = try await agent.connectMail(provider: provider, address: address, password: password)
        mailAccounts = accounts
        return accounts.first { $0.address.lowercased() == address.lowercased() }?.status ?? .unknown
    }

    /// 에이전트가 정보가 부족해 되물은 상태인지 (다음 입력은 그 질문에 대한 답)
    var pendingAgentQuestion: AgentTaskState? {
        guard let last = messages.last(where: { $0.role == .agent })?.agent,
              last.phase == .needsInput, messages.last?.role == .agent else { return nil }
        return last
    }

    /// 작업 담당에게 바로 맡긴다 (v1 방식). 작업 담당이 되물은 뒤의 답과, 처리할 곳을 직접 정한 요청에 쓴다.
    private func runAgent(_ question: String, meetings: [Meeting], retryEngine: Engine?) async {
        guard let agent else {
            messages.append(Message(role: .error, text: AgentError.unreachable.localizedDescription, retryQuestion: question, retryEngine: retryEngine, engine: .local))
            return
        }
        // 정보가 부족해 되물었던 작업이면, 원래 부탁 + 질문 + 답을 새 작업으로 보낸다 (서버 명세)
        var task = question
        var ack = "네, 바로 준비할게요."
        if let previous = messages.dropLast().last(where: { $0.role == .agent })?.agent,
           previous.phase == .needsInput, messages.dropLast().last?.role == .agent {
            task = "\(previous.task)\n\n[추가 정보] 질문: \(previous.question ?? "")\n답: \(question)"
            ack = "알려 주신 내용으로 다시 진행할게요."
        }
        // 자료는 질문 탭과 같은 방식으로 고르고, 서버 한도(8000자)에 맞춰 글로 바꾼다
        let sources = AskContextBuilder.sources(from: meetings)
        let request = AskContextBuilder.build(question: question, history: [], sources: sources, dayText: task).request
        let context = AgentContext.text(from: request)

        isLoading = true
        let state: AgentTaskState
        do {
            state = try await agent.start(task: String(task.prefix(2000)), context: context)
            agentReachable = true
            update(state, ack: ack)
        } catch {
            await handle(error, question: question, agent: agent, retryEngine: retryEngine)
            isLoading = false
            return
        }
        // 맡긴 일은 따로 따라간다. 그동안 다른 말을 보낼 수 있다 (D71)
        isLoading = false
        await track(state, with: agent)
    }

    /// 끝나지 않은 작업을 이어서 확인한다. (앱을 다시 열 때, 화면으로 돌아올 때, 기록에서 대화를 열 때)
    /// 앱이 멈춰 있는 동안에도 맥에서는 작업이 계속되므로, 돌아오면 지금 상태부터 다시 받는다.
    /// 끝나지 않은 작업이 여럿이면 모두 확인한다 (일이 진행되는 동안 다른 일을 또 맡길 수 있다, D71). 이미 따라가는 작업은 건너뛴다.
    func resumeAgent() async {
        guard let agent, !isResuming else { return }
        let pending = messages.compactMap { $0.role == .agent ? $0.agent : nil }
            .filter { !$0.phase.isFinished && !isFollowing($0.id) }
        guard !pending.isEmpty else { return }
        let started = epoch
        isResuming = true
        var fetched: [(id: String, result: Result<AgentTaskState, Error>)] = []
        for task in pending {
            do { fetched.append((task.id, .success(try await agent.state(of: task.id)))) } catch { fetched.append((task.id, .failure(error))) }
        }
        isResuming = false
        guard epoch == started else { return }
        await withTaskGroup(of: Void.self) { group in
            for (id, result) in fetched {
                // 그 사이 사용자가 승인·거부를 눌렀으면 그쪽이 상태를 이어 받는다
                guard !isFollowing(id) else { continue }
                switch result {
                case .success(let state):
                    agentReachable = true
                    group.addTask { await self.track(state, with: agent) }
                case .failure(let error):
                    await handle(error, question: nil, agent: agent, taskID: id)
                }
            }
        }
    }

    /// 작업 하나를 끝나거나 내 답이 필요해질 때까지 따라간다. 따라가는 동안에도 말을 보낼 수 있고, 다른 작업도 함께 따라갈 수 있다 (D71)
    private func track(
        _ state: AgentTaskState, with agent: any AgentProviding, pastApproval: String? = nil, pastQuestion: String? = nil
    ) async {
        let started = epoch
        let key = beginFollowing(state.id)
        defer { endFollowing(key: key) }
        do {
            try await follow(state, with: agent, pastApproval: pastApproval, pastQuestion: pastQuestion)
        } catch {
            // 그 사이 다른 대화로 바뀌었으면 이 대화의 일이 아니다
            guard epoch == started else { return }
            // 작업은 이미 맥에 있다. 같은 부탁을 다시 보내게 하지 않는다
            await handle(error, question: nil, agent: agent, taskID: state.id)
        }
    }

    /// 따라가기를 시작한다. 대화마다 따로 센다 (떠난 대화의 따라가기가 멈추는 사이에 돌아와도 다시 따라갈 수 있게, D126)
    @discardableResult
    private func beginFollowing(_ taskID: String) -> String {
        let key = Self.followKey(epoch, taskID)
        followers[key, default: 0] += 1
        return key
    }

    private func endFollowing(key: String) {
        guard let count = followers[key] else { return }
        followers[key] = count > 1 ? count - 1 : nil
    }

    /// 승인 카드의 승인·거부. 거부 사유가 비어 있으면 작업이 끝난다.
    func decide(_ taskID: String, approve: Bool, reason: String? = nil) async {
        guard let agent, !isLoading,
              let draft = messages.first(where: { $0.agent?.id == taskID })?.agent?.draft,
              let approvalID = draft.approvalID else { return }
        isLoading = true
        // 결정을 보내는 동안과 그 뒤 처리를 따라가는 동안, 이 작업은 여기서 맡는다 (돌아와서 다시 받는 쪽이 끼어들지 않는다)
        let started = epoch
        let key = beginFollowing(taskID)
        var awaitsReply = true
        defer {
            if awaitsReply { isLoading = false }
            endFollowing(key: key)
        }
        do {
            // 승인은 화면에 보인 초안의 해시와 함께 보낸다. 맥에 고정된 초안과 다르면 서버가 실행하지 않는다
            let state: AgentTaskState
            do {
                state = try await BackgroundGrace.run("agent-decide") {
                    try await agent.decide(taskID, approvalID: approvalID, approve: approve, reason: reason, sha256: draft.approvalHash)
                }
            } catch AgentError.unreachable {
                await handle(AgentError.unreachable, question: nil, agent: agent, taskID: taskID, undelivered: true)
                return
            }
            // 결정은 전달됐다. 뒤의 진행은 따로 따라간다 (그동안 다른 말을 보낼 수 있다, D71)
            awaitsReply = false
            isLoading = false
            // 서버는 결정을 받은 직후 아직 같은 승인 대기 상태를 돌려줄 수 있다 → 바뀔 때까지 조회
            try await follow(state, with: agent, pastApproval: approvalID)
        } catch {
            // 그 사이 다른 대화로 옮겼으면 이 대화의 일이 아니다 (D126)
            guard epoch == started else { return }
            // 단추 누르기 승인이 내용이 달라 받아들여지지 않았으면 초안의 말 대신 그 말로 알린다 (D80)
            let mismatch = draft.isAction && error as? AgentError == .hashMismatch
            await handle(error, question: nil, agent: agent, taskID: taskID, text: mismatch ? AgentDraft.actionMismatchText : nil)
        }
    }

    /// 작업 담당의 질문에 답한다. 같은 작업이 이어진다. (선택지 버튼, 또는 질문이 열려 있을 때의 입력창)
    func answer(_ taskID: String, with text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let agent, !isLoading, !text.isEmpty,
              let question = messages.first(where: { $0.agent?.id == taskID })?.agent?.openQuestion else { return }
        isLoading = true
        let started = epoch
        let key = beginFollowing(taskID)
        var awaitsReply = true
        defer {
            if awaitsReply { isLoading = false }
            endFollowing(key: key)
        }
        if messages.last?.role == .error { messages.removeLast() }
        do {
            var state: AgentTaskState
            do {
                state = try await BackgroundGrace.run("agent-answer") {
                    try await agent.answer(taskID, questionID: question.id, answer: String(text.prefix(1000)))
                }
            } catch AgentError.unreachable {
                await handle(AgentError.unreachable, question: nil, agent: agent, taskID: taskID, undelivered: true)
                return
            } catch AgentError.conflict {
                // 질문 시간이 지났거나 이미 답한 질문: 답은 전달되지 않았다. 지금 상태부터 다시 따라간다
                let state = try await agent.state(of: taskID)
                if state.pendingQuestion?.id != question.id || state.phase != .awaitingInput {
                    record(AgentAnswered(question: question.text, answer: text, delivered: false), for: taskID)
                }
                awaitsReply = false
                isLoading = false
                try await follow(state, with: agent)
                return
            }
            record(AgentAnswered(question: question.text, answer: text), for: taskID)
            // 답은 전달됐다. 서버 표시가 늦어도 같은 질문을 다시 묻지 않는다
            if state.phase == .awaitingInput, state.pendingQuestion?.id == question.id { state.pendingQuestion?.received = true }
            // 답은 전달됐다. 뒤의 진행은 따로 따라간다 (그동안 다른 말을 보낼 수 있다, D71)
            awaitsReply = false
            isLoading = false
            // 서버는 답을 받은 직후 아직 같은 질문 상태(received)를 돌려줄 수 있다 → 바뀔 때까지 조회
            try await follow(state, with: agent, pastQuestion: question.id)
        } catch {
            guard epoch == started else { return }
            await handle(error, question: nil, agent: agent, taskID: taskID)
        }
    }

    /// 답한 질문을 작업에 적어 둔다 (채팅에 "질문 / 내 답"으로 남는다)
    private func record(_ answered: AgentAnswered, for taskID: String) {
        guard let index = messages.firstIndex(where: { $0.agent?.id == taskID }) else { return }
        // 읽고 쓰는 것을 한 줄에서 같이 하면 같은 배열을 동시에 건드려 앱이 죽는다 → 먼저 읽어 둔다
        let before = messages[index].agent?.answered ?? []
        messages[index].agent?.answered = before + [answered]
        persist(messages[index])
    }

    /// 진행 중인 작업을 멈춘다. (서버는 진행 중인 단계가 끝난 뒤 멈춘다)
    func cancelAgent(_ taskID: String) async {
        guard let agent else { return }
        let wasSending = messages.first(where: { $0.agent?.id == taskID })?.agent?.phase == .sendPending
        do {
            let state = try await agent.cancel(taskID)
            update(state)
            // 질문의 답을 기다리던 작업은 따라가는 조회가 없다. 멈출 때까지 여기서 확인한다
            // (보내기 전 기다리는 작업도, 따라가던 조회가 끊겼으면 여기서 이어 간다)
            if state.phase == .awaitingInput || state.phase == .sendPending, !isFollowing(taskID) {
                await track(state, with: agent, pastQuestion: state.pendingQuestion?.id)
            }
        } catch AgentError.conflict where wasSending {
            // 취소가 늦었다: 맥이 이미 보내는 중이거나 보냈다. 보낸 메일은 되돌릴 수 없으니, 지금 상태를 받아 사실대로 보여 준다
            guard let state = try? await agent.state(of: taskID) else {
                await handle(AgentError.unreachable, question: nil, agent: agent, taskID: taskID)
                return
            }
            if state.phase != .canceled, let index = messages.firstIndex(where: { $0.agent?.id == taskID }) {
                messages[index].agent?.cancelMissed = true
            }
            update(state)
            // 아직 보내는 중인데 따라가던 조회가 없으면, 결과가 나올 때까지 여기서 따라간다
            if state.phase == .sendPending, !isFollowing(taskID) {
                await track(state, with: agent)
            }
        } catch {
            await handle(error, question: nil, agent: agent, taskID: taskID)
        }
    }

    /// 진행 중이면 상태를 계속 조회한다. 새 승인 대기나 끝나면 멈춘다.
    /// `pastApproval`: 방금 결정한 승인 번호. 이 승인 대기가 그대로면 아직 처리 전이라 계속 조회한다.
    /// `pastQuestion`: 방금 답한 질문 번호. 같은 질문이 그대로면 아직 처리 전이라 계속 조회한다.
    private func follow(
        _ state: AgentTaskState, with agent: any AgentProviding, pastApproval: String? = nil, pastQuestion: String? = nil
    ) async throws {
        var state = state
        func isWaiting(_ state: AgentTaskState) -> Bool {
            state.phase == .running
                // 보내기 전 기다림: 보내거나 취소될 때까지 따라간다
                || state.phase == .sendPending
                || (state.phase == .awaitingApproval && pastApproval != nil && state.draft?.approvalID == pastApproval)
                // 서버가 결정을 이미 받았다고 알려 준 승인 요청 (처리 중)
                || (state.phase == .awaitingApproval && state.draft?.received != nil)
                // 답을 보낸 질문 (처리 중)
                || (state.phase == .awaitingInput && state.pendingQuestion?.received == true)
                || (state.phase == .awaitingInput && pastQuestion != nil && state.pendingQuestion?.id == pastQuestion)
        }
        /// 화면에 반영할 상태인지: 승인 대기는 결정이 처리된 뒤에만 바꾼다 (기존 동작)
        func shows(_ state: AgentTaskState) -> Bool {
            !isWaiting(state) || state.phase == .running || state.phase == .awaitingInput || state.phase == .sendPending
        }
        let started = epoch
        if shows(state) { update(state) }
        while isWaiting(state) {
            try await Task.sleep(for: state.isQueued ? pollInterval * 2 : pollInterval)
            // 그 사이 다른 대화로 바뀌었으면 그만 따라간다 (이 작업의 소식이 다른 대화에 붙지 않게)
            guard epoch == started else { return }
            // 멈추기를 눌러 이미 끝난 작업이면 더 묻지 않는다
            if let current = messages.first(where: { $0.agent?.id == state.id })?.agent, current.phase.isFinished { return }
            state = try await fetch(state.id, with: agent)
            guard epoch == started else { return }
            if shows(state) { update(state) }
        }
    }

    /// 상태 조회. 연결이 잠깐 끊긴 것(앱이 멈췄다 돌아온 직후 등)은 몇 번 다시 시도한다.
    private func fetch(_ id: String, with agent: any AgentProviding) async throws -> AgentTaskState {
        var failures = 0
        while true {
            do {
                return try await agent.state(of: id)
            } catch AgentError.unreachable where failures < 3 {
                failures += 1
                try await Task.sleep(for: pollInterval)
            }
        }
    }

    /// 오류 처리. 진행 중이던 작업이 사라졌으면 그 작업을 실패로 끝내고, 아니면 다시 시도할 수 있는 오류 말풍선.
    /// `undelivered`: 승인·거부를 보내다가 끊긴 경우 (전달됐는지 알 수 없다)
    private func handle(
        _ error: Error, question: String?, agent: any AgentProviding, taskID: String? = nil,
        undelivered: Bool = false, retryEngine: Engine? = nil, text: String? = nil
    ) async {
        if error is CancellationError { return }
        if error as? AgentError == .unreachable { agentReachable = await agent.isReachable() }
        let activeID = taskID ?? messages.last(where: { $0.role == .agent && $0.agent?.phase.isFinished == false })?.agent?.id
        if error as? AgentError == .taskLost, let activeID,
           let index = messages.firstIndex(where: { $0.agent?.id == activeID }) {
            messages[index].agent?.phase = .failed
            messages[index].agent?.draft = nil
            messages[index].agent?.error = error.localizedDescription
            persist(messages[index])
            return
        }
        if error as? AgentError == .unreachable, question == nil, let activeID,
           messages.contains(where: { $0.agent?.id == activeID && $0.agent?.phase.isFinished == false }) {
            // 작업은 맥에서 계속되고 있을 수 있다. 카드는 그대로 두고, 다시 확인할 수 있게 한다
            removeTaskErrors(for: activeID)
            let text = undelivered
                ? "맥에 연결하지 못해서 결정이 전달됐는지 알 수 없어요. 다시 확인해 주세요."
                : "맥과 연결이 끊겨서 지금 상태를 받지 못했어요. 작업은 맥에서 계속되고 있을 수 있어요."
            messages.append(Message(role: .error, text: text, engine: .local, resumeTaskID: activeID))
            return
        }
        if error as? AgentError == .conflict || error as? AgentError == .hashMismatch, let activeID {
            // 이미 바뀐 승인 요청: 지금 상태를 다시 받아 화면을 맞춘다
            if let state = try? await agent.state(of: activeID) { update(state) }
        }
        messages.append(Message(role: .error, text: text ?? error.localizedDescription, retryQuestion: question, retryEngine: retryEngine, engine: .local))
    }

    /// 작업 상태를 화면에 반영한다. 고친 초안이 오면 수정 횟수를 올리고, 끝난 작업은 저장한다.
    /// `ack`: 새 작업을 받았을 때 먼저 보여 줄 확인 문장 (대화로 만든 작업이면 맥이 준 문장)
    private func update(_ state: AgentTaskState, ack: String? = nil) {
        var state = state
        removeTaskErrors(for: state.id)
        if let index = messages.firstIndex(where: { $0.agent?.id == state.id }) {
            let previous = messages[index].agent
            if let draft = state.draft {
                let lastRevision = previous?.draft?.revision ?? previous?.lastRevision ?? 0
                let isSame = previous?.draft?.approvalID == draft.approvalID
                state.draft?.revision = isSame ? (previous?.draft?.revision ?? 1) : lastRevision + 1
            }
            state.lastRevision = state.draft?.revision ?? previous?.draft?.revision ?? previous?.lastRevision ?? 0
            state.ack = previous?.ack
            state.ackBy = previous?.ackBy
            // 대화로 만든 작업의 제목·브리프·원래 부탁은 처음 받은 값을 이어 간다
            state.serverTitle = state.serverTitle ?? previous?.serverTitle
            state.brief = state.brief ?? previous?.brief
            state.request = previous?.request
            state.answered = previous?.answered
            state.cancelMissed = previous?.cancelMissed
            if previous?.usedShop == true { state.usedShop = true }
            state.skill = state.skill ?? previous?.skill
            // 이미 결과를 돌려준 일이 다시 오면(돌려주기 전에 떠난 조회의 답이 늦게 온 것) 새로 시킨 일로 보지 않는다.
            // 그 사이 받은 다음 일이 있으면 그것을 이어 간다 (하던 일을 멈췄다 다시 시작하지 않게)
            if let command = state.browse, browsedJobs.contains("\(state.id)/\(command.id)") {
                state.browse = previous?.browse.flatMap { browsedJobs.contains("\(state.id)/\($0.id)") ? nil : $0 }
            }
            if state.phase == .sendPending {
                // 같은 기다림이면 처음 정한 마감을 이어 간다 (조회할 때마다 남은 시간이 흔들리지 않게)
                if let before = previous?.sendWait, before.cancelUntil == state.sendWait?.cancelUntil, before.deadline != nil {
                    state.sendWait?.deadline = before.deadline
                }
                // 맥이 내용을 다시 보내지 않으면, 방금 승인한 메일을 그대로 보여 준다 (해시가 같을 때만)
                if state.outgoing == nil, let approved = previous?.outgoing ?? previous?.draft,
                   state.sendWait?.sha256 == nil || state.sendWait?.sha256 == approved.sha256 {
                    state.outgoing = approved
                }
            } else if state.phase == .canceled, previous?.phase == .sendPending {
                state.error = AgentTaskState.sendCanceledText
            }
            // 방금 답한 질문이 아직 처리 전으로 오면(received 표시가 늦을 때) 다시 묻지 않게 답한 것으로 둔다
            if state.phase == .awaitingInput, let asked = state.pendingQuestion, asked.received != true,
               previous?.pendingQuestion?.id == asked.id, previous?.pendingQuestion?.received == true {
                state.pendingQuestion?.received = true
            }
            messages[index].agent = state
            // 단계가 바뀌거나 새 초안·새 질문이 왔을 때만 저장한다 (조회할 때마다 쓰지 않는다)
            if state.phase != previous?.phase || state.draft?.approvalID != previous?.draft?.approvalID
                || state.draft?.received != previous?.draft?.received
                || state.pendingQuestion != previous?.pendingQuestion {
                persist(messages[index])
            }
            // 내가 봐야 하는 소식이면, 그 뒤에 나눈 말들 아래로 카드를 내린다 (D71)
            if Self.isNews(state, after: previous) { surface(state.id) }
        } else {
            state.lastRevision = state.draft == nil ? 0 : 1
            state.ack = ack
            let message = Message(role: .agent, text: "", engine: .local, agent: state)
            messages.append(message)
            persist(message)
        }
    }

    /// 작업 소식에 붙었던 오류 말풍선을 지운다: 이 작업의 상태를 받지 못했다는 안내와, 맨 끝에 남은 작업 오류.
    /// 내가 보낸 말의 "다시 시도" 말풍선은 건드리지 않는다 (작업을 따라가는 중에도 말을 보낼 수 있어, 서로의 오류를 지우면 안 된다. D71)
    private func removeTaskErrors(for taskID: String) {
        messages.removeAll { $0.role == .error && $0.resumeTaskID == taskID }
        if let last = messages.last, last.role == .error, last.retryQuestion == nil { messages.removeLast() }
    }

    /// 내가 봐야 하는 소식인지: 새 승인 요청, 새 질문, 끝남. 진행 상황과 내가 멈춘 것은 아니다
    nonisolated static func isNews(_ state: AgentTaskState, after previous: AgentTaskState?) -> Bool {
        switch state.phase {
        case .awaitingApproval:
            // 내 결정을 맥이 처리하는 중이면 새 소식이 아니다
            guard state.draft?.received == nil else { return false }
            return previous?.phase != .awaitingApproval || previous?.draft?.approvalID != state.draft?.approvalID
        case .awaitingInput:
            guard let question = state.openQuestion else { return false }
            return previous?.openQuestion?.id != question.id
        case .needsInput, .done, .failed:
            return previous?.phase != state.phase
        case .running, .sendPending, .canceled:
            return false
        }
    }

    /// 소식이 온 작업 카드를 대화 아래로 옮긴다 (D71).
    /// 일을 맡긴 뒤에 다른 말을 나눴으면, 결과와 승인 요청은 지금 보고 있는 아래쪽에 와야 한다 (위에 묻혀 있으면 온 줄 모른다).
    /// 맡았다는 한 마디는 맡긴 자리에 말풍선으로 남는다. 답을 기다리는 내 말이 있으면 그 앞에 둔다 (`openExchangeStart`).
    /// 카드의 번호는 그대로다 (답장의 인용, 붙인 반응, 작업 목록이 같은 카드를 가리킨다)
    private func surface(_ taskID: String) {
        guard let from = messages.firstIndex(where: { $0.agent?.id == taskID }) else { return }
        let target = openExchangeStart()
        // 이미 맨 아래(또는 답을 기다리는 내 말 바로 앞)에 있으면 그대로 둔다
        guard from + 1 < target else { return }
        let original = storedDate(of: messages[from])
        var card = messages.remove(at: from)
        var to = target - 1
        if from < hiddenCount { hiddenCount -= 1 }
        // 다시 열어도 같은 순서가 되게 시각을 옮긴다 (기록은 시각 순으로 읽는다): 맨 끝이면 지금, 아니면 앞뒤 말의 가운데
        let before = storedDate(of: messages[to - 1])
        if to < messages.count {
            let after = storedDate(of: messages[to])
            card.date = Date(timeIntervalSinceReferenceDate: (before.timeIntervalSinceReferenceDate + after.timeIntervalSinceReferenceDate) / 2)
        } else {
            card.date = max(.now, before)
        }
        if let ack = card.agent?.ack, !ack.isEmpty {
            let writer = card.agent?.ackBy.flatMap(ReplyWriter.init(rawValue:))
            let bubble = Message(role: .assistant, text: ack, engine: .local, date: original, writer: writer)
            card.agent?.ack = nil
            card.agent?.ackBy = nil
            messages.insert(bubble, at: from)
            if from < hiddenCount { hiddenCount += 1 }
            to += 1
            persist(bubble, at: original)
        }
        messages.insert(card, at: to)
        // 옮긴 카드는 언제나 그린다
        if to < hiddenCount { hiddenCount = to }
        persist(card, at: card.date)
    }

    /// 아래쪽에서 아직 끝나지 않은 문답이 시작하는 위치: 답을 기다리는 내 말(다시 시도 말풍선이 붙은 것 포함)과,
    /// 그 앞에서 맥이 되물은 말·처음 부탁. 그런 것이 없으면 맨 끝이다.
    /// 작업 카드를 그 사이에 끼우면 "방금 보낸 말이 마지막"이라는 앞뒤 관계와 되물음의 선택지가 깨진다
    private func openExchangeStart() -> Int {
        var index = messages.count
        while index > 0, messages[index - 1].role == .error { index -= 1 }
        if index > 0, messages[index - 1].role == .user, messages[index - 1].agentReaction == nil {
            index -= 1
        } else if index < messages.count {
            // 내 말 없이 오류만 있으면 (작업 상태를 받지 못했다는 안내) 그 뒤에 둔다
            return messages.count
        }
        while index > 0, messages[index - 1].role == .assistant, messages[index - 1].asksBack {
            while index > 0, messages[index - 1].role == .assistant, messages[index - 1].asksBack { index -= 1 }
            guard index > 0, messages[index - 1].role == .user else { break }
            index -= 1
        }
        return index
    }

    /// 기록에 적힌 시각 (없으면 화면의 시각). 저장할 때의 시각은 말풍선을 만든 시각과 조금 다르다
    private func storedDate(of message: Message) -> Date {
        conversation?.records.first(where: { $0.id == message.id })?.createdAt ?? message.date
    }

    // MARK: - 저장

    /// 화면에 추가하고, 질문·답은 저장한다.
    private func append(_ message: Message) {
        var message = message
        if voiceCall, let callID, Self.foldsIntoCall(message) { message.callID = callID }
        messages.append(message)
        persist(message)
    }

    /// 통화 카드로 접을 말인지 (D137): 내 말과 모아의 말풍선만. 작업·승인 카드, 날씨·로그인·쇼핑 카드, 붙인 것은 접지 않는다
    /// (승인은 화면에서 눌러야 하는데 접힌 카드 안에 있으면 놓치기 쉽다)
    nonisolated static func foldsIntoCall(_ message: Message) -> Bool {
        guard message.role == .user || message.role == .assistant else { return false }
        return message.weather == nil && message.siteLogin == nil && message.siteLoggedIn == nil && message.shopQuery == nil
            && message.uploads == nil
    }

    /// 질문·답·에이전트 작업을 저장한다. 오류는 저장하지 않는다.
    /// 에이전트 작업은 진행 중에도 저장해 두고(앱이 꺼져도 다시 열면 이어서 확인), 상태가 바뀌면 같은 기록을 고친다.
    /// `date`: 기록의 시각을 이 값으로 둔다 (자리를 옮긴 작업 카드와 그 자리에 남긴 말. D71). nil이면 처음 저장한 시각 그대로
    /// 사이드바의 아랫줄을 이 말로 바꾼다 (D116). 글이 없는 작업 카드는 작업 이름으로
    private func updatePreview(_ conversation: Conversation?, text: String, message: Message) {
        guard let conversation else { return }
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (message.agent?.title ?? "") : text
        let snippet = Conversation.snippet(source)
        if !snippet.isEmpty { conversation.preview = snippet }
        // 보고 있는 대화에 저장하는 것이다: 읽은 것으로 둔다 (D126)
        conversation.lastReadAt = .now
    }

    private func persist(_ message: Message, at date: Date? = nil) {
        guard let context, message.role != .error else { return }
        let text = message.agent.map { $0.result ?? $0.question ?? $0.error ?? "" } ?? message.text
        let agentData = message.agent.flatMap { try? JSONEncoder().encode($0) }
        if let record = conversation?.records.first(where: { $0.id == message.id }) {
            record.text = text
            record.agentData = agentData
            record.reaction = message.reaction
            record.agentReaction = message.agentReaction
            record.engineRaw = message.engine == .local ? Engine.local.rawValue : nil
            if let date { record.createdAt = date }
            conversation?.updatedAt = .now
            updatePreview(conversation, text: text, message: message)
            try? context.save()
            return
        }

        let conversation: Conversation
        if let existing = self.conversation {
            conversation = existing
        } else {
            let title = message.role == .user ? message.text : "대화"
            conversation = Conversation(title: String(title.prefix(60)))
            conversation.agentConversationID = agentConversationID
            context.insert(conversation)
            self.conversation = conversation
        }
        let role = switch message.role {
        case .user: "user"
        case .agent: "agent"
        default: "assistant"
        }
        let record = ChatRecord(
            id: message.id,
            role: role,
            text: text,
            found: message.found,
            citationsData: message.citations.isEmpty ? nil : try? JSONEncoder().encode(message.citations),
            engineRaw: message.engine == .local ? Engine.local.rawValue : nil,
            agentData: agentData,
            createdAt: date ?? .now
        )
        record.reaction = message.reaction
        record.agentReaction = message.agentReaction
        record.replyData = message.replyTo.flatMap { try? JSONEncoder().encode($0) }
        record.siteLoggedIn = message.siteLoggedIn
        record.writerRaw = message.writer?.rawValue
        record.weatherData = message.weather.flatMap { try? JSONEncoder().encode($0) }
        record.shopQuery = message.shopQuery
        record.shopViewData = message.shopView.flatMap { try? JSONEncoder().encode($0) }
        record.uploadsData = message.uploads.flatMap { try? JSONEncoder().encode($0) }
        record.callID = message.callID
        conversation.records.append(record)
        conversation.updatedAt = .now
        updatePreview(conversation, text: text, message: message)
        try? context.save()
    }

    // MARK: 사이드바의 대화 고치기 (D116)

    /// 대화의 이름을 바꾼다 (빈 이름이면 그대로 둔다)
    func rename(_ target: Conversation, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        target.title = String(clean.prefix(60))
        try? context?.save()
    }

    /// 사이드바 맨 위에 고정하거나 푼다
    func setPinned(_ target: Conversation, _ pinned: Bool) {
        target.isPinned = pinned
        try? context?.save()
    }

    /// 사이드바에 표시할 이 대화의 상태 (맥이 알려 준 기다리는 작업과 지금 대화의 작업)
    func sidebarBadge(for target: Conversation) -> SidebarBadge? {
        if target.id == conversation?.id {
            if hasPendingApproval { return .approval }
            if openQuestionTask != nil || pendingAgentQuestion != nil { return .answer }
            if messages.contains(where: { $0.agent.map { !$0.phase.isFinished } ?? false }) { return .working }
        }
        let waiting = target.agentConversationID.map { id in waitingTasks.filter { $0.conversationID == id } } ?? []
        if waiting.contains(where: \.isApproval) { return .approval }
        if !waiting.isEmpty { return .answer }
        // 떠난 뒤에도 맥에서 돌고 있는 작업 (D126)
        if target.id != conversation?.id, backgroundTasks.values.contains(target.id) { return .working }
        return nil
    }

    enum SidebarBadge: Equatable {
        case approval, answer, working

        var text: String {
            switch self {
            case .approval: "승인 필요"
            case .answer: "답 필요"
            case .working: "진행 중"
            }
        }
    }

    private static func message(from record: ChatRecord) -> Message {
        let citations = record.citationsData.flatMap { try? JSONDecoder().decode([Citation].self, from: $0) } ?? []
        let role: Message.Role = switch record.roleRaw {
        case "user": .user
        case "agent": .agent
        default: .assistant
        }
        var message = Message(
            id: record.id,
            role: role,
            text: record.text,
            found: record.found,
            citations: citations,
            engine: record.engineRaw == Engine.local.rawValue ? .local : .cloud,
            agent: record.agentData.flatMap { try? JSONDecoder().decode(AgentTaskState.self, from: $0) },
            date: record.createdAt,
            reaction: record.reaction,
            agentReaction: record.agentReaction,
            replyTo: record.replyData.flatMap { try? JSONDecoder().decode(Quote.self, from: $0) },
            siteLoggedIn: record.siteLoggedIn,
            writer: record.writerRaw.flatMap(ReplyWriter.init(rawValue:)),
            weather: record.weatherData.flatMap { try? JSONDecoder().decode(WeatherCard.self, from: $0) },
            shopQuery: record.shopQuery,
            shopView: record.shopViewData.flatMap { try? JSONDecoder().decode(ShopView.self, from: $0) },
            uploads: record.uploadsData.flatMap { try? JSONDecoder().decode(SentUploads.self, from: $0) }
        )
        message.callID = record.callID
        return message
    }

    /// 이전 질문·답 (최근 6개). 오류와 방금 넣은 질문, 다른 곳에서 처리한 대화는 뺀다.
    private func history(for engine: Engine) -> [AskRequest.Turn] {
        // 마지막 사용자 메시지는 지금 보내는 질문
        let previous = messages.last?.role == .user ? messages.dropLast() : messages[...]
        return previous.filter { $0.engine == engine }.compactMap { message in
            switch message.role {
            case .user: AskRequest.Turn(role: .user, text: message.text)
            case .assistant: AskRequest.Turn(role: .assistant, text: message.text)
            case .agent: message.agent?.result.map { AskRequest.Turn(role: .assistant, text: $0) }
            case .error: nil
            }
        }
        .suffix(6)
        .map { $0 }
    }

    nonisolated static func askWithRetry(_ provider: any AskProviding, _ request: AskRequest) async throws -> AskAnswerDTO {
        do {
            return try await provider.ask(request)
        } catch let error as SummaryAPIError where error.isFormatError {
            return try await provider.ask(request)
        }
    }
}
