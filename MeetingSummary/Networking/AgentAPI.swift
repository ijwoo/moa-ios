import CryptoKit
import Foundation

// 맥 에이전트(local-ai-agent) 연동. 서버 명세: local-ai-agent `docs/API.md` (v1, Phase 8 축소판).
//
// 흐름: 작업 요청 → 상태 조회 → 승인 대기(초안 입력칸) → 승인/거부(사유) → 결과
// 범위: 읽기와 초안 저장. 맥이 `send_self`를 지원한다고 알릴 때만 본인 주소로 메일 보내기까지
// (승인 → 잠깐 기다림(취소 가능) → 발송 → 도착 확인). 그 밖의 발송·삭제는 서버가 하지 않는다.
// 주소·토큰은 Config/Secrets.xcconfig(저장소 제외) → Info.plist `MSAgentHost`·`MSAgentToken`.

/// 에이전트 작업 하나의 상태 (앱 화면·저장용으로 정리한 형태)
struct AgentTaskState: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case running
        case awaitingApproval = "awaiting_approval"
        /// 작업 담당이 막혀서 물어봄 (API v2). 답하면 같은 작업이 이어진다
        case awaitingInput = "awaiting_input"
        /// 보내기를 승인했고, 보내기 전 잠깐 기다리는 중 (이 동안 취소할 수 있다). `send_self`를 지원하는 맥만
        case sendPending = "send_pending"
        case done
        /// 정보가 부족해 멈춤. 사용자의 답을 넣어 새 작업으로 다시 요청한다
        case needsInput = "needs_input"
        case failed
        case canceled

        /// 더 이상 바뀌지 않는 상태
        var isFinished: Bool { self != .running && self != .awaitingApproval && self != .awaitingInput && self != .sendPending }
    }

    let id: String
    /// 요청한 일 (정보 부족으로 다시 요청할 때 쓴다)
    var task: String
    /// 지금까지 한 일 (한 줄씩). 마지막 줄은 running이면 진행 중인 일
    var steps: [String]
    var phase: Phase
    /// 앞 작업이 끝나기를 기다리는 중 (서버는 한 번에 하나만 실행)
    var isQueued = false
    /// 줄 선 까닭 한 줄 (`wait_reason`, D152). 없으면 예전 문장
    var waitReason: String?
    /// 작업에 끼워 넣은 내 말 (`steers`, D152)
    var steers: [AgentSteerNote]?
    /// 승인을 기다리는 초안
    var draft: AgentDraft?
    /// 사용자가 승인해 실제로 저장된 초안. 저장 내용은 모델의 보고가 아니라 이 값으로 보여 준다
    var approvedDrafts: [AgentDraft] = []
    /// 에이전트의 보고 (읽기 작업이면 답)
    var result: String?
    /// 정보가 부족할 때 에이전트의 질문
    var question: String?
    /// 실패·취소 이유 (사용자에게 보여 줄 문장)
    var error: String?
    /// 지금까지 받은 마지막 초안의 수정 횟수 (승인 대기가 아닐 때도 다음 수정본 번호를 이어 가기 위해)
    var lastRevision = 0

    // 아래는 나중에 더한 값이라 옵셔널이다 (이전에 저장한 대화 기록에는 없다)

    /// 서버가 붙인 짧은 제목 (API v2부터). 없으면 부탁한 글에서 만든다
    var serverTitle: String?
    /// 지금 하는 일 한 문장 (진행 중일 때)
    var activity: String?
    /// 작업을 맡기자마자 보여 주는 확인 문장 ("네, 바로 준비할게요.")
    var ack: String?
    /// 그 확인 문장을 누가 썼는지 (`ReplyWriter`의 값. 앱이 기록한다, D62). 모르는 값이 적혀 있어도 기록 전체를 버리지 않게 글자로 둔다
    var ackBy: String?
    /// 처리한 곳으로 가는 링크 (열 수 있는 주소만)
    var links: [AgentLink]?
    /// 대화 담당이 작업 담당에게 넘긴 내용 (대화로 만든 작업일 때)
    var brief: AgentBrief?
    /// 사용자가 실제로 쓴 부탁 (대화로 만든 작업은 `task`가 브리프를 펼친 글이라 따로 둔다)
    var request: String?
    /// 맥이 쓴 진행 설명 (API v2). 있으면 작업 상세의 기록을 이것으로 그린다
    var narration: [AgentNarration]?
    /// 작업 담당이 지금 묻고 있는 질문 (`awaitingInput`일 때)
    var pendingQuestion: AgentQuestion?
    /// 끝난 작업의 보고: 한 일, 못 한 일, 확인한 곳 (API v2). 있으면 결과를 `result` 대신 이것으로 보여 준다
    var report: AgentReport?
    /// 이 작업에서 사용자가 답한 질문과 답 (앱이 기록한다)
    var answered: [AgentAnswered]?
    /// 보내기 전 기다리는 시간 (`sendPending`일 때)
    var sendWait: AgentSendWait?
    /// 보내기를 승인한 메일. 기다리는 동안 맥은 내용을 다시 보내지 않아, 승인한 것을 앱이 들고 있는다
    var outgoing: AgentDraft?
    /// 취소를 눌렀지만 늦어서 메일이 이미 나갔는지 (앱이 기록한다)
    var cancelMissed: Bool?
    /// 메일을 보내지 못한 이유의 종류 ("auth_failed"·"not_set" 등). 보내기에 실패했을 때만
    var sendFailure: String?
    /// 로그인이 없거나 풀려서 멈춘 사이트 ("naver"). 맥이 "여기에 로그인하면 된다"고 알려 준 작업에만 있다 (D57)
    var loginSite: String?
    /// 그 로그인이 풀린 것인지 (false면 로그인한 적이 없는 것)
    var loginExpired: Bool?
    /// 맥이 이 아이폰의 쇼핑 화면에 시킨 일 (D75). 작업이 진행 중이고, 앱이 아직 결과를 돌려주지 않은 동안만 있다
    var browse: AgentBrowse?
    /// 이 작업이 이 아이폰의 쇼핑 화면을 썼는지 (앱이 기록한다)
    var usedShop: Bool?
    /// 맥이 이 작업에 쓴 기술의 이름 ("web_find"·"web_browse"·"shop_drive"·사이트 읽기 기술, D77).
    /// 메일 쓰기 같은 보통의 작업에는 없다. 이 키를 모르는 맥의 작업에도 없다
    var skill: String?
    /// 사용자가 승인한 "단추 누르기"의 단추 글 (`result.approved_actions`, 맥의 `site_do`, D80). 초안이 아니라서 `approvedDrafts`에 들지 않는다.
    /// 승인한 것의 이름이다: 실제로 한 일은 보고(`report.done`)가 말한다
    var approvedActions: [String]?

    static let skillLimit = 40
    /// 승인한 단추 글 하나의 길이와 개수 한도
    static let actionNameLimit = 40
    static let actionLimit = 10
    /// 로그인한 사이트 안에서 해 주는 작업의 기술 이름
    static let siteDoSkill = "site_do"
    /// 그 작업이 사이트마다 한 번 묻는 허락 질문의 선택지 (맥이 주는 글 그대로)
    static let sitePermissionChoices = ["이 사이트는 허락", "이번만", "하지 않기"]
}

/// 보내기 전 기다리는 시간. 맥이 알려 준 마감을 이 기기 시계로 옮겨 둔다 (두 시계가 달라도 남은 시간이 맞게)
struct AgentSendWait: Codable, Equatable, Sendable {
    /// 맥이 알려 준 취소 마감 (맥의 시계). 같은 기다림인지 가릴 때 쓴다
    var cancelUntil: String?
    /// 이 기기 시계로 본 마감. 처음 받았을 때 정하고 그대로 이어 간다
    var deadline: Date?
    /// 보낼 메일의 해시 (승인한 초안과 같은지 확인)
    var sha256: String?

    /// 남은 시간(초). 마감을 모르면 nil
    func remaining(at now: Date = .now) -> Int? {
        deadline.map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
    }
}

/// 보낸 메일 하나의 결과 (`report.sent`). 맥이 보낸 뒤 받은편지함에서 직접 확인한 값이다
struct AgentSent: Codable, Equatable, Sendable {
    enum Verified: String, Codable, Sendable {
        /// 받은편지함에 도착한 것을 확인
        case delivered
        /// 메일 서버가 받았지만 도착은 확인하지 못함
        case acceptedOnly = "accepted_only"
        case failed
    }

    var to: [String]
    /// 보낸 시각 (ISO 8601)
    var sentAt: String?
    var verified: Verified
    var sha256: String?
    /// 받는 사람이 내가 아니다 (D89). 받는 분의 받은편지함은 맥이 볼 수 없어 도착을 확인하지 못한다. 나중에 더한 값이라 옵셔널
    var external: Bool?
}

/// 작업을 실행하는 쪽(지금은 맥)에 연결된 메일 계정 (`GET /v1/mail/accounts`). 비밀번호는 그쪽 보안 저장소에만 있고 앱으로 오지 않는다
struct MailAccount: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable {
        case ready
        case authFailed = "auth_failed"
        case unreachable
        case notSet = "not_set"
        /// 앱이 모르는 값
        case unknown
    }

    /// "gmail"·"naver"
    var provider: String
    var address: String
    /// 맥이 마지막으로 로그인해 본 결과
    var status: Status
    /// "나한테 보내 줘"처럼 계정을 말하지 않았을 때 쓰는 계정
    var isDefault: Bool
    var checkedAt: Date?

    var id: String { address }

    var providerName: String {
        switch provider {
        case "gmail": "Gmail"
        case "naver": "네이버 메일"
        default: provider
        }
    }
}

/// 서버 시각 읽기 (ISO 8601, 소수 초가 있어도 읽는다)
enum AgentTime {
    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        if let date = try? Date(iso, strategy: .iso8601) { return date }
        return try? Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// 사용자가 답한 질문 하나
struct AgentAnswered: Codable, Equatable, Sendable {
    var question: String
    var answer: String
    /// 답이 맥에 전달됐는지 (질문 시간이 지난 뒤에 답하면 전달되지 않는다)
    var delivered = true
}

/// 진행 설명 한 줄. 입력한 내용은 들어 있지 않다 (서버가 칸·버튼 이름만 쓴다)
struct AgentNarration: Codable, Equatable, Sendable {
    var time: String?
    var text: String
}

/// 작업 담당의 질문. 선택지가 있으면 버튼으로 보여 주고, 직접 써서 답할 수도 있다
struct AgentQuestion: Codable, Equatable, Sendable {
    let id: String
    var text: String
    var choices: [String] = []
    /// 서버가 답을 이미 받았는지 (받았으면 처리 중이라 다시 묻지 않는다)
    var received: Bool?
    /// 묻는 그때의 화면 (`question.attachment`, D93). 로그인한 사이트 안에서 하는 작업에만 붙는다. 나중에 더한 값이라 옵셔널
    var attachment: AgentAttachment?
    /// 사람이 직접 해야 하는 화면 (`question.handover`, D123). 있으면 카드에 "브라우저 열기"가 붙는다. 나중에 더한 값이라 옵셔널
    var handover: AgentHandover?
}

/// 끝난 작업의 보고
struct AgentReport: Codable, Equatable, Sendable {
    /// 한 일
    var done: [String] = []
    /// 못 한 일과 이유
    var blocked: [String] = []
    /// 실제로 연 페이지 (서버가 단계 기록에서 뽑은 것)
    var sources: [String] = []
    /// 보낸 메일과 도착 확인 (나중에 더한 값이라 옵셔널)
    var sent: [AgentSent]?
    /// 작업이 본 화면의 캡처 (나중에 더한 값이라 옵셔널). 그림은 여기 없다 — 보일 때 따로 받는다
    var attachments: [AgentAttachment]?
    /// 맥의 브라우저가 실제로 연 공개 페이지 ("찾아 달라"는 작업, D64. 나중에 더한 값이라 옵셔널).
    /// 눌렀을 때만 연다. 열 만한 주소만 들어 있다 (`AgentLink.page`)
    var links: [AgentLink]?
    /// 이 보고의 답을 쓴 곳 (`report.by`: `claude` | `local`. "찾아 달라"는 작업에만 온다, D65. 나중에 더한 값이라 옵셔널).
    /// 아는 값만 적어 둔다. `claude`이면 대화에서 답 아래에 "Claude 사용"을 붙인다
    var by: String?
    /// 찾은 상품 목록 (`report.items`, D72. 나중에 더한 값이라 옵셔널). 대화에서 상품 카드로 그린다.
    /// 이름·값·파는 곳은 맥이 받은 값 그대로다 (모델이 쓴 글이 아니다). 앱도 받은 대로만 그린다
    var items: [AgentItem]?
    /// 답변 카드 (`report.card`, D110. 나중에 더한 값이라 옵셔널). 있으면 대화에서 `done`의 줄글 대신 이 카드를 그린다
    var card: AgentReportCard?
    /// 통화 중에 소리로 읽을 한두 문장 (`report.speak`, D134. 맥의 D116부터 끝난 작업에 늘 온다)
    var speak: String?

    /// 보고의 답을 쓴 곳으로 받아들이는 값 (말풍선의 `mac`은 보고에는 없다)
    static let writers = [ReplyWriter.claude.rawValue, ReplyWriter.local.rawValue]

    var isEmpty: Bool {
        done.isEmpty && blocked.isEmpty && sources.isEmpty && (sent ?? []).isEmpty && (attachments ?? []).isEmpty && (links ?? []).isEmpty
            && (items ?? []).isEmpty && card == nil
    }
}

/// 답변 카드 (D110): 끝난 작업의 결과를 일정한 꼴로 — 아이콘과 제목(·부제), 블록 셋까지, 단추 둘까지.
/// 블록은 내 공간과 같다. 단추는 맥의 코드가 정한 것만 온다 (열 만한 주소, 또는 다시 로그인할 사이트)
struct AgentReportCard: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// 읽어 온 결과 ("최근 결제 내역")
        case answer
        /// 무언가 한 뒤 ("장바구니에 담았어요")
        case result
        /// 못 했다: 제목이 한 줄 까닭
        case failed
    }

    struct Action: Codable, Equatable, Sendable {
        var label: String
        /// 누르면 여는 공개 페이지 ("쿠팡에서 보기")
        var url: URL?
        /// 누르면 다시 로그인할 사이트 ("다시 로그인")
        var site: String?
    }

    var kind: Kind
    var title: String
    var subtitle: String?
    var blocks: [SpaceBlock] = []
    var actions: [Action] = []
    /// 이어 할 말 (`card.next.choices`, D111). 고르면 사용자가 친 말처럼 보낸다. 예전에 저장한 카드에는 없다
    var next: [String]?

    static let blockLimit = 3
    static let actionLimit = 2
}

/// 찾은 상품 하나 (`report.items[]`, D72).
///
/// 값은 맥이 받은 그대로다: 앱은 더하거나 빼거나 고쳐 쓰지 않는다 (값이 없으면 그 줄을 그리지 않는다).
/// 주소와 그림 주소는 찾은 페이지(`AgentLink.page`)와 같은 규칙으로 거른다: 공개 https 주소만, 눌렀을 때만 연다.
struct AgentItem: Codable, Equatable, Sendable {
    /// 그 작업 안에서 변하지 않는 번호 ("i1"…). 고를 때 이 번호를 맥에 보낸다. 없으면 글로만 고른다
    var id: String?
    let title: String
    /// 값 (원). 숫자로 온 양수만 받는다. 없으면 값을 그리지 않는다
    var price: Int?
    /// 파는 곳 이름
    var mall: String?
    let url: URL
    var image: URL?
    var brand: String?
    /// 배송비 설명 (상품 페이지를 읽어야 아는 값이라 목록에는 없을 수 있다)
    var shipping: String?
    /// 용량·구성 같은 한 줄 설명 (위와 같다)
    var detail: String?

    /// 한 보고에서 보여 주는 상품 수 (맥과 맞춘 값)
    static let reportLimit = 8
    /// 번호로 받는 글자 수
    static let idLimit = 40

    /// 맥이 보낸 값으로 상품 하나를 만든다. 이름이 없거나 주소가 열 만하지 않으면 버린다. 나머지는 맞지 않는 것만 버린다
    static func make(
        id: String?, title: String?, price: Double?, mall: String?, url: String?, image: String?,
        brand: String?, shipping: String?, detail: String?
    ) -> AgentItem? {
        guard let title = line(title, limit: 120), let url = AgentLink.publicURL(url) else { return nil }
        var item = AgentItem(title: title, url: url)
        if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, id.count <= idLimit { item.id = id }
        // 원 단위의 정수만 값으로 본다 (소수·음수·터무니없이 큰 수는 값이 아니다)
        if let price, price > 0, price < 1_000_000_000_000, price == price.rounded() { item.price = Int(price) }
        item.mall = line(mall, limit: 40)
        item.image = AgentLink.publicURL(image)
        item.brand = line(brand, limit: 40)
        item.shipping = line(shipping, limit: 40)
        item.detail = line(detail, limit: 80)
        return item
    }

    /// 줄바꿈과 앞뒤 빈칸을 정리하고 길면 자른다. 빈 글은 없는 것으로 본다
    private static func line(_ text: String?, limit: Int) -> String? {
        let flat = (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.isEmpty ? nil : String(flat.prefix(limit))
    }

    /// 화면에 쓰는 값: 받은 숫자에 자릿수 쉼표와 "원"만 붙인다 (계산하지 않는다)
    var priceText: String? {
        price.map { "\($0.formatted(.number.locale(Locale(identifier: "ko_KR"))))원" }
    }

    /// 값 아래 한 줄: 파는 곳 · 브랜드 · 배송비 (있는 것만. 파는 곳과 브랜드가 같으면 한 번만)
    var caption: String {
        var parts: [String] = []
        for part in [mall, brand, shipping] {
            if let part, !parts.contains(part) { parts.append(part) }
        }
        return parts.joined(separator: " · ")
    }

    /// 화면에 보일 사이트 주소 (파는 곳 이름이 없을 때 대신 쓴다)
    var host: String { AgentLink(title: "", url: url).host }
}

/// 보고에 붙은 화면 캡처 하나 (D56). 그림 자체가 아니라 그림을 받는 데 필요한 값이다.
///
/// 그림은 화면에 보일 때 `GET v1/tasks/{작업}/attachments/{id}`로 받아 메모리에서만 쓴다 (`CaptureStore`).
/// 대화 기록에는 이 값만 저장되고, 그림은 저장하지 않는다. 맥도 그림을 24시간 뒤에 지운다.
struct AgentAttachment: Codable, Equatable, Sendable, Identifiable {
    /// 주소에 넣는 번호 (글자·숫자·밑줄·붙임표만, `AgentHTTPClient.isPathSafe`)
    let id: String
    var width: Int
    var height: Int
    /// 캡처한 페이지의 사이트 (주소 전체는 받지 않는다)
    var pageHost: String?
    /// 맥의 코드가 붙인 짧은 설명 (모델이 쓴 글이 아니다)
    var caption: String?
    /// 로그인한 화면이라 내 정보가 보일 수 있다. 맥이 "아니다"라고 한 것만 false다
    var isSensitive = true
    /// 맥이 이 그림을 지우는 때 (맥의 시계, ISO 8601)
    var expiresAt: String?
    /// 무엇인지 (D112). 예전에 저장한 것은 nil — 화면 캡처다
    var kind: Kind?
    /// 맥이 알려 준 크기 (영상에만 보인다)
    var bytes: Int?

    enum Kind: String, Codable, Sendable {
        /// 맥이 작업하며 본 화면
        case screenshot
        /// 작업실이 만든 그림 (D112)
        case image
        /// 작업실이 만든 영상 (D112). 누를 때만 받는다
        case video
    }

    var isVideo: Bool { kind == .video }

    /// 한 보고에서 보여 주는 캡처 수
    static let maxCount = 4
    /// 받는 그림의 크기 한도 (맥은 캡처 한 장을 400KB 아래로 만든다. 작업실이 만든 그림은 더 크다, D112)
    static let maxBytes = 12_000_000
    /// 받는 영상의 크기 한도 (D112)
    static let maxVideoBytes = 200_000_000
    static let maxCaption = 60

    /// 가로÷세로. 값이 이상하면 흔한 화면 비율로 본다
    var aspect: CGFloat {
        guard width > 0, height > 0 else { return 1.6 }
        return CGFloat(width) / CGFloat(height)
    }

    /// 맥이 지웠을 시각이 지났는지 (시각을 모르면 지나지 않은 것으로 본다. 그때는 받아 보면 안다)
    func isExpired(at now: Date = .now) -> Bool {
        guard let date = AgentTime.date(expiresAt) else { return false }
        return date <= now
    }

    /// 그림 아래 한 줄: 설명 · 사이트
    var label: String { label(besides: []) }

    /// 그림 아래 한 줄. 바로 아래에 같은 사이트의 "○○ 열기" 줄이 있으면(`shown`) 사이트 주소를 되풀이하지 않는다 (D83).
    /// `shown`은 `AgentLink.site`로 맞춘 이름이다 (소문자, 앞의 "www." 없이)
    func label(besides shown: Set<String>) -> String {
        let host = pageHost.flatMap { shown.contains(AgentLink.site($0)) ? nil : $0 }
        return [caption, host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 받은 것이 그림인지 (JPEG·PNG의 첫 바이트). 형식 이름만 믿지 않는다
    static func isImage(_ data: Data) -> Bool {
        guard data.count >= 8, data.count <= maxBytes else { return false }
        let head = [UInt8](data.prefix(4))
        return head.starts(with: [0xFF, 0xD8, 0xFF]) || head == [0x89, 0x50, 0x4E, 0x47]
    }

    /// 받은 것이 mp4 영상인지 (4~8번째 바이트가 "ftyp"). 형식 이름만 믿지 않는다
    static func isVideo(_ data: Data) -> Bool {
        guard data.count >= 12, data.count <= maxVideoBytes else { return false }
        return [UInt8](data.prefix(8).suffix(4)) == Array("ftyp".utf8)
    }
}

/// 대화 담당이 작업 담당에게 넘긴 내용: 목적, 대상, 지시
struct AgentBrief: Codable, Equatable, Sendable {
    var purpose: String?
    var targets: [String]?
    var instructions: String?

    var isEmpty: Bool {
        (purpose ?? "").isEmpty && (targets ?? []).isEmpty && (instructions ?? "").isEmpty
    }
}

/// 맥을 거친 답의 말풍선 하나를 누가 썼는지 (`replies[].by`, D62).
enum ReplyWriter: String, Equatable, Sendable, CaseIterable {
    /// Claude가 쓴 글 (일상 답, 되묻는 말, 일을 맡았다는 한 마디, 웹 검색 답)
    case claude
    /// 맥의 로컬 모델이 쓴 글 (읽은 결과에 대한 답, 메일 브리핑)
    case local
    /// 모델이 쓴 글이 아니라 맥에 정해 둔 문장 (로그인 안내, "출처: …" 줄)
    case mac

    /// 맥과 맞춘 값의 이름 (local-ai-agent `docs/API.md`의 `replies[].by`)
    static var allNames: [String] { allCases.map(\.rawValue) }
}

/// 내 말이 이미 있던 작업으로 간 것 (D152, 맥의 D132 `action.steer`)
struct AgentSteer: Equatable, Sendable {
    enum Mode: String, Sendable {
        /// 돌고 있는 작업에 전했다 (단계 사이에 반영한다)
        case inject
        /// 승인 대기·대기열이던 작업을 거두고 바꾼 조건으로 새로 시작했다
        case replace
    }

    let taskID: String
    let mode: Mode

    /// 내 말풍선 아래 작은 줄
    var note: String {
        switch mode {
        case .inject: DemoText.t("진행 중인 작업에 전했어요")
        case .replace: DemoText.t("앞 승인을 거두고 새로 시작해요")
        }
    }
}

/// 작업에 끼워 넣은 내 말 하나 (`steers[]`, D152)
struct AgentSteerNote: Codable, Equatable, Sendable {
    let time: String?
    let text: String
    let applied: Bool

    static let textLimit = 200
}

/// 대화 담당의 답 (`POST /v1/messages`). 메시지마다 네 가지 중 하나를 고른다.
struct AgentReply: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// 일상 대화: 답만 보여 준다
        case none
        /// 정보가 부족해 되묻는다. 선택지가 있으면 버튼으로 보여 준다
        case ask(choices: [String])
        /// 작업을 만들었다. 확인 문장을 보여 주고 작업을 따라간다
        case task(AgentTaskState)
        /// 회의 내용 질문: 맥은 답하지 않고, 앱이 기존 Claude 경로로 처리한다
        case routeClaude
        /// 사이트 로그인이 필요하다: 답 아래에 로그인 화면을 여는 카드를 붙인다 (`site`는 "naver")
        case siteLogin(site: String)
        /// 날씨를 물었다: 답 아래에 앱이 날씨 카드를 그린다 (D66). `place`가 nil이면 지금 위치다
        case weather(place: String?, when: WeatherWhen)
        /// 살 것을 말했다: 답 아래에 앱 안의 쇼핑 화면을 여는 카드를 붙인다 (D74). 맥은 검색어만 정하고, 주소는 앱이 만든다
        case shop(query: String)
    }

    var conversationID: String
    var replies: [String]
    var action: Action
    /// 말풍선마다 누가 썼는지 (`replies`와 같은 차례). 맥이 알려 주지 않았거나 모르는 값이면 nil이고, 그 말에는 표시를 붙이지 않는다
    var writers: [ReplyWriter?] = []

    func writer(at index: Int) -> ReplyWriter? {
        writers.indices.contains(index) ? writers[index] : nil
    }
    /// 로그인 안내(`site_login`)가 "로그인이 없어서 하지 못한 부탁"에 대한 것인지 (`action.resume`, D59).
    /// 맥이 이 표시를 모르면(`site_login_resume` 없음) nil: 앱이 말로 가린다
    var loginResume: Bool?
    /// 대화 담당이 내 이번 말에 단 반응 (이모지 하나, D70). 달지 않았으면 nil.
    /// 앱이 그릴 수 있다고 알린 요청(`client_features`의 "reaction")에만 온다
    var reaction: String?
    /// 이 말로 예약이 바뀌었을 때 붙어 오는 바뀐 뒤의 목록 (D91). 붙어 오지 않았으면 nil
    var routines: [AgentRoutine]?
    /// 되물을 때 맥이 권하는 후보 (`action.recommended`, D110). 선택지 가운데 하나일 때만
    var recommended: String?
    /// 한 줄로 끝난 일이라 말풍선 대신 상태 줄로 보일 말의 차례 (`replies[].kind: "status"`, D110)
    var statusLines: Set<Int> = []
    /// 되물을 때 여러 개를 함께 고르는지 (`action.multi`, D111). 고른 것들을 ", "로 이어 한 말로 보낸다
    var multi = false
    /// 후보마다의 대표 그림 (`action.choice_details[].image`, D111). 공개 https 주소만, 후보의 글로 찾는다
    var choiceImages: [String: URL] = [:]
    /// 답 뒤에 이어 할 말 (`action.next`, D111). 고르면 사용자가 친 말처럼 보낸다
    var next: [String] = []
    var nextRecommended: String?
    /// 말풍선마다 소리로 읽을 글 (`replies[].speak`, D134). 통화 중인 말에만 온다. 없으면 nil
    var speaks: [String?] = []
    /// 말풍선마다 맥이 만들기 시작한 목소리의 번호 (`replies[].voice_id`, D136). 없으면 nil
    var voiceIDs: [String?] = []
    /// 내 말이 이미 있던 작업으로 갔다 (D152): `steer` 행동(inject), 또는 작업 행동에 붙은 `steer`(replace)
    var steer: AgentSteer?
    func voiceID(at index: Int) -> String? { voiceIDs.indices.contains(index) ? voiceIDs[index] : nil }

    func isStatus(at index: Int) -> Bool { statusLines.contains(index) }
    func speak(at index: Int) -> String? { speaks.indices.contains(index) ? speaks[index] : nil }
}

/// 고르기 카드의 후보 (D111): 맥이 준 후보를 정리한다
enum AgentChoices {
    /// 되물을 때 후보는 6개까지, 답 뒤의 다음 말은 3개까지
    static let askLimit = 6
    static let nextLimit = 3
    static let textLimit = 80

    static func clean(_ list: [String]?, limit: Int) -> [String] {
        var seen = Set<String>()
        return (list ?? [])
            .map { $0.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(limit)
            .map { String($0.prefix(textLimit)) }
    }

    /// 여러 개를 고른 답: 후보의 차례대로 ", "로 잇는다
    static func joined(_ picked: Set<String>, in choices: [String]) -> String {
        choices.filter(picked.contains).joined(separator: ", ")
    }

}

/// 대화 담당이 내 말에 다는 반응 (D70). 맥과 맞춘 여덟 개만 받는다
enum AgentReaction {
    static let allowed = ["👍", "❤️", "😂", "😮", "😢", "🙏", "👌", "🎉"]

    /// 정해 둔 이모지면 그 이모지를, 아니면 nil을 준다 (모르는 값은 그리지 않는다).
    /// 하트는 꾸밈 표시(U+FE0F)가 붙어 오든 빠져 오든 같은 것으로 읽는다
    static func known(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let bare = strip(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        return allowed.first { strip($0) == bare }
    }

    private static func strip(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0xFE0F }))
    }
}

extension AgentTaskState {
    /// 보내기 전 기다리는 동안 취소했을 때
    static let sendCanceledText = "보내기를 취소했어요. 메일은 보내지 않았어요."

    /// 메일을 보내지 못했을 때의 문장. 이유는 종류만 온다 (비밀번호나 메일 서버의 응답은 오지 않는다)
    static func sendFailureText(_ reason: String?) -> String {
        switch reason {
        case "auth_failed": "메일 계정에 로그인하지 못해 보내지 못했어요. 메일 계정을 다시 연결해 주세요. 보낸 메일은 없어요."
        case "unreachable": "메일 서버에 연결하지 못해 보내지 못했어요. 보낸 메일은 없어요."
        case "not_set": "메일 계정이 연결되어 있지 않아 보내지 못했어요. 보낸 메일은 없어요."
        case "rate_limited": "보내기 한도를 넘어 보내지 못했어요. 보낸 메일은 없어요."
        case "not_allowed": "내 주소가 아닌 곳으로는 보낼 수 없어요. 보낸 메일은 없어요."
        case "rejected": "메일 서버가 받아 주지 않아 보내지 못했어요. 보낸 메일은 없어요."
        // 맥이 초안의 날짜를 검사한다: 원문에 없는 연도가 다시 써도 남으면 승인 화면으로 보내지 않고 끝낸다 (D63)
        case "invented_date": "맥이 쓴 초안에 원문에 없는 연도가 들어가 있어 보내지 않았어요. 보낸 메일은 없어요."
        default: "메일을 보내지 못했어요. 보낸 메일은 없어요."
        }
    }

    /// 사이트에 로그인하면 풀리는 실패인지 (로그인이 없거나 풀려서 멈춤)
    var needsSiteLogin: Bool { phase == .failed && loginSite != nil }

    /// 로그인 때문에 멈췄을 때 작업 카드에 쓰는 문장
    static func loginFailureText(site: String?, expired: Bool) -> String {
        let name = site.map(SiteName.display)
        if expired { return name.map { "\($0) 로그인이 풀려서 멈췄어요." } ?? "로그인이 풀려서 멈췄어요." }
        return name.map { "\($0) 로그인이 필요해서 멈췄어요." } ?? "로그인이 필요해서 멈췄어요."
    }

    /// 메일 계정을 연결하면 풀리는 실패인지 (로그인 실패·계정 없음)
    var needsMailAccount: Bool { phase == .failed && (sendFailure == "auth_failed" || sendFailure == "not_set") }

    /// 작업 카드 제목: 서버 제목이 없으면 부탁한 글의 첫 줄
    var title: String {
        if let serverTitle, !serverTitle.isEmpty { return serverTitle }
        let first = task.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if first.isEmpty { return "맥 에이전트 작업" }
        return first.count > 28 ? first.prefix(27).trimmingCharacters(in: .whitespaces) + "…" : first
    }

    /// 작업 카드의 상태 이름
    var statusLabel: String { DemoText.t(statusLabelKorean) }

    private var statusLabelKorean: String {
        switch phase {
        case .running: isQueued ? "대기 중" : "진행 중"
        case .awaitingApproval: "승인 필요"
        case .awaitingInput: "답변 필요"
        case .sendPending: "보내기 대기"
        case .done: "완료"
        case .needsInput: "답변 필요"
        case .canceled: "취소됨"
        case .failed: "실패"
        }
    }

    /// 지금 상태를 한 문장으로 (작업 카드·작업 상세)
    var currentStatus: String { DemoText.t(currentStatusKorean) }

    private var currentStatusKorean: String {
        switch phase {
        case .running:
            isQueued ? (waitReason ?? "앞 작업이 끝나기를 기다리고 있어요") : (activity ?? "작업을 준비하고 있어요")
        case .awaitingApproval:
            draft?.isSend == true ? "보낼 메일을 확인해 주세요" : (draft?.isAction == true ? "누를 단추를 확인해 주세요" : "초안을 확인해 주세요")
        case .awaitingInput: pendingQuestion?.received == true ? "답을 받아 이어서 진행해요" : "질문에 답해 주세요"
        case .sendPending: "곧 메일을 보내요. 그 전에는 취소할 수 있어요"
        case .done:
            if !sent.isEmpty {
if sent.allSatisfy({ $0.verified == .delivered }) {
                    "메일을 보냈고 도착을 확인했어요"
                } else {
                    sent.contains { $0.external == true } ? "메일을 보냈어요. 받는 분의 도착은 확인할 수 없어요" : "메일을 보냈어요. 도착은 확인하지 못했어요"
                }
            } else {
                savedDrafts.isEmpty ? "작업을 마쳤어요" : "초안 \(savedDrafts.count)개를 저장했어요"
            }
        case .needsInput: "정보가 더 필요해요"
        case .canceled: error ?? Self.canceledText
        case .failed: error ?? Self.unfinishedText
        }
    }

    // MARK: 대화의 작업 줄 (D82)

    /// 끝난 작업인지 (완료·취소·실패). 대화의 작업 줄은 끝난 작업을 약한 글씨 한 줄로만 둔다
    var isSettled: Bool { phase == .done || phase == .canceled || phase == .failed }

    /// 작업 줄에서 제목 뒤에 붙는 상태 이름. 완료는 체크 표시가, 일하는 중은 아래의 한 문장이 말하므로 붙이지 않는다
    var lineStatus: String? {
        phase == .done || isWorking ? nil : statusLabel
    }

    /// 작업 줄 아래에 붙는 "지금 하는 일" 한 문장. 맥이 일하는 동안에만 있다 (앞 작업을 기다리는 중 포함)
    var lineActivity: String? { isWorking ? currentStatus : nil }

    /// 까닭을 따로 담지 않은 문장들: 멈췄다는 것만 말한다
    static let canceledText = "작업을 취소했어요."
    static let deniedText = "승인하지 않아 작업을 끝냈어요."
    static let unfinishedText = "작업을 끝내지 못했어요."

    /// 끝내지 못한 작업에서 말풍선으로 말할 까닭 한 문장 (D82). 없으면 말하지 않는다.
    /// 작업 줄은 "취소됨"·"실패"만 말하므로 까닭은 말로 하되, 바로 아래에서 같은 말을 또 하게 되면 뺀다:
    /// - 로그인 카드가 붙으면 카드가 "○○ 로그인이 풀렸어요"라고 말한다
    /// - 까닭 없이 멈췄다고만 하는 문장(취소·승인하지 않음·끝내지 못함)은 보고에 하지 못한 일이 적혀 있으면 그 보고가 말한다
    /// 시간 초과·사이트의 차단·보내기 취소처럼 까닭이 담긴 문장은 보고가 있어도 그대로 말한다
    func stopReason(showsLoginCard: Bool) -> String? {
        guard phase == .canceled || phase == .failed else { return nil }
        if showsLoginCard { return nil }
        let reason = currentStatus
        let saysOnlyStopped = [Self.canceledText, Self.deniedText, Self.unfinishedText].contains(reason)
        if saysOnlyStopped, let report, !report.blocked.isEmpty { return nil }
        return reason
    }

    /// 못 한 일의 답변 카드에 붙일 한 줄 까닭 (D118). 맥이 부제도 블록도 없이 "하지 못했어요"만 보내면
    /// 카드에 단추만 덩그러니 남았다. 보고의 못 한 일 → 멈춘 까닭 → 결과 글 순서로 찾고, 제목과 같은 말은 쓰지 않는다
    func cardReason(for card: AgentReportCard) -> String? {
        guard card.kind == .failed, card.subtitle == nil, card.blocks.isEmpty else { return nil }
        let candidates = (report?.blocked ?? []) + [stopReason(showsLoginCard: false), error, result].compactMap { $0 }
        let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != title && ![Self.canceledText, Self.deniedText, Self.unfinishedText].contains($0) }
    }

    /// 결과 아래의 "○○ 열기" 줄에 쓸 주소 (D81, D82).
    /// 보고가 있으면 보고의 근거 주소만 쓴다 (사이트마다 하나). 맥이 근거를 비워 보낸 것은 그 사이트의 화면에서 나온 답이 아니라는 뜻이라
    /// 그때는 줄을 두지 않는다: 마지막으로 머문 페이지(`links`)로 되돌아가지 않는다. `links`는 보고를 보내지 않는 예전 맥에서만 쓴다
    var openLinks: [AgentLink] {
        guard let report else { return links ?? [] }
        return AgentLink.onePerSite(report.sources.compactMap(AgentLink.openable))
    }

    /// 대화에서 승인한 초안이 결과의 본문이고 보고는 그 아래 덧말인지: 못 한 일이 없는 보고 + 보내거나 저장한 초안
    var reportFollowsDrafts: Bool {
        guard let report, !(report.done.isEmpty && report.blocked.isEmpty) else { return false }
        return report.blocked.isEmpty && !(sentDrafts.isEmpty && savedDrafts.isEmpty)
    }

    /// 대화에서 답 아래에 "Claude 사용"을 붙일지: 끝난 작업의 답을 Claude가 썼다고 맥이 알렸을 때 (D65)
    var marksClaudeOnResult: Bool {
        guard phase == .done, let report, !report.done.isEmpty, report.by == ReplyWriter.claude.rawValue else { return false }
        return !reportFollowsDrafts
    }

    /// 일을 맡았다는 한 마디 아래에 "Claude 사용"을 붙일지 (D62).
    /// 표시는 한 차례에 한 번만 한다 (D83): 답 아래에 붙으면 여기에는 붙이지 않는다
    var marksClaudeOnAck: Bool {
        ack != nil && ackBy == ReplyWriter.claude.rawValue && !marksClaudeOnResult
    }

    /// 작업 상세의 기록. 맥이 쓴 진행 설명이 있으면 그것으로(시각 포함), 없으면 단계 기록으로 만든다.
    /// 단계 기록에서는 동작 줄(열기·입력·누르기)은 흐리게, 승인·거부 같은 고비는 굵게 보여 준다
    var timeline: [AgentEvent] {
        if let narration, !narration.isEmpty {
            return narration.enumerated().map { index, line in
                AgentEvent(id: index, kind: .narration, text: line.text, time: AgentEvent.clock(line.time))
            }
        }
        return steps.enumerated().map { index, text in
            AgentEvent(id: index, kind: AgentEvent.milestones.contains { text.hasPrefix($0) } ? .milestone : .action, text: text)
        }
    }

    /// 단계가 이보다 많으면 앞의 것을 접고 마지막 `stepsShownWhenFolded`개만 보인다 (D112)
    static let stepFoldThreshold = 10
    static let stepsShownWhenFolded = 6

    static func foldedStepCount(_ total: Int) -> Int {
        total > stepFoldThreshold ? total - stepsShownWhenFolded : 0
    }

    /// 작업 담당이 묻고 있고 아직 답하지 않은 질문
    var openQuestion: AgentQuestion? {
        guard phase == .awaitingInput, let pendingQuestion, pendingQuestion.received != true else { return nil }
        return pendingQuestion
    }

    /// 맥이 일하는 중인지 (진행 중이거나, 답을 받아 이어 가는 중)
    var isWorking: Bool {
        phase == .running || (phase == .awaitingInput && pendingQuestion?.received == true)
    }

    /// 보낸 메일의 결과 (보내기에 실패한 것은 뺀다)
    var sent: [AgentSent] { (report?.sent ?? []).filter { $0.verified != .failed } }

    /// 승인해 보낸 메일 (내용)
    var sentDrafts: [AgentDraft] { approvedDrafts.filter(\.isSend) }

    /// 승인해 저장만 한 초안
    var savedDrafts: [AgentDraft] { approvedDrafts.filter { !$0.isSend } }

    /// 로그인한 사이트의 화면을 Claude가 봐도 되는지 묻는 허락 질문인지 (맥의 `site_do`, D80).
    /// 맥은 이 질문에서 선택지의 글 그대로만 답으로 받는다: 입력창에 쓴 글은 허락으로 치지 않고 하지 않은 채 끝낸다.
    /// 선택지가 맥의 것과 한 글자라도 다르면 보통 질문으로 본다 (모르는 질문에 "단추로만"이라고 잘못 말하지 않는다)
    var asksSitePermission: Bool {
        skill == AgentTaskState.siteDoSkill && openQuestion?.choices == AgentTaskState.sitePermissionChoices
    }

    /// 승인한 단추를 말하는 줄 (D80). "눌렀다"고 하지 않는다: 맥이 주는 것은 승인받은 단추의 이름이고, 한 일은 보고가 말한다
    var approvedActionsLine: String? {
        guard let names = approvedActions, !names.isEmpty else { return nil }
        return "승인한 단추: " + names.map { "'\($0)'" }.joined(separator: ", ")
    }

    /// 입력은 했는데 승인·저장 없이 끝났는지 (보고가 "작성했다"여도 저장된 것은 없다).
    /// 찾아보기·둘러보기·읽기처럼 기술로 하는 작업(`skill`)은 처음부터 저장할 것이 없다: 검색칸에 글을 넣은 것은 여기에 들지 않는다 (D77)
    var typedWithoutSaving: Bool {
        phase == .done && skill == nil && approvedDrafts.isEmpty && steps.contains { $0.hasPrefix("입력") }
    }
}

/// 작업 기록의 한 줄
struct AgentEvent: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case action, milestone, narration }

    static let approvalRequested = "승인 요청"
    static let feedbackApplied = "거부 사유 반영"
    static let milestones = [approvalRequested, feedbackApplied]

    let id: Int
    let kind: Kind
    let text: String
    /// 그 일이 있었던 시각 ("오후 3:10"). 맥이 알려 준 경우에만
    var time: String?

    /// 서버 시각(ISO 8601, UTC)을 이 기기의 시각 표기로 바꾼다
    static func clock(_ iso: String?) -> String? {
        guard let iso, let date = try? Date(iso, strategy: .iso8601) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// 서버가 알려 주는 기능 이름 (`GET /v1/health`의 `features`). 앱은 여기 있는 기능만 켠다
enum AgentFeature {
    /// 작업 담당의 질문 (`awaiting_input`). 작업을 만드는 요청에 `X-Api-Version: 2`를 붙여야 켜진다
    static let taskQuestions = "task_questions"
    /// 같은 `client_message_id`로 다시 보내면 새로 판단하지 않고 처음 응답을 돌려준다
    static let messageReplay = "client_message_id"
    /// 대화 답변의 말투 (`tone`: friendly·formal). 답하는 말만 바뀌고 판단·작업·초안은 그대로다
    static let tone = "tone"
    /// 본인 주소로 메일 보내기. 작업을 만드는 요청에 `X-Api-Version: 3`을 붙여야 보내기 작업이 만들어진다
    static let sendSelf = "send_self"
    /// 앱에서 메일 계정 연결 (앱 비밀번호를 받아 작업을 실행하는 쪽의 보안 저장소에 넣는다. 지금은 맥의 키체인)
    static let mailConnect = "mail_connect"
    /// 에이전트 브라우저의 사이트 로그인을 앱에서 대신 채우기 (D48). 메시지 요청에 `X-Api-Version: 4`를 붙여야
    /// 대화 담당이 "로그인 화면 열기"(`site_login`)로 답한다
    static let siteLogin = "site_login"
    /// 보고의 화면 캡처 (`result.report.attachments`, D56). 맥에서 켰을 때만 온다.
    /// 앱은 이 이름을 확인하지 않는다: 캡처가 오면 보여 주고, 안 오면 아무것도 달라지지 않는다
    static let reportAttachments = "report_attachments"
    /// 맡길 수 있는 일 카드 (`GET /v1/skills`, D53)
    static let skills = "skills"
    /// 로그인 안내에 "하지 못한 부탁이 있다"는 표시가 온다 (`action.resume`, D59). 있으면 로그인 뒤 그 부탁을 다시 보낸다
    static let siteLoginResume = "site_login_resume"
    /// 답의 말풍선마다 누가 썼는지(`replies[].by`)가 붙는다 (D62). 있으면 Claude가 쓴 답 아래에 "Claude 사용"을 붙인다
    static let replyBy = "reply_by"
    /// "찾아 달라"는 말이 작업이 된다: 검색으로 답을 찾고, 맥이 격리된 브라우저로 그 답에 나온 공개 페이지를 직접 연다 (D64·D65). 설명만 바꾼다
    static let webFind = "web_find"
    /// 그 작업이 페이지를 네이버 검색 API로 찾는다 (D65). 없으면 Anthropic의 웹 검색이다. 설명만 바꾼다
    static let webFindNaver = "web_find_naver"
    /// 그 작업에서 맥의 브라우저가 연 공개 페이지의 글을 Claude가 읽는다 (D66. 맥의 기본은 꺼짐). 설명만 바꾼다
    static let webFindReadsCloud = "web_find_reads_cloud"
    /// 정해진 기능에 없는 부탁을 맥의 격리 브라우저로 직접 해 본다 (D76). 그 작업에서는 브라우저가 연 공개 페이지의 화면 글을
    /// Claude가 보고 무엇을 누를지 정한다. 응답의 꼴은 찾기 작업과 같고, 앱은 데이터 처리 방식의 글만 달리 쓴다
    static let webBrowse = "web_browse"
    /// 그 작업의 보고에 맥이 열어 읽은 페이지(`report.links`: 제목·주소·대표 그림 주소)가 실릴 수 있다 (D64).
    /// 앱은 오면 그리고, 이 이름으로는 설명만 바꾼다
    static let reportLinks = "report_links"
    /// 답장으로 가리킨 작업을 함께 보낸다 (`reply_to.task_id`, D59). 맥은 그 대화의 작업일 때만 쓴다
    static let replyTo = "reply_to"
    /// 지금 시각을 함께 보낸다 (`client_time`, D59). "오늘·내일" 같은 말을 이 기기의 시각으로 읽는다
    static let clientTime = "client_time"
    /// 대화 판단(답할지·되물을지·일로 만들지)을 Claude가 한다 (D60). 맥에서 켰을 때만 온다.
    /// 요청과 응답의 꼴은 같다. 앱은 이 이름으로 "내 말이 어디로 가는지" 설명만 바꾼다 (`DialogPlaceModel`)
    static let dialogCloud = "dialog_cloud"
    /// 앱이 붙인 회의 자료의 내용이 Claude로 간다 (D61). `dialog_cloud`는 있는데 이것이 없으면 "붙어 있다"는 사실만 간다
    static let dialogContext = "dialog_context"
    /// 공개 정보(날씨·가격·뉴스 등)를 웹 검색으로 찾아 답한다 (D61). `dialog_cloud`가 있을 때만 온다.
    /// 응답의 꼴은 평소 답과 같다(출처는 마지막 말풍선의 글 한 줄). 앱은 이 이름으로 설명만 바꾼다
    static let webLookup = "web_lookup"
    /// 날씨 물음에 맥이 답을 쓰지 않고 "날씨 카드를 그려라"(`action.type == "weather"`)로 답할 수 있다 (D66).
    /// 이 이름이 있을 때만 요청에 `client_features`와 `events`를 넣는다 (모르는 키를 받은 맥은 요청을 거절한다)
    static let weatherAction = "weather_action"
    /// 맥이 알림을 보낼 수 있다 (D67. 맥에 Apple 알림 키를 넣어 두었을 때만 온다).
    /// 이 이름이 있을 때만 이 기기의 알림 주소를 맥에 등록한다 (`POST /v1/push/devices`)
    static let push = "push"
    /// 알림에 띄울 실제 글을 맥이 따로 준다 (D73, `GET /v1/tasks/{id}/notification`). 알림 확장이 받아 바꿔 띄운다 (`PushText`).
    /// 앱은 이 이름을 "데이터 처리 방식"의 설명에만 쓴다 (확장은 묻지 않고 청해 보고, 못 받으면 정해진 문장을 둔다)
    static let pushText = "push_text"
    /// 대화 담당이 내 말에 반응(이모지 하나)을 달 수 있다 (D70. 대화 판단을 Claude가 할 때만 온다).
    /// 이 이름이 있을 때만 요청의 `client_features`에 "reaction"을 넣는다. 그 요청에는 말 없이 반응만 올 수 있다
    static let reaction = "reaction"
    /// 찾은 상품을 목록(`result.report.items`)으로 보낼 수 있다 (D72).
    /// 이 이름이 있을 때만 목록에 "고르기"를 두고, 고른 상품의 번호를 `reply_to.item_id`로 함께 보낸다
    static let reportItems = "report_items"
    /// 쇼핑 "옆에서 봐 주기" (D74. 대화 판단을 Claude가 할 때만 온다).
    /// 이 이름이 있을 때만 요청의 `client_features`에 "shop"을 넣고, "확인해 줘"를 누른 화면의 값(`view`)을 보낸다
    static let shopView = "shop_view"
    /// 쇼핑 "스스로 찾아 오기" (D75). 맥의 작업이 이 아이폰의 쇼핑 화면에 검색과 상품 열기를 시키고, 앱이 읽은 것을 돌려받는다.
    /// 이 이름이 있을 때만 요청의 `client_features`에 "shop_drive"를 넣는다
    static let shopDrive = "shop_drive"
    /// 사진·PDF 붙여 묻기 (D85. 맥의 D73). 붙인 것은 맥을 거쳐 Claude가 직접 본다.
    /// 이 이름이 있을 때만 입력창에 "+"를 두고, `POST /v1/uploads`로 올린 뒤 그 번호를 메시지의 `uploads`에 넣는다
    static let uploads = "uploads"
    /// 다른 사람에게 메일 보내기 (D89. 맥의 D77). 받는 사람은 연락처의 이름이거나 내가 직접 쓴 주소다.
    /// 형식은 본인에게 보내기와 같고, 승인과 결과에 `external: true`가 붙는다
    static let sendOthers = "send_others"
    /// 예약해 둔 일 (D91. 맥의 D80): 정한 때에 정한 말을 맥이 대신 건넨다.
    /// 이 이름이 있을 때만 예약 화면을 두고 `/v1/routines`를 부른다
    static let routines = "routines"
    /// 활동 목록과 전역 검색 (`/v1/activity`, `/v1/search`, 맥의 D103). 없으면 활동 탭에는 이 기기의 회의만 보인다 (D120)
    static let activity = "activity"
    /// 손 넘기기 (D123, 맥의 D106): 사람 확인 퍼즐 같은 화면을 폰에서 직접 푼다
    static let handover = "handover"
    /// 에이전트에게 거는 전화 (D134, 맥의 D116). 있을 때만 대화 화면에 전화 단추를 두고, 통화 중인 말에 `client_features`의 "voice_call"을 넣는다
    static let voiceCall = "voice_call"
    /// 통화 답을 내 목소리로 (D136, 맥의 D117): `/v1/voice/…`로 조각을 받아 재생한다
    static let voiceTTS = "voice_tts"
    /// 오래 가는 기억 (D151, 맥의 D129): 있을 때만 내 정보에 "기억" 줄을 두고 `/v1/memory`를 부른다
    static let memory = "memory"
    /// 이 이름이 있을 때만 내 공간을 쓴다 (`/v1/space`, D94)
    static let space = "space"
    /// 이 이름이 있을 때만 내 공간의 카드를 손으로 옮기고·크기를 바꾸고·뺀다 (`POST /v1/space/arrange`, D100)
    static let spaceArrange = "space_arrange"
}

/// 메시지에 덧붙여 보내는 것 (D66). 맥이 그 기능을 알 때만 실제로 간다
struct MessageExtras: Equatable, Sendable {
    /// 앱이 그릴 수 있는 것 ("weather": 날씨 카드, "reaction": 내 말에 붙는 반응)
    var clientFeatures: [String] = []
    /// 지난 말 뒤로 앱이 보여 준 것 (날씨 카드에 보인 내용 한 줄씩). 맥은 대화 기록에 적어 다음 판단에 쓴다
    var weatherEvents: [String] = []
    /// 답장으로 가리킨 작업의 목록에서 고른 상품의 번호 (`reply_to.item_id`, D72). 작업 번호와 함께일 때만 간다
    var replyItemID: String?
    /// 작업이 아닌 말풍선에 답장했을 때 그 말풍선의 글과 누구의 말인지 (`reply_to.text`·`role`, D124, 맥의 D108)
    var replyQuote: ReplyQuote?

    struct ReplyQuote: Equatable, Sendable {
        enum Role: String, Sendable {
            case user, assistant
        }

        let text: String
        let role: Role

        /// 맥이 받는 글 길이
        static let limit = 500

        init?(text: String, role: Role) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            self.text = String(trimmed.prefix(Self.limit))
            self.role = role
        }
    }
    /// 앱 안의 쇼핑 화면에서 "확인해 줘"를 눌러 읽은 것 (D74). 그 말을 보낼 때만 간다 (화면을 옮길 때마다 가지 않는다)
    var view: ShopView?
    /// 이 말에 붙인 사진·PDF의 번호 (맥에 올리고 받은 `u_…`, D85). 4개까지 간다
    var uploads: [String] = []
    /// 내 말에 이름이 나온 연락처의 `{이름: 메일 주소}` (D89). 주소록 전체가 아니다
    var contacts: [String: String] = [:]
    /// 내 말에 이름이 나왔지만 메일 주소가 없는 연락처의 이름 (D92)
    var contactsNoEmail: [String] = []

    static let none = MessageExtras()
    /// 앱이 날씨 카드를 그릴 수 있다는 표시
    static let weatherFeature = "weather"
    /// 앱이 반응을 그릴 수 있다는 표시 (D70)
    static let reactionFeature = "reaction"
    /// 앱이 쇼핑 화면을 열 수 있다는 표시 (D74)
    static let shopFeature = "shop"
    /// 앱이 맥의 작업이 시키는 대로 쇼핑 화면을 옮기고 읽어 줄 수 있다는 표시 (D75)
    static let shopDriveFeature = "shop_drive"
    /// 통화 중인 말이라는 표시 (D134)
    static let voiceCallFeature = "voice_call"
    /// "쇼핑 화면을 열어라"는 답을 받을 수 있는 요청인지
    var acceptsShop: Bool { clientFeatures.contains(Self.shopFeature) }
    /// 반응만 오고 말은 없는 응답을 받을 수 있는 요청인지
    var acceptsReaction: Bool { clientFeatures.contains(Self.reactionFeature) }
    /// 한 번에 알리는 개수 (맥과 맞춘 값)
    static let eventLimit = 3
    /// 한 말에 붙이는 사진·PDF의 수 (맥과 맞춘 값. 넘는 것은 맥이 버린다)
    static let uploadLimit = 4
}

/// 처리한 곳으로 가는 링크
struct AgentLink: Codable, Equatable, Sendable {
    let title: String
    let url: URL
    /// 그 페이지가 대표 그림으로 적어 둔 주소 (`report.links[].image`, D64). 나중에 더한 값이라 옵셔널이다.
    /// 그림은 여기 없다 — 카드를 그릴 때 아이폰이 그 사이트에서 직접 받아 메모리에서만 쓴다 (`LinkThumbnailStore`)
    var image: URL?

    /// 아이폰에서 열 만한 주소만 링크로 만든다: https이고, 테스트·내부 주소가 아닐 것
    static func openable(_ string: String?) -> AgentLink? {
        guard let string, let url = URL(string: string), url.scheme == "https",
              let host = url.host()?.lowercased(), host.contains(".") else { return nil }
        let blocked = [".test", ".example", ".invalid", ".localhost", ".local", ".internal", ".ts.net"]
        guard !blocked.contains(where: host.hasSuffix), host.contains(where: \.isLetter) else { return nil }
        return AgentLink(title: host, url: url)
    }

    /// "○○ 열기" 줄은 사이트마다 하나만 둔다. 줄의 글자가 사이트 주소뿐이라, 같은 사이트의 페이지가 여럿이면
    /// 똑같은 줄이 되풀이된다 (D81). 남기는 것은 그 사이트에서 마지막으로 연 페이지 — 맥은 연 차례대로 보낸다.
    /// 줄의 차례는 사이트가 처음 나온 차례이고, 앞의 "www."만 다른 주소는 같은 사이트로 본다
    static func onePerSite(_ links: [AgentLink]) -> [AgentLink] {
        var order: [String] = []
        var last: [String: AgentLink] = [:]
        for link in links {
            let host = link.url.host()?.lowercased() ?? link.url.absoluteString
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if last[site] == nil { order.append(site) }
            last[site] = link
        }
        return order.compactMap { last[$0] }
    }

    /// 한 보고에서 보여 주는 페이지 수 (`report.links`, D64)
    static let reportLimit = 5

    /// 공개 웹 주소만 돌려준다: https, 공개 도메인(숫자 주소·내부 이름 아님), 아이디·비밀번호가 든 주소 아님, 500자 이하.
    /// 맥도 같은 것을 거르지만, 아이폰이 직접 접속하는 주소라 앱도 한 번 더 본다
    static func publicURL(_ string: String?) -> URL? {
        guard let string, string.count <= 500, let url = openable(string)?.url,
              url.user() == nil, url.password() == nil,
              let host = url.host()?.lowercased(), !host.contains(":"),
              let top = host.split(separator: ".").last,
              top.count >= 2, top.allSatisfy(\.isLetter) || top.hasPrefix("xn--") else { return nil }
        return url
    }

    /// 맥의 브라우저가 열어 읽은 페이지 하나. 주소가 열 만하지 않으면 버린다. 그림 주소만 맞지 않으면 그림만 버린다.
    /// 제목은 줄바꿈과 앞뒤 빈칸을 정리해 80자까지 쓰고, 없으면 사이트 주소를 쓴다
    static func page(title: String?, url: String?, image: String?) -> AgentLink? {
        guard let url = publicURL(url) else { return nil }
        let link = AgentLink(title: "", url: url)
        let title = (title ?? "").components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return AgentLink(title: title.isEmpty ? link.host : String(title.prefix(80)), url: url, image: publicURL(image))
    }

    /// 화면에 보일 사이트 주소 (앞의 "www."는 뺀다). 맥이 준 `site` 값이 아니라 실제로 열리는 주소에서 뽑는다
    var host: String { Self.site(url.host() ?? url.absoluteString) }

    /// 사이트를 견줄 때 쓰는 이름: 소문자, 앞의 "www." 없이
    static func site(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// 승인을 받을 초안 (저장하려는 입력칸들)
struct AgentDraft: Codable, Equatable, Sendable {
    struct Field: Codable, Equatable, Sendable {
        let label: String
        let value: String
    }

    /// 승인·거부할 때 함께 보내는 번호. 고친 초안이 오면 바뀐다
    let approvalID: String?
    /// "임시 저장" 같은 동작 이름
    let action: String
    let fields: [Field]
    /// 거부 사유를 반영해 다시 쓴 횟수 (처음 1)
    var revision: Int = 1
    /// 서버가 고정한 초안의 해시 (16진수 64자). 저장한 초안에는 승인한 해시
    var sha256: String?
    /// 앱이 받은 내용으로 직접 계산한 해시. 승인할 때 이 값을 보내, 화면에 보인 내용과 맥에 고정된 초안이 같을 때만 실행되게 한다
    var shownSHA256: String?
    /// 서버가 이미 받은 결정 ("approve"·"reject"). 있으면 처리 중이라 다시 묻지 않는다
    var received: String?
    /// 동작 종류 ("draft"·"send"·"action"). 나중에 더한 값이라 옵셔널
    var kind: String?
    /// 단추를 누를 화면의 사이트 주소 (호스트만. `kind`가 "action"일 때만 적는다, D80).
    /// 로그인한 화면의 주소 전체는 적지 않는다. 나중에 더한 값이라 옵셔널
    var site: String?
    /// 받는 사람이 내가 아닌 메일 (`approval.external`, D89). 나중에 더한 값이라 옵셔널
    var external: Bool?
    /// 누르려는 단추가 있는 그 화면 (`approval.attachment`, D93). 무엇을 승인하는지 눈으로 볼 수 있게. 나중에 더한 값이라 옵셔널
    var attachment: AgentAttachment?

    /// 다른 사람에게 보내는 메일인지 (보내면 되돌릴 수 없다: 받는 사람을 눈에 띄게 보여 준다)
    var isExternal: Bool { isSend && external == true }
    /// 저장이 아니라 실제로 보내는 메일인지
    var isSend: Bool { kind == "send" }
    /// 초안이 아니라, 로그인한 사이트의 화면에서 단추 하나를 누르는 승인인지 (맥의 `site_do`, D80).
    /// `action`이 누를 단추의 글이고, `fields`는 그 화면에 넣은 값이다 (없을 수 있다)
    var isAction: Bool { kind == AgentDraft.actionKind }
    static let actionKind = "action"

    /// 승인 카드에 보일 사이트 주소: 주소에서 호스트만 뽑는다 (http·https만, 앞의 "www."는 뺀다). 읽지 못하면 없다
    static func siteHost(_ url: String?) -> String? {
        guard let url, let parts = URLComponents(string: url), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), !host.isEmpty, host.count <= 253 else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// 단추 누르기 승인에서, 보여 준 내용과 맥에 고정된 내용이 달라 승인이 받아들여지지 않았을 때의 말 (초안의 말을 쓰지 않는다)
    static let actionMismatchText = "보여 드린 내용과 맥에 있는 내용이 달라서 승인하지 않았어요. 누를 단추와 내용을 다시 확인해 주세요."

    /// 승인할 때 보낼 해시: 화면에 보인 내용으로 계산한 값이 먼저다
    var approvalHash: String? { shownSHA256 ?? sha256 }
    /// 화면에 보여 줄 짧은 확인 번호 (해시 앞 8자리)
    var shortHash: String? { (sha256 ?? shownSHA256).map { String($0.prefix(8)) } }

    static let recipientLabel = "받는 사람"

    var title: String? { value(of: "제목") }
    var body: String? { value(of: "본문") }
    /// 제목·본문 외의 칸 (받는 사람 등)
    var otherFields: [Field] { fields.filter { $0.label != "제목" && $0.label != "본문" } }

    private func value(of label: String) -> String? {
        fields.first { $0.label == label }?.value
    }

    /// 서버가 주는 입력칸 사전을 보기 좋은 순서로 (JSON 객체는 순서가 보장되지 않는다)
    static func orderedFields(_ fields: [String: String]) -> [Field] {
        let preferred = ["보내는 사람", "받는 사람", "참조", "제목", "본문"]
        let known = preferred.compactMap { key in fields[key].map { Field(label: key, value: $0) } }
        let rest = fields.keys.filter { !preferred.contains($0) }.sorted().map { Field(label: $0, value: fields[$0] ?? "") }
        return known + rest
    }
}

protocol AgentProviding: Sendable {
    /// 맥에 연결되는지 (Tailscale·맥 전원·서버 상태)
    func isReachable() async -> Bool
    /// 작업을 맡긴다. context는 앱이 고른 회의 발췌 (8000자 이하, 서버에 저장되지 않음)
    /// 대화 담당에게 메시지를 보낸다. `conversationID`는 처음엔 nil, 다음부터는 응답으로 받은 값.
    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply
    /// 위와 같되 메시지 번호를 함께 보낸다. 응답을 받지 못해 같은 번호로 다시 보내면 맥은 처음 결과를 돌려준다 (작업이 두 개 생기지 않는다)
    func message(_ text: String, conversationID: String?, context: String?, messageID: String?) async throws -> AgentReply
    /// 위와 같되, 답장으로 가리킨 작업의 번호를 함께 보낸다 (맥이 `reply_to`를 알 때만 실제로 간다)
    func message(_ text: String, conversationID: String?, context: String?, messageID: String?, replyTaskID: String?) async throws -> AgentReply
    /// 위와 같되, 앱이 그릴 수 있는 것과 앱이 보여 준 것을 함께 보낸다 (맥이 `weather_action`을 알 때만 실제로 간다, D66)
    func message(
        _ text: String, conversationID: String?, context: String?, messageID: String?, replyTaskID: String?, extras: MessageExtras
    ) async throws -> AgentReply
    /// 맥이 이 기능을 지원하는지 (`AgentFeature`). 마지막 연결 확인 때 받은 목록으로 답한다
    func supports(_ feature: String) async -> Bool
    /// 작업 담당의 질문에 답한다. 같은 작업이 이어진다
    func answer(_ id: String, questionID: String, answer: String) async throws -> AgentTaskState
    func start(task: String, context: String?) async throws -> AgentTaskState
    func state(of id: String) async throws -> AgentTaskState
    /// 승인 또는 거부. 거부 사유가 있으면 에이전트가 고쳐서 다시 승인을 요청하고, 없으면 작업이 끝난다.
    /// `sha256`: 사용자에게 보여 준 초안의 해시. 맥에 고정된 초안과 다르면 실행되지 않는다 (`hashMismatch`).
    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState
    func cancel(_ id: String) async throws -> AgentTaskState
    /// 맥이 쇼핑 화면에 시킨 일의 결과를 돌려준다 (D75). 같은 작업이 이어진다
    func browsed(_ id: String, result: BrowseResult) async throws -> AgentTaskState
    /// 맥에 등록된 메일 계정과 마지막 로그인 확인 결과. `check`면 지금 다시 로그인해 본다 (몇 초 걸린다)
    func mailAccounts(check: Bool) async throws -> [MailAccount]
    /// 메일 계정을 연결한다. 앱 비밀번호는 받는 쪽이 보안 저장소에 넣고 바로 로그인해 본다. 돌아오는 것은 계정 목록뿐이다 (비밀번호는 돌아오지 않는다)
    func connectMail(provider: String, address: String, password: String) async throws -> [MailAccount]
    /// 에이전트 브라우저의 사이트별 로그인 상태
    func sites() async throws -> [SiteStatus]
    /// 로그인을 시작한다 (맥이 로그인 화면을 연다). 진행 중이던 로그인은 취소된다
    func startSiteLogin(site: String, method: String) async throws -> SiteLogin
    /// 지금 상태. 앱이 묻지 않는 동안에도 맥에서는 로그인이 이어진다
    func siteLogin(site: String, id: String) async throws -> SiteLogin
    /// 지금 화면(`step`)의 입력칸에 넣을 값을 보낸다. 같은 화면에는 한 번만 들어간다. 값은 돌아오지 않는다
    func sendSiteLoginInput(site: String, id: String, step: Int, values: [String: String]) async throws -> SiteLogin
    func cancelSiteLogin(site: String, id: String) async throws -> SiteLogin
    func siteLogout(site: String) async throws -> [SiteStatus]
    /// 저장된 로그인이 실제로 살아 있는지 지금 열어 본다 (10~20초)
    func checkSite(site: String) async throws -> [SiteStatus]
    /// 맥의 브라우저가 본 그 사이트의 아이콘 (D132, 맥의 D110). 아직 없으면 nil
    func siteIcon(site: String) async throws -> Data?
    /// 오래 가는 기억 (D151, 맥의 D129): 요약본과 그 상태
    func memory() async throws -> AgentMemory
    /// 요약본을 고친다. 맥이 저장한 글(비밀 꼴을 지우고 3000자로 자른 것)이 돌아온다
    func setMemoryProfile(_ profile: String) async throws -> String
    /// 요약본을 한 단계 전으로 되돌린다
    func undoMemory() async throws -> String
    /// 지난 대화에서 찾는다 (1~100자)
    func searchMemory(_ query: String) async throws -> [MemoryHit]
    /// 요약본과 지난 대화를 모두 지운다 (되돌릴 수 없다)
    func clearMemory() async throws
    /// 통화 목소리 (D136, 맥의 D117): 맥의 목소리 모델을 미리 올린다. 올라와 있으면 true
    func voiceWarm() async throws -> Bool
    /// 이 글을 내 목소리로 만들기 시작한다. 받을 번호가 돌아온다
    func voiceCreate(text: String) async throws -> String
    /// 만든 목소리의 n번째 조각 (0부터)
    func voiceChunk(id: String, index: Int) async throws -> VoiceChunk
    /// 남은 생성을 멈춘다 (끼어들었을 때)
    func voiceCancel(id: String) async
    /// 맥이 지금 할 수 있는 일 (카드 목록). 순서는 맥이 정한 그대로
    func skills() async throws -> [AgentSkill]
    /// 예약해 둔 일의 목록 (D91)
    func routines() async throws -> [AgentRoutine]
    /// 예약을 켜거나 끈다. 바뀐 뒤의 목록이 돌아온다
    func setRoutine(id: String, enabled: Bool) async throws -> [AgentRoutine]
    /// 예약을 지운다. 바뀐 뒤의 목록이 돌아온다
    func deleteRoutine(id: String) async throws -> [AgentRoutine]
    /// 예약이 돈 기록 (최근 것부터 20건)
    func routineRuns() async throws -> [RoutineRun]
    /// 예약의 지침을 바꾼다 (빈 글이면 지운다, D93). 바뀐 뒤의 목록이 돌아온다
    func setRoutineNotes(id: String, notes: String) async throws -> [AgentRoutine]
    /// 한 예약의 기록 (최근 것부터, D93)
    func routineRuns(routineID: String, limit: Int) async throws -> [RoutineRun]
    /// 실행 하나 (D93). 그런 기록이 없으면 nil
    func routineRun(id: String) async throws -> RoutineRun?
    /// 내 공간의 구성 (D94)
    func space() async throws -> AgentSpace
    /// 내 공간을 말로 고친다 (2~10초). 바뀐 뒤의 구성과 무엇이 바뀌었는지가 돌아온다
    func editSpace(text: String) async throws -> SpaceEdit
    /// 한 번 되돌린다. 되돌릴 것이 없으면 `conflict`
    func undoSpace() async throws -> SpaceEdit
    /// 비운다
    func clearSpace() async throws -> SpaceEdit
    /// 맥이 채우는 카드 하나의 내용을 새로 받는다 (0~20초)
    func refreshSpace(card: String) async throws -> AgentSpace
    /// 예약을 지금 한 번 뒤에서 돌린다 (D103. 내 공간 카드의 "지금 가져오기"). 없는 예약이면 실패한다
    func runRoutine(id: String) async throws
    /// 카드의 차례와 크기를 그대로 정한다 (D100. 판단 모델을 부르지 않는다). 목록에 없는 카드는 빠진다. 새 카드는 만들지 못한다
    func arrangeSpace(_ cards: [SpaceArrangement]) async throws -> SpaceEdit
    /// 보고에 붙은 캡처 그림 (JPEG·PNG 바이트). 맥이 이미 지웠으면 `attachmentGone`
    func attachment(taskID: String, id: String) async throws -> Data
    /// 작업실이 만든 영상 (D112)
    func video(taskID: String, id: String) async throws -> Data
    /// 지금 내 답을 기다리는 작업 (승인·질문, D113). 앱을 열 때 기기에 없는 대화의 승인 카드도 찾는다
    func waitingTasks() async throws -> [AgentWaitingTask]
    /// 맥에 남은 활동 (끝난 작업·예약 실행, 최근 것부터. D120)
    func activity(limit: Int) async throws -> [ActivityEntry]
    /// 맥 쪽 기록에서 찾기 (끝난 작업·예약 실행·예약, D120)
    func searchMac(_ query: String, limit: Int) async throws -> [ActivityEntry]
    /// 손 넘기기 화면 한 장 (D123). 끝났으면 `handoverClosed`
    func handoverFrame(id: String) async throws -> HandoverFrame
    /// 손 넘기기 화면에 손짓 하나를 보낸다 (D123). 끝났으면 `handoverClosed`
    func handoverInput(id: String, _ input: HandoverInput) async throws
    /// 대화에 붙일 사진·PDF를 맥에 올리고 번호(`u_…`)를 받는다 (D85). 맥은 메모리에만 두고 30분 동안 쓰이지 않으면 지운다.
    /// `name`: 보여 주는 파일 이름 (없어도 된다)
    func upload(_ data: Data, name: String?) async throws -> String
    /// 알림을 받을 이 기기를 맥에 등록한다 (D67). 같은 주소로 다시 보내면 덮어쓴다.
    /// `environment`: TestFlight·배포 빌드는 "production", Xcode로 넣은 빌드는 "sandbox"
    func registerPush(token: String, environment: String, bundleID: String) async throws
    /// 등록을 지운다 (알림을 껐을 때). 등록이 없어도 성공이다
    func unregisterPush(token: String) async throws
}

extension AgentProviding {
    // 나중에 생긴 기능의 기본값: 모르는 맥(이전 서버)은 지원하지 않는 것으로 본다
    func message(_ text: String, conversationID: String?, context: String?, messageID: String?) async throws -> AgentReply {
        try await message(text, conversationID: conversationID, context: context)
    }
    func message(_ text: String, conversationID: String?, context: String?, messageID: String?, replyTaskID: String?) async throws -> AgentReply {
        try await message(text, conversationID: conversationID, context: context, messageID: messageID)
    }
    func message(
        _ text: String, conversationID: String?, context: String?, messageID: String?, replyTaskID: String?, extras: MessageExtras
    ) async throws -> AgentReply {
        try await message(text, conversationID: conversationID, context: context, messageID: messageID, replyTaskID: replyTaskID)
    }
    func supports(_ feature: String) async -> Bool { false }
    func answer(_ id: String, questionID: String, answer: String) async throws -> AgentTaskState { throw AgentError.conflict }
    func browsed(_ id: String, result: BrowseResult) async throws -> AgentTaskState { throw AgentError.conflict }
    func mailAccounts(check: Bool) async throws -> [MailAccount] { [] }
    func connectMail(provider: String, address: String, password: String) async throws -> [MailAccount] { throw AgentError.conflict }
    func sites() async throws -> [SiteStatus] { [] }
    func startSiteLogin(site: String, method: String) async throws -> SiteLogin { throw AgentError.conflict }
    func siteLogin(site: String, id: String) async throws -> SiteLogin { throw AgentError.conflict }
    func sendSiteLoginInput(site: String, id: String, step: Int, values: [String: String]) async throws -> SiteLogin { throw AgentError.conflict }
    func cancelSiteLogin(site: String, id: String) async throws -> SiteLogin { throw AgentError.conflict }
    func siteLogout(site: String) async throws -> [SiteStatus] { throw AgentError.conflict }
    func checkSite(site: String) async throws -> [SiteStatus] { throw AgentError.conflict }
    func siteIcon(site: String) async throws -> Data? { nil }
    func memory() async throws -> AgentMemory { throw AgentError.conflict }
    func setMemoryProfile(_ profile: String) async throws -> String { throw AgentError.conflict }
    func undoMemory() async throws -> String { throw AgentError.conflict }
    func searchMemory(_ query: String) async throws -> [MemoryHit] { [] }
    func clearMemory() async throws { throw AgentError.conflict }
    func voiceWarm() async throws -> Bool { false }
    func voiceCreate(text: String) async throws -> String { throw AgentError.conflict }
    func voiceChunk(id: String, index: Int) async throws -> VoiceChunk { .unavailable }
    func voiceCancel(id: String) async {}
    func skills() async throws -> [AgentSkill] { [] }
    func routines() async throws -> [AgentRoutine] { [] }
    func setRoutine(id: String, enabled: Bool) async throws -> [AgentRoutine] { throw AgentError.conflict }
    func deleteRoutine(id: String) async throws -> [AgentRoutine] { throw AgentError.conflict }
    func routineRuns() async throws -> [RoutineRun] { [] }
    func setRoutineNotes(id: String, notes: String) async throws -> [AgentRoutine] { throw AgentError.conflict }
    func routineRuns(routineID: String, limit: Int) async throws -> [RoutineRun] { [] }
    func routineRun(id: String) async throws -> RoutineRun? { try await routineRuns().first { $0.id == id } }
    func space() async throws -> AgentSpace { .empty }
    func editSpace(text: String) async throws -> SpaceEdit { throw AgentError.conflict }
    func undoSpace() async throws -> SpaceEdit { throw AgentError.conflict }
    func clearSpace() async throws -> SpaceEdit { throw AgentError.conflict }
    func refreshSpace(card: String) async throws -> AgentSpace { throw AgentError.conflict }
    func arrangeSpace(_ cards: [SpaceArrangement]) async throws -> SpaceEdit { throw AgentError.conflict }
    func runRoutine(id: String) async throws { throw AgentError.conflict }
    func attachment(taskID: String, id: String) async throws -> Data { throw AgentError.attachmentGone }
    func video(taskID: String, id: String) async throws -> Data { throw AgentError.attachmentGone }
    func waitingTasks() async throws -> [AgentWaitingTask] { [] }
    func activity(limit: Int) async throws -> [ActivityEntry] { [] }
    func searchMac(_ query: String, limit: Int) async throws -> [ActivityEntry] { [] }
    func handoverFrame(id: String) async throws -> HandoverFrame { throw AgentError.handoverClosed }
    func handoverInput(id: String, _ input: HandoverInput) async throws { throw AgentError.handoverClosed }
    func upload(_ data: Data, name: String?) async throws -> String { throw AgentError.uploadUnsupported }
    func registerPush(token: String, environment: String, bundleID: String) async throws { throw AgentError.conflict }
    func unregisterPush(token: String) async throws { throw AgentError.conflict }
}

/// 초안 해시 (local-ai-agent `docs/API.md` "초안 고정과 해시").
/// sha256( JSON{"action","fields","kind","url"} ), 키는 사전순, 구분자는 공백 없이, 한글은 그대로.
enum AgentDraftHash {
    static func sha256(action: String, fields: [String: String], kind: String, url: String) -> String {
        let fieldsJSON = "{" + fields.keys.sorted(by: scalarOrder).map { quote($0) + ":" + quote(fields[$0] ?? "") }.joined(separator: ",") + "}"
        let json = "{\"action\":\(quote(action)),\"fields\":\(fieldsJSON),\"kind\":\(quote(kind)),\"url\":\(quote(url))}"
        return SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 서버(Python)는 키를 유니코드 코드 값 순서로 정렬한다
    private static func scalarOrder(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    /// 서버와 같은 JSON 문자열 표기 (Python `json.dumps(ensure_ascii=False)`)
    private static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

enum AgentClient {
    /// 앱이 쓸 에이전트 클라이언트. nil이면 질문 탭에 에이전트 선택이 나타나지 않는다.
    @MainActor
    static func fromEnvironment() -> (any AgentProviding)? {
        #if DEBUG
        if DemoData.arguments.contains("-demoAgent") {
            // 가짜 맥은 하나만 둔다 (실제 맥처럼, 대화에서 로그인한 것이 연동 센터에도 보이게)
            if let demoClient { return demoClient }
            // -demoAgentV1: 진행 설명·질문·보고가 없는 이전 서버처럼
            // -demoAgentSend: 본인 주소로 메일 보내기를 지원하는 맥처럼 [-demoAgentSendResult unverified|late|auth_failed|unreachable|not_set|no_address|invented_date]
            let client = MockAgentClient(
                reachable: !DemoData.arguments.contains("-demoAgentOffline"), v2: !DemoData.arguments.contains("-demoAgentV1"),
                failingChecks: Int(DemoData.value(after: "-demoAgentBlip") ?? "") ?? 0,
                mail: DemoData.arguments.contains("-demoAgentSend") ? MockMail(demo: DemoData.value(after: "-demoAgentSendResult")) : nil,
                // -demoSiteLogin [hold|captcha|code|choice|blocked|unsupported|unsupported_login|unknown_field|logged_in]: 사이트 로그인을 지원하는 맥처럼
                // -demoMailSetup [imap|failed|not_logged_in]: 메일 연결("네이버 메일 연결")도 해 주는 맥처럼
                sites: DemoData.arguments.contains("-demoSiteLogin") || DemoData.arguments.contains("-demoMailSetup")
                    ? MockSites(
                        demo: DemoData.value(after: "-demoSiteLogin"),
                        offersMailSetup: DemoData.arguments.contains("-demoMailSetup"), mailSetup: DemoData.value(after: "-demoMailSetup")
                    )
                    : nil,
                // -demoSkills: 맡길 수 있는 일을 알려 주는 맥처럼 (준비 상태는 -demoAgentSend·-demoSiteLogin logged_in에 따른다)
                offersSkills: DemoData.arguments.contains("-demoSkills"),
                // -demoCapture [blocked|open|gone|flaky|login]: 보고에 화면 캡처를 붙이는 맥처럼 (`-demoAgentAsk "결제내역 알려줘"`로 시작한다)
                captures: DemoData.arguments.contains("-demoCapture") ? MockCaptures(demo: DemoData.value(after: "-demoCapture")) : nil,
                // -demoDialogCloud: 대화 판단을 Claude에 맡긴 맥처럼 (데이터 처리 방식 화면의 설명이 바뀐다)
                // -demoShopHold search|open: drive일 때, 그 일의 결과를 받고 머문다 (쇼핑 화면의 "찾는 중"을 찍을 때)
                // -demoDialogCloud [bare|web|by|find|naver|weather|react|shop|browse|drive]: bare는 회의 자료의 내용을 보내지 않는 맥, web은 웹 검색도 하는 맥,
                // by는 누가 썼는지도 알리는 맥, find는 "찾아 달라"는 말에 검색으로 답을 찾고 브라우저로 그 페이지를 여는 맥,
                // naver는 그 페이지를 네이버 검색으로 찾는 맥, weather는 find에 더해 날씨 물음에 앱이 날씨 카드를 그리게 하는 맥
                // -demoAttach [one|two|pdf|mix]: 사진·PDF를 받는 맥처럼 (D85. Claude 판단인 맥만 받는다: -demoDialogCloud가 없으면 by로 둔다).
                // 입력창에 앱이 그린 가상의 사진·PDF를 붙여 둔다. -demoAttachSend "말"·-demoAttachOnly로 보낸다. -demoAttachSlow 초: 올리는 데 그만큼 걸린다
                dialogCloud: demoDialogCloud(),
                // -demoPush ask|on|denied|real: 알림을 보낼 수 있는 맥처럼 (권한은 `PushCenter`의 가짜가 답한다. real이면 실제 시스템에 묻는다)
                offersPush: DemoData.arguments.contains("-demoPush"), offersPushText: DemoData.arguments.contains("-demoPush"),
                // -demoAgentSlow 초: 메시지의 답이 그만큼 늦게 오는 맥처럼 (실제 맥은 2~6초)
                replyDelay: .seconds(DemoData.value(after: "-demoAgentSlow").flatMap { Double($0) } ?? 0),
                // -demoSiteDo [allowed]: 로그인한 사이트 안에서 해 주는 맥처럼 (`-demoAgentAsk "todo.test에 할 일 추가해줘"`로 시작한다, D80)
                siteDo: DemoData.arguments.contains("-demoSiteDo") ? MockSiteDo(demo: DemoData.value(after: "-demoSiteDo")) : nil,
                // -demoRoutines [empty]: 예약을 하는 맥처럼 (D91. `-demoScreen routines`로 예약 화면, `-demoRoutineRun`으로 결과를 대화로 연 모습)
                routines: DemoData.arguments.contains("-demoRoutines") ? MockRoutines(demo: DemoData.value(after: "-demoRoutines")) : nil,
                // -demoSpace [empty|full]: 내 공간을 하는 맥처럼 (D94. `-demoTab space`로 그 탭을, `-demoSpaceSay "말"`로 말로 고친 모습을 본다)
                space: DemoData.arguments.contains("-demoSpace") ? MockSpace(demo: DemoData.value(after: "-demoSpace")) : nil,
                // -demoWaiting: 맥이 직접 만든 대화에 승인을 기다리는 작업이 하나 있는 맥처럼 (D113. 입력창 위에 "기다리는 작업" 줄)
                waitingDemo: DemoData.arguments.contains("-demoWaiting"),
                // -demoActivity: 활동 목록과 전역 검색을 하는 맥처럼 (D120. -demoRoutines와 함께면 예약 실행도 보인다)
                offersActivity: DemoData.arguments.contains("-demoActivity")
            )
            demoClient = client
            return client
        }
        #endif
        return AgentHTTPClient.fromBundle()
    }

    #if DEBUG
    @MainActor private static var demoClient: MockAgentClient?

    @MainActor
    private static func demoDialogCloud() -> MockDialogCloud? {
        let attaches = DemoData.arguments.contains("-demoAttach")
        guard DemoData.arguments.contains("-demoDialogCloud") || attaches else { return nil }
        var cloud = MockDialogCloud(
            demo: DemoData.arguments.contains("-demoDialogCloud") ? DemoData.value(after: "-demoDialogCloud") : "by",
            hold: DemoData.value(after: "-demoShopHold")
        )
        if attaches {
            cloud.takesUploads = true
            cloud.uploadReplies = DemoUploads.replies(
                DemoData.value(after: "-demoAttach"), textless: DemoData.arguments.contains("-demoAttachOnly")
            )
            cloud.uploadDelay = .seconds(DemoData.value(after: "-demoAttachSlow").flatMap { Double($0) } ?? 0)
        }
        return cloud
    }
    #endif
}

enum AgentError: LocalizedError, Equatable {
    case unreachable
    case unauthorized
    case busy
    /// 맥 에이전트가 다시 시작되어 작업 기록이 없어짐 (404 task_not_found)
    case taskLost
    /// 이미 처리된 승인 요청 등 (409)
    case conflict
    /// 화면에 보인 초안과 맥에 고정된 초안이 다름 (409 hash_mismatch). 실행되지 않았다
    case hashMismatch
    case invalidResponse
    /// 맥이 시간 안에 답하지 못함 (로컬 모델이 작업 중이면 대화도 늦어진다)
    case slow
    /// 메일 계정 연결: 보낼 수 있는 내 주소 목록에 없는 주소 (403 not_allowed). 비밀번호는 보관되지 않았다
    case notAllowed
    /// 메일 계정 연결을 짧은 시간에 너무 여러 번 시도함 (429 rate_limited)
    case rateLimited
    /// 사이트 로그인: 이미 지나간 화면에 입력을 보냄 (409 stale_step). 값은 들어가지 않았다
    case staleStep
    /// 사이트 로그인: 서버가 이 로그인을 더는 기억하지 않음 (404 unknown_login. 끝난 지 10분이 지났거나 서버가 다시 시작됨)
    case loginLost
    /// 사이트 로그인: 서버가 모르는 사이트 (404 unknown_site)
    case unknownSite
    /// 보고의 캡처: 맥이 이미 지웠다 (404 attachment_gone. 24시간이 지났거나 맥이 다시 시작됨)
    case attachmentGone
    /// 손 넘기기가 끝났다 (질문이 끝났거나 5분 동안 입력이 없어 맥이 닫음, 404)
    case handoverClosed
    /// 붙이기: 맥이 받지 않는 종류이거나 (415 unsupported_media_type), 붙이기를 모르는 맥이다
    case uploadUnsupported
    /// 붙이기: 한도를 넘는 크기 (413 payload_too_large. 사진 7MB, PDF 10MB)
    case uploadTooLarge
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: "맥에 연결하지 못해서 보내지 못했어요."
        case .unauthorized: "맥 에이전트 토큰이 맞지 않아요. 앱 설정을 확인해 주세요."
        case .busy: "맥 에이전트가 다른 작업으로 바빠요. 잠시 후 다시 시도해 주세요."
        case .taskLost: "맥 에이전트가 다시 시작되어 이 작업 기록이 사라졌어요."
        case .conflict: "이미 처리된 승인 요청이에요."
        case .hashMismatch: "보여 드린 초안과 맥에 있는 초안이 달라서 승인하지 않았어요. 초안을 다시 확인해 주세요."
        case .invalidResponse: "맥 에이전트의 응답을 읽지 못했어요."
        case .slow: "맥의 답이 늦어지고 있어요. 잠시 후 다시 시도해 주세요."
        case .notAllowed: "허용되지 않은 요청이에요."
        case .rateLimited: "짧은 시간에 너무 여러 번 시도했어요. 잠시 후 다시 시도해 주세요."
        case .staleStep: "화면이 이미 넘어갔어요. 지금 화면을 다시 확인해 주세요."
        case .loginLost: "로그인 기록이 사라졌어요. 다시 시도해 주세요."
        case .unknownSite: "맥 에이전트가 모르는 사이트예요."
        case .attachmentGone: "캡처가 지워졌어요."
        case .handoverClosed: "브라우저 화면이 닫혔어요."
        case .uploadUnsupported: "맥이 받지 않는 파일이에요. 사진과 PDF만 붙일 수 있어요."
        case .uploadTooLarge: "파일이 너무 커서 보내지 못했어요. 사진은 7MB, PDF는 10MB까지 붙일 수 있어요."
        case .server(let message): message
        }
    }
}

// MARK: - HTTP 클라이언트

struct AgentHTTPClient: AgentProviding {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared
    /// 답변 말투. 보낼 때마다 지금 설정을 읽는다 (내 정보에서 바꾸면 다음 말부터 적용)
    var tone: @Sendable () -> ReplyTone = { ReplyTone.current() }
    /// 마지막 연결 확인에서 받은 기능 목록
    private let features = FeatureStore()

    /// 기능 목록 보관 (연결을 확인할 때마다 새로 받는다)
    private final class FeatureStore: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        func set(_ new: Set<String>) { lock.withLock { names = new } }
        func contains(_ name: String) -> Bool { lock.withLock { names.contains(name) } }
        var all: Set<String> { lock.withLock { names } }
    }

    static func fromBundle(_ bundle: Bundle = .main) -> AgentHTTPClient? {
        guard let host = bundle.object(forInfoDictionaryKey: "MSAgentHost") as? String, !host.isEmpty,
              let token = bundle.object(forInfoDictionaryKey: "MSAgentToken") as? String, !token.isEmpty,
              let url = URL(string: "https://\(host)")
        else { return nil }
        return AgentHTTPClient(baseURL: url, token: token)
    }

    func isReachable() async -> Bool {
        guard let (data, status) = try? await send("GET", "v1/health", body: nil as Empty?, timeout: 5) else { return false }
        guard status == 200 else { return false }
        features.set(Self.decodeFeatures(data))
        return true
    }

    func supports(_ feature: String) async -> Bool { features.contains(feature) }

    /// `features`가 없으면(이전 서버) 모두 꺼진 것으로 본다
    static func decodeFeatures(_ data: Data) -> Set<String> {
        struct Health: Decodable { let features: [String]? }
        return Set((try? JSONDecoder().decode(Health.self, from: data))?.features ?? [])
    }

    /// 대화는 로컬 모델이 한 번 더 판단할 때 20~50초 걸릴 수 있다 (명세 권장: 120초 이상)
    static let messageTimeout: TimeInterval = 150

    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        try await message(text, conversationID: conversationID, context: context, messageID: nil)
    }

    func message(_ text: String, conversationID: String?, context: String?, messageID: String?) async throws -> AgentReply {
        try await message(text, conversationID: conversationID, context: context, messageID: messageID, replyTaskID: nil)
    }

    func message(_ text: String, conversationID: String?, context: String?, messageID: String?, replyTaskID: String?) async throws -> AgentReply {
        try await message(text, conversationID: conversationID, context: context, messageID: messageID, replyTaskID: replyTaskID, extras: .none)
    }

    func message(
        _ text: String, conversationID: String?, context: String?, messageID: String?, replyTaskID: String?, extras: MessageExtras
    ) async throws -> AgentReply {
        let body = MessageBody(
            text: text, conversationID: conversationID, context: context, messageID: messageID,
            replyTaskID: replyTaskID, tone: tone().rawValue, features: features.all, extras: extras
        )
        let (data, status) = try await send("POST", "v1/messages", body: body, timeout: Self.messageTimeout, createsTask: true)
        return try Self.decodeReply(
            data: data, status: status, resumeFlag: features.contains(AgentFeature.siteLoginResume),
            acceptsReaction: body.client_features?.contains(MessageExtras.reactionFeature) == true,
            acceptsShop: body.client_features?.contains(MessageExtras.shopFeature) == true
        )
    }

    /// `POST /v1/messages`의 본문. 나중에 생긴 키는 그것을 아는 맥에만 보낸다
    /// (모르는 키를 받은 맥은 요청을 거절한다. 없는 값은 요청에 들어가지 않는다)
    struct MessageBody: Encodable, Equatable {
        struct ReplyTo: Encodable, Equatable {
            /// 가리킨 작업 (작업 카드에 답장했을 때). 있으면 맥은 이것을 먼저 쓴다
            var task_id: String?
            /// 그 작업의 상품 목록에서 고른 것 (D72). 없으면 요청에 들어가지 않는다
            var item_id: String?
            /// 작업이 아닌 말풍선에 답장했을 때 그 글과 누구의 말인지 (D124, 맥의 D108)
            var text: String?
            var role: String?
        }

        let text: String
        let conversation_id: String?
        let context: String?
        let client_message_id: String?
        let tone: String?
        let reply_to: ReplyTo?
        let client_time: String?
        /// 앱이 그릴 수 있는 것 (D66). 맥은 이것이 있을 때만 "날씨 카드를 그려라"로 답한다
        let client_features: [String]?
        /// 지난 말 뒤로 앱이 보여 준 것 (D66)
        let events: [Event]?
        /// 앱 안의 쇼핑 화면에서 읽은 것 (D74). "확인해 줘"를 누른 말에만 있다
        let view: ShopView?
        /// 이 말에 붙인 사진·PDF의 번호 (D85). 붙이기를 아는 맥에만, 붙인 것이 있을 때만 넣는다
        let uploads: [String]?
        /// 내 말에 이름이 나온 연락처 (D89). 있을 때만 넣는다 (없으면 맥은 그 대화의 앞선 값을 그대로 쓴다)
        let contacts: [String: String]?
        /// 내 말에 이름이 나왔지만 메일 주소가 없는 연락처의 이름 (D92). 있을 때만 넣는다
        let contacts_no_email: [String]?

        struct Event: Encodable, Equatable {
            let type: String
            let text: String
        }

        init(
            text: String, conversationID: String?, context: String?, messageID: String?, replyTaskID: String?,
            tone: String, features: Set<String>, extras: MessageExtras = .none, now: Date = .now, timeZone: TimeZone = .current
        ) {
            self.text = String(text.prefix(AgentHTTPClient.messageLimit))
            conversation_id = conversationID
            self.context = context
            client_message_id = features.contains(AgentFeature.messageReplay) ? messageID : nil
            self.tone = features.contains(AgentFeature.tone) ? tone : nil
            // 고른 상품의 번호는 맥이 상품 목록을 알 때만 넣는다 (모르는 키를 받은 맥은 요청을 거절한다)
            let itemID = features.contains(AgentFeature.reportItems) ? extras.replyItemID : nil
            // 작업에 답장했으면 작업 번호를, 말풍선에 답장했으면 그 글과 누구의 말인지를 (D124)
            if !features.contains(AgentFeature.replyTo) {
                reply_to = nil
            } else if let replyTaskID {
                reply_to = ReplyTo(task_id: replyTaskID, item_id: itemID)
            } else if let quote = extras.replyQuote {
                reply_to = ReplyTo(text: quote.text, role: quote.role.rawValue)
            } else {
                reply_to = nil
            }
            client_time = features.contains(AgentFeature.clientTime) ? Self.clientTime(now, timeZone: timeZone) : nil
            // 날씨: 맥이 아는 때에만 넣는다. 보여 준 것은 메시지 번호가 함께 갈 때만 알린다
            // (번호가 없으면 다시 보낸 요청을 맥이 구분하지 못해 같은 내용이 두 번 적힌다)
            // 그릴 수 있는 것은 맥이 그 기능을 알 때에만 이름을 넣는다 (날씨 카드, 반응)
            let weather = features.contains(AgentFeature.weatherAction)
            let drawable = extras.clientFeatures.filter { name in
                switch name {
                case MessageExtras.weatherFeature: weather
                case MessageExtras.reactionFeature: features.contains(AgentFeature.reaction)
                case MessageExtras.shopFeature: features.contains(AgentFeature.shopView)
                case MessageExtras.shopDriveFeature: features.contains(AgentFeature.shopView) && features.contains(AgentFeature.shopDrive)
                case MessageExtras.voiceCallFeature: features.contains(AgentFeature.voiceCall)
                default: false
                }
            }
            client_features = drawable.isEmpty ? nil : drawable
            // 읽은 화면: 쇼핑 화면을 아는 맥에, 그 이름을 알린 요청에만 넣는다. 맥이 받는 크기 안으로 줄여서
            view = drawable.contains(MessageExtras.shopFeature) ? extras.view?.fitted() : nil
            // 붙인 것: 붙이기를 아는 맥에만, 맥이 준 번호 꼴인 것만 4개까지. 붙인 것이 있으면 글은 비어 있어도 된다
            let attached = features.contains(AgentFeature.uploads)
                ? Array(extras.uploads.filter(AgentHTTPClient.isUploadID).prefix(MessageExtras.uploadLimit)) : []
            uploads = attached.isEmpty ? nil : attached
            // 연락처: 맥이 받는 꼴(이름 1~50자, 메일 주소 꼴)인 것만. 하나라도 어긋나면 맥이 요청 전체를 거절한다
            let people = extras.contacts.filter { ContactMatch.isName($0.key) && ContactMatch.isAddress($0.value) }
            contacts = people.isEmpty || people.count > ContactMatch.limit ? nil : people
            // 주소 없는 사람: 이름 꼴인 것만, 주소 있는 쪽에 없는 이름만
            let bare = Array(extras.contactsNoEmail.filter { ContactMatch.isName($0) && people[$0] == nil }.prefix(ContactMatch.limit))
            contacts_no_email = bare.isEmpty ? nil : bare
            let lines = extras.weatherEvents
                .map { $0.split(whereSeparator: \.isNewline).joined(separator: " ") }
                .filter { !$0.isEmpty }
                .prefix(MessageExtras.eventLimit)
                .map { Event(type: "weather", text: String($0.prefix(WeatherCard.summaryLimit))) }
            events = weather && client_message_id != nil && !lines.isEmpty ? Array(lines) : nil
        }

        /// 이 기기의 지금 시각 (ISO 8601, 시간대 차이 포함. 예: 2026-11-13T14:20:00+09:00).
        /// 기기의 달력·언어 설정과 상관없이 같은 모양이고, 차이가 없는 시간대도 "Z"가 아니라 +00:00으로 쓴다
        static func clientTime(_ date: Date, timeZone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
            return formatter.string(from: date)
        }
    }

    func answer(_ id: String, questionID: String, answer: String) async throws -> AgentTaskState {
        struct Body: Encodable { let question_id: String; let answer: String }
        let (data, status) = try await send("POST", "v1/tasks/\(id)/answer", body: Body(question_id: questionID, answer: String(answer.prefix(1000))))
        return try Self.decodeTask(data: data, status: status)
    }

    func start(task: String, context: String?) async throws -> AgentTaskState {
        struct Body: Encodable { let task: String; let context: String?; let plan: Bool }
        let (data, status) = try await send("POST", "v1/tasks", body: Body(task: task, context: context, plan: false), createsTask: true)
        return try Self.decodeTask(data: data, status: status)
    }

    func state(of id: String) async throws -> AgentTaskState {
        let (data, status) = try await send("GET", "v1/tasks/\(id)", body: nil as Empty?)
        return try Self.decodeTask(data: data, status: status)
    }

    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        struct Body: Encodable {
            let approval_id: String
            let decision: String
            let reason: String?
            let sha256: String?
        }
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Body(approval_id: approvalID, decision: approve ? "approve" : "reject",
                        reason: approve || reason?.isEmpty != false ? nil : String(reason!.prefix(500)),
                        sha256: approve ? sha256 : nil)
        let (data, status) = try await send("POST", "v1/tasks/\(id)/approval", body: body)
        return try Self.decodeTask(data: data, status: status)
    }

    func cancel(_ id: String) async throws -> AgentTaskState {
        let (data, status) = try await send("POST", "v1/tasks/\(id)/cancel", body: nil as Empty?)
        return try Self.decodeTask(data: data, status: status)
    }

    func browsed(_ id: String, result: BrowseResult) async throws -> AgentTaskState {
        let (data, status) = try await send("POST", "v1/tasks/\(id)/browser", body: result)
        return try Self.decodeTask(data: data, status: status)
    }

    func mailAccounts(check: Bool) async throws -> [MailAccount] {
        let (data, status) = check
            ? try await send("POST", "v1/mail/accounts/check", body: nil as Empty?, timeout: 40)
            : try await send("GET", "v1/mail/accounts", body: nil as Empty?, timeout: 10)
        return try Self.decodeAccounts(data: data, status: status)
    }

    func connectMail(provider: String, address: String, password: String) async throws -> [MailAccount] {
        struct Body: Encodable { let provider: String; let address: String; let app_password: String }
        // 지원한다고 알린 맥에만 보낸다 (모르는 서버에 비밀번호를 보내지 않는다)
        guard features.contains(AgentFeature.mailConnect) else { throw AgentError.conflict }
        let (data, status) = try await send(
            "POST", "v1/mail/accounts/connect", body: Body(provider: provider, address: address, app_password: password), timeout: 40
        )
        return try Self.decodeAccounts(data: data, status: status)
    }

    // MARK: 사이트 로그인 (D48)

    func sites() async throws -> [SiteStatus] {
        guard features.contains(AgentFeature.siteLogin) else { return [] }
        let (data, status) = try await send("GET", "v1/sites", body: nil as Empty?, timeout: 10)
        return try Self.decodeSites(data: data, status: status)
    }

    func startSiteLogin(site: String, method: String) async throws -> SiteLogin {
        struct Body: Encodable { let method: String }
        let (data, status) = try await send("POST", "\(try sitePath(site))/login", body: Body(method: method))
        return try Self.decodeSiteLogin(data: data, status: status)
    }

    func siteLogin(site: String, id: String) async throws -> SiteLogin {
        let (data, status) = try await send("GET", try loginPath(site, id), body: nil as Empty?, timeout: 15)
        return try Self.decodeSiteLogin(data: data, status: status)
    }

    /// 아이디·비밀번호가 지나가는 요청은 이것 하나다. 응답에는 상태만 돌아온다
    func sendSiteLoginInput(site: String, id: String, step: Int, values: [String: String]) async throws -> SiteLogin {
        struct Body: Encodable { let step: Int; let values: [String: String] }
        let (data, status) = try await send("POST", "\(try loginPath(site, id))/input", body: Body(step: step, values: values))
        return try Self.decodeSiteLogin(data: data, status: status)
    }

    func cancelSiteLogin(site: String, id: String) async throws -> SiteLogin {
        let (data, status) = try await send("POST", "\(try loginPath(site, id))/cancel", body: nil as Empty?, timeout: 15)
        return try Self.decodeSiteLogin(data: data, status: status)
    }

    func siteLogout(site: String) async throws -> [SiteStatus] {
        let (data, status) = try await send("POST", "\(try sitePath(site))/logout", body: nil as Empty?)
        return try Self.decodeSites(data: data, status: status)
    }

    func checkSite(site: String) async throws -> [SiteStatus] {
        let (data, status) = try await send("POST", "\(try sitePath(site))/check", body: nil as Empty?, timeout: 45)
        return try Self.decodeSites(data: data, status: status)
    }

    func siteIcon(site: String) async throws -> Data? {
        let (data, status) = try await send("GET", "\(try sitePath(site))/icon", body: nil as Empty?, timeout: 10, uncached: true)
        // 아직 받아 두지 않았다 (404 icon_not_found). 예전 맥도 404다
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw Self.decodeError(data: data, status: status) }
        guard data.count <= SiteStatus.iconLimit, AgentAttachment.isImage(data) else { throw AgentError.invalidResponse }
        return data
    }

    // MARK: 통화 목소리 (D136, 맥의 D117)

    func voiceWarm() async throws -> Bool {
        struct Reply: Decodable { let ready: Bool? }
        guard features.contains(AgentFeature.voiceTTS) else { return false }
        let (data, status) = try await send("POST", "v1/voice/warm", body: nil as Empty?, timeout: 20)
        guard (200..<300).contains(status) else { throw Self.decodeError(data: data, status: status) }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.ready ?? false
    }

    func voiceCreate(text: String) async throws -> String {
        struct Body: Encodable { let text: String }
        struct Reply: Decodable { let id: String }
        guard features.contains(AgentFeature.voiceTTS) else { throw AgentError.conflict }
        let (data, status) = try await send("POST", "v1/voice", body: Body(text: String(text.prefix(VoiceText.sayLimit))), timeout: 15)
        guard (200..<300).contains(status) else { throw Self.decodeError(data: data, status: status) }
        guard let id = (try? JSONDecoder().decode(Reply.self, from: data))?.id, Self.isPathSafe(id) else { throw AgentError.invalidResponse }
        return id
    }

    func voiceChunk(id: String, index: Int) async throws -> VoiceChunk {
        guard Self.isPathSafe(id), index >= 0 else { return .gone }
        // 맥은 조각이 없으면 10초까지 붙잡고 있다가 409로 돌려준다
        let (data, status) = try await send("GET", "v1/voice/\(id)/\(index)", body: nil as Empty?, timeout: 20, uncached: true)
        return Self.decodeVoiceChunk(data: data, status: status)
    }

    func voiceCancel(id: String) async {
        guard Self.isPathSafe(id) else { return }
        _ = try? await send("DELETE", "v1/voice/\(id)", body: nil as Empty?, timeout: 5)
    }

    nonisolated static func decodeVoiceChunk(data: Data, status: Int) -> VoiceChunk {
        switch status {
        case 200: return data.count >= 44 && data.count <= VoiceChunk.maxBytes ? .audio(data) : .unavailable
        case 204: return .end
        case 409: return .notReady
        case 404: return .gone
        default: return .unavailable
        }
    }

    // MARK: 맡길 수 있는 일 (D53)

    // MARK: 오래 가는 기억 (D151)

    func memory() async throws -> AgentMemory {
        guard features.contains(AgentFeature.memory) else { throw AgentError.conflict }
        let (data, status) = try await send("GET", "v1/memory", body: nil as Empty?, timeout: 10, uncached: true)
        return try MemoryDecoding.memory(data: data, status: status)
    }

    func setMemoryProfile(_ profile: String) async throws -> String {
        struct Body: Encodable { let profile: String }
        guard features.contains(AgentFeature.memory), profile.count <= AgentMemory.sendLimit else { throw AgentError.conflict }
        let (data, status) = try await send("PUT", "v1/memory/profile", body: Body(profile: profile), timeout: 15)
        return try MemoryDecoding.profile(data: data, status: status)
    }

    func undoMemory() async throws -> String {
        guard features.contains(AgentFeature.memory) else { throw AgentError.conflict }
        let (data, status) = try await send("POST", "v1/memory/undo", body: nil as Empty?, timeout: 15)
        return try MemoryDecoding.profile(data: data, status: status)
    }

    func searchMemory(_ query: String) async throws -> [MemoryHit] {
        let query = String(query.prefix(MemoryModel.queryLimit))
        guard features.contains(AgentFeature.memory), !query.isEmpty else { return [] }
        let (data, status) = try await send(
            "GET", "v1/memory/search", body: nil as Empty?, timeout: 15, uncached: true, query: [URLQueryItem(name: "q", value: query)]
        )
        return try MemoryDecoding.hits(data: data, status: status)
    }

    func clearMemory() async throws {
        guard features.contains(AgentFeature.memory) else { throw AgentError.conflict }
        let (data, status) = try await send("DELETE", "v1/memory", body: nil as Empty?, timeout: 15)
        try MemoryDecoding.cleared(data: data, status: status)
    }

    // MARK: 예약해 둔 일 (D91)

    func routines() async throws -> [AgentRoutine] {
        guard features.contains(AgentFeature.routines) else { return [] }
        let (data, status) = try await send("GET", "v1/routines", body: nil as Empty?, timeout: 10, uncached: true)
        return try RoutineDecoding.routines(data: data, status: status)
    }

    func setRoutine(id: String, enabled: Bool) async throws -> [AgentRoutine] {
        struct Body: Encodable { let enabled: Bool }
        guard features.contains(AgentFeature.routines), Self.isPathSafe(id) else { throw AgentError.conflict }
        let (data, status) = try await send("POST", "v1/routines/\(id)", body: Body(enabled: enabled), timeout: 10)
        return try RoutineDecoding.routines(data: data, status: status)
    }

    func deleteRoutine(id: String) async throws -> [AgentRoutine] {
        guard features.contains(AgentFeature.routines), Self.isPathSafe(id) else { throw AgentError.conflict }
        let (data, status) = try await send("DELETE", "v1/routines/\(id)", body: nil as Empty?, timeout: 10)
        return try RoutineDecoding.routines(data: data, status: status)
    }

    func routineRuns() async throws -> [RoutineRun] {
        guard features.contains(AgentFeature.routines) else { return [] }
        let (data, status) = try await send("GET", "v1/routines/runs", body: nil as Empty?, timeout: 10, uncached: true)
        return try RoutineDecoding.runs(data: data, status: status)
    }

    func setRoutineNotes(id: String, notes: String) async throws -> [AgentRoutine] {
        struct Body: Encodable { let notes: String }
        guard features.contains(AgentFeature.routines), Self.isPathSafe(id) else { throw AgentError.conflict }
        let (data, status) = try await send("POST", "v1/routines/\(id)", body: Body(notes: notes), timeout: 10)
        return try RoutineDecoding.routines(data: data, status: status)
    }

    func routineRuns(routineID: String, limit: Int) async throws -> [RoutineRun] {
        guard features.contains(AgentFeature.routines), Self.isPathSafe(routineID) else { return [] }
        let (data, status) = try await send(
            "GET", "v1/routines/runs", body: nil as Empty?, timeout: 10, uncached: true,
            query: [URLQueryItem(name: "routine_id", value: routineID), URLQueryItem(name: "limit", value: String(max(1, min(100, limit))))]
        )
        return try RoutineDecoding.runs(data: data, status: status)
    }

    func routineRun(id: String) async throws -> RoutineRun? {
        guard features.contains(AgentFeature.routines), Self.isPathSafe(id) else { return nil }
        let (data, status) = try await send("GET", "v1/routines/runs/\(id)", body: nil as Empty?, timeout: 10, uncached: true)
        // 실행 하나를 따로 주지 않는 예전 맥(404)이면 최근 기록에서 찾는다
        if let run = try RoutineDecoding.run(data: data, status: status) { return run }
        return try await routineRuns().first { $0.id == id }
    }

    func skills() async throws -> [AgentSkill] {
        guard features.contains(AgentFeature.skills) else { return [] }
        let (data, status) = try await send("GET", "v1/skills", body: nil as Empty?, timeout: 10)
        return try Self.decodeSkills(data: data, status: status)
    }

    // MARK: 내 공간 (D94)

    func space() async throws -> AgentSpace {
        guard features.contains(AgentFeature.space) else { return .empty }
        let (data, status) = try await send("GET", "v1/space", body: nil as Empty?, timeout: 10, uncached: true)
        return try SpaceDecoding.space(data: data, status: status)
    }

    /// 판단 모델을 불러 2~10초 걸린다. 넉넉히 기다리고, 넘기면 "늦는다"로 알린다
    func editSpace(text: String) async throws -> SpaceEdit {
        // `app_cards`: 앱이 채울 수 있는 폰 카드 (D95). 맥은 여기 있는 종류만 새로 만든다
        struct Body: Encodable {
            let text: String
            let app_cards: [String]
        }
        guard features.contains(AgentFeature.space) else { throw AgentError.conflict }
        let body = Body(text: String(text.prefix(SpaceModel.textLimit)), app_cards: SpaceCard.Kind.appCards)
        let (data, status) = try await send("POST", "v1/space/edit", body: body, timeout: 60)
        return try SpaceDecoding.edit(data: data, status: status)
    }

    func undoSpace() async throws -> SpaceEdit {
        guard features.contains(AgentFeature.space) else { throw AgentError.conflict }
        let (data, status) = try await send("POST", "v1/space/undo", body: nil as Empty?, timeout: 10)
        // 되돌릴 것이 없다
        if status == 404 { throw AgentError.conflict }
        return try SpaceDecoding.edit(data: data, status: status)
    }

    func clearSpace() async throws -> SpaceEdit {
        guard features.contains(AgentFeature.space) else { throw AgentError.conflict }
        let (data, status) = try await send("DELETE", "v1/space", body: nil as Empty?, timeout: 10)
        return try SpaceDecoding.edit(data: data, status: status)
    }

    /// 카드 하나에 0~20초 (메일·말로 만든 카드는 모델을 부른다). 내 메일 같은 내용이라 기기의 캐시에도 남기지 않는다
    func refreshSpace(card: String) async throws -> AgentSpace {
        struct Body: Encodable { let card: String }
        guard features.contains(AgentFeature.space), SpaceCard.isID(card) else { throw AgentError.conflict }
        let (data, status) = try await send("POST", "v1/space/refresh", body: Body(card: card), timeout: 60, uncached: true)
        return try SpaceDecoding.space(data: data, status: status)
    }

    func runRoutine(id: String) async throws {
        guard features.contains(AgentFeature.routines), Self.isPathSafe(id) else { throw AgentError.conflict }
        let (data, status) = try await send("POST", "v1/routines/\(id)/run", body: nil as Empty?, timeout: 10)
        guard (200..<300).contains(status) else { throw Self.decodeError(data: data, status: status) }
    }

    func arrangeSpace(_ cards: [SpaceArrangement]) async throws -> SpaceEdit {
        struct Body: Encodable { let cards: [SpaceArrangement] }
        guard features.contains(AgentFeature.spaceArrange), cards.allSatisfy({ SpaceCard.isID($0.id) }) else { throw AgentError.conflict }
        let (data, status) = try await send("POST", "v1/space/arrange", body: Body(cards: cards), timeout: 10)
        return try SpaceDecoding.edit(data: data, status: status)
    }

    // MARK: 알림 (D67)

    /// 알림을 보낸다고 알린 맥에만 등록한다. 주소는 16진수 글자일 때만 보낸다 (주소 경로에도 그대로 들어간다)
    func registerPush(token: String, environment: String, bundleID: String) async throws {
        guard features.contains(AgentFeature.push), PushToken.isValid(token) else { throw AgentError.conflict }
        struct Body: Encodable {
            let token: String
            let environment: String
            let bundle_id: String
        }
        let (data, status) = try await send(
            "POST", "v1/push/devices", body: Body(token: token, environment: environment, bundle_id: bundleID), timeout: 10
        )
        guard status == 200 else { throw Self.decodeError(data: data, status: status) }
    }

    func unregisterPush(token: String) async throws {
        guard features.contains(AgentFeature.push), PushToken.isValid(token) else { throw AgentError.conflict }
        let (data, status) = try await send("DELETE", "v1/push/devices/\(token)", body: nil as Empty?, timeout: 10)
        guard status == 200 else { throw Self.decodeError(data: data, status: status) }
    }

    // MARK: 보고의 캡처 (D56)

    /// 캡처 그림을 받는다. 주소는 맥이 준 것을 쓰지 않고 작업 번호와 캡처 번호로 직접 만든다 (다른 주소를 열지 않게).
    /// 내 화면이 찍힌 그림이라 기기의 캐시에도 남기지 않는다.
    func attachment(taskID: String, id: String) async throws -> Data {
        guard AgentHTTPClient.isPathSafe(taskID), AgentHTTPClient.isPathSafe(id) else { throw AgentError.invalidResponse }
        let (data, status) = try await send(
            "GET", "v1/tasks/\(taskID)/attachments/\(id)", body: nil as Empty?, timeout: 20, uncached: true
        )
        guard status == 200 else { throw Self.decodeError(data: data, status: status) }
        guard AgentAttachment.isImage(data) else { throw AgentError.invalidResponse }
        return data
    }

    /// 작업실이 만든 영상을 받는다 (D112). 그림과 같은 길이지만 크고 오래 걸린다. 기기의 캐시에 남기지 않는다
    func video(taskID: String, id: String) async throws -> Data {
        guard AgentHTTPClient.isPathSafe(taskID), AgentHTTPClient.isPathSafe(id) else { throw AgentError.invalidResponse }
        let (data, status) = try await send(
            "GET", "v1/tasks/\(taskID)/attachments/\(id)", body: nil as Empty?, timeout: 180, uncached: true
        )
        guard status == 200 else { throw Self.decodeError(data: data, status: status) }
        guard AgentAttachment.isVideo(data) else { throw AgentError.invalidResponse }
        return data
    }

    // MARK: 기다리는 작업 (D113)

    func waitingTasks() async throws -> [AgentWaitingTask] {
        let (data, status) = try await send(
            "GET", "v1/tasks", body: nil as Empty?, timeout: 10, uncached: true,
            query: [URLQueryItem(name: "status", value: AgentWaitingTask.statuses.joined(separator: ","))]
        )
        return try AgentWaitingTask.decode(data: data, status: status)
    }

    // MARK: 활동·전역 검색 (D120, 맥의 D103)

    func activity(limit: Int) async throws -> [ActivityEntry] {
        guard features.contains(AgentFeature.activity) else { return [] }
        let (data, status) = try await send(
            "GET", "v1/activity", body: nil as Empty?, timeout: 10, uncached: true,
            query: [URLQueryItem(name: "limit", value: String(max(1, min(100, limit))))]
        )
        return try ActivityDecoding.entries(data: data, status: status, key: "items")
    }

    func searchMac(_ query: String, limit: Int) async throws -> [ActivityEntry] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard features.contains(AgentFeature.activity), !words.isEmpty else { return [] }
        let (data, status) = try await send(
            "GET", "v1/search", body: nil as Empty?, timeout: 10, uncached: true,
            query: [URLQueryItem(name: "q", value: String(words.prefix(100))), URLQueryItem(name: "limit", value: String(max(1, min(50, limit))))]
        )
        return try ActivityDecoding.entries(data: data, status: status, key: "items")
    }

    // MARK: 손 넘기기 (D123, 맥의 D106)

    func handoverFrame(id: String) async throws -> HandoverFrame {
        guard AgentHTTPClient.isPathSafe(id) else { throw AgentError.invalidResponse }
        let (data, status) = try await send("GET", "v1/handover/\(id)/frame", body: nil as Empty?, timeout: 10, uncached: true)
        if status == 404 { throw AgentError.handoverClosed }
        return try Self.decodeHandoverFrame(data: data, status: status)
    }

    func handoverInput(id: String, _ input: HandoverInput) async throws {
        guard AgentHTTPClient.isPathSafe(id) else { throw AgentError.invalidResponse }
        let (data, status) = try await send("POST", "v1/handover/\(id)/input", body: input.body, timeout: 10)
        if status == 404 { throw AgentError.handoverClosed }
        guard (200..<300).contains(status) else { throw Self.decodeError(data: data, status: status) }
    }

    // MARK: 사진·PDF 붙이기 (D85)

    /// 맥이 주는 붙인 것의 번호 꼴 (`u_` + 영문·숫자·-·_ 8~40자). 맥은 이 꼴이 아닌 것을 버린다
    /// `POST /v1/messages`의 `text` 상한 (맥과 맞춘 값, 2026-11-17에 2000 → 16000. 긴 제작안을 통째로 붙여 보낼 수 있게)
    static let messageLimit = 16000

    static func isUploadID(_ id: String) -> Bool {
        guard id.hasPrefix("u_") else { return false }
        let rest = id.dropFirst(2)
        return (8...40).contains(rest.count) && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// 붙일 사진·PDF를 올린다. 본문은 파일 그대로다 (JSON이 아니다). 붙이기를 아는 맥에만 보낸다.
    /// 내 사진·문서라 기기의 캐시에도 남기지 않는다. 종류는 맥이 파일의 머리로 정한다
    func upload(_ data: Data, name: String?) async throws -> String {
        guard features.contains(AgentFeature.uploads) else { throw AgentError.uploadUnsupported }
        guard !data.isEmpty else { throw AgentError.invalidResponse }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/uploads"), timeoutInterval: Self.uploadTimeout)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(token, forHTTPHeaderField: "X-App-Token")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let name = Self.uploadFilename(name) { request.setValue(name, forHTTPHeaderField: "X-Filename") }
        let received: (Data, URLResponse)
        do {
            let session = self.session === URLSession.shared ? Self.uncachedSession : self.session
            received = try await session.upload(for: request, from: data)
        } catch {
            if (error as? URLError)?.code == .timedOut { throw AgentError.slow }
            throw AgentError.unreachable
        }
        let status = (received.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.decodeError(data: received.0, status: status) }
        struct Wrapper: Decodable { struct Upload: Decodable { let id: String }; let upload: Upload }
        guard let id = try? JSONDecoder().decode(Wrapper.self, from: received.0).upload.id, Self.isUploadID(id) else {
            throw AgentError.invalidResponse
        }
        return id
    }

    /// 큰 파일을 느린 연결로 올릴 때를 생각한 시간
    static let uploadTimeout: TimeInterval = 90

    /// `X-Filename`에 넣을 이름: 경로는 떼고, 100자까지, 퍼센트 인코딩해서. 없거나 비면 nil
    static func uploadFilename(_ name: String?) -> String? {
        guard let name = name?.split(separator: "/").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        // 머리글에는 ASCII만 넣는다 (`CharacterSet.alphanumerics`는 한글도 글자로 쳐서 그대로 둔다)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String(name.prefix(100)).addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// 디스크에 아무것도 남기지 않는 연결 (캡처 그림용)
    private static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// 지원한다고 알린 맥에만 보낸다 (모르는 서버에 아이디·비밀번호를 보내지 않는다)
    private func sitePath(_ site: String) throws -> String {
        guard features.contains(AgentFeature.siteLogin) else { throw AgentError.conflict }
        guard Self.isPathSafe(site) else { throw AgentError.unknownSite }
        return "v1/sites/\(site)"
    }

    private func loginPath(_ site: String, _ id: String) throws -> String {
        guard Self.isPathSafe(id) else { throw AgentError.loginLost }
        return "\(try sitePath(site))/login/\(id)"
    }

    static func decodeAccounts(data: Data, status: Int) throws -> [MailAccount] {
        struct Wrapper: Decodable {
            struct Account: Decodable {
                let provider: String?
                let address: String
                let status: String?
                let `default`: Bool?
                let checked_at: String?
            }
            let accounts: [Account]
        }
        guard (200..<300).contains(status) else { throw decodeError(data: data, status: status) }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { throw AgentError.invalidResponse }
        return wrapper.accounts.filter { !$0.address.isEmpty }.map {
            MailAccount(
                provider: $0.provider ?? "", address: $0.address, status: MailAccount.Status(rawValue: $0.status ?? "") ?? .unknown,
                isDefault: $0.default ?? false, checkedAt: AgentTime.date($0.checked_at)
            )
        }
    }

    private struct Empty: Encodable {}

    /// `createsTask`: 작업을 만들 수 있는 요청. 맥이 질문 방식을 지원하면 `X-Api-Version: 2`를 붙여,
    /// 작업 담당이 막혔을 때 작업을 끝내지 않고 물어보게 한다 (이 헤더가 없으면 이전 방식인 `needs_input`으로 끝난다).
    /// 맥이 본인 주소 발송을 지원하면 3을 붙인다 (2의 기능을 포함). 3을 붙인 요청에만 보내기 작업이 만들어지므로,
    /// 보내기 화면을 모르는 이전 앱에는 `send_pending` 상태가 가지 않는다.
    /// 맥이 사이트 로그인을 지원하면 4를 붙인다 (3의 기능을 포함). 4를 붙인 요청에만 "로그인 화면 열기"(`site_login`)로 답한다
    private func send<Body: Encodable>(
        _ method: String, _ path: String, body: Body?, timeout: TimeInterval = 30, createsTask: Bool = false,
        uncached: Bool = false, query: [URLQueryItem] = []
    ) async throws -> (Data, Int) {
        var url = baseURL.appendingPathComponent(path)
        // 물음표 뒤의 값은 경로에 섞지 않고 따로 붙인다 (경로에 넣으면 글자가 바뀌어 다른 주소가 된다)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if uncached { request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData }
        request.setValue(token, forHTTPHeaderField: "X-App-Token")
        if createsTask, features.contains(AgentFeature.siteLogin) {
            request.setValue("4", forHTTPHeaderField: "X-Api-Version")
        } else if createsTask, features.contains(AgentFeature.sendSelf) {
            request.setValue("3", forHTTPHeaderField: "X-Api-Version")
        } else if createsTask, features.contains(AgentFeature.taskQuestions) {
            request.setValue("2", forHTTPHeaderField: "X-Api-Version")
        }
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        } else if method == "POST" {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        do {
            // 캐시 없이 받을 것은 따로 둔 연결로 (바꿔 끼운 연결이 있으면 — 테스트 — 그것을 그대로 쓴다)
            let session = uncached && self.session === URLSession.shared ? Self.uncachedSession : self.session
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            // 오래 기다리는 요청이 시간을 넘긴 것은 맥이 꺼진 것이 아니라 답이 늦는 것이다 (보내기 전에 연결을 확인한다)
            if (error as? URLError)?.code == .timedOut, timeout >= 60 { throw AgentError.slow }
            throw AgentError.unreachable
        }
    }

    // MARK: 응답 해석

    static func decodeTask(data: Data, status: Int) throws -> AgentTaskState {
        guard (200..<300).contains(status) else { throw decodeError(data: data, status: status) }
        guard let dto = try? JSONDecoder().decode(TaskDTO.self, from: data) else { throw AgentError.invalidResponse }
        return dto.state
    }

    /// `resumeFlag`: 맥이 로그인 안내에 "하지 못한 부탁" 표시를 주는지 (`site_login_resume`). 주는 맥이면 표시가 없는 안내는 false다.
    /// `acceptsReaction`: 반응을 그릴 수 있다고 알린 요청인지 (D70). 그때만 반응을 읽고, 말 없이 반응만 있는 응답도 받는다.
    /// `acceptsShop`: 쇼핑 화면을 열 수 있다고 알린 요청인지 (D74). 그때만 "쇼핑 화면을 열어라"로 읽는다
    static func decodeReply(
        data: Data, status: Int, resumeFlag: Bool = false, acceptsReaction: Bool = false, acceptsShop: Bool = false
    ) throws -> AgentReply {
        guard (200..<300).contains(status) else { throw decodeError(data: data, status: status) }
        guard let dto = try? JSONDecoder().decode(ReplyDTO.self, from: data) else { throw AgentError.invalidResponse }
        let bubbles = (dto.replies ?? []).filter { !$0.text.isEmpty }
        let replies = bubbles.map(\.text)
        // 모르는 값은 nil로 읽는다 (나중에 값이 늘어도 답은 그대로 보여 준다)
        var writers = bubbles.map { $0.by.flatMap(ReplyWriter.init(rawValue:)) }
        if writers.allSatisfy({ $0 == nil }) { writers = [] }
        // 반응: 알린 요청에만, 정해 둔 이모지일 때만 (그 밖의 값은 없는 것으로 읽는다)
        let reaction = acceptsReaction ? AgentReaction.known(dto.reaction.flatMap { $0.isString ? $0.text : nil }) : nil
        let action: AgentReply.Action
        var loginResume: Bool?
        var askRecommended: String?
        var multi = false
        var choiceImages: [String: URL] = [:]
        switch dto.action.type {
        case "task":
            guard let task = dto.action.task else { throw AgentError.invalidResponse }
            action = .task(task.state)
        case "ask":
            let choices = AgentChoices.clean(dto.action.choices, limit: AgentChoices.askLimit)
            action = .ask(choices: choices)
            // 권하는 후보는 선택지 가운데 하나일 때만 받는다
            if let recommended = dto.action.recommended, choices.contains(recommended) { askRecommended = recommended }
            // 여러 개 고르기는 후보가 둘 이상일 때만 (D111)
            multi = choices.count > 1 && dto.action.multi?.value == true
            // 후보의 그림: 후보의 글과 같은 줄만, 열 만한 공개 https 주소만 (맥이 실제로 연 페이지의 그림)
            for detail in (dto.action.choice_details?.value ?? []).compactMap(\.value) {
                guard let text = AgentChoices.clean([detail.text ?? ""], limit: 1).first, choices.contains(text),
                      let image = AgentLink.publicURL(detail.image), image.scheme == "https" else { continue }
                choiceImages[text] = image
            }
        case "steer":
            // 끼어들기 (D152): 말은 돌고 있는 작업으로 갔다. 답은 말풍선으로 보이고, 내 말에 표시가 붙는다
            guard !replies.isEmpty else { throw AgentError.invalidResponse }
            action = .none
        case "route_claude":
            action = .routeClaude
        case "site_login":
            // 주소에 넣을 수 있는 이름일 때만 로그인 카드를 붙인다. 아니면 답만 보여 준다
            if let site = dto.action.site, isPathSafe(site) {
                action = .siteLogin(site: site)
                if resumeFlag { loginResume = dto.action.resume?.value ?? false }
            } else {
                guard !replies.isEmpty else { throw AgentError.invalidResponse }
                action = .none
            }
        case "weather":
            // 지역이 없거나 글자가 아니면 지금 위치다. 때를 모르면 오늘이다
            let place = dto.action.place.flatMap { $0.isString ? $0.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            action = .weather(
                place: place.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) },
                when: WeatherWhen(dto.action.when.flatMap { $0.isString ? $0.text : nil })
            )
        case "shop" where acceptsShop:
            // 검색어가 글이고 비어 있지 않을 때만 쇼핑 카드를 붙인다. 아니면 답만 보여 준다.
            // 여기서 받는 것은 검색어뿐이다: 주소는 앱이 만든다 (맥이 준 주소를 열지 않는다)
            let query = dto.action.query.flatMap { $0.isString ? ShopText.clean($0.text, limit: ShopView.queryLimit) : nil }
            if let query {
                action = .shop(query: query)
            } else {
                guard !replies.isEmpty else { throw AgentError.invalidResponse }
                action = .none
            }
        default:
            // 모르는 종류라도 답이 있으면 그대로 보여 준다. 말이 없어도 반응이 있으면 그것이 답이다 ("ㅇㅋ"에 👌만)
            guard !replies.isEmpty || reaction != nil else { throw AgentError.invalidResponse }
            action = .none
        }
        // 끼어들기 (D152): steer 행동은 그 작업에 전한 것(inject), 작업 행동에 붙은 steer는 앞 작업을 거두고 새로 시작한 것(replace)
        var steer: AgentSteer?
        if dto.action.type == "steer", let id = dto.action.task_id, isPathSafe(id) {
            steer = AgentSteer(taskID: id, mode: AgentSteer.Mode(rawValue: dto.action.mode ?? "") ?? .inject)
        } else if dto.action.type == "task", let raw = dto.action.steer?.value, let id = raw.task_id, isPathSafe(id) {
            steer = AgentSteer(taskID: id, mode: AgentSteer.Mode(rawValue: raw.mode ?? "") ?? .replace)
        }
        // 답 뒤의 다음 말 (D111): 말로 답했을 때만
        var next: [String] = []
        var nextRecommended: String?
        if action == .none, !replies.isEmpty, let value = dto.action.next?.value {
            next = AgentChoices.clean(value.choices, limit: AgentChoices.nextLimit)
            if let recommended = value.recommended, next.contains(recommended) { nextRecommended = recommended }
        }
        return AgentReply(
            conversationID: dto.conversation_id, replies: replies, action: action, writers: writers,
            loginResume: loginResume, reaction: reaction, routines: dto.routines?.routines,
            recommended: askRecommended,
            // 한 줄로 끝난 일 (D110): 상태 줄로 보일 말의 차례
            statusLines: Set(bubbles.indices.filter { bubbles[$0].kind == "status" }),
            multi: multi, choiceImages: choiceImages, next: next, nextRecommended: nextRecommended,
            speaks: speaks(bubbles.map(\.speak)),
            voiceIDs: bubbles.contains { $0.voice_id.map(isPathSafe) == true }
                ? bubbles.map { $0.voice_id.flatMap { isPathSafe($0) ? $0 : nil } } : [],
            steer: steer
        )
    }

    /// 읽을 글을 다듬는다 (앞뒤 빈칸을 떼고, 빈 글이면 nil). 하나도 없으면 빈 목록
    private static func speaks(_ raw: [String?]) -> [String?] {
        let cleaned = raw.map { $0.flatMap(VoiceText.clean) }
        return cleaned.allSatisfy { $0 == nil } ? [] : cleaned
    }

    struct ReplyDTO: Decodable {
        struct Reply: Decodable {
            let text: String
            /// 글자가 아닌 값이 와도 응답 전체를 버리지 않는다 (없는 것으로 읽는다)
            let by: String?
            /// "status"면 한 줄로 끝난 일 (D110)
            let kind: String?
            /// 통화 중이면 소리로 읽을 글 (D134)
            let speak: String?
            /// 맥이 만들기 시작한 내 목소리의 번호 (D136)
            let voice_id: String?
            enum CodingKeys: String, CodingKey { case text, by, kind, speak, voice_id }
            init(from decoder: Decoder) throws {
                let box = try decoder.container(keyedBy: CodingKeys.self)
                text = try box.decode(String.self, forKey: .text)
                by = try? box.decode(String.self, forKey: .by)
                kind = try? box.decode(String.self, forKey: .kind)
                speak = try? box.decode(String.self, forKey: .speak)
                voice_id = try? box.decode(String.self, forKey: .voice_id)
            }
        }
        struct Action: Decodable {
            let type: String
            let choices: [String]?
            /// 되물을 때 권하는 후보 (D110)
            let recommended: String?
            /// 여러 개 고르기 (D111)
            let multi: Flag?
            /// 후보마다의 그림 (D111)
            let choice_details: SpaceDecoding.Lossy<[SpaceDecoding.Lossy<ChoiceDetail>]>?
            /// 답 뒤의 다음 말 (D111)
            let next: SpaceDecoding.Lossy<Next>?
            let task: TaskDTO?
            let site: String?
            let resume: Flag?
            /// 날씨 (D66). 글자가 아닌 값이 와도 응답 전체를 버리지 않는다
            let place: Loose?
            let when: Loose?
            /// 쇼핑 검색어 (D74). 글자가 아닌 값이 와도 응답 전체를 버리지 않는다
            let query: Loose?
            /// 끼어들기 (D152): `steer` 행동의 작업 번호와 방식, 작업 행동에 붙은 `steer`
            let task_id: String?
            let mode: String?
            let steer: SpaceDecoding.Lossy<SteerDTO>?
        }
        struct SteerDTO: Decodable {
            let task_id: String?
            let mode: String?
        }
        struct ChoiceDetail: Decodable {
            let text: String?
            let image: String?
        }
        struct Next: Decodable {
            let choices: [String]?
            let recommended: String?
        }
        /// 참·거짓이 아닌 값이 와도 응답 전체를 버리지 않는다 (없는 것으로 읽는다)
        struct Flag: Decodable {
            let value: Bool?
            init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Bool.self) }
        }

        let conversation_id: String
        let replies: [Reply]?
        let action: Action
        /// 반응 (D70). 글자가 아닌 값이 와도 응답 전체를 버리지 않는다
        let reaction: Loose?
        /// 바뀐 뒤의 예약 목록 (D91). 꼴이 어긋나도 응답 전체를 버리지 않는다
        let routines: RoutineDecoding.ReplyList?
    }

    static func decodeError(data: Data, status: Int) -> AgentError {
        struct Wrapper: Decodable { struct Body: Decodable { let code: String; let message: String? }; let error: Body }
        let body = try? JSONDecoder().decode(Wrapper.self, from: data).error
        switch (status, body?.code) {
        case (401, _): return .unauthorized
        case (404, "task_not_found"): return .taskLost
        case (409, "hash_mismatch"): return .hashMismatch
        case (409, "stale_step"): return .staleStep
        case (409, "busy"): return .busy
        case (404, "unknown_login"): return .loginLost
        case (404, "unknown_site"): return .unknownSite
        case (404, "attachment_gone"): return .attachmentGone
        case (415, _): return .uploadUnsupported
        case (413, _): return .uploadTooLarge
        case (409, _): return .conflict
        case (429, "busy"): return .busy
        case (403, "not_allowed"): return .notAllowed
        case (429, "rate_limited"): return .rateLimited
        default: return .server(body?.message ?? "맥 에이전트 오류 (HTTP \(status))")
        }
    }

    struct TaskDTO: Decodable {
        struct Step: Decodable {
            let tool: String
            let args: [String: Loose]?
            let status: String
            let url: String?
        }

        struct Approval: Decodable {
            let approval_id: String
            let action: String
            let fields: [String: Loose]
            let kind: String?
            let url: String?
            let sha256: String?
            let received: String?
            let external: Bool?
            let attachment: CardCapture?

            /// 받은 내용으로 직접 계산한 해시. 값이 모두 글자이고 계산에 필요한 항목이 다 있을 때만
            var shownSHA256: String? {
                guard sha256 != nil, let kind, let url, fields.values.allSatisfy(\.isString) else { return nil }
                return AgentDraftHash.sha256(action: action, fields: fields.mapValues(\.text), kind: kind, url: url)
            }
        }

        struct Saved: Decodable {
            let action: String
            let fields: [String: Loose]
            let sha256: String?
            let kind: String?
        }

        struct Result: Decodable {
            let outcome: String
            let summary: String?
            let approved_drafts: [Saved]?
            /// 승인한 "단추 누르기"의 단추 글 (D80). 초안과 따로 온다
            let approved_actions: Names?
            let question: String?
            let report: Report?
            /// 이유의 종류 (`send_failed`: 보내지 못한 이유, `needs_login`: `login_expired`·`login_missing`)
            let reason: String?
            /// 사용자가 하면 풀리는 일 (`needs_login`일 때 `{"type": "site_login", "site": "naver"}`)
            let action: Next?
        }

        /// 글자 목록. 꼴이 달라도 결과 전체를 버리지 않는다 (목록이 아니면 빈 것으로, 글자가 아닌 요소는 뺀다)
        struct Names: Decodable {
            let list: [String]

            init(from decoder: Decoder) throws {
                let items = (try? decoder.singleValueContainer().decode([Loose].self)) ?? []
                list = items.filter(\.isString).map(\.text)
            }
        }

        /// 쇼핑 화면에 시킨 일 (D75). 모양이 달라도 작업 전체를 못 읽게 하지 않는다 (시킨 일이 없는 것으로 본다)
        struct Browser: Decodable {
            let command: AgentBrowse?

            private enum Keys: String, CodingKey { case id, type, query, items }

            init(from decoder: Decoder) throws {
                let container = try? decoder.container(keyedBy: Keys.self)
                command = AgentBrowse.make(
                    id: (try? container?.decode(String.self, forKey: .id)) ?? nil,
                    type: (try? container?.decode(String.self, forKey: .type)) ?? nil,
                    query: (try? container?.decode(String.self, forKey: .query)) ?? nil,
                    items: (try? container?.decode([Int].self, forKey: .items)) ?? nil
                )
            }
        }

        /// 모양이 달라도 결과 전체를 못 읽게 하지 않는다 (없는 것으로 본다)
        struct Next: Decodable {
            let type: String?
            let site: String?

            private enum Keys: String, CodingKey { case type, site }

            init(from decoder: Decoder) throws {
                let container = try? decoder.container(keyedBy: Keys.self)
                type = (try? container?.decode(String.self, forKey: .type)) ?? nil
                site = (try? container?.decode(String.self, forKey: .site)) ?? nil
            }
        }

        /// 항목마다 따로 읽는다 (하나가 형식에 맞지 않아도 나머지는 보여 준다)
        struct Report: Decodable {
            let done: [String]?
            let blocked: [String]?
            let sources: [String]?
            let sent: [Sent]?
            let attachments: Attachments?
            let links: Links?
            /// 글자가 아닌 값이 와도 보고 전체를 버리지 않는다 (`Loose`)
            let by: Loose?
            let items: Items?
            /// 답변 카드 (D110). 꼴이 어긋나면 카드만 버린다 (보고의 나머지는 그대로)
            let card: SpaceDecoding.Lossy<Card>?
            /// 통화 중에 읽을 한두 문장 (D134). 글자가 아닌 값이 와도 보고 전체를 버리지 않는다
            let speak: Loose?
        }

        /// 답변 카드 (`report.card`, D110)
        struct Card: Decodable {
            struct Action: Decodable {
                let label: String?
                let url: String?
                let site: String?
            }
            let kind: String?
            let title: String?
            let subtitle: String?
            let blocks: [SpaceDecoding.Lossy<SpaceDecoding.BlockDTO>]?
            let actions: [SpaceDecoding.Lossy<Action>]?
            let next: SpaceDecoding.Lossy<ReplyDTO.Next>?

            var card: AgentReportCard? {
                func clean(_ text: String?, _ limit: Int) -> String? {
                    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                    return String(text.prefix(limit))
                }
                guard let kind = kind.flatMap(AgentReportCard.Kind.init(rawValue:)), let title = clean(title, 30) else { return nil }
                // 단추: 열 만한 공개 주소이거나, 다시 로그인할 사이트일 때만 (맥이 준 아무 주소나 열지 않는다)
                let actions = (actions ?? []).compactMap(\.value).compactMap { item -> AgentReportCard.Action? in
                    guard let label = clean(item.label, 16) else { return nil }
                    if let url = AgentLink.openable(item.url)?.url { return AgentReportCard.Action(label: label, url: url) }
                    if let site = clean(item.site, 40), AgentHTTPClient.isPathSafe(site) { return AgentReportCard.Action(label: label, site: site) }
                    return nil
                }
                return AgentReportCard(
                    kind: kind, title: title, subtitle: clean(subtitle, 40),
                    blocks: Array((blocks ?? []).compactMap { $0.value?.block }.prefix(AgentReportCard.blockLimit)),
                    actions: Array(actions.prefix(AgentReportCard.actionLimit)),
                    next: { let list = AgentChoices.clean(next?.value?.choices, limit: AgentChoices.nextLimit); return list.isEmpty ? nil : list }()
                )
            }
        }

        /// 보고의 상품 목록 (`report.items`, D72). 꼴이 다른 요소, 이름이 없거나 주소가 열 만하지 않은 상품은 그것만 버린다.
        /// 같은 주소·같은 번호는 한 번만, 최대 `AgentItem.reportLimit`개. 값은 숫자로 온 것만 읽는다 (글자로 온 값은 짐작하지 않는다)
        struct Items: Decodable {
            private struct Item: Decodable {
                let item: AgentItem?
                enum Keys: String, CodingKey { case id, title, price, mall, url, image, brand, shipping, detail }
                init(from decoder: Decoder) throws {
                    guard let box = try? decoder.container(keyedBy: Keys.self) else {
                        item = nil
                        return
                    }
                    func text(_ key: Keys) -> String? { try? box.decode(String.self, forKey: key) }
                    // 참·거짓은 숫자가 아니다
                    let isFlag = (try? box.decode(Bool.self, forKey: .price)) != nil
                    item = AgentItem.make(
                        id: text(.id), title: text(.title), price: isFlag ? nil : try? box.decode(Double.self, forKey: .price),
                        mall: text(.mall), url: text(.url), image: text(.image), brand: text(.brand),
                        shipping: text(.shipping), detail: text(.detail)
                    )
                }
            }

            let items: [AgentItem]

            init(from decoder: Decoder) throws {
                var urls = Set<URL>()
                var ids = Set<String>()
                let found = ((try? decoder.singleValueContainer().decode([Item].self)) ?? []).compactMap(\.item)
                items = Array(found.filter { item in
                    if let id = item.id, ids.contains(id) { return false }
                    guard urls.insert(item.url).inserted else { return false }
                    if let id = item.id { ids.insert(id) }
                    return true
                }.prefix(AgentItem.reportLimit))
            }
        }

        /// 보고의 페이지 목록 (`report.links`). 꼴이 다른 요소나 열 만하지 않은 주소는 그것만 버린다.
        /// 같은 주소는 한 번만, 최대 `AgentLink.reportLimit`개. 맥이 주는 `site`는 읽지 않는다 (주소에서 직접 뽑는다)
        struct Links: Decodable {
            private struct Item: Decodable {
                let link: AgentLink?
                enum Keys: String, CodingKey { case title, url, image }
                init(from decoder: Decoder) throws {
                    guard let box = try? decoder.container(keyedBy: Keys.self) else {
                        link = nil
                        return
                    }
                    link = AgentLink.page(
                        title: try? box.decode(String.self, forKey: .title), url: try? box.decode(String.self, forKey: .url),
                        image: try? box.decode(String.self, forKey: .image)
                    )
                }
            }

            let items: [AgentLink]

            init(from decoder: Decoder) throws {
                var seen = Set<URL>()
                let found = ((try? decoder.singleValueContainer().decode([Item].self)) ?? []).compactMap(\.link)
                items = Array(found.filter { seen.insert($0.url).inserted }.prefix(AgentLink.reportLimit))
            }
        }

        /// 보고의 캡처 목록. 형식에 맞지 않는 항목은 그것만 버린다 (캡처 때문에 보고 전체를 못 읽지 않게)
        /// 승인·질문 카드에 붙는 화면 하나 (D93). 꼴이 어긋나면 없는 것으로 본다 (카드 자체는 그대로 읽는다)
        struct CardCapture: Decodable {
            let value: AgentAttachment?

            init(from decoder: Decoder) throws {
                // 카드에는 화면 캡처만 받는다
            value = (try? Attachments.Item(from: decoder)).flatMap { Attachments.attachment(from: $0) }.flatMap { $0.kind == .screenshot ? $0 : nil }
            }
        }

        struct Attachments: Decodable {
            struct Item: Decodable {
                let id: String?
                let type: String?
                let mime: String?
                let width: Int?
                let height: Int?
                let bytes: Int?
                let page_host: String?
                let caption: String?
                let sensitive: Bool?
                let expires_at: String?
            }
            private struct Skipped: Decodable {}

            let items: [AgentAttachment]

            init(from decoder: Decoder) throws {
                guard var list = try? decoder.unkeyedContainer() else {
                    items = []
                    return
                }
                var found: [AgentAttachment] = []
                while !list.isAtEnd {
                    if let item = try? list.decode(Item.self) {
                        if let attachment = Self.attachment(from: item), !found.contains(where: { $0.id == attachment.id }) {
                            found.append(attachment)
                        }
                    } else if (try? list.decode(Skipped.self)) == nil {
                        break
                    }
                }
                // 영상은 하나만 (맥은 영상을 먼저 준다)
                var hasVideo = false
                found = found.filter { item in
                    guard item.isVideo else { return true }
                    defer { hasVideo = true }
                    return !hasVideo
                }
                items = Array(found.prefix(AgentAttachment.maxCount))
            }

            /// 화면 캡처·만든 그림(png·jpeg)·만든 영상(mp4)이고, 주소에 넣을 수 있는 번호일 때만 (D112)
            static func attachment(from item: Item) -> AgentAttachment? {
                guard let kind = item.type.flatMap(AgentAttachment.Kind.init(rawValue:)), let id = item.id, AgentHTTPClient.isPathSafe(id),
                      let mime = item.mime?.lowercased() else { return nil }
                switch kind {
                case .screenshot, .image: guard ["image/jpeg", "image/png"].contains(mime) else { return nil }
                case .video: guard mime == "video/mp4" else { return nil }
                }
                let clean = { (text: String?, limit: Int) -> String? in
                    let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : String(text.prefix(limit))
                }
                // 사이트 이름은 호스트 꼴일 때만 보여 준다 (주소나 글이 들어오면 버린다)
                let host = clean(item.page_host, 100).flatMap { host in
                    host.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" } ? host : nil
                }
                return AgentAttachment(
                    id: id, width: max(0, item.width ?? 0), height: max(0, item.height ?? 0), pageHost: host,
                    caption: clean(item.caption, AgentAttachment.maxCaption),
                    // 맥이 "공개 화면"이라고 분명히 말한 것만 바로 보여 준다
                    isSensitive: item.sensitive != false, expiresAt: item.expires_at,
                    kind: kind, bytes: item.bytes.flatMap { $0 > 0 ? $0 : nil }
                )
            }
        }

        struct Sent: Decodable {
            let to: Recipients?
            let sent_at: String?
            let verified: String?
            let sha256: String?
            let external: Bool?
        }

        /// 보내기 전 기다림 (`send_pending`). 시각은 모두 맥의 시계 (UTC, ISO 8601)
        struct Send: Decodable {
            let sha256: String?
            /// 승인한 것과 같은 내용
            let fields: [String: Loose]?
            let cancel_until: String?
            let now: String?
            /// 받는 사람이 내가 아니다 (D89)
            let external: Bool?
        }

        /// 주소 하나 또는 여러 개
        struct Recipients: Decodable {
            let list: [String]

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let one = try? container.decode(String.self) { list = [one] } else { list = (try? container.decode([String].self)) ?? [] }
            }
        }

        struct Question: Decodable {
            let question_id: String
            let text: String
            let choices: [String]?
            let received: Bool?
            let attachment: CardCapture?
            /// `question.handover` (D123). 꼴이 틀리면 없는 것으로 (질문 전체를 버리지 않게)
            let handover: LooseHandover?
        }

        struct Narration: Decodable {
            let time: String?
            let text: String
        }

        let id: String
        let status: String
        let task: String
        let steps: [Step]?
        let approval: Approval?
        let result: Result?
        let title: String?
        let brief: AgentBrief?
        let narration: [Narration]?
        let question: Question?
        let send: Send?
        let browser: Browser?
        /// 줄 선 까닭 (D152). 글자가 아닌 값이 와도 작업 전체를 버리지 않는다
        let wait_reason: Loose?
        /// 끼워 넣은 내 말 (D152). 꼴이 틀린 줄은 버린다
        let steers: SpaceDecoding.Lossy<[SpaceDecoding.Lossy<SteerDTO>]>?

        struct SteerDTO: Decodable {
            let time: String?
            let text: String?
            let applied: Bool?
        }

        /// 이 작업에 쓴 기술의 이름 (없으면 보통의 작업). 글이 아닌 값이 와도 작업 전체를 버리지 않게 느슨하게 받는다
        let skill: Loose?

        var state: AgentTaskState {
            var state = AgentTaskState(id: id, task: task, steps: (steps ?? []).map(Self.describe), phase: .running)
            state.isQueued = status == "queued"
            if state.isQueued, let reason = wait_reason, reason.isString {
                state.waitReason = ActivityDecoding.clean(reason.text, limit: 80)
            }
            let notes = (steers?.value ?? []).compactMap(\.value).compactMap { dto -> AgentSteerNote? in
                guard let text = ActivityDecoding.clean(dto.text, limit: AgentSteerNote.textLimit) else { return nil }
                return AgentSteerNote(time: dto.time, text: text, applied: dto.applied ?? false)
            }
            if !notes.isEmpty { state.steers = notes }
            if let skill, skill.isString, !skill.text.isEmpty, skill.text.count <= AgentTaskState.skillLimit { state.skill = skill.text }
            if let title, !title.isEmpty { state.serverTitle = title }
            if let brief, !brief.isEmpty { state.brief = brief }
            state.activity = steps?.last.map(Self.activity)
            if let narration, !narration.isEmpty {
                state.narration = narration.map { AgentNarration(time: $0.time, text: $0.text) }
                // 맥이 쓴 설명이 있으면 작업 카드에도 그 말을 쓴다
                if let last = narration.last?.text, !last.isEmpty { state.activity = last }
            }
            if let approval {
                state.draft = AgentDraft(
                    approvalID: approval.approval_id,
                    action: approval.action,
                    fields: AgentDraft.orderedFields(approval.fields.mapValues(\.text)),
                    sha256: approval.sha256,
                    shownSHA256: approval.shownSHA256,
                    received: approval.received,
                    kind: approval.kind,
                    // 어느 사이트의 단추인지 (호스트만). 초안·보내기의 기록은 예전 그대로 둔다
                    site: approval.kind == AgentDraft.actionKind ? AgentDraft.siteHost(approval.url) : nil,
                    // 다른 사람에게 보내는 메일 (D89). 보내는 메일에서만 본다
                    external: approval.kind == "send" ? approval.external : nil,
                    attachment: approval.attachment?.value
                )
            }
            if let result {
                state.result = result.summary
                state.question = result.question
                if let report = result.report {
                    let clean = { (items: [String]?) in (items ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
                    var value = AgentReport(done: clean(report.done), blocked: clean(report.blocked), sources: clean(report.sources))
                    let sent = (report.sent ?? []).map {
                        // 모르는 확인 값은 "도착을 확인하지 못함"으로 본다 (확인했다고 잘못 말하지 않는다)
                        AgentSent(
                            to: $0.to?.list ?? [], sentAt: $0.sent_at,
                            verified: AgentSent.Verified(rawValue: $0.verified ?? "") ?? .acceptedOnly, sha256: $0.sha256,
                            external: $0.external
                        )
                    }
                    if !sent.isEmpty { value.sent = sent }
                    if let attachments = report.attachments?.items, !attachments.isEmpty { value.attachments = attachments }
                    if let links = report.links?.items, !links.isEmpty { value.links = links }
                    if let items = report.items?.items, !items.isEmpty { value.items = items }
                    // 답을 쓴 곳: 아는 값만 받는다 (모르는 값이면 표시하지 않는다)
                    if let by = report.by, by.isString, AgentReport.writers.contains(by.text) { value.by = by.text }
                    value.card = report.card?.value?.card
                    if let speak = report.speak, speak.isString { value.speak = VoiceText.clean(speak.text) }
                    if !value.isEmpty { state.report = value }
                }
                let pressed = (result.approved_actions?.list ?? [])
                    .map { $0.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { String($0.prefix(AgentTaskState.actionNameLimit)) }
                if !pressed.isEmpty { state.approvedActions = Array(pressed.prefix(AgentTaskState.actionLimit)) }
                state.approvedDrafts = (result.approved_drafts ?? []).map {
                    AgentDraft(
                        approvalID: nil, action: $0.action, fields: AgentDraft.orderedFields($0.fields.mapValues(\.text)),
                        sha256: $0.sha256, kind: $0.kind
                    )
                }
            }
            switch status {
            case "queued", "running":
                state.phase = .running
                // 쇼핑 화면에 시킨 일은 진행 중일 때만 받는다
                if status == "running", let command = browser?.command {
                    state.browse = command
                    state.usedShop = true
                }
            case "awaiting_approval": state.phase = .awaitingApproval
            case "awaiting_input":
                // 질문이 빠진 응답이면 물어볼 수 없으니 진행 중으로 두고 다음 조회를 기다린다
                if let question, !question.text.isEmpty {
                    state.phase = .awaitingInput
                    state.pendingQuestion = AgentQuestion(
                        id: question.question_id, text: question.text,
                        choices: (question.choices ?? []).filter { !$0.isEmpty }, received: question.received,
                        attachment: question.attachment?.value, handover: question.handover?.value
                    )
                }
            case "completed":
                state.phase = .done
                // 마지막으로 머문 페이지 (열 수 있는 주소일 때만)
                state.links = (steps ?? []).last { $0.url != nil }.flatMap { AgentLink.openable($0.url) }.map { [$0] }
            case "send_pending":
                state.phase = .sendPending
                var wait = AgentSendWait(cancelUntil: send?.cancel_until, sha256: send?.sha256)
                if let until = AgentTime.date(send?.cancel_until) {
                    // 남은 시간은 맥의 시계끼리 뺀 값으로 구해, 이 기기 시계의 마감으로 옮긴다
                    wait.deadline = AgentTime.date(send?.now).map { Date.now.addingTimeInterval(until.timeIntervalSince($0)) } ?? until
                }
                state.sendWait = wait
                if let fields = send?.fields, !fields.isEmpty {
                    state.outgoing = AgentDraft(
                        approvalID: nil, action: "보내기", fields: AgentDraft.orderedFields(fields.mapValues(\.text)),
                        sha256: send?.sha256, kind: "send", external: send?.external
                    )
                }
            case "needs_input": state.phase = .needsInput
            case "cancelled":
                state.phase = .canceled
                state.error = send == nil ? AgentTaskState.canceledText : AgentTaskState.sendCanceledText
            default:
                // failed: 사유 코드를 문장으로
                switch result?.outcome {
                case "approval_denied", "cancelled":
                    state.phase = .canceled
                    state.error = AgentTaskState.deniedText
                case "needs_login":
                    // 사이트 로그인이 없거나 풀려서 멈췄다. 맥이 사이트를 알려 줬으면 대화에서 바로 로그인할 수 있게 한다.
                    // 사이트 번호는 주소에 들어가므로 안전한 글자일 때만 받는다
                    state.phase = .failed
                    let expired = result?.reason == "login_expired"
                    if result?.action?.type == "site_login", let site = result?.action?.site, AgentHTTPClient.isPathSafe(site) {
                        state.loginSite = site
                        state.loginExpired = expired
                    }
                    state.error = AgentTaskState.loginFailureText(site: state.loginSite, expired: expired)
                default:
                    state.phase = .failed
                    state.error = Self.failureText(result?.outcome, reason: result?.reason)
                    if result?.outcome == "send_failed" { state.sendFailure = result?.reason ?? "" }
                }
            }
            return state
        }

        static func failureText(_ outcome: String?, reason: String? = nil) -> String {
            switch outcome {
            case "send_failed":
                AgentTaskState.sendFailureText(reason)
            case "approval_expired": "승인을 기다리는 시간(30분)이 지나 작업이 끝났어요."
            case "approval_mismatch": "승인한 내용과 실제 화면이 달라 저장하지 않았어요."
            case "max_steps": "단계 수 한도에 걸려 작업을 끝내지 못했어요."
            case "timeout": "시간이 너무 오래 걸려 작업을 멈췄어요."
            case "too_many_failures": "실패가 반복되어 작업을 멈췄어요."
            case "loop_detected": "같은 동작을 반복해서 작업을 멈췄어요."
            case "verify_failed": "맥의 완료 보고가 실제로 한 일과 맞지 않아 작업을 끝냈어요."
            case "internal_error": "맥 에이전트 안에서 오류가 나 작업을 끝내지 못했어요."
            case "provider_error": "맥의 모델을 부르지 못했어요. Ollama가 켜져 있는지 확인해 주세요."
            case "site_blocked": "사이트가 접속을 막아서 작업을 멈췄어요."
            case "browser_failed": "쇼핑 화면에서 읽어 오지 못해 작업을 끝냈어요."
            default: AgentTaskState.unfinishedText
            }
        }

        /// 서버의 한 단계를 사람이 읽는 한 줄로
        static func describe(_ step: Step) -> String {
            let arg = { (key: String) in step.args?[key]?.text ?? "" }
            var text: String = switch step.tool {
            case "navigate": "열기 · \(shortURL(arg("url").isEmpty ? (step.url ?? "") : arg("url")))"
            case "observe": "화면 확인"
            case "click": "누르기"
            case "type": "입력 · \(arg("text").prefix(30))"
            case "select_option": "선택"
            case "scroll": "스크롤"
            case "extract_text": "내용 읽기"
            case "ask_user": "질문 준비"
            case "search_web": "갈 곳 찾기"
            case "shop_search": "쇼핑 검색 결과 읽기"
            case "shop_open": "상품 화면 열어 읽기"
            case "finish": "마무리"
            default: {
                // 작업실의 단계 (D112): 맥이 붙인 한 줄 설명이 있으면 그것을 (명령의 첫 줄·파일 이름 — 영어일 수 있다)
                let brief = arg("brief").components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
                return brief.isEmpty ? step.tool : String(brief.prefix(80))
            }()
            }
            switch step.status {
            case "error": text += " (실패)"
            case "rejected": text += " (거부됨)"
            case "policy_denied": text += " (허용되지 않아 막힘)"
            case "needs_approval": text = AgentEvent.approvalRequested
            case "approval_feedback": text = AgentEvent.feedbackApplied
            default: break
            }
            return text
        }

        /// 지금 하는 일을 한 문장으로 (작업 카드에 보이는 말)
        static func activity(_ step: Step) -> String {
            switch step.status {
            case "needs_approval": return "승인을 기다리고 있어요"
            case "approval_feedback": return "요청하신 대로 고치고 있어요"
            default: break
            }
            return switch step.tool {
            case "navigate": "페이지를 열고 있어요"
            case "observe", "scroll": "화면을 살펴보고 있어요"
            case "click", "select_option": "화면에서 항목을 고르고 있어요"
            case "type": "내용을 입력하고 있어요"
            case "extract_text": "내용을 읽고 있어요"
            case "ask_user": "여쭤볼 내용을 정리하고 있어요"
            case "search_web": "갈 곳을 찾고 있어요"
            case "shop_search", "shop_open": "쇼핑 화면에서 찾고 있어요"
            case "finish": "마무리하고 있어요"
            default: "작업하고 있어요"
            }
        }

        static func shortURL(_ string: String) -> String {
            guard let url = URL(string: string), let host = url.host() else { return string }
            return host + (url.path() == "/" ? "" : url.path())
        }
    }

    /// 문자열·숫자·불리언 어느 것이든 글자로 받는다 (args·fields 값)
    struct Loose: Decodable {
        let text: String
        var isString = false

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) { text = string; isString = true }
            else if let bool = try? container.decode(Bool.self) { text = bool ? "true" : "false" }
            else if let number = try? container.decode(Double.self) {
                text = number.rounded() == number ? String(Int(number)) : String(number)
            } else { text = "" }
        }
    }
}

// MARK: - 요청 자료

enum AgentContext {
    /// 서버가 받는 context 최대 길이
    static let limit = 8000

    /// 질문 탭이 고른 회의 자료를 에이전트용 글로 바꾼다. 줄 단위로 한도에서 자른다.
    /// `recent`: 방금 Claude와 나눈 질문·답. 맥은 그 답을 보지 못했으므로 "그 내용으로 메일 써줘"를 알아듣게 앞에 붙인다.
    static func text(from request: AskRequest, recent: [AskRequest.Turn] = []) -> String? {
        var lines: [String] = []
        if !recent.isEmpty {
            lines.append("## 방금 나눈 회의 질문과 답")
            for turn in recent {
                // 긴 답이 회의 발췌 자리를 다 쓰지 않게 줄인다
                lines.append((turn.role == .user ? "질문: " : "답: ") + String(turn.text.prefix(1200)))
            }
            lines.append("")
        }
        for meeting in request.meetings {
            lines.append("## \(meeting.title) (\(meeting.date))")
            if let summary = meeting.summary, !summary.isEmpty { lines.append("요약: \(summary)") }
            for utterance in meeting.utterances {
                lines.append("[\(MeetingText.timestamp(utterance.start))] \(utterance.text)")
            }
            lines.append("")
        }
        if !request.otherMeetings.isEmpty {
            lines.append("## 다른 회의 목록")
            for meeting in request.otherMeetings {
                lines.append("- \(meeting.title) (\(meeting.date))" + (meeting.topic.map { ": \($0)" } ?? ""))
            }
        }
        // 보낼 자료가 없으면 날짜만 따로 보내지 않는다
        guard !lines.isEmpty else { return nil }
        // "오늘 회의"가 어느 회의인지는 자료만 봐서는 알 수 없다. 앱이 날짜로 확인한 사실을 맨 앞에 적는다
        if let today = request.today {
            var header = ["오늘 날짜: \(today)"]
            if let day = request.day {
                // "그 날 녹음한 회의는 없습니다"는 맥이 읽는 글자다 (메일 부탁이면 다른 날 회의로 보낼지 되묻는다). 바꾸려면 맥 쪽과 먼저 맞춘다
                header.append(day.found
                    ? "부탁이 가리키는 날: \(day.label). 그 날 녹음한 회의만 아래에 담았습니다."
                    : "부탁이 가리키는 날: \(day.label). 그 날 녹음한 회의는 없습니다. 아래는 다른 날 회의입니다.")
            }
            lines.insert(contentsOf: header + [""], at: 0)
        }
        var text = ""
        for line in lines {
            if text.count + line.count + 1 > limit { break }
            text += line + "\n"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 맥이 만든 내 목소리의 한 조각 (D136)
enum VoiceChunk: Equatable, Sendable {
    /// wav 한 조각 (24kHz 모노 16bit, 약 1초)
    case audio(Data)
    /// 다 받았다
    case end
    /// 10초 기다려도 아직 없다: 같은 조각을 다시 받는다
    case notReady
    /// 맥이 목소리를 만들 수 없다: 폰 목소리로 읽는다
    case unavailable
    /// 없거나 10분이 지났다
    case gone

    /// 한 조각의 크기 한도 (1초 조각은 48KB 남짓)
    static let maxBytes = 2_000_000
}
