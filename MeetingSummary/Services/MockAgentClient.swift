#if DEBUG
import AVFoundation
import Foundation
import UIKit

/// 개발용 가짜 맥 에이전트. 화면 확인과 테스트용으로, 실제 서버(local-ai-agent `docs/API.md`)의 흐름을 흉내 낸다.
///
/// 상태를 조회할 때마다 한 단계씩 진행한다 (시간이 아니라 조회 횟수 기준이라 테스트가 결정적이다).
/// - 시작 → 메일 열기 → 화면 확인 → 초안 입력 → 승인 대기
/// - 거부 + 사유 → 사유 반영 → 다시 입력 → 승인 대기 (새 approval_id)
/// - 거부, 사유 없음 → 끝 (승인하지 않음)
/// - 승인 → 저장 → 완료 (approved_drafts에 저장한 초안)
/// - 부탁에 "언제"가 있고 회의 자료가 없으면 → 정보 부족 질문
///
/// `v2`를 켜면 새 서버처럼 동작한다: 진행 설명(narration), 한 일·못 한 일 보고(report), 같은 메시지 번호 다시 받기,
/// 그리고 부탁에 "참조"가 있으면 작업 중간에 질문(awaiting_input)을 하고 답을 받아 이어 간다.
///
/// 대화 담당(`message`)은 글자 규칙으로 넷 중 하나를 고른다:
/// - 인사·고맙다는 말 → 바로 답
/// - 메일·초안 부탁인데 받는 사람이 없으면 → 선택지와 함께 되묻고, 답을 받으면 작업을 만든다
/// - 받는 사람이 있는 메일·초안 부탁 → 작업 (제목, 브리프, "네, ○○ 준비할게요.")
/// - 그 밖 → 회의 질문으로 보고 Claude로 넘긴다
///
/// `mail`을 주면 메일 보내기(`send_self`)와 계정 연결(`mail_connect`)을 지원하는 맥처럼 동작한다:
/// "나한테 메일로 보내 줘" → 계정 확인 → 보내기 승인 대기 → 승인 → 잠깐 기다림(취소 가능) → 발송 → 도착 확인
///
/// `sites`를 주면 사이트 로그인(`site_login`)을 지원하는 맥처럼 동작한다:
/// "네이버 로그인해 줘" → 로그인 화면 열기 → 아이디·비밀번호 입력 → 휴대폰 승인 대기 → 로그인됨
///
/// `offersSkills`를 켜면 맡길 수 있는 일(`skills`)을 알려 주는 맥처럼 동작한다: 카드 넷을 돌려주고,
/// 준비가 되었는지는 실제 맥처럼 지금 상태(메일 계정, 네이버 로그인)로 정한다. "오늘 온 메일 요약해줘"에는 가상 브리핑으로 답한다
///
/// `captures`를 주면 보고에 화면 캡처(`report_attachments`)를 붙이는 맥처럼 동작한다:
/// "결제내역 알려줘" → 페이지 열기 → 읽기 → 답 + 읽은 화면의 캡처 (로그인이 풀려 있으면 멈춘 화면의 캡처)
///
/// `siteDo`를 주면 로그인한 사이트 안에서 해 주는(`site_do`) 맥처럼 동작한다 (D80. 사이트 "todo.test"도 할 일도 지어낸 것이다):
/// "todo.test에 할 일 추가해줘" → (처음이면) 그 화면을 Claude가 봐도 되는지 묻기 → 열기 → 입력 → 단추 누르기 승인 대기 → 승인 → 누르기 → 보고

/// 로그인한 사이트 안에서 해 주는 가짜 맥의 설정 (`site_do`, D80). 글은 실제 맥이 보내는 것과 같게 둔다
struct MockSiteDo: Sendable {
    /// 그 사이트의 화면을 Claude가 봐도 된다고 이미 허락했는지 (허락했으면 묻지 않는다)
    var allowed = false

    init(allowed: Bool = false) { self.allowed = allowed }

    /// 실행 인자 값: `allowed`(이미 허락한 사이트라 묻지 않는다)
    init(demo: String?) { allowed = demo == "allowed" }

    static let host = "todo.test"
    static let siteName = "가상할일"
    static let page = "https://todo.test/list"
    static let button = "추가"
    static let question = "\(siteName)의 로그인한 화면을 Claude가 보고 조작해도 될까요? 그 화면의 글이 Claude로 갑니다(비밀번호는 가지 않아요)."
    static let refused = "허락하지 않으셔서 하지 않았어요."
    static let unanswered = "허락을 받지 못해 하지 않았어요. 다시 말씀해 주시면 여쭐게요."
    /// 결과 글: 맥이 쓰는 꼴 그대로 첫 줄에 결론 한 문장, 그 아래 "- "로 시작하는 짧은 줄 (D82)
    static let done = "할 일 목록에 '주간 보고 쓰기'를 추가했어요.\n- 목록에 새 할 일이 보이는 것을 확인했어요\n- 지금 할 일은 3건이에요"

    /// 승인 카드에 실리는 "누를 단추": 초안과 같은 네 값으로 확인 번호를 만든다. `revised`면 거부 사유를 반영해 고친 값이다
    static func approval(id: String, revised: Bool) -> AgentDraft {
        let fields = ["할 일": "주간 보고 쓰기", "기한": revised ? "월요일" : "금요일"]
        let hash = AgentDraftHash.sha256(action: button, fields: fields, kind: AgentDraft.actionKind, url: page)
        return AgentDraft(
            approvalID: id, action: button, fields: AgentDraft.orderedFields(fields), sha256: hash, shownSHA256: hash,
            kind: AgentDraft.actionKind, site: AgentDraft.siteHost(page),
            // 누르려는 단추가 있는 그 화면 (D93. 그림은 앱이 그린 가상 화면이다)
            attachment: AgentAttachment(
                id: "p1", width: Int(MockCaptures.pageSize.width), height: Int(MockCaptures.pageSize.height), pageHost: host,
                caption: "'\(button)' 단추가 있는 화면"
            )
        )
    }
}

/// 대화 판단을 Claude에 맡긴 가짜 맥이 함께 알리는 것
struct MockDialogCloud: Sendable {
    /// 회의 자료의 내용을 Claude로 보낸다 (`dialog_context`)
    var sendsContext = true
    /// 공개 정보를 웹 검색으로 찾는다 (`web_lookup`)
    var webLookup = false
    /// 답의 말풍선마다 누가 썼는지 알린다 (`reply_by`)
    var marksWriter = false
    /// "찾아 달라"는 말을 작업으로 만들어 답을 찾고, 브라우저로 연 페이지를 보고에 붙인다 (`web_find` + `report_links`)
    var findsPages = false
    /// 그 페이지를 네이버 검색으로 찾는다 (`web_find_naver`). 그러면 답은 맥의 로컬 모델이 쓴다
    var findsWithNaver = false
    /// 브라우저가 연 공개 페이지의 글을 Claude가 읽는다고 알린다 (`web_find_reads_cloud`). 가짜 맥의 답은 달라지지 않는다
    var pagesReadByCloud = false
    /// 정해진 기능에 없는 부탁을 맥의 브라우저로 직접 해 본다고 알린다 (`web_browse`, D76). 가짜 맥의 답은 달라지지 않는다
    var browsesWeb = false
    /// 날씨 물음에 "날씨 카드를 그려라"로 답한다 (`weather_action`). 앱이 그릴 수 있다고 알린 요청에만 그렇게 답한다
    var showsWeather = false
    /// 내 말에 반응(이모지 하나)을 단다 (`reaction`, D70). 앱이 그릴 수 있다고 알린 요청에만 단다
    var reacts = false
    /// 살 것을 찾아 달라는 말에 상품 목록을 보고에 붙이고, 고른 상품의 번호를 받는다 (`report_items`, D72). 찾기를 하는 맥일 때만
    var listsItems = false
    /// 살 것을 말하면 "쇼핑 화면을 열어라"로 답하고, 앱이 읽어 보낸 화면의 값으로 답한다 (`shop_view`, D74).
    /// 앱이 쇼핑 화면을 열 수 있다고 알린 요청에만 그렇게 답한다
    var opensShop = false
    /// 살 것을 말하면 작업을 만들어, 앱의 쇼핑 화면에 검색과 상품 열기를 시키고 읽어 온 것으로 상품 목록을 만든다 (`shop_drive`, D75).
    /// 쇼핑 화면을 아는 맥일 때만. 앱이 그렇게 할 수 있다고 알린 요청에만 그렇게 한다
    var drivesShop = false
    /// 개발용: 그 일(`search`·`open`)의 결과를 받은 뒤 다음으로 넘어가지 않고 머문다 (쇼핑 화면의 "찾는 중"을 찍을 때)
    var driveHold: AgentBrowse.Kind?
    /// 대화에 붙인 사진·PDF를 받는다 (`uploads`, D85). 실제 맥처럼 Claude 판단일 때만 알린다
    var takesUploads = false
    /// 붙인 것을 보고 하는 답 (화면 확인용으로 정해 둔 가상의 말. 가짜 맥은 그림을 읽지 않는다). 비어 있으면 받았다는 말만 한다
    var uploadReplies: [String] = []
    /// 붙인 것 하나를 받는 데 걸리는 시간 (올리는 중의 모습을 찍을 때)
    var uploadDelay: Duration = .zero

    init(
        sendsContext: Bool = true, webLookup: Bool = false, marksWriter: Bool = false, findsPages: Bool = false,
        findsWithNaver: Bool = false, showsWeather: Bool = false, pagesReadByCloud: Bool = false, reacts: Bool = false,
        listsItems: Bool = false, opensShop: Bool = false, drivesShop: Bool = false, browsesWeb: Bool = false
    ) {
        self.browsesWeb = browsesWeb
        self.opensShop = opensShop
        self.drivesShop = opensShop && drivesShop
        self.showsWeather = showsWeather
        self.reacts = reacts
        self.listsItems = findsPages && listsItems
        self.pagesReadByCloud = findsPages && pagesReadByCloud
        self.sendsContext = sendsContext
        self.webLookup = webLookup
        self.marksWriter = marksWriter
        self.findsPages = findsPages
        self.findsWithNaver = findsPages && findsWithNaver
    }

    /// 실행 인자 값: `bare`(회의 자료의 내용을 보내지 않음), `web`(웹 검색도 함), `by`(웹 검색도 하고, 누가 썼는지도 알림),
    /// `find`(by에 더해, "찾아 달라"는 말에 검색으로 답을 찾고 브라우저로 그 페이지를 엶), `naver`(find인데 네이버 검색으로 찾음),
    /// `weather`(find에 더해, 날씨 물음에 앱이 날씨 카드를 그리게 함), `react`(weather에 더해, 내 말에 반응을 닮),
    /// `shop`(react에 더해, 살 것을 찾아 달라는 말에 상품 목록을 줌),
    /// `browse`(react에 더해, 살 것을 말하면 앱 안의 쇼핑 화면을 열게 하고 읽어 보낸 화면으로 답함. D74),
    /// `drive`(browse에 더해, 살 것을 말하면 앱의 쇼핑 화면에 검색과 상품 열기를 시켜 상품 목록을 만들어 옴. D75.
    /// 맥의 브라우저로 직접 해 보기도 한다고 알림. D76 — 데이터 처리 방식의 글만 달라진다)
    init(demo: String?, hold: String? = nil) {
        let reacts = demo == "react" || demo == "shop" || demo == "browse" || demo == "drive"
        let finds = demo == "find" || demo == "naver" || demo == "weather" || reacts
        let both = demo == "by" || finds
        self.init(
            sendsContext: demo != "bare", webLookup: demo == "web" || both, marksWriter: both, findsPages: finds,
            findsWithNaver: demo == "naver", showsWeather: demo == "weather" || reacts, reacts: reacts,
            listsItems: demo == "shop" || demo == "drive", opensShop: demo == "browse" || demo == "drive", drivesShop: demo == "drive",
            browsesWeb: demo == "drive"
        )
        driveHold = hold.flatMap(AgentBrowse.Kind.init(rawValue:))
    }
}

/// 가상 쇼핑몰의 사람 확인 화면 (손 넘기기, D123). 지어낸 그림이다: 누른 곳에 점을 찍고 쓴 글을 칸에 보인다
enum MockHandoverScreen {
    static let size = CGSize(width: 390, height: 640)

    static func frame(inputs: [HandoverInput]) -> HandoverFrame {
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 2; return f }())
        let image = renderer.jpegData(withCompressionQuality: 0.8) { context in
            UIColor(white: 0.96, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 24, y: 120, width: 342, height: 400), cornerRadius: 12).fill()
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.darkText]
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.darkGray]
            ("가상몰" as NSString).draw(at: CGPoint(x: 24, y: 48), withAttributes: title)
            ("사람인지 확인해 주세요" as NSString).draw(at: CGPoint(x: 44, y: 140), withAttributes: title)
            ("자전거가 있는 칸을 모두 누르세요" as NSString).draw(at: CGPoint(x: 44, y: 172), withAttributes: body)
            for row in 0..<3 {
                for column in 0..<3 {
                    let rect = CGRect(x: 44 + column * 104, y: 210 + row * 84, width: 96, height: 76)
                    UIColor(hue: CGFloat((row * 3 + column) % 9) / 9, saturation: 0.25, brightness: 0.9, alpha: 1).setFill()
                    UIBezierPath(roundedRect: rect, cornerRadius: 6).fill()
                }
            }
            let typed = inputs.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
            UIColor(white: 0.9, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 44, y: 470, width: 302, height: 36), cornerRadius: 8).fill()
            ((typed.isEmpty ? "확인 문자" : typed) as NSString).draw(at: CGPoint(x: 54, y: 478), withAttributes: body)
            UIColor.systemRed.setFill()
            for case let .tap(x, y) in inputs.suffix(12) {
                UIBezierPath(ovalIn: CGRect(x: x - 8, y: y - 8, width: 16, height: 16)).fill()
            }
        }
        return HandoverFrame(image: image, width: Int(size.width), height: Int(size.height))
    }
}

actor MockAgentClient: AgentProviding {
    private struct Job {
        var state: AgentTaskState
        var queue: [String]
        var next: AgentTaskState.Phase
        var reason: String?
        var approvals = 0
        var recipient = "team@mail.test"
        let context: String?
        /// 초안을 쓰기 전에 물어볼 질문 (v2)
        var asks: AgentQuestion?
        /// 보내는 메일 작업이면 보내는 계정의 주소 (보내는 곳 = 받는 곳)
        var sendsFrom: String?
        /// 보내기 전 기다림이 조회 몇 번 더 이어지는지
        var waitLeft = 0
        /// 사이트를 읽고 답하는 작업 (승인이 없다. 끝나면 답과 캡처를 붙인다)
        var reads = false
        /// 공개 페이지를 찾아 읽고 답하는 작업 (승인이 없다. 끝나면 답과 읽은 페이지를 붙인다)
        var finds = false
        /// 살 것을 찾는 작업 (끝나면 상품 목록을 붙인다, D72)
        var shops = false
        /// 앱의 쇼핑 화면에 일을 시켜 살 것을 찾는 작업 (D75). 폰이 결과를 돌려줄 때만 다음으로 넘어간다
        var drives = false
        /// 그 작업에서 폰이 읽어 보낸 목록
        var list: [ShopView.Item] = []
        /// 로그인한 사이트 안에서 하는 작업 (`site_do`, D80): 승인은 초안이 아니라 "단추 누르기"다
        var acts = false
        /// 시작하기 전에 물어볼 허락 (그 사이트의 화면을 Claude가 봐도 되는지)
        var permission: AgentQuestion?
        /// 허락을 받지 못했으면 그 이유 (이 말로 끝낸다)
        var refusal: String?
        /// 작업실에서 보고서를 만드는 작업 (`-demoReport`): 끝나면 보고서를 만들었다고 답한다
        var report = false
        /// 이 작업이 속한 맥의 대화 (기다리는 작업 목록에 싣는다)
        var conversationID: String?
        /// 데모 영상용 (`-demoReel`): 손 넘기기 뒤에 답변 카드로 끝난다
        var reel = false
    }

    private var reachable: Bool
    /// 맥이 꺼지거나 다시 켜진 것처럼 (테스트용)
    func setReachable(_ reachable: Bool) { self.reachable = reachable }
    /// 처음 몇 번의 연결 확인이 실패하는지 (잠깐 끊겼다 돌아오는 맥)
    private var failingChecks: Int
    private let v2: Bool
    /// 메시지 번호별 처음 응답 (v2)
    private var replies: [String: AgentReply] = [:]
    /// 받은 답 (테스트 확인용)
    private(set) var answers: [(questionID: String, answer: String)] = []
    /// 받은 메시지 번호 (테스트 확인용)
    private(set) var messageIDs: [String?] = []
    /// 메시지와 함께 받은 "답장으로 가리킨 작업" 번호 (테스트 확인용)
    private(set) var replyTaskIDs: [String?] = []
    /// 메시지와 함께 받은 것: 앱이 그릴 수 있는 것, 앱이 보여 준 것 (테스트 확인용. 다시 보낸 요청도 센다)
    private(set) var receivedExtras: [MessageExtras] = []
    /// 통화를 받는 맥인지 (`voice_call`, D134)
    var takesCalls = true
    /// 내 목소리를 만들어 주는 맥인지 (`voice_tts`, D136)
    var takesVoice = false
    /// 만든 목소리의 조각들 (번호 → 조각 차례)
    private var voices: [String: [VoiceChunk]] = [:]
    /// 끼어들어 멈춘 목소리
    private(set) var cancelledVoices: [String] = []
    /// 앱이 알린 연락처 `{이름: 메일 주소}` (D89)
    private(set) var contacts: [String: String] = [:]
    /// 앱이 알린, 메일 주소가 없는 사람의 이름 (D92)
    private(set) var contactsNoEmail: [String] = []
    /// 맥이 읽은(알아들은) 쇼핑 화면들: 쇼핑 화면을 아는 맥이, 그 표시가 온 요청에서만 읽는다
    private(set) var shopViews: [ShopView] = []
    /// 폰이 돌려준 "시킨 일의 결과"들 (테스트 확인용)
    private(set) var browseResults: [(taskID: String, result: BrowseResult)] = []
    /// 다음 결과 받기들이 이 오류로 실패한다 (테스트용)
    private var browseFailures: [AgentError] = []
    /// 대화 기록에 적은 "앱이 보여 준 날씨". 실제 맥처럼 같은 메시지 번호로 다시 온 요청의 것은 다시 적지 않는다
    private(set) var recordedWeather: [String] = []
    /// 지금 판단하는 메시지에 딸려 온 것
    private var extras = MessageExtras.none
    /// 지금 판단하는 메시지가 답장으로 가리킨 작업
    private var repliedTask: String?
    /// 다음 메시지들을 받지 못한 것으로 한다 (테스트용. 받지 못한 요청에 딸려 온 것은 적지 않는다)
    private var messageFailures: [AgentError] = []
    /// 다음 메시지들에 그대로 줄 응답 (테스트용. 대화 번호만 맞춰서 준다)
    private var scripted: [AgentReply] = []
    private var jobs: [String: Job] = [:]
    private var counter = 0
    private var conversations = 0
    /// 되물은 뒤 답을 기다리는 대화 (대화 번호 → 원래 부탁)
    private var asked: [String: String] = [:]
    /// 대화 담당이 받은 메시지 (테스트 확인용)
    private(set) var received: [(text: String, conversationID: String?, context: String?)] = []
    /// 메일 보내기 설정. nil이면 보내기를 모르는 맥
    private var mail: MockMail?
    private var accounts: [MailAccount]
    /// 계정 연결을 받은 횟수 (테스트 확인용. 비밀번호는 어디에도 남기지 않는다)
    private(set) var connects = 0
    /// 사이트 로그인 설정. nil이면 사이트 로그인을 모르는 맥
    private var sites: MockSites?
    private var logins: [String: LoginRun] = [:]
    private var siteCheckedAt: Date?
    /// 로그인을 시작한 횟수와 취소를 받은 횟수 (테스트 확인용)
    private(set) var loginStarts = 0
    private(set) var loginCancels = 0
    /// 받은 입력의 화면 번호와 칸 이름 (테스트 확인용. 값은 어디에도 남기지 않는다)
    private(set) var loginInputs: [(step: Int, names: [String])] = []
    /// 맡길 수 있는 일을 알려 주는 맥인지
    private let offersSkills: Bool
    /// 보고에 화면 캡처를 붙이는 설정. nil이면 캡처를 모르는 맥
    private let captures: MockCaptures?
    /// 로그인한 사이트 안에서 해 주는 설정. nil이면 그 일을 모르는 맥. "이 사이트는 허락"을 받으면 허락한 것으로 바뀐다
    private var siteDo: MockSiteDo?
    /// 대화 판단을 Claude에 맡겼다고 알리는 설정 (`dialog_cloud`). nil이면 로컬 판단. 가짜 맥의 답은 달라지지 않는다
    private let dialogCloud: MockDialogCloud?
    /// 캡처 그림을 달라는 요청을 받은 횟수 (테스트 확인용)
    private(set) var captureRequests = 0
    /// 메시지에 답하기까지 걸리는 시간 (실제 맥은 2~6초. 화면 확인과 "답을 기다리는 동안"의 시험에 쓴다)
    private let replyDelay: Duration
    /// 예약해 둔 일 (D91). nil이면 예약을 모르는 맥
    private var routineBook: MockRoutines?
    /// 예약 목록을 달라는 요청을 받은 횟수 (테스트 확인용)
    private(set) var routineListCalls = 0

    init(
        reachable: Bool = true, v2: Bool = false, failingChecks: Int = 0, mail: MockMail? = nil, sites: MockSites? = nil,
        offersSkills: Bool = false, captures: MockCaptures? = nil, dialogCloud: MockDialogCloud? = nil, offersPush: Bool = false,
        offersPushText: Bool = false, replyDelay: Duration = .zero, siteDo: MockSiteDo? = nil, routines: MockRoutines? = nil,
        space: MockSpace? = nil, spaceArranges: Bool = true, waitingDemo: Bool = false,
        offersActivity: Bool = false
    ) {
        self.offersActivity = offersActivity
        self.spaceArranges = spaceArranges
        self.spaceBook = space
        self.routineBook = routines
        self.siteDo = siteDo
        self.replyDelay = replyDelay
        self.offersPush = offersPush
        // 알림을 보내지 않는 맥은 알림의 글도 주지 않는다
        self.offersPushText = offersPush && offersPushText
        self.dialogCloud = dialogCloud
        self.offersSkills = offersSkills
        self.captures = captures
        self.reachable = reachable
        self.v2 = v2
        self.failingChecks = failingChecks
        self.mail = mail
        self.accounts = mail?.accounts ?? []
        self.sites = sites
        if waitingDemo {
            counter += 1
            jobs["t_mac_\(counter)"] = Self.macJob(id: "t_mac_\(counter)", conversationID: "c_mac_workroom", title: "보고서 메일 보내기")
        }
    }

    // MARK: 활동·전역 검색 (D120)

    /// 활동 목록과 검색을 하는 맥인지
    private let offersActivity: Bool

    func activity(limit: Int) async throws -> [ActivityEntry] {
        guard reachable else { throw AgentError.unreachable }
        guard offersActivity else { return [] }
        return Array(activityEntries().prefix(limit))
    }

    // MARK: 오래 가는 기억 (D151): `-demoMemory [empty]`, 테스트는 `enableMemory()`

    private var memoryBook: MockMemory? = ProcessInfo.processInfo.arguments.contains("-demoMemory")
        ? MockMemory(demo: ProcessInfo.processInfo.arguments.firstIndex(of: "-demoMemory").flatMap { index in
            let args = ProcessInfo.processInfo.arguments
            return args.indices.contains(index + 1) ? args[index + 1] : nil
        })
        : nil

    func enableMemory(_ book: MockMemory = MockMemory(demo: nil)) { memoryBook = book }
    var memoryProfile: String? { memoryBook?.profile }

    func memory() async throws -> AgentMemory {
        guard reachable else { throw AgentError.unreachable }
        guard let book = memoryBook else { throw AgentError.server("not_found") }
        return AgentMemory(profile: book.profile, turns: book.archive.count, since: book.archive.isEmpty ? nil : "2026-11-11", updatedAt: book.updatedAt, source: book.source)
    }

    func setMemoryProfile(_ profile: String) async throws -> String {
        guard reachable else { throw AgentError.unreachable }
        guard memoryBook != nil, profile.count <= AgentMemory.sendLimit else { throw AgentError.server("invalid_request") }
        // 지금 글을 먼저 꺼내 둔다 (같은 값을 읽으면서 고치면 접근이 겹친다)
        let current = memoryBook?.profile ?? ""
        memoryBook?.previous = [current]
        // 실제 맥처럼: 비밀 꼴(여기서는 10자리 넘는 숫자)을 지우고 3000자로 자른다
        let cleaned = profile.replacing(/[0-9][0-9-]{9,}/, with: "[지움]")
        memoryBook?.profile = String(cleaned.prefix(AgentMemory.savedLimit))
        memoryBook?.source = .user
        memoryBook?.updatedAt = .now
        return memoryBook?.profile ?? ""
    }

    /// 실제 맥처럼 한 단계뿐이다: 지금 판과 전 판을 맞바꾼다. 전 판이 없으면 409(`nothing_to_undo`)
    func undoMemory() async throws -> String {
        guard reachable else { throw AgentError.unreachable }
        guard let previous = memoryBook?.previous.popLast() else { throw AgentError.conflict }
        let current = memoryBook?.profile ?? ""
        memoryBook?.previous = [current]
        memoryBook?.profile = previous
        memoryBook?.source = .undo
        memoryBook?.updatedAt = .now
        return previous
    }

    func searchMemory(_ query: String) async throws -> [MemoryHit] {
        guard reachable else { throw AgentError.unreachable }
        guard let book = memoryBook else { throw AgentError.server("not_found") }
        return book.archive.enumerated()
            .filter { $0.element.text.localizedCaseInsensitiveContains(query) }
            .map { index, line in MemoryHit(id: index, when: line.when, isMine: line.mine, text: line.text, next: line.next) }
    }

    func clearMemory() async throws {
        guard reachable else { throw AgentError.unreachable }
        guard memoryBook != nil else { throw AgentError.server("not_found") }
        memoryBook = MockMemory(demo: "empty")
        memoryClears += 1
    }

    private(set) var memoryClears = 0

    // MARK: 손 넘기기 (D123): "사람 확인" 이 든 말 → 가상 쇼핑몰의 사람 확인 화면에서 멈춘다 (`-demoHandover`)

    /// 손 넘기기를 하는 맥처럼 (실행 인자 `-demoHandover`, 테스트는 `enableHandover()`)
    private var handoverDemo = ProcessInfo.processInfo.arguments.contains("-demoHandover")
    /// 앱이 보낸 손짓 (테스트가 본다). 쓴 글도 여기에만 (가짜 맥이라)
    private(set) var handoverInputs: [HandoverInput] = []
    /// 맥이 받아 둔 사이트 아이콘 (D132, 테스트가 넣는다)
    private var siteIconData: [String: Data] = [:]

    func enableHandover() { handoverDemo = true }

    /// 작업실의 보고서 만들기 단계 (`-demoReport`). 끼어들기를 볼 수 있게 길다 (모두 지어낸 것이다)
    static let reportSteps = [
        "작업실 · 자료를 읽었어요", "작업실 · 쪽 구성을 정했어요", "작업실 · 숫자를 표로 정리했어요", "작업실 · 그래프를 그렸어요",
        "작업실 · 요약 문단을 썼어요", "작업실 · 제목과 머리말을 다듬었어요", "작업실 · 쪽 나눔을 확인했어요", "작업실 · 그래프를 다시 그렸어요",
        "작업실 · 글자 크기를 맞췄어요", "작업실 · PDF로 엮었어요", "작업실 · 결과를 확인했어요",
    ]

    /// 데모 영상 (`-demoReel`): 명령 → 사람 확인을 폰으로 넘겨 풀기 → 답변 카드. 앱도 이 인자로 저절로 누른다
    static let reelDemo = ProcessInfo.processInfo.arguments.contains("-demoReel")

    /// 데모 영상의 답변 카드 (가게·값은 모두 지어낸 것)
    static let reelCard = AgentReportCard(
        kind: .answer, title: "무선 이어폰 최저가", subtitle: "가상몰 · 판매처 3곳 비교",
        blocks: [
            .stat(label: "가장 싼 곳", value: "39,800원", note: "무료 배송"),
            .list([
                SpaceBlock.Item(title: "달빛 전자", subtitle: "내일 도착", trailing: "39,800원"),
                SpaceBlock.Item(title: "가람 디지털", subtitle: "모레 도착", trailing: "41,500원"),
                SpaceBlock.Item(title: "한빛 상점", subtitle: "3일 뒤 도착", trailing: "43,000원"),
            ]),
        ],
        actions: [AgentReportCard.Action(label: "가상몰에서 보기", url: URL(string: "https://shop.example.com/earbuds"))]
    )

    /// 작업실에서 보고서를 만드는 맥처럼 (실행 인자 `-demoReport`, 테스트는 `enableReport()`): 단계가 길어 끼어들기를 보기 좋다
    private var reportDemo = ProcessInfo.processInfo.arguments.contains("-demoReport")
    func enableReport() { reportDemo = true }

    /// 끼어들기를 하는 맥처럼 (D152. 실행 인자 `-demoSteer`, 테스트는 `enableSteer()`)
    private var steerDemo = ProcessInfo.processInfo.arguments.contains("-demoSteer")
    func enableSteer() { steerDemo = true }

    static let handoverChoices = ["다 했어요", "그만하기"]

    /// 이 번호의 손 넘기기가 아직 열려 있는지 (작업 질문, 또는 답하지 않은 로그인 물음 D149)
    private func handoverOpen(_ id: String) -> Bool {
        handoverJob(id) != nil || logins.values.contains { $0.login.state == .needChoice && $0.login.handover?.id == id }
    }

    /// 지금 열린 손 넘기기의 작업 (질문이 답을 받기 전까지만)
    private func handoverJob(_ id: String) -> Job? {
        jobs.values.first { job in
            job.state.phase == .awaitingInput && job.state.pendingQuestion?.handover?.id == id && job.state.pendingQuestion?.received != true
        }
    }

    func handoverFrame(id: String) async throws -> HandoverFrame {
        guard reachable else { throw AgentError.unreachable }
        guard handoverOpen(id) else { throw AgentError.handoverClosed }
        return MockHandoverScreen.frame(inputs: handoverInputs)
    }

    func handoverInput(id: String, _ input: HandoverInput) async throws {
        guard reachable else { throw AgentError.unreachable }
        guard handoverOpen(id) else { throw AgentError.handoverClosed }
        handoverInputs.append(input)
    }

    private func handOffHandover(_ request: String, conversationID: String) async throws -> AgentReply {
        var state = try await start(task: request, context: nil)
        state.serverTitle = "가상몰에서 찾기"
        jobs[state.id]?.state = state
        jobs[state.id]?.queue = Self.reelDemo ? ["열기 · shop.test", "화면 확인", "가격 비교"] : ["열기 · shop.test", "화면 확인"]
        jobs[state.id]?.reel = Self.reelDemo
        jobs[state.id]?.next = .done
        jobs[state.id]?.asks = AgentQuestion(
            id: "q-\(state.id)", text: "사람인지 확인하는 화면이 나왔어요. 브라우저를 열어 직접 풀어 주세요. 다 하면 \"다 했어요\"를 눌러 주세요.",
            choices: Self.handoverChoices,
            handover: AgentHandover(id: "h_\(state.id.filter { $0.isLetter || $0.isNumber })", reason: "사람 확인 퍼즐", host: "shop.test", idleClose: 300)
        )
        return AgentReply(conversationID: conversationID, replies: ["네, 가상몰에서 찾아볼게요."], action: .task(state))
    }

    func searchMac(_ query: String, limit: Int) async throws -> [ActivityEntry] {
        guard reachable else { throw AgentError.unreachable }
        guard offersActivity else { return [] }
        let words = query.trimmingCharacters(in: .whitespaces)
        var found = activityEntries().filter { $0.title.localizedCaseInsensitiveContains(words) || ($0.line?.localizedCaseInsensitiveContains(words) ?? false) }
        for routine in routineBook?.routines ?? [] where routine.title.localizedCaseInsensitiveContains(words) || routine.prompt.localizedCaseInsensitiveContains(words) {
            found.append(ActivityEntry(id: routine.id, kind: .routineDefinition, at: routine.lastRunAt ?? .now, title: routine.title, snippet: routine.prompt))
        }
        return Array(found.prefix(limit))
    }

    /// 끝난 작업과 예약 실행 (최근 것부터). 지어낸 기록은 실제 맥처럼 끝난 것만 싣는다
    private func activityEntries() -> [ActivityEntry] {
        var entries: [ActivityEntry] = jobs.values.compactMap { job in
            let state = job.state
            guard state.phase.isFinished else { return nil }
            let failed = state.phase == .failed || state.phase == .canceled
            return ActivityEntry(
                id: state.id, kind: .task, at: .now, title: state.serverTitle ?? state.task,
                status: failed ? "failed" : "completed", line: state.result ?? state.report?.done.first ?? state.error,
                conversationID: job.conversationID, cardKind: failed ? "failed" : nil
            )
        }
        for run in routineBook?.runs ?? [] {
            entries.append(ActivityEntry(
                id: run.id, kind: .routine, at: run.ranAt ?? .now, title: run.title, status: run.status,
                line: run.replies.first?.text, conversationID: run.conversationID, taskID: run.taskID
            ))
        }
        return entries.sorted { $0.at > $1.at }
    }

    // MARK: 기다리는 작업 (D113)

    /// 기다리는 작업 목록을 달라는 요청을 받은 횟수 (테스트 확인용)
    private(set) var waitingCalls = 0

    func waitingTasks() async throws -> [AgentWaitingTask] {
        guard reachable else { throw AgentError.unreachable }
        waitingCalls += 1
        return jobs.values
            .filter { $0.state.phase == .awaitingApproval || $0.state.phase == .awaitingInput }
            .sorted { $0.state.id < $1.state.id }
            .map {
                AgentWaitingTask(
                    id: $0.state.id, isApproval: $0.state.phase == .awaitingApproval,
                    title: $0.state.serverTitle ?? $0.state.task, conversationID: $0.conversationID
                )
            }
    }

    /// 맥이 직접 만든 대화에 승인을 기다리는 작업을 하나 둔다 (작업실 → 보고서 메일 보내기처럼). 앱이 만든 작업이 아니다
    @discardableResult
    func seedMacTask(conversationID: String?, title: String = "보고서 메일 보내기") -> String {
        counter += 1
        let id = "t_mac_\(counter)"
        jobs[id] = Self.macJob(id: id, conversationID: conversationID, title: title)
        return id
    }

    private static func macJob(id: String, conversationID: String?, title: String) -> Job {
        var state = AgentTaskState(id: id, task: "\(title): 가상 주간 보고서", steps: ["열기 · mail.test/compose", "화면 확인"], phase: .awaitingApproval)
        state.serverTitle = title
        state.draft = Self.draft(context: "## 가상 주간 보고서", reason: nil, approvalID: "ap-\(id)-1", recipient: "team@mail.test")
        var job = Job(state: state, queue: [], next: .done, context: nil)
        job.approvals = 1
        job.conversationID = conversationID
        return job
    }

    // MARK: 내 공간 (D94)

    /// 내 공간 (D94). nil이면 내 공간을 모르는 맥
    private var spaceBook: MockSpace?
    /// 카드를 새로 채워 달라는 요청을 받은 카드 번호 (테스트 확인용)
    private(set) var spaceRefreshes: [String] = []
    /// 말로 고쳐 달라는 요청으로 받은 말 (테스트 확인용)
    private(set) var spaceEdits: [String] = []
    /// 손으로 고치기를 받는 맥인지 (D100). 아니면 `arrangeSpace`가 거절한다
    private let spaceArranges: Bool
    /// 손으로 고쳐 달라는 요청으로 받은 차례 (테스트 확인용)
    private(set) var spaceArrangements: [[SpaceArrangement]] = []
    /// 다음 손으로 고치기를 실패시킨다 (테스트용)
    private var failsNextArrange = false

    func failNextArrange() { failsNextArrange = true }

    /// 지금 돌려 달라는 요청을 받은 예약 (테스트 확인용)
    private(set) var routinesRun: [String] = []

    /// 예약을 지금 돌린다 (D103). 가짜 맥은 바로 끝난 것으로 치고, 그 예약에 이은 카드를 다음 새로 받기에 채운다
    func runRoutine(id: String) async throws {
        guard reachable else { throw AgentError.unreachable }
        guard id != "rt_missing" else { throw AgentError.server("not_found") }
        routinesRun.append(id)
        // 돌린 예약이 대화로 넘어가는 맥처럼 (D128. 테스트가 정한다)
        if let status = nextRunStatus, var book = routineBook {
            book.runs.insert(RoutineRun(
                id: "rr_now\(routinesRun.count)", routineID: id, title: "가상 지원 현황", status: status, ranAt: .now,
                conversationID: "c_run\(routinesRun.count)", replies: [.init(text: "가상사이트 로그인이 필요해요.")]
            ), at: 0)
            routineBook = book
        }
    }

    /// 다음에 돌리는 예약이 남길 실행의 상태 (D128, 테스트용)
    private var nextRunStatus: String?
    func setNextRunStatus(_ status: String?) { nextRunStatus = status }

    func arrangeSpace(_ cards: [SpaceArrangement]) async throws -> SpaceEdit {
        guard reachable else { throw AgentError.unreachable }
        guard spaceBook != nil, spaceArranges else { throw AgentError.conflict }
        if failsNextArrange {
            failsNextArrange = false
            throw AgentError.unreachable
        }
        spaceArrangements.append(cards)
        guard let result = spaceBook?.arrange(cards) else { throw AgentError.server("unknown_card") }
        return result
    }

    func space() async throws -> AgentSpace {
        guard reachable else { throw AgentError.unreachable }
        return spaceBook?.space ?? .empty
    }

    func editSpace(text: String) async throws -> SpaceEdit {
        guard reachable else { throw AgentError.unreachable }
        guard spaceBook != nil else { throw AgentError.conflict }
        if replyDelay > .zero { try? await Task.sleep(for: replyDelay) }
        spaceEdits.append(text)
        return spaceBook?.edit(text) ?? SpaceEdit(space: .empty)
    }

    func undoSpace() async throws -> SpaceEdit {
        guard reachable else { throw AgentError.unreachable }
        guard let result = spaceBook?.undo() else { throw AgentError.conflict }
        return result
    }

    func clearSpace() async throws -> SpaceEdit {
        guard reachable else { throw AgentError.unreachable }
        guard spaceBook != nil else { throw AgentError.conflict }
        return spaceBook?.clear() ?? SpaceEdit(space: .empty)
    }

    func refreshSpace(card: String) async throws -> AgentSpace {
        guard reachable else { throw AgentError.unreachable }
        guard spaceBook != nil else { throw AgentError.conflict }
        spaceRefreshes.append(card)
        spaceBook?.fill(card)
        return spaceBook?.space ?? .empty
    }

    // MARK: 예약해 둔 일 (D91)

    func routines() async throws -> [AgentRoutine] {
        guard reachable else { throw AgentError.unreachable }
        routineListCalls += 1
        return routineBook?.routines ?? []
    }

    func setRoutine(id: String, enabled: Bool) async throws -> [AgentRoutine] {
        guard reachable else { throw AgentError.unreachable }
        guard let index = routineBook?.routines.firstIndex(where: { $0.id == id }) else { throw AgentError.server("not_found") }
        routineBook?.routines[index].enabled = enabled
        // 실제 맥처럼: 끄면 다음에 도는 때가 없다
        if !enabled { routineBook?.routines[index].nextRunAt = nil }
        return routineBook?.routines ?? []
    }

    func deleteRoutine(id: String) async throws -> [AgentRoutine] {
        guard reachable else { throw AgentError.unreachable }
        guard routineBook?.routines.contains(where: { $0.id == id }) == true else { throw AgentError.server("not_found") }
        routineBook?.routines.removeAll { $0.id == id }
        return routineBook?.routines ?? []
    }

    func routineRuns() async throws -> [RoutineRun] {
        guard reachable else { throw AgentError.unreachable }
        return routineBook?.runs ?? []
    }

    func setRoutineNotes(id: String, notes: String) async throws -> [AgentRoutine] {
        guard reachable else { throw AgentError.unreachable }
        guard let index = routineBook?.routines.firstIndex(where: { $0.id == id }) else { throw AgentError.server("not_found") }
        routineBook?.routines[index].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return routineBook?.routines ?? []
    }

    func routineRuns(routineID: String, limit: Int) async throws -> [RoutineRun] {
        guard reachable else { throw AgentError.unreachable }
        return Array((routineBook?.runs ?? []).filter { $0.routineID == routineID }.prefix(limit))
    }

    func routineRun(id: String) async throws -> RoutineRun? {
        guard reachable else { throw AgentError.unreachable }
        runLookups += 1
        return routineBook?.runs.first { $0.id == id }
    }

    /// 실행 하나를 따로 물은 횟수 (테스트 확인용)
    private(set) var runLookups = 0

    /// 예약이 돌았다 (테스트용): 실행 기록을 맨 앞에 더한다
    func addRun(_ run: RoutineRun) {
        routineBook?.runs.insert(run, at: 0)
    }

    func isReachable() async -> Bool {
        if failingChecks > 0 {
            failingChecks -= 1
            return false
        }
        return reachable
    }

    func supports(_ feature: String) async -> Bool {
        switch feature {
        case AgentFeature.sendSelf, AgentFeature.mailConnect: mail != nil
        case AgentFeature.routines: routineBook != nil
        case AgentFeature.memory: memoryBook != nil
        case AgentFeature.activity: offersActivity
        case AgentFeature.space: spaceBook != nil
        case AgentFeature.spaceArrange: spaceBook != nil && spaceArranges
        // 다른 사람에게 보내기 (D89): 메일을 보내는 맥이 연락처를 받았을 때부터 알린다
        case AgentFeature.sendOthers: mail != nil && !contacts.isEmpty
        case AgentFeature.siteLogin: sites != nil
        case AgentFeature.voiceCall: takesCalls
        case AgentFeature.voiceTTS: takesVoice
        case AgentFeature.skills: offersSkills
        case AgentFeature.dialogCloud: dialogCloud != nil
        case AgentFeature.dialogContext: dialogCloud?.sendsContext == true
        case AgentFeature.webLookup: dialogCloud?.webLookup == true
        case AgentFeature.replyBy: dialogCloud?.marksWriter == true
        case AgentFeature.webFind, AgentFeature.reportLinks: dialogCloud?.findsPages == true
        case AgentFeature.webFindNaver: dialogCloud?.findsWithNaver == true
        case AgentFeature.webFindReadsCloud: dialogCloud?.pagesReadByCloud == true
        case AgentFeature.webBrowse: dialogCloud?.browsesWeb == true
        case AgentFeature.weatherAction: dialogCloud?.showsWeather == true
        case AgentFeature.reaction: dialogCloud?.reacts == true
        case AgentFeature.reportItems: dialogCloud?.listsItems == true
        case AgentFeature.shopView: dialogCloud?.opensShop == true
        case AgentFeature.shopDrive: dialogCloud?.drivesShop == true
        case AgentFeature.uploads: dialogCloud?.takesUploads == true
        case AgentFeature.push: offersPush
        case AgentFeature.pushText: offersPushText
        default: v2
        }
    }

    // MARK: 사진·PDF 붙이기 (D85)

    /// 받은 것 (테스트 확인용. 실제 맥처럼 종류와 크기, 이름만 적는다)
    private(set) var uploadCalls: [(kind: String, bytes: Int, name: String?)] = []
    /// 들고 있는 것: 번호 → 종류
    private var heldUploads: [String: String] = [:]
    /// 다음 올리기들이 이 오류로 실패한다 (테스트용)
    private var uploadFailures: [AgentError] = []
    /// 붙인 것과 함께 온 메시지 (테스트 확인용)
    private(set) var uploadMessages: [(text: String, ids: [String])] = []

    func failNextUpload(_ error: AgentError) { uploadFailures.append(error) }
    /// 몇 개를 받은 뒤의 올리기가 한 번 실패한다 (여러 개를 올리다 끊긴 것처럼. 테스트용)
    private var uploadBreak: (after: Int, error: AgentError)?
    func failUpload(after received: Int, with error: AgentError) { uploadBreak = (uploadCalls.count + received, error) }

    /// 들고 있던 것을 지운다 (30분이 지났거나 다시 켠 맥처럼. 테스트용)
    func dropUploads() { heldUploads = [:] }

    /// 실제 맥처럼: 종류는 파일의 머리로 정하고, 사진 7MB·PDF 10MB를 넘으면 받지 않는다
    func upload(_ data: Data, name: String?) async throws -> String {
        guard reachable else { throw AgentError.unreachable }
        guard dialogCloud?.takesUploads == true else { throw AgentError.uploadUnsupported }
        if let delay = dialogCloud?.uploadDelay, delay > .zero { try? await Task.sleep(for: delay) }
        if !uploadFailures.isEmpty { throw uploadFailures.removeFirst() }
        if let stop = uploadBreak, uploadCalls.count >= stop.after {
            uploadBreak = nil
            throw stop.error
        }
        let kind: String
        if UploadPrep.isPDF(data) {
            kind = "pdf"
        } else if data.starts(with: [0xFF, 0xD8, 0xFF]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: Array("GIF8".utf8)) {
            kind = "image"
        } else {
            throw AgentError.uploadUnsupported
        }
        guard data.count <= (kind == "pdf" ? UploadPrep.pdfLimit : UploadPrep.imageLimit) else { throw AgentError.uploadTooLarge }
        uploadCalls.append((kind, data.count, name))
        let id = "u_mockfile" + String(format: "%04d", uploadCalls.count)
        heldUploads[id] = kind
        return id
    }

    // MARK: 알림 (D67)

    /// 알림을 보낼 수 있는 맥인지 (Apple 알림 키를 넣어 둔 맥)
    private let offersPush: Bool
    private let offersPushText: Bool
    /// 등록된 기기: 알림 주소 → 환경 (테스트 확인용)
    private(set) var pushDevices: [String: String] = [:]
    /// 등록·지우기 요청을 받은 순서 (테스트 확인용)
    private(set) var pushCalls: [String] = []
    /// 등록을 거절하는 맥처럼 (테스트용. 예: 아직 받지 않는 환경)
    private var rejectsPush = false

    func setRejectsPush(_ rejects: Bool) { rejectsPush = rejects }

    func registerPush(token: String, environment: String, bundleID: String) async throws {
        guard reachable else { throw AgentError.unreachable }
        guard offersPush else { throw AgentError.conflict }
        pushCalls.append("register \(environment)")
        guard !rejectsPush, PushToken.isValid(token) else { throw AgentError.server("invalid_request") }
        pushDevices[token] = environment
    }

    func unregisterPush(token: String) async throws {
        guard reachable else { throw AgentError.unreachable }
        guard offersPush else { throw AgentError.conflict }
        pushCalls.append("unregister")
        pushDevices[token] = nil
    }

    /// 실제 맥처럼: 메일을 읽을 계정이 있는지, 네이버에 로그인되어 있는지로 준비를 정한다
    func skills() async throws -> [AgentSkill] {
        guard reachable else { throw AgentError.unreachable }
        guard offersSkills else { return [] }
        let needsMail = hasMailAccount ? [] : [AgentSkill.Need(kind: "mail_account", message: "메일 계정 연결이 필요해요", prompt: "네이버 메일 연결해줘")]
        let needsNaver = sites?.loggedIn == true ? [] : [AgentSkill.Need(kind: "site:naver", message: "네이버 로그인이 필요해요", prompt: "네이버 로그인해줘")]
        return [
            AgentSkill(
                id: "mail_briefing", title: "오늘 온 메일 브리핑",
                description: "오늘 받은 메일을 읽고, 챙겨야 할 것부터 정리해 드려요. 읽음 표시는 바꾸지 않아요.",
                category: "메일", prompt: "오늘 온 메일 요약해줘", isAvailable: needsMail.isEmpty, needs: needsMail
            ),
            AgentSkill(
                id: "mail_to_self", title: "회의 요약을 내 메일로 보내기",
                description: "회의 내용을 정리해 내 메일 주소로 보내 드려요. 보내기 전에 내용을 보여 드리고 승인을 받아요.",
                category: "메일", prompt: "오늘 회의 내용 요약해서 나한테 메일로 보내줘", isBeta: true, isAvailable: needsMail.isEmpty, needs: needsMail
            ),
            AgentSkill(
                id: "naver_login", title: "네이버 로그인",
                description: "맥의 에이전트 브라우저에 네이버 로그인 상태를 만들어요. 아이디·비밀번호 입력과 인증은 직접 하세요.",
                category: "연결", prompt: "네이버 로그인해줘"
            ),
            AgentSkill(
                id: "naver_mail_connect", title: "네이버 메일 연결",
                description: "네이버 메일을 읽고 보낼 수 있게 연결해요. 설정은 제가 하고, 비밀번호 확인과 승인만 직접 하세요.",
                category: "연결", prompt: "네이버 메일 연결해줘", isAvailable: needsNaver.isEmpty, needs: needsNaver
            ),
        ]
    }

    private var hasMailAccount: Bool { accounts.contains { $0.status == .ready } }

    func mailAccounts(check: Bool) async throws -> [MailAccount] {
        guard reachable else { throw AgentError.unreachable }
        if check { accounts = accounts.map { var account = $0; account.checkedAt = .now; return account } }
        return accounts
    }

    /// 실제 서버처럼: 받은 앱 비밀번호로 로그인해 보고, 되면 보관한다. 여기서는 로그인 결과만 흉내 낸다
    /// ("wrong"이 들어 있으면 로그인 실패). 비밀번호는 저장하지도 돌려주지도 않는다
    func connectMail(provider: String, address: String, password: String) async throws -> [MailAccount] {
        guard reachable else { throw AgentError.unreachable }
        guard mail != nil else { throw AgentError.conflict }
        connects += 1
        // 보낼 수 있는 주소는 실행하는 쪽에서만 정한다: 목록에 없는 주소는 로그인해 보지도 않고 거절한다
        guard let index = accounts.firstIndex(where: { $0.address.lowercased() == address.lowercased() }) else {
            throw AgentError.notAllowed
        }
        let works = !password.contains("wrong")
        accounts[index].provider = provider
        accounts[index].status = works ? .ready : .authFailed
        accounts[index].checkedAt = .now
        if works { mail?.failure = nil }
        return accounts
    }

    /// 실제 맥처럼: 그 기능(`weather_action`, `reaction`)을 알 때만 딸려 온 것을 읽는다
    func message(
        _ text: String, conversationID: String?, context: String?, messageID: String?, replyTaskID: String?, extras: MessageExtras
    ) async throws -> AgentReply {
        guard reachable else { throw AgentError.unreachable }
        receivedExtras.append(extras)
        if replyDelay > .zero { try? await Task.sleep(for: replyDelay) }
        if !messageFailures.isEmpty { throw messageFailures.removeFirst() }
        var known = MessageExtras.none
        if dialogCloud?.showsWeather == true {
            known.clientFeatures += extras.clientFeatures.filter { $0 == MessageExtras.weatherFeature }
            known.weatherEvents = extras.weatherEvents
        }
        if dialogCloud?.reacts == true {
            known.clientFeatures += extras.clientFeatures.filter { $0 == MessageExtras.reactionFeature }
        }
        // 고른 상품의 번호는 상품 목록을 아는 맥만 읽는다
        if dialogCloud?.listsItems == true { known.replyItemID = extras.replyItemID }
        // 쇼핑 화면을 아는 맥만 그 표시와 읽은 화면을 읽는다
        if dialogCloud?.opensShop == true {
            known.clientFeatures += extras.clientFeatures.filter { $0 == MessageExtras.shopFeature }
            if known.acceptsShop { known.view = extras.view }
        }
        if dialogCloud?.drivesShop == true {
            known.clientFeatures += extras.clientFeatures.filter { $0 == MessageExtras.shopDriveFeature }
        }
        // 붙인 것의 번호는 붙이기를 아는 맥만 읽는다 (4개까지)
        if dialogCloud?.takesUploads == true { known.uploads = Array(extras.uploads.prefix(MessageExtras.uploadLimit)) }
        // 연락처: 실제 맥처럼, 오면 그 대화의 값으로 바꾸고 없으면 앞선 값을 둔다
        if !extras.contacts.isEmpty { contacts = extras.contacts }
        if !extras.contactsNoEmail.isEmpty { contactsNoEmail = extras.contactsNoEmail.filter { extras.contacts[$0] == nil && contacts[$0] == nil } }
        self.extras = known
        var reply = try await message(text, conversationID: conversationID, context: context, messageID: messageID, replyTaskID: replyTaskID)
        // 통화 중인 말 (D134): 실제 맥처럼 말풍선마다 읽을 글을 붙인다
        if takesCalls, extras.clientFeatures.contains(MessageExtras.voiceCallFeature) {
            reply.speaks = reply.replies.map { VoiceText.spoken($0) }
            // 내 목소리 (D136): 실제 맥처럼 응답을 보내기 전에 만들기 시작한다
            if takesVoice { reply.voiceIDs = reply.speaks.map { $0.map { makeVoice($0) } } }
        }
        return reply
    }

    func message(_ text: String, conversationID: String?, context: String?, messageID: String?, replyTaskID: String?) async throws -> AgentReply {
        guard reachable else { throw AgentError.unreachable }
        replyTaskIDs.append(replyTaskID)
        repliedTask = replyTaskID
        return try await message(text, conversationID: conversationID, context: context, messageID: messageID)
    }

    /// 다음 메시지를 이 오류로 돌려준다 (맥이 받지 못한 요청을 시험할 때)
    func failNextMessage(_ error: AgentError) {
        messageFailures.append(error)
    }

    /// 다음 메시지에 이 응답을 그대로 준다 (맥이 새로 주기로 한 값을 시험할 때)
    func script(_ reply: AgentReply) {
        scripted.append(reply)
    }

    func message(_ text: String, conversationID: String?, context: String?, messageID: String?) async throws -> AgentReply {
        guard reachable else { throw AgentError.unreachable }
        messageIDs.append(messageID)
        // 실제 서버처럼: 같은 번호는 새로 판단하지 않고 처음 응답을 (작업은 지금 상태로) 돌려준다
        if v2, let messageID, var first = replies[messageID] {
            extras = .none
            repliedTask = nil
            if case .task(let task) = first.action, let now = jobs[task.id]?.state { first.action = .task(now) }
            return first
        }
        let reply = try await message(text, conversationID: conversationID, context: context)
        if v2, let messageID { replies[messageID] = reply }
        return reply
    }

    func answer(_ id: String, questionID: String, answer: String) async throws -> AgentTaskState {
        guard reachable else { throw AgentError.unreachable }
        guard var job = jobs[id] else { throw AgentError.taskLost }
        guard job.state.phase == .awaitingInput, job.state.pendingQuestion?.id == questionID,
              job.state.pendingQuestion?.received != true else { throw AgentError.conflict }
        answers.append((questionID, answer))
        // 실제 서버처럼: 답을 받은 직후에는 같은 질문 상태에 received만 붙여 돌려준다
        job.state.pendingQuestion?.received = true
        if job.acts, job.state.pendingQuestion?.choices == AgentTaskState.sitePermissionChoices {
            // 실제 맥처럼: 선택지의 글 그대로만 허락으로 받는다. 그 밖의 답(입력창에 쓴 글도)은 허락이 아니다
            let choices = AgentTaskState.sitePermissionChoices
            if answer == choices[0] {
                siteDo?.allowed = true
            } else if answer != choices[1] {
                job.refusal = answer == choices[2] ? MockSiteDo.refused : MockSiteDo.unanswered
            }
        } else if job.state.pendingQuestion?.handover != nil {
            // 손 넘기기 (D123): "그만하기"면 하지 않고 끝낸다
            if answer == Self.handoverChoices[1] { job.refusal = "사람 확인을 하지 않아 멈췄어요." }
        } else {
            job.reason = "참조: \(answer)"
        }
        jobs[id] = job
        return job.state
    }

    func message(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        var reply = try await decide(text, conversationID: conversationID, context: context)
        // 누가 썼는지 알리는 맥처럼: 정해 둔 답(로그인 안내, "출처" 줄)은 mac, 브리핑은 local, 나머지 대화 말은 claude
        if dialogCloud?.marksWriter == true, reply.writers.isEmpty, !reply.replies.isEmpty {
            let isLogin = if case .siteLogin = reply.action { true } else { false }
            reply.writers = reply.replies.map { text in
                if isLogin || text.hasPrefix("출처: ") { return .mac }
                return text == Self.briefing ? .local : .claude
            }
        }
        return reply
    }

    /// 살 것을 말한 글이면 검색어를 준다 ("생수 2L 6개 사고 싶어" → "생수 2L 6개"). 가격만 묻는 말은 아니다
    static func shopQuery(in text: String) -> String? {
        let endings = ["사고 싶어요", "사고 싶어", "사고싶어", "사야 해", "사야 돼", "사야겠어", "사줘", "사 줘", "살래", "주문하고 싶어", "주문해줘", "주문해 줘"]
        guard let ending = endings.first(where: text.contains), let range = text.range(of: ending) else { return nil }
        var query = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        for particle in ["을", "를", "좀", " 하나"] where query.hasSuffix(particle) && query.count > particle.count + 1 {
            query = String(query.dropLast(particle.count)).trimmingCharacters(in: .whitespaces)
        }
        return ShopText.clean(query, limit: ShopView.queryLimit)
    }

    /// 읽어 보낸 화면에 대한 답: 받은 값을 그대로 쓴다
    static func answer(about view: ShopView, formal: Bool) -> String {
        switch view.kind {
        case .product:
            var parts: [String] = []
            let name = view.fields.title.map { "‘\($0)’" } ?? "이 상품"
            if let price = view.fields.price {
                var line = "\(name)은 \(ShopText.won(price))"
                if let original = view.fields.originalPrice { line += "(원래 \(ShopText.won(original)))" }
                parts.append(line + (formal ? "입니다." : "이에요."))
            } else {
                parts.append("\(name)의 가격은 화면에서 읽지 못했" + (formal ? "습니다." : "어요."))
            }
            if let shipping = view.fields.shipping {
                parts.append("배송은 \(shipping)" + (formal ? "입니다." : "이에요."))
            } else {
                parts.append("배송비는 화면에서 읽지 못했" + (formal ? "습니다." : "어요."))
            }
            if let arrival = view.fields.arrival { parts.append("도착은 \(arrival)" + (formal ? "입니다." : "이에요.")) }
            if let option = view.fields.options?.first {
                parts.append("\(option.name)은 \(option.values.joined(separator: ", ")) 중에서 고를 수 있" + (formal ? "습니다." : "어요."))
            }
            return parts.joined(separator: " ")
        case .list:
            let items = view.fields.items ?? []
            let priced = items.filter { $0.price != nil }
            guard let cheapest = priced.min(by: { ($0.price ?? 0) < ($1.price ?? 0) }), let price = cheapest.price else {
                return "화면에 상품 \(items.count)개가 보이는데 가격은 읽지 못했" + (formal ? "습니다." : "어요.")
            }
            let mall = cheapest.mall.map { " (\($0))" } ?? ""
            return "화면에 보이는 \(items.count)개 중에서는 ‘\(cheapest.title)’\(mall)이 \(ShopText.won(price))으로 가장 싸" + (formal ? "습니다." : "요.")
        }
    }

    private func decide(_ text: String, conversationID: String?, context: String?) async throws -> AgentReply {
        guard reachable else { throw AgentError.unreachable }
        received.append((text, conversationID, context))
        // 이 메시지에 딸려 온 것은 이 판단에만 쓴다. 앱이 보여 준 날씨는 대화 기록에 적는다 (최대 3개)
        let extras = self.extras
        self.extras = .none
        let repliedTask = self.repliedTask
        self.repliedTask = nil
        recordedWeather += extras.weatherEvents.prefix(MessageExtras.eventLimit)
        let id: String
        if let conversationID {
            id = conversationID
        } else {
            conversations += 1
            id = "conv-\(conversations)"
        }
        if !scripted.isEmpty {
            var reply = scripted.removeFirst()
            reply.conversationID = id
            return reply
        }
        // 예약해 둔 일 (D91): "+"가 보내는 말에는 되묻고, 때가 든 부탁은 예약으로 만든다. 바뀐 뒤의 목록을 응답에 붙인다
        if routineBook != nil {
            if text == RoutinesModel.newPrompt {
                return AgentReply(
                    conversationID: id, replies: ["어떤 걸 예약해 둘까요? 할 일이랑 날짜나 주기만 알려 주세요."], action: .none
                )
            }
            if text.contains("매일"), text.contains("시") {
                let made = AgentRoutine(
                    id: "rt_made\((routineBook?.routines.count ?? 0) + 1)", title: String(text.prefix(20)), prompt: text, enabled: true,
                    kind: "daily", whenText: "매일 오전 8:00", nextRunAt: Date.now.addingTimeInterval(3600)
                )
                routineBook?.routines.append(made)
                // 실제 맥처럼 (D110): 예약을 만든 답은 한 줄 상태로 온다
                var reply = AgentReply(conversationID: id, replies: ["예약했어요 · 매일 오전 8:00"], action: .none)
                reply.statusLines = [0]
                reply.routines = routineBook?.routines
                return reply
            }
        }

        // 붙인 것 (D85): 들고 있는 번호일 때만 본다. 가짜 맥은 그림을 읽지 않고, 정해 둔 가상의 말로 답한다
        if !extras.uploads.isEmpty {
            uploadMessages.append((text, extras.uploads))
            let kinds = extras.uploads.compactMap { heldUploads[$0] }
            guard kinds.count == extras.uploads.count else {
                var reply = AgentReply(
                    conversationID: id, replies: ["붙이신 것을 받지 못했어요(시간이 지나 지워졌을 수 있어요). 다시 붙여 주세요."], action: .none
                )
                if dialogCloud?.marksWriter == true { reply.writers = [.mac] }
                return reply
            }
            if let replies = dialogCloud?.uploadReplies, !replies.isEmpty {
                return AgentReply(conversationID: id, replies: replies, action: .none)
            }
            let images = kinds.filter { $0 == "image" }.count
            let seen = [images > 0 ? "사진 \(images)장" : nil, kinds.count > images ? "PDF \(kinds.count - images)개" : nil]
                .compactMap { $0 }.joined(separator: "과 ")
            return AgentReply(conversationID: id, replies: ["붙여 주신 \(seen)을 봤어요."], action: .none)
        }

        if let original = asked.removeValue(forKey: id) {
            return try await handOff(original, target: text, conversationID: id, context: context)
        }
        // 실제 서버처럼: 말투는 답하는 말에만 쓰인다 (작업·초안·승인은 그대로)
        let formal = ReplyTone.current() == .formal
        // 상품 목록에서 고른 것 (D72): 글이 아니라 번호로 그 작업의 목록에서 집는다. 가짜 맥은 골랐다는 말만 한다
        if let itemID = extras.replyItemID, let repliedTask,
           let item = jobs[repliedTask]?.state.report?.items?.first(where: { $0.id == itemID }) {
            let reply = formal ? "‘\(item.title)’ 상품을 골랐습니다." : "네, ‘\(item.title)’ 골랐어요."
            return AgentReply(conversationID: id, replies: [reply], action: .none)
        }
        // 앱이 읽어 보낸 쇼핑 화면 (D74): 받은 값만으로 답한다 (값을 지어내지 않는다. 없는 것은 읽지 못했다고 한다)
        if let view = extras.view {
            shopViews.append(view)
            return AgentReply(conversationID: id, replies: [Self.answer(about: view, formal: formal)], action: .none)
        }
        // 스스로 찾아 오는 맥 (D75): 앱이 그렇게 할 수 있다고 알렸으면, 살 것을 말할 때 작업을 만들어 앱의 쇼핑 화면에 검색을 시킨다
        if extras.acceptsShop, extras.clientFeatures.contains(MessageExtras.shopDriveFeature), let query = Self.shopQuery(in: text) {
            return try await handOffDrive(query, request: text, conversationID: id, formal: formal)
        }
        // 쇼핑 화면을 아는 맥: 앱이 열 수 있다고 알렸으면, 살 것을 말할 때 검색어만 정해 준다 (작업을 만들지 않는다)
        if extras.acceptsShop, let query = Self.shopQuery(in: text) {
            let reply = formal
                ? "쇼핑 화면에서 ‘\(query)’ 상품을 함께 보겠습니다. 아래에서 열어 주십시오."
                : "쇼핑 화면에서 ‘\(query)’ 같이 볼게요. 아래에서 열어 주세요!"
            return AgentReply(conversationID: id, replies: [reply], action: .shop(query: query))
        }
        // 반응을 다는 맥 (D70): 앱이 그릴 수 있다고 알린 요청에만. 짧은 맞장구에는 말 없이 반응만 준다
        if extras.acceptsReaction {
            if ["ㅇㅋ", "넵", "오케이", "알겠어"].contains(text) {
                return AgentReply(conversationID: id, replies: [], action: .none, reaction: "👌")
            }
            if text.contains("합격") || text.contains("붙었") {
                let reply = formal ? "축하드립니다. 정말 고생 많으셨습니다." : "와, 축하해요! 그동안 고생 많았어요."
                return AgentReply(conversationID: id, replies: [reply], action: .none, reaction: "🎉")
            }
            if text.contains("고마") || text.contains("고맙") {
                let reply = formal ? "별말씀을요. 필요하시면 또 말씀해 주십시오." : "별거 아니에요 ㅎㅎ 또 필요하면 말해요."
                return AgentReply(conversationID: id, replies: [reply], action: .none, reaction: "🙏")
            }
            if text.contains("ㅋㅋ") {
                let reply = formal ? "재미있으셨다니 다행입니다." : "ㅋㅋ 저도 웃겼어요."
                return AgentReply(conversationID: id, replies: [reply], action: .none, reaction: "😂")
            }
        }
        if ["안녕", "고마워", "고맙"].contains(where: text.contains) {
            let reply = formal
                ? "안녕하십니까. 회의 내용을 묻거나 메일 초안 같은 일을 맡기실 수 있습니다."
                : "안녕하세요. 회의 내용을 물어보거나 메일 초안 같은 일을 맡겨 주세요."
            return AgentReply(conversationID: id, replies: [reply], action: .none)
        }
        if text.contains("피곤") {
            let reply = formal ? "수고 많으셨습니다. 잠시 쉬어 가시기 바랍니다." : "오늘 고생 많으셨어요. 잠깐 쉬었다 해도 괜찮아요."
            return AgentReply(conversationID: id, replies: [reply], action: .none)
        }
        // 날씨 카드를 아는 맥: 앱이 그릴 수 있다고 알렸으면 답을 쓰지 않고 "어디·언제"만 정해 준다 (미세먼지·태풍 소식은 웹 검색 답이다)
        if dialogCloud?.showsWeather == true, extras.clientFeatures.contains(MessageExtras.weatherFeature),
           text.contains("날씨"), !text.contains("미세먼지") {
            let place = MockWeatherService.places.first(where: text.contains) ?? (text.contains("없는마을") ? "없는마을" : nil)
            let (when, period): (WeatherWhen, String) =
                text.contains("내일") ? (.tomorrow, "내일")
                : text.contains("이번 주") || text.contains("주말") ? (.week, "이번 주")
                : text.contains("지금") ? (.now, "지금") : (.today, "오늘")
            let head = [place, period].compactMap { $0 }.joined(separator: " ")
            let reply = formal ? "\(head) 날씨를 바로 보여 드리겠습니다." : "\(head) 날씨 바로 볼게요!"
            return AgentReply(conversationID: id, replies: [reply], action: .weather(place: place, when: when))
        }
        // 앱이 보여 준 날씨를 알고 있는 맥: 이어지는 말에는 그 내용으로 답한다 (앱이 알린 한 줄만 본다)
        if dialogCloud?.showsWeather == true, text.contains("우산"), let shown = recordedWeather.last {
            let rainy = shown.contains("비") && !shown.contains("강수확률 0%") && !shown.contains("강수확률 10%")
            let reply = rainy
                ? (formal ? "비 소식이 있으니 우산을 챙기시기 바랍니다." : "비 소식이 있으니까 우산 챙기는 게 좋겠어요!")
                : (formal ? "비 소식이 없어 우산은 두고 가셔도 됩니다." : "비 소식은 없어서 우산은 안 챙겨도 될 것 같아요.")
            return AgentReply(conversationID: id, replies: [reply], action: .none)
        }
        // 웹 검색을 하는 맥: 공개 정보를 찾아 답하고 마지막에 출처 줄을 붙인다 (지어낸 값과 지어낸 사이트 이름이다)
        if dialogCloud?.webLookup == true, text.contains("날씨") {
            return AgentReply(
                conversationID: id,
                replies: ["서울은 지금 맑고 12도예요.", "저녁에는 6도까지 내려가니 겉옷을 챙기시면 좋아요.", "출처: 가상날씨, 가상기상청"],
                action: .none
            )
        }
        // 상품 목록을 주는 맥: 살 것을 찾아 달라는 말은 상품을 찾는 작업이 된다 (승인 없음. 찾기만 한다)
        if dialogCloud?.listsItems == true, text.contains("추천") || text.contains("사려") || text.contains("사야") || text.contains("살 만한") {
            return try await handOffFind(text, conversationID: id, shops: true)
        }
        // 공개 페이지를 찾아 읽는 맥: "찾아 달라"는 말은 작업이 된다 (승인 없음)
        if dialogCloud?.findsPages == true, text.contains("찾아") {
            return try await handOffFind(text, conversationID: id)
        }
        // 사이트 로그인을 아는 맥: 짧은 "네이버 … 로그인/연결" 말에만 로그인 화면을 연다 (모델을 부르지 않는다)
        // 더 좁은 말(메일 연결)을 먼저 본다: "네이버 메일 연결해줘"는 로그인이 아니라 메일 연결이다
        if sites?.mailSetup != nil, text.count <= 40, text.contains("네이버"), text.contains("메일"),
           text.contains("연결") || text.contains("연동") {
            let reply = formal ? "네이버 메일 연결을 시작하겠습니다." : "네이버 메일 연결을 시작할게요."
            return AgentReply(conversationID: id, replies: [reply], action: .siteLogin(site: MockSites.mailSetupSite))
        }
        if sites != nil, text.count <= 40, text.contains("네이버"), !text.contains("로그아웃"),
           text.contains("로그인") || text.contains("연결") {
            return AgentReply(conversationID: id, replies: ["네이버 로그인 화면을 열게요."], action: .siteLogin(site: "naver"))
        }
        // 끼어들기를 하는 맥 (D152, `-demoSteer`, 테스트는 `enableSteer()`): 도는 작업이 있을 때 "바꿔"·"줄여"가 든 말은 그 작업에 전한다
        if steerDemo, text.contains("바꿔") || text.contains("줄여"),
           let running = jobs.values.first(where: { $0.state.phase == .running && ($0.conversationID == nil || $0.conversationID == id) }) {
            var job = running
            job.state.steers = (job.state.steers ?? []) + [AgentSteerNote(time: Date.now.formatted(.iso8601), text: text, applied: false)]
            narrate(&job, "덧붙인 말을 받았어요 — 지금 단계가 끝나면 반영해요")
            jobs[job.state.id] = job
            var reply = AgentReply(
                conversationID: id, replies: ["지금 하는 작업에 전했어요. 지금 단계가 끝나면 반영해요."], action: .none
            )
            reply.steer = AgentSteer(taskID: job.state.id, mode: .inject)
            return reply
        }
        if reportDemo, text.contains("보고서") {
            var state = try await start(task: text, context: nil)
            state.serverTitle = "보고서 만들기"
            state.skill = "workroom"
            jobs[state.id]?.state = state
            jobs[state.id]?.queue = Self.reportSteps
            jobs[state.id]?.next = .done
            jobs[state.id]?.report = true
            return AgentReply(conversationID: id, replies: ["네, 작업실에서 한 장짜리 보고서로 만들게요."], action: .task(state))
        }
        if handoverDemo, text.contains("사람 확인") || (Self.reelDemo && text.contains("최저가")) {
            return try await handOffHandover(text, conversationID: id)
        }
        // 로그인한 사이트 안에서 해 주는 맥: "todo.test에 … 추가해줘" → 그 사이트 안에서 하는 작업 (D80)
        if siteDo != nil, text.contains(MockSiteDo.host) {
            return try await handOffAct(text, conversationID: id)
        }
        // 캡처를 붙이는 맥: "결제내역 알려줘" → 사이트를 읽고 답하는 작업 (승인 없음)
        if captures != nil, text.contains("결제내역") {
            // 실제 서버처럼: 로그인한 적이 없으면 작업을 만들지 않고 로그인부터 해 달라고 답한다
            if captures?.script == .login, let sites, !sites.loggedIn {
                let reply = formal ? "네이버 로그인이 필요합니다. 먼저 로그인해 주십시오." : "네이버 로그인이 필요해요. 먼저 로그인해 주세요."
                return AgentReply(conversationID: id, replies: [reply], action: .siteLogin(site: "naver"))
            }
            return try await handOffRead(text, conversationID: id)
        }
        // 맡길 수 있는 일을 아는 맥: "오늘 온 메일 요약해줘" → 가상 브리핑 (작업을 만들지 않고 여러 줄로 바로 답한다)
        if offersSkills, text.contains("메일"), text.contains("요약"), text.contains("온"), !text.contains("보내") {
            guard hasMailAccount else {
                return AgentReply(conversationID: id, replies: ["메일 계정이 아직 연결되지 않았어요. 먼저 연결해 주세요."], action: .none)
            }
            return AgentReply(conversationID: id, replies: [Self.briefing], action: .none)
        }
        // 메일 보내기를 아는 맥: "나한테 메일로 보내 줘" → 내 주소로 보내는 작업
        if mail != nil, text.contains("메일"), text.contains("보내"), ["나한테", "나에게", "내 ", "내게"].contains(where: text.contains) {
            return try await handOffSend(text, conversationID: id, context: context)
        }
        // 다른 사람에게 보내기 (D89): 앱이 알린 연락처의 이름이 말에 있으면 그 사람에게 보내는 작업
        let said = text.lowercased().filter { !$0.isWhitespace }
        if mail != nil, text.contains("메일"), text.contains("보내"),
           contacts.keys.contains(where: { ContactMatch.keys(for: $0).contains(where: said.contains) }) {
            return try await handOffSend(text, conversationID: id, context: context)
        }
        // 연락처에 있지만 메일 주소가 없는 사람 (D92): 없다고 하지 않고 주소를 묻는다
        if mail != nil, text.contains("메일"), text.contains("보내"),
           let name = contactsNoEmail.first(where: { ContactMatch.keys(for: $0).contains(where: said.contains) }) {
            return AgentReply(
                conversationID: id, replies: ["\(name) 님은 연락처에 있는데 메일 주소가 없어요. 보낼 주소를 알려 주세요."], action: .ask(choices: [])
            )
        }
        // 고르기 카드 (D111, 실제 맥처럼): 여러 개 고르기 + 추천 + 그림 / 답 뒤의 다음 말 (모두 지어낸 것이다)
        if text.contains("카드"), text.contains("더") {
            var reply = AgentReply(
                conversationID: id, replies: ["어떤 카드를 더 놓을까요? 여러 개 골라도 돼요."],
                action: .ask(choices: ["오늘 할 일", "원달러 환율", "다음 공휴일", "택배 도착", "운동 기록"])
            )
            reply.recommended = "원달러 환율"
            reply.multi = true
            return reply
        }
        if text.contains("고를") || text.contains("골라") {
            var reply = AgentReply(
                conversationID: id, replies: ["두 가지를 찾았어요. 어느 쪽으로 할까요?"],
                action: .ask(choices: ["가상상점 무선 이어폰 A", "가상상점 무선 이어폰 B", "둘 다 아니에요"])
            )
            reply.recommended = "가상상점 무선 이어폰 A"
            reply.choiceImages = [
                "가상상점 무선 이어폰 A": URL(string: "https://img.example-shop.com/a.png")!,
                "가상상점 무선 이어폰 B": URL(string: "https://img.example-shop.com/b.png")!,
            ]
            return reply
        }
        if text.contains("차이") {
            var reply = AgentReply(
                conversationID: id,
                replies: ["파이썬은 읽기 쉬운 문법으로 데이터·자동화에 많이 쓰고, 자바스크립트는 웹 브라우저에서 돌아가 화면을 다루는 데 많이 써요."],
                action: .none
            )
            reply.next = ["처음 배우기엔 어느 쪽이 좋아?", "둘 다 쓰는 예를 보여 줘"]
            reply.nextRecommended = "처음 배우기엔 어느 쪽이 좋아?"
            return reply
        }
        if text.contains("메일") || text.contains("초안") {
            let target = ["팀", "에게", "한테", "@"].first(where: text.contains)
            guard target != nil else {
                asked[id] = text
                // 실제 맥처럼 (D110): 되물을 때 권하는 후보 하나
                var reply = AgentReply(conversationID: id, replies: ["누구에게 보낼 메일인가요?"], action: .ask(choices: ["팀 전체", "나에게만"]))
                reply.recommended = "나에게만"
                return reply
            }
            return try await handOff(text, target: text.contains("나에게") ? "나에게만" : "팀 전체", conversationID: id, context: context)
        }
        return AgentReply(conversationID: id, replies: [], action: .routeClaude)
    }

    /// 가상 브리핑 (보낸 곳·제목 모두 지어낸 것이다)
    static let briefing = """
    오늘 온 메일은 5통이에요. 답장이 필요한 것이 1통, 기한이 있는 안내가 1통 있어요.
    - 14:20 가상상사 구매팀: 견적서 회신 요청 (금요일까지 답장)
    - 11:05 가상카드: 11월 이용 대금 안내 (결제일 25일)
    - 09:40 가상배송: 주문하신 상품이 출발했어요
    그 밖의 2통은 소식지예요.
    """

    /// 대화 담당이 작업 담당에게 넘긴다: 브리프를 만들고 작업을 시작한다
    private func handOff(_ request: String, target: String, conversationID: String, context: String?) async throws -> AgentReply {
        let title = "회의 공유 메일 초안"
        let address = target.contains("나") ? "me@mail.test" : "team@mail.test"
        let brief = AgentBrief(
            purpose: "회의에서 나온 내용을 메일로 공유",
            targets: [address],
            instructions: "회의 발췌에서 결정 사항과 할 일을 골라 메일 초안을 쓰고 임시 저장한다. 보내지 않는다."
        )
        var state = try await start(task: "\(brief.purpose ?? "")\n대상: \(address)\n\(brief.instructions ?? "")", context: context)
        state.serverTitle = title
        state.brief = brief
        jobs[state.id]?.state = state
        jobs[state.id]?.recipient = address
        if v2, request.contains("참조") {
            jobs[state.id]?.asks = AgentQuestion(id: "q-\(state.id)", text: "참조에는 누구를 넣을까요?", choices: ["넣지 않기", "팀 전체"])
        }
        return AgentReply(conversationID: conversationID, replies: ["네, \(title) 준비할게요."], action: .task(state))
    }

    /// 내 주소로 보내는 작업을 만든다. 계정은 말에 서비스 이름이 있으면 그 계정, 없으면 기본 계정
    private func handOffSend(_ request: String, conversationID: String, context: String?) async throws -> AgentReply {
        let wantsGmail = request.contains("지메일") || request.lowercased().contains("gmail")
        let wanted = wantsGmail ? "gmail" : (request.contains("네이버") ? "naver" : nil)
        let account = accounts.first { $0.provider == wanted } ?? accounts.first(where: \.isDefault) ?? accounts.first
        let address = account?.address ?? "me@naver.test"
        let title = "회의 정리 메일 보내기"
        let brief = AgentBrief(
            purpose: "회의에서 나온 내용을 내 메일로 보내기",
            targets: [address],
            instructions: "회의 발췌에서 결정 사항과 할 일을 골라 메일을 쓰고, 승인을 받은 뒤 내 주소로 보낸다. 다른 주소로는 보내지 않는다."
        )
        var state = try await start(task: "\(brief.purpose ?? "")\n대상: \(address)\n\(brief.instructions ?? "")", context: context)
        state.serverTitle = title
        state.brief = brief
        jobs[state.id]?.state = state
        // 다른 사람에게 보내기 (D89): 말에 연락처의 이름이 있으면 그 주소로 보낸다
        let other = contacts.first { name, _ in ContactMatch.keys(for: name).contains(where: request.lowercased().filter { !$0.isWhitespace }.contains) }
        jobs[state.id]?.recipient = other?.value ?? address
        jobs[state.id]?.sendsFrom = address
        jobs[state.id]?.queue = [Self.accountCheck, "입력 · 보낼 메일"]
        jobs[state.id]?.next = .awaitingApproval
        return AgentReply(conversationID: conversationID, replies: ["네, \(title) 준비할게요."], action: .task(state))
    }

    /// 로그인한 사이트 안에서 하는 작업을 만든다 (가상 사이트 "가상할일", D80). 처음이면 허락부터 묻는다
    private func handOffAct(_ request: String, conversationID: String) async throws -> AgentReply {
        var state = try await start(task: request, context: nil)
        state.serverTitle = "\(MockSiteDo.host)에서 하기"
        state.skill = AgentTaskState.siteDoSkill
        jobs[state.id]?.state = state
        jobs[state.id]?.queue = ["열기 · todo.test/list", "화면 확인", "입력 · 할 일"]
        jobs[state.id]?.next = .awaitingApproval
        jobs[state.id]?.acts = true
        if siteDo?.allowed != true {
            jobs[state.id]?.permission = AgentQuestion(
                id: "q-\(state.id)", text: MockSiteDo.question, choices: AgentTaskState.sitePermissionChoices
            )
        }
        return AgentReply(
            conversationID: conversationID, replies: ["네, \(MockSiteDo.host)에서 해 볼게요."], action: .task(state),
            writers: dialogCloud?.marksWriter == true ? [.claude] : []
        )
    }

    /// 승인을 기다리는 동안 그 화면의 값이 달라졌다 (테스트용): 같은 승인 번호인데 내용과 확인 번호가 다르다
    func changeScreen(_ id: String) {
        guard let approvalID = jobs[id]?.state.draft?.approvalID, jobs[id]?.acts == true else { return }
        jobs[id]?.state.draft = MockSiteDo.approval(id: approvalID, revised: true)
    }

    /// 사이트를 읽고 답하는 작업을 만든다 (가상 사이트 "가상페이")
    private func handOffRead(_ request: String, conversationID: String) async throws -> AgentReply {
        var state = try await start(task: request, context: nil)
        state.serverTitle = "결제내역 확인"
        jobs[state.id]?.state = state
        jobs[state.id]?.queue = ["열기 · pay.shop.test/history", "화면 확인"]
        jobs[state.id]?.next = .done
        jobs[state.id]?.reads = true
        return AgentReply(conversationID: conversationID, replies: ["네, 결제내역을 확인할게요."], action: .task(state))
    }

    /// 공개 페이지를 찾아 읽고 답하는 작업을 만든다 (가게·물건·사이트 모두 지어낸 것이다)
    /// `shops`: 살 것을 찾는 작업 (끝나면 답과 페이지 대신 상품 목록을 붙인다, D72)
    private func handOffFind(_ request: String, conversationID: String, shops: Bool = false) async throws -> AgentReply {
        var state = try await start(task: request, context: nil)
        // 실제 맥은 이 작업의 제목을 늘 이렇게 붙인다 (상품 찾기의 제목은 가짜 맥이 붙인 것이다)
        state.serverTitle = shops ? "상품 찾기" : "웹에서 찾기"
        jobs[state.id]?.state = state
        jobs[state.id]?.queue = shops ? ["검색 · 무선 이어폰"] : ["검색 · 소리콩 2 가격"] + MockFind.links.map { "읽기 · \($0.host)" }
        jobs[state.id]?.next = .done
        jobs[state.id]?.finds = true
        jobs[state.id]?.shops = shops
        return AgentReply(
            conversationID: conversationID, replies: ["네, 찾아볼게요."], action: .task(state),
            writers: dialogCloud?.marksWriter == true ? [.claude] : []
        )
    }

    // MARK: 쇼핑 화면에 일 시키기 (D75)

    /// 살 것을 찾는 작업을 만들고, 앱의 쇼핑 화면에 첫 일(검색)을 시킨다. 가짜 맥은 어디에도 접속하지 않는다
    private func handOffDrive(_ query: String, request: String, conversationID: String, formal: Bool) async throws -> AgentReply {
        var state = try await start(task: request, context: nil)
        state.serverTitle = "상품 찾기"
        state.usedShop = true
        state.browse = AgentBrowse(id: "b1", kind: .search, query: query, items: nil)
        state.activity = "쇼핑 화면에서 ‘\(query)’ 검색을 열어요"
        jobs[state.id]?.state = state
        jobs[state.id]?.queue = []
        jobs[state.id]?.next = .done
        jobs[state.id]?.drives = true
        return AgentReply(
            conversationID: conversationID,
            replies: [formal ? "쇼핑 화면에서 ‘\(query)’ 상품을 찾아보겠습니다." : "네, 쇼핑 화면에서 ‘\(query)’ 찾아볼게요."],
            action: .task(state), writers: dialogCloud?.marksWriter == true ? [.claude] : []
        )
    }

    /// 다음 결과 받기들이 실패하게 한다 (테스트용)
    func failBrowse(_ errors: [AgentError]) { browseFailures = errors }

    /// 폰이 시킨 일의 결과를 돌려줬다: 검색이면 열 상품을 골라 다음 일을 시키고, 상품 화면이면 받은 값으로 상품 목록을 만들어 끝낸다.
    /// 실제 맥처럼: 지금 시킨 일의 결과가 아니면 받지 않는다(409). 값은 받은 그대로 쓴다 (지어내지 않는다)
    func browsed(_ id: String, result: BrowseResult) async throws -> AgentTaskState {
        guard reachable else { throw AgentError.unreachable }
        if !browseFailures.isEmpty { throw browseFailures.removeFirst() }
        guard var job = jobs[id] else { throw AgentError.taskLost }
        guard job.drives, job.state.phase == .running, let command = job.state.browse, command.id == result.id else {
            throw AgentError.conflict
        }
        browseResults.append((id, result))
        defer { jobs[id] = job }
        let products = result.views.filter { $0.view.kind == .product }
        switch (result.outcome, command.kind) {
        case (.ok, .search):
            guard let list = result.views.first(where: { $0.view.kind == .list })?.view.fields.items, !list.isEmpty else {
                stopDrive(&job, "검색 결과를 읽지 못했어요.", narration: "검색 결과를 읽지 못해 끝냈어요")
                break
            }
            job.list = list
            job.state.steps.append("검색 · \(command.query ?? "")")
            narrate(&job, "검색 결과 \(list.count)개를 읽었어요")
            // 개발용: 여기서 머문다 (다음 일을 시키지 않는다)
            if dialogCloud?.driveHold == .search {
                job.state.browse = nil
                break
            }
            let picks = Array(0..<min(AgentBrowse.openLimit, list.count))
            job.state.browse = AgentBrowse(id: "b2", kind: .open, query: nil, items: picks)
            narrate(&job, "상품 \(picks.count)개의 화면을 열어 볼게요")
        case (.ok, .open), (.limited, .open) where !products.isEmpty:
            job.state.steps.append("상품 화면 \(products.count)개 읽기")
            if dialogCloud?.driveHold == .open {
                job.state.browse = nil
                break
            }
            finishDrive(&job, products: products, result: result)
        case (.nothing, .open):
            // 상품 화면은 하나도 읽지 못했다: 목록에서 읽은 것만 글로 알린다 (목록의 상품에는 주소가 없어 카드로 그리지 못한다)
            job.state.browse = nil
            job.state.phase = .done
            job.state.activity = nil
            job.state.report = AgentReport(
                done: ["검색 결과에서 읽은 것만 알려 드려요."] + job.list.map { item in
                    ([item.title, item.price.map(ShopText.won), item.mall] as [String?]).compactMap { $0 }.joined(separator: " · ")
                },
                blocked: ["상품 화면은 열지 못했어요. 목록의 링크가 상품 화면으로 바로 가는 주소가 아니었어요."]
            )
            narrate(&job, "작업을 마쳤어요")
        case (.limited, _):
            let status = result.status.map { " (응답 \($0))" } ?? ""
            stopDrive(&job, "쇼핑 사이트가 접속을 제한해서 멈췄어요\(status). 다시 시도하지 않았어요.", narration: "사이트가 접속을 제한해 멈췄어요")
        case (.blocked, _):
            stopDrive(
                &job, "쇼핑 화면이 검색 결과가 아닌 다른 화면으로 넘어가서 멈췄어요. 로그인이나 확인이 필요한 화면일 수 있어요.",
                narration: "다른 화면으로 넘어가 멈췄어요"
            )
        case (.refused, _):
            stopDrive(&job, "쇼핑 화면에서 더 열 수 없어서 멈췄어요.", narration: "더 열 수 없어 멈췄어요")
        default:
            stopDrive(&job, "쇼핑 화면을 열지 못했어요.", narration: "쇼핑 화면을 열지 못해 끝냈어요")
        }
        return job.state
    }

    /// 상품 화면에서 읽어 온 값으로 상품 목록을 만들어 끝낸다. 이름·값·파는 곳·배송비는 폰이 읽은 그대로다
    private func finishDrive(_ job: inout Job, products: [BrowseResult.Entry], result: BrowseResult) {
        let items = products.enumerated().compactMap { offset, entry -> AgentItem? in
            let fields = entry.view.fields
            guard let title = fields.title, let url = URL(string: entry.view.url) else { return nil }
            var item = AgentItem(title: title, url: url)
            item.id = "i\(offset + 1)"
            item.price = fields.price
            item.mall = fields.seller
            item.shipping = fields.shipping
            item.detail = fields.arrival
            return item
        }
        var blocked: [String] = []
        if !result.skipped.isEmpty { blocked.append("상품 \(result.skipped.count)개는 열지 않았어요.") }
        if result.outcome == .limited { blocked.append("쇼핑 사이트가 접속을 제한해서 여기까지만 읽었어요. 다시 시도하지 않았어요.") }
        job.state.browse = nil
        job.state.phase = .done
        job.state.activity = nil
        job.state.report = AgentReport(
            done: ["쇼핑 화면에서 상품 \(items.count)개를 열어 읽었어요. 값과 배송비는 화면에서 읽은 그대로예요."],
            blocked: blocked, items: items
        )
        narrate(&job, "작업을 마쳤어요")
    }

    /// 쇼핑 화면이 막혀 작업을 끝낸다 (실제 맥의 `site_blocked`: 첫 줄에 이유)
    private func stopDrive(_ job: inout Job, _ reason: String, narration: String) {
        job.state.browse = nil
        job.state.phase = .failed
        job.state.activity = nil
        job.state.error = "사이트가 접속을 막아서 작업을 멈췄어요."
        job.state.report = AgentReport(blocked: [reason])
        narrate(&job, narration)
    }

    /// 찾기 작업을 끝낸다: 답과, 맥의 브라우저가 실제로 연 페이지 (실제 맥처럼 `sources`에도 같은 주소가 있다).
    /// 답을 쓴 곳도 알린다: 웹 검색으로 찾았으면 Claude, 네이버 검색으로 찾았으면 맥의 로컬 모델.
    /// 실제 맥은 연 화면의 캡처 한 장도 붙이지만(공개 화면), 가짜 맥은 붙이지 않는다
    private func finishFind(_ job: inout Job) {
        job.state.phase = .done
        job.state.activity = nil
        if job.shops {
            // 상품 목록: 보고의 말은 짧게, 값은 목록에 (실제 맥처럼 목록의 값은 모델이 쓰지 않는다)
            job.state.report = AgentReport(done: MockShop.answer, items: MockShop.items)
            narrate(&job, "작업을 마쳤어요")
            return
        }
        job.state.report = AgentReport(
            done: MockFind.answer, sources: MockFind.links.map(\.url.absoluteString), links: MockFind.links,
            by: (dialogCloud?.findsWithNaver == true ? ReplyWriter.local : .claude).rawValue
        )
        narrate(&job, "작업을 마쳤어요")
    }

    /// 읽기 작업을 끝낸다: 답과, 그 답을 읽은 화면의 캡처. 로그인이 풀려 있으면 멈춘 화면의 캡처
    private func finishRead(_ job: inout Job) {
        // 로그인을 아는 맥이면 로그인한 뒤에는 읽힌다 (대화에서 로그인하고 이어서 하는 흐름 확인용)
        let blocked = captures?.script == .blocked && sites?.loggedIn != true
        let attachment = AgentAttachment(
            id: "a1", width: Int(MockCaptures.pageSize.width), height: Int(MockCaptures.pageSize.height),
            pageHost: blocked ? "login.shop.test" : "pay.shop.test",
            caption: blocked ? "가상페이 로그인 화면" : "가상페이 결제내역 화면",
            // 실제 맥처럼: 로그인 상태를 실은 브라우저의 화면은 멈춘 화면(로그인 화면)도 가린다.
            // "가리지 않아도 된다"는 시험용 사이트의 화면뿐이다 (`open`)
            isSensitive: captures?.script != .open,
            expiresAt: Date.now.addingTimeInterval(24 * 3600).formatted(.iso8601)
        )
        if captures?.script == .pair {
            // 화면 두 장을 보고 답한 일: 캡처 두 장 + 문단 여럿으로 쓴 답 (D84 화면 확인용)
            let stats = AgentAttachment(
                id: "a2", width: attachment.width, height: attachment.height, pageHost: "pay.shop.test",
                caption: "가상페이 이용 통계 화면", isSensitive: true, expiresAt: attachment.expiresAt
            )
            job.state.phase = .done
            job.state.report = AgentReport(
                done: [MockCaptures.briefing], sources: ["https://pay.shop.test/history"], attachments: [attachment, stats]
            )
            narrate(&job, "작업을 마쳤어요")
            return
        }
        if captures?.script == .workroom {
            // 작업실 (D112): 실제 맥처럼 단계가 길게 쌓이고, 결과로 짧은 영상(먼저)과 그림이 붙는다 (모두 지어낸 것이다)
            for line in MockCaptures.workroomSteps { narrate(&job, line) }
            let expires = Date.now.addingTimeInterval(24 * 3600).formatted(.iso8601)
            let video = AgentAttachment(
                id: "v1", width: 1080, height: 1920, caption: "소개 영상 12초", isSensitive: false, expiresAt: expires,
                kind: .video, bytes: 8_400_000
            )
            let picture = AgentAttachment(
                id: "g1", width: Int(MockCaptures.pageSize.width), height: Int(MockCaptures.pageSize.height),
                caption: "보고서 1쪽", isSensitive: false, expiresAt: expires, kind: .image
            )
            job.state.phase = .done
            job.state.report = AgentReport(done: ["한 장짜리 보고서와 12초 소개 영상을 만들었어요."], attachments: [video, picture])
            narrate(&job, "작업을 마쳤어요")
            return
        }
        if captures?.script == .failcard {
            // 실기기에서 본 꼴 그대로 (D118): 카드에는 제목과 단추뿐이고, 까닭은 못 한 일에만 있다
            job.state.phase = .done
            var report = AgentReport(
                done: [], blocked: ["보안 확인 화면에서 막혔어요. 사람인지 확인하는 칸은 제가 누르지 않아요."],
                sources: ["https://check.example.org/verify"], attachments: [attachment]
            )
            report.card = AgentReportCard(
                kind: .failed, title: "하지 못했어요", subtitle: nil, blocks: [],
                actions: [AgentReportCard.Action(label: "사이트에서 보기", url: URL(string: "https://check.example.org/verify"))]
            )
            job.state.report = report
            narrate(&job, "보안 확인 화면에서 멈췄어요")
            return
        }
        if captures?.script == .longcard {
            job.state.phase = .done
            var report = AgentReport(done: [MockCaptures.answer], sources: [], attachments: [attachment])
            report.card = MockCaptures.longCard
            job.state.report = report
            narrate(&job, "작업을 마쳤어요")
            return
        }
        if captures?.script == .card {
            // 답변 카드 (D110): 실제 맥처럼 줄글(`done`)과 카드를 함께 준다. 앱은 카드를 그린다
            job.state.phase = .done
            var report = AgentReport(done: [MockCaptures.answer], sources: ["https://pay.shop.test/history"], attachments: [attachment])
            report.card = MockCaptures.card
            job.state.report = report
            narrate(&job, "작업을 마쳤어요")
            return
        }
        if blocked, sites != nil {
            // 실제 맥처럼: 어느 사이트에 로그인하면 되는지 알려 준다 (`needs_login` + `action`)
            job.state.phase = .failed
            job.state.loginSite = "naver"
            job.state.loginExpired = true
            job.state.error = AgentTaskState.loginFailureText(site: "naver", expired: true)
            job.state.report = AgentReport(blocked: ["네이버 로그인이 풀렸어요. 다시 로그인해 주세요."], attachments: [attachment])
            narrate(&job, "로그인이 풀려 있어 읽지 못하고 끝냈어요")
        } else if blocked {
            job.state.phase = .failed
            job.state.error = "가상페이 로그인이 풀렸어요."
            job.state.report = AgentReport(blocked: ["가상페이 로그인이 풀렸어요. 다시 로그인해 주세요"], attachments: [attachment])
            narrate(&job, "로그인이 풀려 있어 읽지 못하고 끝냈어요")
        } else {
            job.state.phase = .done
            job.state.report = AgentReport(
                done: [MockCaptures.answer], sources: ["https://pay.shop.test/history"], attachments: [attachment]
            )
            narrate(&job, "작업을 마쳤어요")
        }
    }

    func video(taskID: String, id: String) async throws -> Data {
        guard reachable else { throw AgentError.unreachable }
        guard let job = jobs[taskID], job.state.report?.attachments?.contains(where: { $0.id == id && $0.isVideo }) == true else {
            throw AgentError.attachmentGone
        }
        return try await MockCaptures.video()
    }

    func attachment(taskID: String, id: String) async throws -> Data {
        guard reachable else { throw AgentError.unreachable }
        guard let job = jobs[taskID] else { throw AgentError.taskLost }
        captureRequests += 1
        // 승인·질문 카드의 화면 (D93)
        if job.state.draft?.attachment?.id == id || job.state.pendingQuestion?.attachment?.id == id {
            return MockCaptures.pageImage(loginPage: false, stats: false)
        }
        guard let captures, captures.script != .gone,
              job.state.report?.attachments?.contains(where: { $0.id == id }) == true else { throw AgentError.attachmentGone }
        // flaky: 처음 한 번은 받지 못한다 ("다시 시도" 확인용)
        if captures.script == .flaky, captureRequests == 1 { throw AgentError.unreachable }
        return MockCaptures.pageImage(loginPage: job.state.phase == .failed, stats: id == "a2")
    }

    func start(task: String, context: String?) async throws -> AgentTaskState {
        guard reachable else { throw AgentError.unreachable }
        counter += 1
        let id = "task-\(counter)"
        var state = AgentTaskState(id: id, task: task, steps: [], phase: .running)
        if v2 { state.narration = [Self.say("작업을 시작했어요")] }
        let asksBack = task.contains("언제") && context == nil
        jobs[id] = Job(
            state: state,
            queue: asksBack ? ["열기 · mail.test/inbox", "화면 확인"] : ["열기 · mail.test/compose", "화면 확인", "입력 · 회의 공유"],
            next: asksBack ? .needsInput : .awaitingApproval,
            context: context
        )
        return state
    }

    func state(of id: String) async throws -> AgentTaskState {
        guard reachable else { throw AgentError.unreachable }
        guard var job = jobs[id] else { throw AgentError.taskLost }
        // 끼워 넣은 말은 다음 조회(다음 단계)에서 반영한다 (D152)
        if let notes = job.state.steers, notes.contains(where: { !$0.applied }) {
            job.state.steers = notes.map { AgentSteerNote(time: $0.time, text: $0.text, applied: true) }
            narrate(&job, "덧붙인 말을 반영하고 있어요")
        }
        if job.drives, job.state.phase == .running {
            // 폰의 쇼핑 화면을 기다린다 (결과가 와야 넘어간다)
        } else if job.state.phase == .awaitingInput, job.state.pendingQuestion?.received == true {
            // 답을 받았다 → 이어서 진행
            job.state.pendingQuestion = nil
            if let why = job.refusal {
                // 실제 맥처럼: 허락이 아니면 아무것도 열지 않고, 그 말로 끝낸다 (실패가 아니다)
                job.queue = []
                job.state.phase = .done
                job.state.result = why
                job.state.report = AgentReport(done: [why])
                narrate(&job, "허락을 받지 못해 하지 않고 끝냈어요")
            } else {
                job.state.phase = .running
                narrate(&job, "답을 받아 이어서 진행해요")
            }
        } else if job.state.phase == .running, let question = job.permission {
            // 사이트를 열기 전에 묻는다: 그 화면을 Claude가 봐도 되는지
            job.permission = nil
            job.state.phase = .awaitingInput
            job.state.pendingQuestion = question
            narrate(&job, "확인할 것이 있어 질문을 보냈어요")
        } else if job.state.phase == .running, let question = job.asks, job.queue.count == 1 {
            // 초안을 쓰기 직전에 물어본다
            job.asks = nil
            job.state.phase = .awaitingInput
            job.state.pendingQuestion = question
            narrate(&job, "확인할 것이 있어 질문을 보냈어요")
        } else if job.state.phase == .sendPending {
            if job.waitLeft > 0 {
                job.waitLeft -= 1
            } else {
                deliver(&job)
            }
        } else if job.state.phase == .running, job.queue.first == Self.accountCheck, let reason = mail?.failure {
            // 실제 서버처럼: 승인을 받기 전에 계정을 확인하고, 안 되면 아무것도 보내지 않고 끝낸다
            job.queue = []
            job.state.phase = .failed
            job.state.sendFailure = reason
            job.state.error = AgentTaskState.sendFailureText(reason)
            job.state.report = AgentReport(blocked: [AgentTaskState.sendFailureText(reason)])
            narrate(&job, reason == "invented_date" ? "초안의 날짜가 원문과 달라 보내지 않고 끝냈어요" : "메일 계정을 쓸 수 없어 보내지 않고 끝냈어요")
        } else if job.state.phase == .running, job.reads, job.queue.isEmpty {
            finishRead(&job)
        } else if job.state.phase == .running, job.finds, job.queue.isEmpty {
            finishFind(&job)
        } else if job.state.phase == .running {
            if !job.queue.isEmpty {
                let step = job.queue.removeFirst()
                job.state.steps.append(step)
                job.state.activity = Self.activity(step)
                narrate(&job, Self.narration(step))
            } else {
                job.state.phase = job.next
                switch job.next {
                case .awaitingApproval:
                    job.approvals += 1
                    job.state.steps.append(AgentEvent.approvalRequested)
                    if job.acts {
                        narrate(&job, "'\(MockSiteDo.button)'를 눌러도 될지 승인을 기다리고 있어요")
                        job.state.draft = MockSiteDo.approval(id: "ap-\(id)-\(job.approvals)", revised: job.reason != nil)
                        break
                    }
                    narrate(&job, job.sendsFrom == nil ? "초안을 저장해도 될지 승인을 기다리고 있어요" : "메일을 보내도 될지 승인을 기다리고 있어요")
                    job.state.draft = Self.draft(
                        context: job.context, reason: job.reason, approvalID: "ap-\(id)-\(job.approvals)", recipient: job.recipient,
                        sender: job.sendsFrom
                    )
                case .done where job.reel:
                    job.state.result = "가장 싼 곳은 달빛 전자, 39,800원이에요."
                    var report = AgentReport(done: ["가상몰에서 무선 이어폰 판매처 3곳의 값을 비교했어요"], sources: ["https://shop.example.com/earbuds"])
                    report.card = Self.reelCard
                    job.state.report = report
                    narrate(&job, "작업을 마쳤어요")
                case .done where job.report:
                    let steered = job.state.steers?.isEmpty == false
                    job.state.result = steered ? "한 장짜리 보고서를 만들었어요. 그래프는 막대로 바꿨어요." : "한 장짜리 보고서를 만들었어요."
                    job.state.report = AgentReport(done: [job.state.result ?? ""])
                    narrate(&job, "작업을 마쳤어요")
                case .done where job.acts:
                    // 실제 맥처럼: 한 일은 보고가 말하고, 그 사이트 안의 주소는 붙이지 않는다. 답은 Claude가 썼다
                    job.state.result = MockSiteDo.done
                    job.state.report = AgentReport(done: [MockSiteDo.done], by: ReplyWriter.claude.rawValue)
                    narrate(&job, "작업을 마쳤어요")
                case .done:
                    job.state.result = "메일 초안을 임시 저장했어요. 보내지는 않았어요."
                    if v2 {
                        job.state.report = AgentReport(
                            done: ["회의에서 나온 결정 사항과 할 일을 메일 초안으로 정리했어요", "초안을 임시 저장했어요"],
                            blocked: job.reason?.contains("팀 전체") == true ? ["참조 칸은 주소를 찾지 못해 비워 두었어요"] : [],
                            sources: ["http://mail.test/compose"]
                        )
                    }
                    narrate(&job, "작업을 마쳤어요")
                case .needsInput:
                    job.state.question = "어느 회의를 말씀하시는 건가요? 회의 이름이나 날짜를 알려 주세요."
                default:
                    break
                }
            }
        }
        jobs[id] = job
        return job.state
    }

    func decide(_ id: String, approvalID: String, approve: Bool, reason: String?, sha256: String?) async throws -> AgentTaskState {
        guard reachable else { throw AgentError.unreachable }
        guard var job = jobs[id], job.state.phase == .awaitingApproval,
              job.state.draft?.approvalID == approvalID else { throw AgentError.conflict }
        // 실제 서버처럼: 보낸 해시가 고정한 초안과 다르면 실행하지 않는다
        if approve, let sha256, sha256 != job.state.draft?.sha256 { throw AgentError.hashMismatch }
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if approve, let draft = job.state.draft, draft.isSend {
            // 보내기 승인: 바로 보내지 않고 잠깐 기다린다 (그동안 취소할 수 있다)
            let wait = mail?.wait ?? 10
            let until = Date.now.addingTimeInterval(wait)
            job.state.draft = nil
            job.state.phase = .sendPending
            job.state.outgoing = draft
            job.state.sendWait = AgentSendWait(cancelUntil: until.formatted(.iso8601), deadline: until, sha256: draft.sha256)
            job.waitLeft = mail?.waitPolls ?? 0
            narrate(&job, "보내기를 승인받았어요. \(Int(wait))초 뒤에 보내요")
        } else if approve, let draft = job.state.draft, draft.isAction {
            // 단추 누르기 승인 (D80): 실제 맥처럼 승인한 단추의 글을 적고(초안 목록에는 넣지 않는다) 그 단추를 누른다
            job.state.approvedActions = (job.state.approvedActions ?? []) + [draft.action]
            job.state.draft = nil
            job.state.phase = .running
            job.queue = ["누르기 · \(draft.action)"]
            job.next = .done
        } else if approve {
            if let draft = job.state.draft { job.state.approvedDrafts = [draft] }
            job.state.draft = nil
            job.state.phase = .running
            job.queue = ["누르기"]
            job.next = .done
        } else if reason.isEmpty {
            job.state.draft = nil
            job.state.phase = .canceled
            job.state.error = AgentTaskState.deniedText
        } else {
            job.state.draft = nil
            job.state.phase = .running
            job.state.steps.append(AgentEvent.feedbackApplied)
            job.state.activity = "요청하신 대로 고치고 있어요"
            narrate(&job, "요청하신 대로 고치고 있어요")
            job.queue = job.acts ? ["입력 · 기한"] : ["입력 · 수정한 본문"]
            job.next = .awaitingApproval
            job.reason = reason
        }
        jobs[id] = job
        return job.state
    }

    func cancel(_ id: String) async throws -> AgentTaskState {
        guard var job = jobs[id] else { throw AgentError.taskLost }
        guard !job.state.phase.isFinished else { throw AgentError.conflict }
        if job.state.phase == .sendPending {
            if mail?.lateCancel == true {
                // 취소가 늦었다: 이미 보내는 중이라 받아들이지 않는다 (다음 조회에서 보낸 결과가 온다)
                job.waitLeft = 0
                jobs[id] = job
                throw AgentError.conflict
            }
            job.state.phase = .canceled
            job.state.sendWait = nil
            job.state.error = AgentTaskState.sendCanceledText
            narrate(&job, "보내기를 취소했어요. 메일은 보내지 않았어요")
            jobs[id] = job
            return job.state
        }
        job.state.phase = .canceled
        job.state.draft = nil
        job.state.pendingQuestion = nil
        job.state.error = AgentTaskState.canceledText
        narrate(&job, "작업을 취소했어요")
        jobs[id] = job
        return job.state
    }

    /// 기다림이 끝나 메일을 보낸다: 보낸 메일(내용)과 도착 확인 결과를 남긴다
    private func deliver(_ job: inout Job) {
        let mailed = job.state.outgoing
        let verified = mail?.verified ?? .delivered
        job.state.phase = .done
        job.state.sendWait = nil
        job.state.outgoing = nil
        job.state.approvedDrafts = mailed.map { [$0] } ?? []
        job.state.result = "메일을 보냈어요."
        job.state.report = AgentReport(
            done: ["회의에서 나온 결정 사항과 할 일을 메일로 정리했어요", job.recipient == job.sendsFrom ? "내 주소로 메일을 보냈어요" : "메일을 보냈어요"],
            blocked: [],
            sources: [],
            // 다른 사람에게 보낸 메일은 실제 맥처럼 도착을 확인하지 못한다
            sent: [AgentSent(
                to: [job.recipient], sentAt: Date.now.formatted(.iso8601), verified: job.recipient == job.sendsFrom ? verified : .acceptedOnly,
                sha256: mailed?.sha256, external: job.recipient == job.sendsFrom ? nil : true
            )]
        )
        narrate(&job, "메일을 보냈어요")
        narrate(&job, verified == .delivered ? "받은편지함에 도착한 것을 확인했어요" : "도착은 아직 확인하지 못했어요")
    }

    /// 진행 설명 한 줄을 더한다 (v2). 진행 중이면 작업 카드의 "지금 하는 일"도 이 말로 바꾼다
    private func narrate(_ job: inout Job, _ text: String) {
        guard v2 || job.sendsFrom != nil else { return }
        job.state.narration = (job.state.narration ?? []) + [Self.say(text)]
        if job.state.phase == .running { job.state.activity = text }
    }

    private static func say(_ text: String) -> AgentNarration {
        AgentNarration(time: Date.now.formatted(.iso8601), text: text)
    }

    /// 실제 서버의 진행 설명 문장 (입력한 내용은 쓰지 않고 칸·버튼 이름만)
    private static let accountCheck = "확인 · 메일 계정"

    private static func narration(_ step: String) -> String {
        if step.hasPrefix("작업실 · ") { return String(step.dropFirst(6)) }
        if step == accountCheck { return "메일 계정에 로그인되는지 확인했어요" }
        if step.hasSuffix("보낼 메일") { return "보낼 메일을 썼어요" }
        if step.hasPrefix("검색") { return "웹에서 답을 찾았어요" }
        if step.hasPrefix("읽기") { return "\(step.dropFirst(5)) 페이지를 열어 확인했어요" }
        // 사이트 안에서 하는 작업 (D80)
        if step.hasPrefix("열기 · \(MockSiteDo.host)") { return "\(MockSiteDo.host)를 열었어요" }
        if step.hasPrefix("입력 · 할 일") || step.hasPrefix("입력 · 기한") { return "'\(step.dropFirst(5))' 칸을 채웠어요" }
        if step.hasPrefix("누르기 · ") { return "'\(step.dropFirst(6))'를 눌렀어요" }
        if step.hasPrefix("열기") { return "mail.test를 열었어요" }
        if step.hasPrefix("입력") { return "'본문' 칸을 채웠어요" }
        if step.hasPrefix("누르기") { return "'임시 저장'을 눌렀어요" }
        return "화면 내용을 읽었어요"
    }

    private static func activity(_ step: String) -> String {
        if step.hasPrefix("작업실 · ") { return "작업실에서 보고서를 만들고 있어요" }
        if step == accountCheck { return "메일 계정을 확인하고 있어요" }
        if step.hasSuffix("보낼 메일") { return "보낼 메일을 쓰고 있어요" }
        if step.hasPrefix("검색") { return "웹에서 찾고 있어요" }
        if step.hasPrefix("읽기") { return "찾은 페이지를 열어 보고 있어요" }
        if step.hasPrefix("열기") { return "페이지를 열고 있어요" }
        if step.hasPrefix("입력") { return "내용을 입력하고 있어요" }
        if step.hasPrefix("누르기") { return "화면에서 항목을 고르고 있어요" }
        return "화면을 살펴보고 있어요"
    }

    /// 요청에 담긴 회의 발췌로 만든 가짜 초안. `sender`가 있으면 저장이 아니라 보내는 메일이다
    private static func draft(context: String?, reason: String?, approvalID: String, recipient: String, sender: String? = nil) -> AgentDraft {
        let lines = context?.split(separator: "\n").map(String.init) ?? []
        let heading = lines.first { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) } ?? "지난 회의"
        let title = heading.components(separatedBy: " (").first ?? heading
        let points = lines.filter { $0.hasPrefix("[") }.prefix(3).map { "• " + ($0.components(separatedBy: "] ").last ?? $0) }
        var body = "안녕하세요.\n\n\(title)에서 나온 내용을 공유드립니다.\n\n\(points.joined(separator: "\n"))\n\n감사합니다."
        if let reason { body += "\n\n(반영한 요청: \(reason))" }
        var fields = ["받는 사람": recipient, "제목": "[공유] \(title) 정리", "본문": body]
        if let sender {
            fields["보내는 사람"] = sender
            let hash = AgentDraftHash.sha256(action: "보내기", fields: fields, kind: "send", url: "mailto:\(recipient)")
            return AgentDraft(
                approvalID: approvalID, action: "보내기", fields: AgentDraft.orderedFields(fields), sha256: hash, shownSHA256: hash, kind: "send",
                external: recipient != sender ? true : nil
            )
        }
        let hash = AgentDraftHash.sha256(action: "임시 저장", fields: fields, kind: "draft", url: "http://mail.test/compose")
        return AgentDraft(
            approvalID: approvalID,
            action: "임시 저장",
            fields: AgentDraft.orderedFields(fields),
            sha256: hash,
            shownSHA256: hash
        )
    }
}

// MARK: - 사이트 로그인

extension MockAgentClient {
    /// 로그인 화면이 차례로 보여 주는 것
    enum LoginStage: Sendable, Equatable {
        case input, captcha, picture, code, approval, choice, unknownField, fail(String), done
        /// 글자로 답할 수 없는 확인 문제: 손 넘기기로 직접 푼다 (D149)
        case handover
        // 간편인증 (D90): 인증 앱 고르기 → 본인 확인 칸 → 동의 → 폰에서 인증한 뒤 "인증 완료"
        case authApps, identity, consent, authDone
        // 메일 연결 ("네이버 메일 연결"). 글은 실제 맥이 보내는 것과 같게 둔다
        /// 연결할 주소를 묻는다
        case mailAddress
        /// IMAP/SMTP 사용이 꺼져 있어 켤지 묻는다
        case mailImap
        /// 네이버가 비밀번호를 다시 묻는다
        case mailPassword
        /// 앱 비밀번호를 만들지 묻는다
        case mailCreate
        case mailDone
        /// 맥이 까닭을 글로 알리며 끝낸다 (state, reason, message)
        case stop(SiteLogin.State, String?, String)

        /// 이 화면 앞에 맥이 일하는 동안 보여 주는 말
        var workingMessage: String? {
            switch self {
            case .mailImap: "네이버 메일의 IMAP/SMTP 설정을 확인하고 있어요"
            case .mailPassword: "네이버 보안설정으로 가고 있어요"
            case .mailCreate: "네이버 보안설정으로 가고 있어요"
            case .mailDone: "만든 비밀번호로 메일 서버에 연결해 보고 있어요"
            default: nil
            }
        }

        /// 여러 번 틀려 끝낼 때의 말 (메일 연결만)
        var tooManyWrong: String? {
            switch self {
            case .mailAddress: "주소를 확인하지 못했어요"
            case .mailPassword: "비밀번호가 여러 번 맞지 않아 끝냈어요"
            default: nil
            }
        }

        /// "취소"를 골랐을 때의 말 (메일 연결만)
        var declined: String? {
            switch self {
            case .mailImap: "IMAP/SMTP 설정을 바꾸지 않고 끝냈어요"
            case .mailCreate: "애플리케이션 비밀번호를 만들지 않고 끝냈어요"
            default: nil
            }
        }
    }

    struct LoginRun {
        var login: SiteLogin
        var plan: [LoginStage]
        /// "확인하고 있어요" 뒤에 보여 줄 단계
        var next = 0
        var nextError: String?
        var wrong = 0
        var approvalLeft = 0
        let started = Date.now
    }

    func sites() async throws -> [SiteStatus] {
        guard reachable else { throw AgentError.unreachable }
        guard let sites else { return [] }
        var list = [SiteStatus(
            site: "naver", name: "네이버", status: sites.loggedIn ? .loggedIn : .loggedOut, checkedAt: siteCheckedAt, methods: ["qr", "password"]
        )]
        if sites.mailSetup != nil {
            // 실제 맥처럼: 네이버 메일 계정이 쓸 수 있는 상태면 연결된 것이다
            let connected = accounts.contains { $0.provider == "naver" && $0.status == .ready }
            list.append(SiteStatus(
                site: MockSites.mailSetupSite, name: "네이버 메일 연결", status: connected ? .loggedIn : .loggedOut, checkedAt: nil, methods: ["password"]
            ))
        }
        // 화면 확인용 (`-demoSitesMany`): 로그인 안 된 가상 사이트들. 맥이 이름 자리에 주소를 보내는 경우도 (D142)
        if ProcessInfo.processInfo.arguments.contains("-demoSitesMany") {
            let saramin = await SiteName.service("saramin.co.kr")
            let example = await SiteName.service("example.com")
            list += [
                SiteStatus(site: "saramin", name: saramin, status: .loggedOut, checkedAt: nil, methods: ["password"], host: "saramin.co.kr"),
                SiteStatus(site: "coupang", name: "쿠팡", status: .loggedOut, checkedAt: nil, methods: ["qr"]),
                SiteStatus(site: "example", name: example, status: .unknown, checkedAt: nil, methods: []),
            ]
        }
        return list
    }

    func startSiteLogin(site: String, method: String) async throws -> SiteLogin {
        guard reachable else { throw AgentError.unreachable }
        guard let sites else { throw AgentError.conflict }
        let mailSetup = site == MockSites.mailSetupSite ? sites.mailSetup : nil
        guard site == "naver" || mailSetup != nil else { throw AgentError.unknownSite }
        loginStarts += 1
        // 실제 서버처럼: 10분에 다섯 번까지만 시작할 수 있다
        guard loginStarts <= 5 else { throw AgentError.rateLimited }
        // 진행 중이던 로그인은 취소된다
        for key in logins.keys where logins[key]?.login.state.isFinished == false {
            logins[key]?.login.state = .cancelled
            logins[key]?.login.expiresIn = 0
        }
        let id = "l_\(loginStarts)"
        let login = SiteLogin(id: id, site: site, method: method, state: .starting, step: 0, message: "", expiresIn: 600)
        var plan = sites.script.plan
        if let mailSetup {
            // 실제 맥처럼: 네이버에 로그인해 둔 브라우저로 하는 일이라, 로그인이 먼저다
            plan = sites.loggedIn ? mailSetup.plan : [.stop(.failed, "not_logged_in", "먼저 네이버 로그인을 해 주세요")]
        }
        logins[id] = LoginRun(login: login, plan: plan)
        return login
    }

    /// 조회할 때마다 한 단계씩 나아간다
    func siteLogin(site: String, id: String) async throws -> SiteLogin {
        guard reachable else { throw AgentError.unreachable }
        guard var run = logins[id] else { throw AgentError.loginLost }
        switch run.login.state {
        case .starting, .working:
            present(&run)
        case .needApproval:
            run.approvalLeft -= 1
            if run.approvalLeft <= 0, sites?.script != .hold { present(&run) }
        default:
            break
        }
        if !run.login.state.isFinished { run.login.expiresIn = max(1, 600 - Int(Date.now.timeIntervalSince(run.started))) }
        logins[id] = run
        return run.login
    }

    /// 받은 값은 맞는지만 보고 버린다 ("wrong"이 들어 있으면 틀린 것). 값은 저장하지도 돌려주지도 않는다
    func sendSiteLoginInput(site: String, id: String, step: Int, values: [String: String]) async throws -> SiteLogin {
        guard reachable else { throw AgentError.unreachable }
        guard var run = logins[id] else { throw AgentError.loginLost }
        guard run.login.step == step, run.login.state == .needInput || run.login.state == .needChoice else { throw AgentError.staleStep }
        let expected = run.login.state == .needChoice ? [SiteLogin.choiceName] : run.login.fields.map(\.name)
        guard Set(values.keys) == Set(expected), values.values.allSatisfy({ !$0.isEmpty && $0.count <= 256 }) else {
            throw AgentError.server("invalid_request")
        }
        loginInputs.append((step, values.keys.sorted()))
        let shown = run.plan.indices.contains(run.next - 1) ? run.plan[run.next - 1] : nil
        if values.values.contains(where: { $0.contains("wrong") }) {
            run.wrong += 1
            // 같은 화면이 다시 나온다. 세 번째 틀리면 그만둔다
            if run.wrong >= 3 {
                run.plan = [shown?.tooManyWrong.map { .stop(.failed, "wrong_input", $0) } ?? .fail("wrong_input")]
                run.next = 0
            } else {
                run.next -= 1
                run.nextError = "wrong_input"
            }
        } else if values[SiteLogin.choiceName] == "취소", let message = shown?.declined {
            run.plan = [.stop(.cancelled, nil, message)]
            run.next = 0
        }
        run.login.state = .working
        run.login.message = (run.plan.indices.contains(run.next) ? run.plan[run.next].workingMessage : nil) ?? "확인하고 있어요"
        run.login.fields = []
        run.login.image = nil
        run.login.error = nil
        run.login.text = nil
        run.login.choices = []
        run.login.handover = nil
        logins[id] = run
        return run.login
    }

    func cancelSiteLogin(site: String, id: String) async throws -> SiteLogin {
        guard reachable else { throw AgentError.unreachable }
        guard var run = logins[id] else { throw AgentError.loginLost }
        loginCancels += 1
        if !run.login.state.isFinished {
            run.login = SiteLogin(
                id: id, site: site, method: run.login.method, state: .cancelled, step: run.login.step, message: "로그인을 취소했어요", expiresIn: 0
            )
        }
        logins[id] = run
        return run.login
    }

    func siteLogout(site: String) async throws -> [SiteStatus] {
        guard reachable else { throw AgentError.unreachable }
        sites?.loggedIn = false
        siteCheckedAt = .now
        return try await self.sites()
    }

    func setSiteIcon(_ data: Data?, for site: String) { siteIconData[site] = data }

    // MARK: 통화 목소리 (D136)

    func setTakesVoice(_ value: Bool) { takesVoice = value }
    func setVoice(_ id: String, chunks: [VoiceChunk]) { voices[id] = chunks }

    private func makeVoice(_ text: String) -> String {
        let id = "v_\(voices.count + 1)"
        voices[id] = [.audio(MockVoice.wav), .end]
        return id
    }

    func voiceWarm() async throws -> Bool { takesVoice }

    func voiceCreate(text: String) async throws -> String {
        guard takesVoice else { throw AgentError.conflict }
        return makeVoice(text)
    }

    func voiceChunk(id: String, index: Int) async throws -> VoiceChunk {
        guard let chunks = voices[id] else { return .gone }
        return index < chunks.count ? chunks[index] : .end
    }

    func voiceCancel(id: String) async { cancelledVoices.append(id) }

    func siteIcon(site: String) async throws -> Data? {
        guard reachable else { throw AgentError.unreachable }
        return siteIconData[site]
    }

    func checkSite(site: String) async throws -> [SiteStatus] {
        guard reachable else { throw AgentError.unreachable }
        siteCheckedAt = .now
        return try await self.sites()
    }

    /// 다음 단계의 화면을 보여 준다 (화면이 바뀔 때마다 번호가 올라간다)
    private func present(_ run: inout LoginRun) {
        guard run.plan.indices.contains(run.next) else { return }
        let stage = run.plan[run.next]
        run.next += 1
        var login = SiteLogin(
            id: run.login.id, site: run.login.site, method: run.login.method, state: .needInput, step: run.login.step + 1, message: "", expiresIn: 600
        )
        login.error = run.nextError
        run.nextError = nil
        login.host = sites?.host
        switch stage {
        case .input:
            login.message = "네이버 로그인 정보를 입력해 주세요"
            login.fields = [.init(name: "id", label: "아이디 또는 전화번호", secret: false), .init(name: "password", label: "비밀번호", secret: true)]
        case .captcha:
            login.message = "보안문자를 입력해 주세요"
            login.image = MockSites.captchaImage()
            login.fields = [.init(name: "password", label: "비밀번호", secret: true), .init(name: "captcha", label: "보안문자", secret: false)]
        case .picture:
            // 실제 네이버가 아이디·비밀번호 뒤에 보여 준 "추가 확인" 화면의 모양 (2026-11-12 맥 세션이 알려 옴): 그림 한 장, 답 칸 하나, 물음은 message에
            login.message = "그림을 보고 답해 주세요: 영수증에 적힌 가게 전화번호의 뒤 4자리는 무엇입니까?"
            login.image = MockSites.receiptImage()
            login.fields = [.init(name: "captcha", label: "정답을 입력해 주세요", secret: false)]
        case .code:
            login.message = "휴대폰으로 받은 인증 번호를 입력해 주세요"
            login.fields = [.init(name: "code", label: "인증 번호", secret: false)]
        case .approval:
            login.state = .needApproval
            login.message = "휴대폰의 네이버 앱 알림에서 로그인을 승인해 주세요"
            run.approvalLeft = sites?.approvalPolls ?? 3
        case .choice:
            login.state = .needChoice
            login.text = "이 브라우저를 자주 쓰는 기기로 등록할까요?"
            login.choices = ["등록", "등록 안 함"]
        case .handover:
            // 실제 맥의 꼴 (2026-11-18 맥 세션이 알려 옴): need_choice + ["다 했어요", "그만하기"] + handover
            login.state = .needChoice
            login.text = "사이트가 그림을 눌러 고르는 확인 문제를 띄웠어요. 브라우저를 열어 직접 풀어 주세요."
            login.choices = Self.handoverChoices
            login.handover = AgentHandover(id: "h_\(run.login.id)", reason: "사람 확인 퍼즐", host: sites?.host ?? "login.test", idleClose: 300)
        case .authApps:
            login.state = .needChoice
            login.text = "어느 인증 앱으로 본인 확인을 할까요?"
            login.choices = MockSites.authApps + ["그만하기"]
        case .identity:
            login.message = "본인 확인에 쓸 정보를 입력해 주세요"
            login.fields = [
                .init(name: "name", label: "이름", secret: false), .init(name: "birth", label: "생년월일 8자리", secret: false),
                .init(name: "phone", label: "휴대폰 번호", secret: false),
            ]
        case .consent:
            login.state = .needChoice
            login.text = "아래에 동의하고 인증을 요청할까요?\n· 개인정보 수집ㆍ이용 동의\n· 고유식별정보 처리 동의\n· 제3자 정보 제공 동의"
            login.choices = ["동의하고 인증 요청", "그만하기"]
        case .authDone:
            login.state = .needChoice
            login.text = "폰의 인증 앱에 온 요청을 인증한 뒤 '인증 완료'를 눌러 주세요"
            login.choices = ["인증 완료", "그만하기"]
        case .unknownField:
            login.message = "추가 정보를 입력해 주세요"
            login.fields = [.init(name: "birthday", label: "생년월일", secret: false)]
        case .fail(let reason):
            login.state = .failed
            login.reason = reason
            login.expiresIn = 0
        case .done:
            login.state = .loggedIn
            login.message = "로그인했어요"
            login.expiresIn = 0
            sites?.loggedIn = true
            siteCheckedAt = .now
        case .mailAddress:
            login.message = login.error == nil ? "연결할 네이버 메일 주소(또는 아이디)를 입력해 주세요" : "네이버 메일 주소 형식이 아니에요. 다시 입력해 주세요"
            login.fields = [.init(name: "id", label: "네이버 메일 주소", secret: false)]
        case .mailImap:
            login.state = .needChoice
            login.message = "IMAP/SMTP 사용을 켤까요?"
            login.text = "네이버 메일의 IMAP/SMTP 사용이 꺼져 있어요. 메일을 읽고 보내려면 '사용함'으로 바꿔야 해요. 바꿀까요?"
            login.choices = ["바꾸기", "취소"]
        case .mailPassword:
            login.message = login.error == nil
                ? "네이버가 본인 확인을 위해 비밀번호를 다시 물어요(2단계 인증 관리 화면으로 들어가는 중이에요)"
                : "입력한 비밀번호가 맞지 않아요. 다시 입력해 주세요"
            login.fields = [.init(name: "password", label: "비밀번호", secret: true)]
        case .mailCreate:
            login.state = .needChoice
            login.message = "애플리케이션 비밀번호를 만들까요?"
            login.text = "네이버에 'AIagent'이라는 이름의 애플리케이션 비밀번호를 새로 만들까요? 만든 비밀번호는 \(MockSites.mailSetupAddress) 메일을 읽고 보내는 데만 쓰고, 맥의 보안 저장소에만 보관해요. 네이버 보안설정에서 언제든 지울 수 있어요."
            login.choices = ["만들기", "취소"]
        case .mailDone:
            login.state = .loggedIn
            login.message = "네이버 메일을 연결했어요. 이제 메일을 읽고 보낼 수 있어요"
            login.expiresIn = 0
            // 실제 맥처럼: 연결한 주소가 기본 메일 계정이 된다 (가상 주소 하나로 흉내 낸다)
            accounts = accounts.filter { $0.address != MockSites.mailSetupAddress }.map { var account = $0; account.isDefault = false; return account }
            accounts.insert(MailAccount(provider: "naver", address: MockSites.mailSetupAddress, status: .ready, isDefault: true, checkedAt: .now), at: 0)
            mail?.failure = nil
        case .stop(let state, let reason, let message):
            login.state = state
            login.reason = reason
            login.message = message
            login.expiresIn = 0
        }
        run.login = login
    }
}

/// 가짜 맥의 사이트 로그인 설정
struct MockSites: Sendable {
    enum Script: String, Sendable {
        /// 입력 → 휴대폰 승인 → 로그인
        case normal
        /// 휴대폰 승인에서 머문다 (화면 확인용)
        case hold
        /// 입력 → 보안문자 → 승인 → 로그인
        case captcha
        /// 입력 → 그림을 보고 답하는 추가 확인 → 승인 → 로그인
        case receipt
        /// 입력 → 그림 확인 → 로그인 칸이 한 번 더 → 승인 → 로그인 (2026-11-12 실제 네이버에서 본 순서)
        case relogin
        /// 입력 → 인증 번호 → 로그인
        case code
        /// 입력 → 승인 → 기기 등록 물음 → 로그인
        case choice
        /// 입력 → 사이트가 막음
        case blocked
        /// 입력 → 에이전트가 모르는 화면
        case unsupported
        /// 입력 → 로그인은 됐지만 그 상태가 이어지지 않는 사이트 (다시 해도 같다)
        case unsupportedLogin = "unsupported_login"
        /// 앱이 모르는 입력칸을 묻는다
        case unknownField = "unknown_field"
        /// 간편인증 (D90): 인증 앱 → 이름·생년월일·휴대폰 번호 → 동의 → 인증 완료
        case simple
        /// 입력 → 그림을 눌러 고르는 확인 문제(손 넘기기, D149) → 로그인
        case handover

        var plan: [MockAgentClient.LoginStage] {
            switch self {
            case .normal, .hold: [.input, .approval, .done]
            case .captcha: [.input, .captcha, .approval, .done]
            case .receipt: [.input, .picture, .approval, .done]
            case .relogin: [.input, .picture, .input, .approval, .done]
            case .code: [.input, .code, .done]
            case .choice: [.input, .approval, .choice, .done]
            // 실패의 글은 실제 맥이 보내는 문장과 같게 둔다
            case .blocked: [.input, .stop(.failed, "blocked", MockSites.blockedMessage)]
            case .unsupported: [.input, .fail("unsupported_page")]
            case .unsupportedLogin: [.input, .stop(.failed, "unsupported_login", MockSites.unsupportedLoginMessage)]
            case .unknownField: [.unknownField]
            case .simple: [.authApps, .identity, .consent, .authDone, .done]
            case .handover: [.input, .handover, .done]
            }
        }
    }

    /// "네이버 메일 연결"이 보여 주는 순서
    enum MailSetup: String, Sendable {
        /// 주소 → 비밀번호 재확인 → 앱 비밀번호를 만들지 물음 → 연결 (2026-11-12 실제 계정에서 본 순서)
        case normal
        /// 주소 → IMAP/SMTP를 켤지 물음 → 비밀번호 재확인 → 만들지 물음 → 연결
        case imap
        /// 주소 → 비밀번호 재확인 → 만들었지만 메일 서버 로그인에 실패
        case failed

        var plan: [MockAgentClient.LoginStage] {
            switch self {
            case .normal: [.mailAddress, .mailPassword, .mailCreate, .mailDone]
            case .imap: [.mailAddress, .mailImap, .mailPassword, .mailCreate, .mailDone]
            case .failed: [
                .mailAddress, .mailPassword, .mailCreate,
                .stop(.failed, "wrong_input", "비밀번호는 만들었지만 메일 서버 로그인에 실패했어요(auth_failed). 주소가 맞는지 확인하고, 네이버 보안설정에서 'AIagent' 비밀번호를 지운 뒤 다시 해 주세요"),
            ]
            }
        }
    }

    static let mailSetupSite = "naver_mail"
    /// 메일 연결이 끝나면 생기는 계정의 가상 주소
    static let mailSetupAddress = "me@naver.test"
    /// 로그인이 막혔을 때 맥이 보내는 문장 (맥이 정해 둔 글 + 사이트 이름)
    static let blockedMessage = "네이버가 이 로그인을 막았어요. 잠시 뒤에 다시 하거나 다른 방법을 써 주세요"
    /// 로그인은 됐지만 다음에 열 때 이어지지 않는 사이트에서 맥이 보내는 문장
    static let unsupportedLoginMessage = "네이버 로그인은 끝까지 됐는데, 그 로그인 상태가 다음에 열 때 이어지지 않았어요. 이 사이트는 아직 이어서 쓸 수 없어요(다시 로그인해도 같아요)."

    var script: Script = .normal
    /// 맥이 메일 연결을 대신 해 주는지 (nil이면 사이트 목록에 없다)
    var mailSetup: MailSetup?
    /// 이미 로그인된 상태로 시작할지
    var loggedIn = false
    /// 휴대폰 승인 대기가 조회 몇 번 동안 이어지는지
    var approvalPolls = 3
    /// 입력을 받는 화면의 호스트 (네이버가 아닌 사이트의 로그인처럼 알려 줄 때만. 가상 주소)
    var host: String?

    init(script: Script = .normal, loggedIn: Bool = false, approvalPolls: Int = 3, mailSetup: MailSetup? = nil, host: String? = nil) {
        self.script = script
        self.loggedIn = loggedIn
        self.approvalPolls = approvalPolls
        self.mailSetup = mailSetup
        self.host = host
    }

    /// 화면 확인용 (`-demoSiteLogin`): hold · captcha · receipt · relogin · code · choice · blocked · unsupported · unknown_field · logged_in.
    /// `-demoMailSetup` [`imap|failed|not_logged_in`]: 메일 연결도 해 주는 맥처럼 (네이버에는 로그인된 것으로 둔다. `not_logged_in`만 빼고)
    init(demo: String?, offersMailSetup: Bool = false, mailSetup: String? = nil) {
        self.init(script: Script(rawValue: demo ?? "") ?? .normal, loggedIn: demo == "logged_in")
        if offersMailSetup {
            self.mailSetup = MailSetup(rawValue: mailSetup ?? "") ?? .normal
            loggedIn = mailSetup != "not_logged_in"
        }
    }

    /// 화면 확인용 영수증 그림 (앱이 그린 가짜. 가게·번호 모두 지어낸 것이다)
    static func receiptImage() -> Data {
        let size = CGSize(width: 300, height: 520)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let ink = UIColor(white: 0.15, alpha: 1)
            func draw(_ text: String, _ y: CGFloat, size fontSize: CGFloat = 13, bold: Bool = false, right: String? = nil) {
                let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
                (text as NSString).draw(at: CGPoint(x: 20, y: y), withAttributes: [.font: font, .foregroundColor: ink])
                if let right {
                    let width = (right as NSString).size(withAttributes: [.font: font]).width
                    (right as NSString).draw(at: CGPoint(x: size.width - 20 - width, y: y), withAttributes: [.font: font, .foregroundColor: ink])
                }
            }
            func rule(_ y: CGFloat) {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 20, y: y))
                path.addLine(to: CGPoint(x: size.width - 20, y: y))
                path.setLineDash([4, 3], count: 2, phase: 0)
                UIColor(white: 0.5, alpha: 1).setStroke()
                path.stroke()
            }
            draw("가상 문구점 (보기용)", 24, size: 17, bold: true)
            draw("주소: 가상시 보기구 예시로 12", 58)
            draw("전화: 02-0000-4821", 80)
            draw("2026-11-12 10:30", 102)
            rule(130)
            draw("공책 2권", 146, right: "3,000")
            draw("연필 5자루", 170, right: "2,500")
            draw("지우개 1개", 194, right: "700")
            draw("자 1개", 218, right: "1,200")
            rule(250)
            draw("합계", 266, size: 15, bold: true, right: "7,400")
            draw("받은 금액", 296, right: "10,000")
            draw("거스름돈", 320, right: "2,600")
            rule(352)
            draw("영수증 번호 0000-0000", 368)
            draw("이용해 주셔서 감사합니다", 400)
        }
    }

    /// 화면 확인용 보안문자 그림 (실제 사이트의 것이 아니다)
    /// 간편인증에서 고르는 인증 앱 13곳 (모두 지어낸 이름이다)
    static let authApps = [
        "하늘인증", "바다페이", "노을패스", "구름뱅크", "별빛인증", "솔잎페이", "달빛패스", "모래뱅크", "이슬인증", "바람페이", "산들패스", "강물뱅크", "햇살인증",
    ]

    static func captchaImage() -> Data {
        let size = CGSize(width: 240, height: 80)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(white: 0.96, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.6, alpha: 1).setStroke()
            for index in 0..<4 {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: 14 + CGFloat(index) * 17))
                path.addCurve(
                    to: CGPoint(x: size.width, y: 62 - CGFloat(index) * 13),
                    controlPoint1: CGPoint(x: 70, y: 78 - CGFloat(index) * 20), controlPoint2: CGPoint(x: 160, y: CGFloat(index) * 24)
                )
                path.lineWidth = 1.2
                path.stroke()
            }
            for (index, letter) in ["7", "k", "D", "m", "4", "x"].enumerated() {
                let cg = context.cgContext
                cg.saveGState()
                cg.translateBy(x: 26 + CGFloat(index) * 34, y: 40)
                cg.rotate(by: CGFloat([-0.25, 0.18, -0.1, 0.3, -0.2, 0.12][index]))
                (letter as NSString).draw(
                    at: CGPoint(x: -10, y: -20),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor(white: 0.2, alpha: 1)]
                )
                cg.restoreGState()
            }
        }
    }
}

/// 가짜 맥의 메일 보내기 설정 (가상 주소만 쓴다)
struct MockMail: Sendable {
    /// 보낸 뒤 도착 확인 결과
    var verified: AgentSent.Verified = .delivered
    /// 승인 전에 걸리는 실패 ("auth_failed"·"unreachable"·"not_set"는 계정을 연결하면 풀린다.
    /// "invented_date"는 초안의 날짜 검사에 걸린 것이라 계정과 상관없다)
    var failure: String?
    /// 보내기 전 기다리는 시간(초)과, 그 기다림이 조회 몇 번 동안 이어지는지
    var wait: TimeInterval = 10
    var waitPolls = 7
    /// 취소가 늦는 경우 (이미 보내는 중이라 받아들여지지 않는다)
    var lateCancel = false
    /// 보낼 수 있는 내 주소가 하나도 정해지지 않은 서버
    var noAddresses = false

    /// 등록된 계정: 네이버가 기본, Gmail이 둘째
    var accounts: [MailAccount] {
        if noAddresses { return [] }
        let status = MailAccount.Status(rawValue: failure ?? "") ?? .ready
        return [
            MailAccount(provider: "naver", address: "me@naver.test", status: status, isDefault: true, checkedAt: nil),
            MailAccount(provider: "gmail", address: "me@gmail.test", status: .ready, isDefault: false, checkedAt: nil),
        ]
    }

    init(verified: AgentSent.Verified = .delivered, failure: String? = nil, wait: TimeInterval = 10, waitPolls: Int = 7, lateCancel: Bool = false) {
        self.verified = verified
        self.failure = failure
        self.wait = wait
        self.waitPolls = waitPolls
        self.lateCancel = lateCancel
    }

    /// 화면 확인용 (`-demoAgentSendResult`): unverified · late · auth_failed · unreachable · not_set · no_address · invented_date
    init(demo: String?) {
        switch demo {
        case "unverified": self.init(verified: .acceptedOnly)
        case "late": self.init(lateCancel: true)
        case "auth_failed", "unreachable", "not_set", "invented_date": self.init(failure: demo)
        case "no_address":
            self.init(failure: "not_set")
            noAddresses = true
        default: self.init()
        }
    }
}

/// 내 공간을 하는 가짜 맥 (`-demoSpace`). 카드도 그 내용도 모두 지어낸 것이다.
/// 실제 맥은 판단 모델이 구성을 내지만, 여기서는 말에 든 낱말로 정해진 대로만 바꾼다
struct MockSpace: Sendable {
    private(set) var space: AgentSpace {
        // 구성이 바뀔 때마다 추천을 다시 고른다 (만든 카드는 추천에서 빠진다)
        didSet { space.suggestions = Self.suggest(space.cards) }
    }
    private var history: [AgentSpace] = []
    private var made = 0
    /// 어느 종목인지 되물어 놓고 답을 기다리는 중
    private var awaitingStock = false

    /// 실행 인자 값: `empty`(아직 아무것도 없는 내 공간), `full`·없음(카드가 찬 내 공간)
    init(demo: String?) {
        self.init(cards: demo == "empty" ? [] : Self.demoCards)
    }

    init(cards: [SpaceCard] = []) {
        space = AgentSpace(cards: cards, suggestions: Self.suggest(cards))
    }

    /// 지금 구성에 없는 것 가운데 바로 만들 수 있는 것 (실제 맥은 연결된 계정·예약·공개 정보에서 고른다)
    static func suggest(_ cards: [SpaceCard]) -> [AgentSpace.Suggestion] {
        let titles = Set(cards.map(\.title))
        return [("오늘 온 메일", "오늘 온 메일 카드 넣어줘"), ("원달러 환율", "원달러 환율 카드 넣어줘"), ("날씨", "날씨 카드 넣어줘"), ("오늘 일정", "오늘 일정 카드 넣어줘")]
            .filter { !titles.contains($0.0) }
            .map { AgentSpace.Suggestion(label: $0.0, say: $0.1) }
    }

    /// 말에 든 낱말과 그 카드 (종류, 처음 이름, 처음 크기)
    private static let known: [(words: [String], kind: SpaceCard.Kind, title: String, size: SpaceCard.Size)] = [
        (["메일"], .mailToday, "오늘 온 메일", .medium),
        (["회의", "할 일", "하기로"], .meetingTodos, "회의에서 내가 하기로 한 일", .large),
        (["일정"], .calendarToday, "오늘 일정", .small),
        (["날씨"], .weather, "날씨", .small),
        (["브리핑"], .routineResult, "아침 브리핑", .medium),
        (["환율"], .custom, "원달러 환율", .small),
        (["배송", "주문"], .custom, "주문·배송", .medium),
    ]

    static let demoCards: [SpaceCard] = [
        SpaceCard(id: "c_todos", kind: .meetingTodos, size: .large, title: "회의에서 내가 하기로 한 일"),
        SpaceCard(id: "c_calendar", kind: .calendarToday, size: .small, title: "오늘 일정"),
        SpaceCard(id: "c_weather", kind: .weather, size: .small, title: "날씨"),
        filled(SpaceCard(id: "c_mail", kind: .mailToday, size: .medium, title: "오늘 온 메일")),
        filled(SpaceCard(id: "c_rate", kind: .custom, size: .small, title: "원달러 환율")),
        filled(SpaceCard(id: "c_storage", kind: .custom, size: .small, title: "드라이브 용량")),
        filled(SpaceCard(id: "c_orders", kind: .custom, size: .medium, title: "달빛 서점 주문")),
        filled(SpaceCard(id: "c_gold", kind: .custom, size: .small, title: "금 시세")),
        filled(SpaceCard(id: "c_holiday", kind: .custom, size: .small, title: "다음 공휴일")),
        SpaceCard(id: "c_briefing", kind: .routineResult, size: .medium, title: "아침 메일 브리핑", state: .unavailable, why: "내일 오전 8:00에 처음 돌아요"),
        SpaceCard(
            id: "c_pay", kind: .custom, size: .medium, title: "가람페이 결제 내역", state: .unavailable, why: "사이트 확인이 필요해요",
            action: SpaceCard.Action(label: "매일 아침에 모아보기", say: "매일 아침 9시에 가람페이 결제 내역 알려줘")
        ),
    ]

    /// 카드의 내용을 지어내 채운다 (실제 맥이 주는 꼴 그대로)
    static func filled(_ card: SpaceCard) -> SpaceCard {
        var card = card
        card.state = .ok
        card.why = nil
        card.dataAt = .now
        switch (card.kind, card.title) {
        case (.mailToday, _):
            card.mailCount = 5
            card.mailServices = ["네이버", "지메일"]
            card.mails = [
                SpaceCard.Mail(time: "오전 9:10", from: "한빛 보안센터", subject: "새 기기에서 로그인했어요", service: "지메일"),
                SpaceCard.Mail(time: "오전 8:42", from: "모아 배포 알림", subject: "빌드 58 처리가 끝났어요", service: "지메일"),
                SpaceCard.Mail(time: "오전 7:55", from: "가람 문구", subject: "결제 영수증", service: "네이버"),
                SpaceCard.Mail(time: "오전 7:31", from: "모아 배포 알림", subject: "빌드 57 처리가 끝났어요", service: "지메일"),
                SpaceCard.Mail(time: "오전 6:20", from: "달빛 서점", subject: "주문하신 책을 보냈어요", service: "네이버"),
            ]
            card.mailHeadline = "챙길 메일 1통"
            card.mailPicks = [
                SpaceCard.Pick(
                    title: "새 기기에서 로그인했어요", note: "내가 한 것이 아니면 비밀번호 바꾸기", service: "지메일",
                    say: "오늘 온 '새 기기에서 로그인했어요' 메일 자세히 알려줘"
                ),
            ]
            card.mailRest = "배포 안내 2통, 영수증·배송 안내 2통"
            card.blocks = [.text("챙길 메일 1통 · 배포 안내 2통, 영수증·배송 안내 2통")]
        case (.routineResult, _):
            card.blocks = [.text("오늘 온 메일은 5통이에요. 서울은 맑고 낮 최고 15도예요.")]
        case (_, "원달러 환율"):
            card.blocks = [.stat(label: "원달러 환율", value: "1,382.0원", note: "개장가 기준"), .text("개장가 기준이에요. 기사마다 시점이 달라 조금씩 다를 수 있어요.")]
            card.delta = "−4.0"
            card.deltaUp = false
            card.trend = [1391.5, 1388.0, 1390.2, 1386.0, 1384.5, 1386.0, 1382.0]
            card.changedAt = .now
        case (_, "금 시세"):
            card.blocks = [.pairs([SpaceBlock.Pair(label: "살 때", value: "52만 원"), SpaceBlock.Pair(label: "팔 때", value: "47만 원")])]
        case (_, "다음 공휴일"):
            let soon = Calendar.current.dateComponents([.year, .month, .day], from: Calendar.current.date(byAdding: .day, value: 39, to: .now) ?? .now)
            card.blocks = [.date(label: "성탄절", day: soon, note: "금요일")]
        case (_, "달빛 서점 주문"):
            card.blocks = [.list([
                SpaceBlock.Item(title: "여름의 문장들", subtitle: "오늘 출고", trailing: "배송 중", isNew: true),
                SpaceBlock.Item(title: "작은 정원 가꾸기", subtitle: "어제 도착", trailing: "배송 완료"),
                SpaceBlock.Item(title: "천천히 걷는 법", subtitle: "11월 12일 도착", trailing: "배송 완료"),
            ])]
            card.newCount = 1
            card.changedAt = .now
            card.quicks = [
                SpaceCard.Quick(label: "자세히 묻기", kind: .say("달빛 서점 주문 내역 자세히 알려줘")),
                SpaceCard.Quick(label: "지금 가져오기", kind: .run("rt_demo_orders")),
            ]
        case (_, "드라이브 용량"):
            card.blocks = [.progress(label: "15GB 가운데 9.3GB 사용", ratio: 0.62)]
        default:
            card.blocks = [.text("지어낸 내용이에요.")]
        }
        return card
    }

    /// 말로 고친다. 무엇이 바뀌었는지는 앞뒤 구성을 견줘 쓴다
    mutating func edit(_ text: String) -> SpaceEdit {
        // 되묻기 (D105): 무엇을 보일지 모자라면 묻고, 다음 말을 그 답으로 읽는다
        if text.contains("주식") || text.contains("주가") {
            awaitingStock = true
            return SpaceEdit(space: space, changes: [], say: "어느 종목 주가를 보여 드릴까요?", asking: true)
        }
        if awaitingStock {
            awaitingStock = false
            made += 1
            history.append(space)
            let title = "\(text.trimmingCharacters(in: .whitespaces)) 주가"
            var card = SpaceCard(id: "c_made\(made)", kind: .custom, size: .small, title: title)
            card.state = .empty
            space = AgentSpace(cards: space.cards + [card], canUndo: true)
            return SpaceEdit(space: space, changes: ["'\(title)' 카드를 더했어요"])
        }
        let mentioned = Self.known.filter { entry in entry.words.contains { text.contains($0) } }
        guard !mentioned.isEmpty else {
            return SpaceEdit(space: space, changes: [], say: "무엇을 바꿀지 알아듣지 못했어요. 보고 싶은 것을 말해 주세요.")
        }
        var cards = space.cards
        var changes: [String] = []
        let removing = ["빼", "지워", "없애"].contains { text.contains($0) }
        // "A는 크게, B는 빼 줘": 빼라는 말 앞에서 마지막으로 말한 것만 뺀다
        let removed = removing ? mentioned.last : nil
        for entry in mentioned {
            let index = cards.firstIndex { $0.kind == entry.kind && (entry.kind != .custom || $0.title == entry.title) }
            if let removed, removed.title == entry.title {
                if let index {
                    changes.append("'\(cards[index].title)' 카드를 뺐어요")
                    cards.remove(at: index)
                }
                continue
            }
            var at = index
            if at == nil {
                made += 1
                var card = SpaceCard(id: "c_made\(made)", kind: entry.kind, size: entry.size, title: entry.title)
                if !entry.kind.filledByApp { card.state = .empty }
                // 로그인해야 볼 수 있는 것은 채우지 않는다
                if entry.title == "주문·배송" {
                    card.state = .unavailable
                    card.why = "로그인이 필요해요."
                }
                cards.append(card)
                at = cards.count - 1
                changes.append("'\(entry.title)' 카드를 더했어요")
            }
            guard var position = at else { continue }
            if text.contains("맨 위"), entry.title == mentioned.first?.title, position != 0 {
                cards.insert(cards.remove(at: position), at: 0)
                position = 0
                changes.append("'\(entry.title)' 카드를 맨 위로 옮겼어요")
            }
            if text.contains("크게"), entry.title == mentioned.first?.title, cards[position].size != .large {
                cards[position].size = .large
                changes.append("'\(entry.title)' 카드를 크게 했어요")
            }
            if text.contains("작게"), entry.title == mentioned.first?.title, cards[position].size != .small {
                cards[position].size = .small
                changes.append("'\(entry.title)' 카드를 작게 했어요")
            }
        }
        guard cards != space.cards else { return SpaceEdit(space: space, changes: [], say: "이미 그렇게 되어 있어요.") }
        history.append(space)
        space = AgentSpace(cards: cards, canUndo: true)
        return SpaceEdit(space: space, changes: changes)
    }

    /// 차례와 크기를 그대로 정한다. 모르는 카드가 있으면 nil. 무엇이 바뀌었는지는 앞뒤를 견줘 쓴다
    mutating func arrange(_ wanted: [SpaceArrangement]) -> SpaceEdit? {
        var cards: [SpaceCard] = []
        var changes: [String] = []
        for item in wanted {
            guard var card = space.cards.first(where: { $0.id == item.id }), let size = SpaceCard.Size(rawValue: item.size) else { return nil }
            if card.size != size {
                card.size = size
                changes.append("'\(card.title)' 카드를 \(size == .large ? "크게" : (size == .small ? "작게" : "보통 크기로")) 했어요")
            }
            cards.append(card)
        }
        let kept = Set(cards.map(\.id))
        for gone in space.cards where !kept.contains(gone.id) { changes.append("'\(gone.title)' 카드를 뺐어요") }
        if cards.map(\.id) != space.cards.map(\.id).filter(kept.contains) { changes.append("카드의 차례를 바꿨어요") }
        guard cards != space.cards else { return SpaceEdit(space: space) }
        history.append(space)
        space = AgentSpace(cards: cards, canUndo: true)
        return SpaceEdit(space: space, changes: changes)
    }

    /// 한 번 되돌린다. 되돌릴 것이 없으면 nil
    mutating func undo() -> SpaceEdit? {
        guard let last = history.popLast() else { return nil }
        space = AgentSpace(cards: last.cards, canUndo: !history.isEmpty)
        return SpaceEdit(space: space, changes: ["앞의 화면으로 되돌렸어요"])
    }

    mutating func clear() -> SpaceEdit {
        history.append(space)
        space = AgentSpace(cards: [], canUndo: true)
        return SpaceEdit(space: space, changes: ["내 공간을 비웠어요"])
    }

    /// 카드 하나의 내용을 채운다 (채울 수 없는 카드는 그대로 둔다)
    mutating func fill(_ id: String) {
        guard let index = space.cards.firstIndex(where: { $0.id == id }) else { return }
        let card = space.cards[index]
        guard !card.kind.filledByApp, card.state != .unavailable else { return }
        space.cards[index] = Self.filled(card)
    }
}

/// 예약을 하는 가짜 맥의 설정 (`-demoRoutines`). 예약도 결과도 모두 지어낸 것이다
struct MockRoutines: Sendable {
    var routines: [AgentRoutine] = []
    var runs: [RoutineRun] = []

    /// 실행 인자 값: `empty`(예약이 하나도 없는 맥)
    init(demo: String?) {
        if demo != "empty" { self = .demo() }
    }

    init(routines: [AgentRoutine] = [], runs: [RoutineRun] = []) {
        self.routines = routines
        self.runs = runs
    }

    static let briefingRunID = "rr_demo_briefing"

    static func demo(now: Date = .now, calendar: Calendar = .current) -> MockRoutines {
        func at(_ hour: Int, _ minute: Int, addingDays days: Int) -> Date? {
            calendar.date(byAdding: .day, value: days, to: now).flatMap { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: $0) }
        }
        return MockRoutines(
            routines: [
                AgentRoutine(
                    id: "rt_briefing", title: "아침 브리핑", prompt: "오늘 온 메일이랑 날씨 요약해줘", enabled: true, kind: "daily",
                    whenText: "매일 오전 7:30", nextRunAt: at(7, 30, addingDays: 1), lastRunAt: at(7, 30, addingDays: 0), lastStatus: "done",
                    notes: "- 보안 관련 메일을 맨 위에 말해 줘\n- 광고 메일은 몇 통인지만 알려 줘\n- 비 소식이 있으면 우산을 챙기라고 말해 줘"
                ),
                AgentRoutine(
                    id: "rt_weekly", title: "주간 회의 정리", prompt: "지난 회의 내용 나한테 메일로 보내줘", enabled: true, kind: "weekly",
                    whenText: "매주 월요일 오전 9:00", nextRunAt: at(9, 0, addingDays: 4), lastStatus: "task"
                ),
                AgentRoutine(
                    id: "rt_workshop", title: "워크숍 준비물 확인", prompt: "가을 워크숍 준비물 다시 알려줘", enabled: true, kind: "once",
                    whenText: "12월 5일 오전 10:00", nextRunAt: at(10, 0, addingDays: 19)
                ),
                AgentRoutine(
                    id: "rt_news", title: "저녁 뉴스", prompt: "오늘 주요 뉴스 알려줘", enabled: false, kind: "daily",
                    whenText: "매일 오후 6:00", lastStatus: "missed"
                ),
            ],
            runs: [
                RoutineRun(
                    id: briefingRunID, routineID: "rt_briefing", title: "아침 브리핑", status: "done", ranAt: at(7, 30, addingDays: 0),
                    conversationID: "conv-routine-1",
                    replies: [
                        .init(text: "오늘 온 메일은 3통이에요. 가상문구의 배송 안내, 가을 워크숍 일정 확인, 주간 회의 초대예요.", writer: nil),
                        .init(text: "날씨는 맑고 낮 최고 12도예요. 저녁에는 5도까지 내려가요.", writer: nil),
                    ]
                ),
                // 지난 날의 기록 (D93: 맥이 파일에 남겨, 예약마다 날짜별로 볼 수 있다)
                RoutineRun(
                    id: "rr_demo_briefing_1", routineID: "rt_briefing", title: "아침 브리핑", status: "done", ranAt: at(7, 30, addingDays: -1),
                    conversationID: "conv-routine-2",
                    replies: [.init(text: "어제 온 메일은 1통이에요. 가상문구의 주문 확인이에요. 날씨는 흐리고 낮 최고 9도예요.", writer: nil)]
                ),
                RoutineRun(id: "rr_demo_briefing_2", routineID: "rt_briefing", title: "아침 브리핑", status: "missed", ranAt: at(8, 40, addingDays: -2)),
                RoutineRun(
                    id: "rr_demo_briefing_3", routineID: "rt_briefing", title: "아침 브리핑", status: "done", ranAt: at(7, 30, addingDays: -3),
                    conversationID: "conv-routine-3",
                    replies: [.init(text: "온 메일이 없어요. 날씨는 맑고 낮 최고 11도예요.", writer: nil)]
                ),
                // 작업이 된 실행: 작업은 맥이 다시 켜지면 사라지지만, 끝난 결과는 기록에 남는다
                RoutineRun(
                    id: "rr_demo_weekly", routineID: "rt_weekly", title: "주간 회의 정리", status: "task", ranAt: at(9, 0, addingDays: -3),
                    conversationID: "conv-routine-4", taskID: "task-gone-weekly", taskStatus: "completed",
                    taskResult: ["주간 회의 정리를 내 주소로 보냈어요."]
                ),
            ]
        )
    }
}

/// 보고에 화면 캡처를 붙이는 가짜 맥의 설정 (`-demoCapture`)
/// "찾아 달라"는 작업의 가짜 결과 (물건·가게·가격·사이트 모두 지어낸 것이다. 주소는 실제로 없는 `.example`이다)
enum MockFind {
    /// 실제 맥처럼 원소 하나에 줄바꿈이 있는 한 덩어리 글이다 (주소는 적지 않는다)
    static let answer = [
        "소리콩 2는 가상몰에서 89,000원에 팔고 있어요.\n가격 비교에서는 가장 싼 곳이 84,500원이에요(배송비 별도).\n후기에는 통화 음질이 좋다는 말이 많아요."
    ]

    /// 실제 서버가 걸러 낼 주소라 읽는 길(`AgentLink.page`)을 거치지 않고 바로 만든다. 마지막 것은 대표 그림이 없는 페이지다
    static let links = [
        AgentLink(
            title: "소리콩 2 무선 이어폰 - 가상몰", url: URL(string: "https://shop.example/earbuds/sorikong-2")!,
            image: URL(string: "https://img.shop.example/sorikong-2.jpg")
        ),
        AgentLink(
            title: "소리콩 2 가격 비교: 파는 곳 12곳 - 가상가격", url: URL(string: "https://www.price.example/compare/sorikong-2")!,
            image: URL(string: "https://cdn.price.example/og/sorikong-2.png")
        ),
        AgentLink(title: "한 달 써 본 소리콩 2 - 가상후기", url: URL(string: "https://review.example/posts/1024")!)
    ]

    /// 가짜 대표 그림 (앱이 그린 것. 밖으로 나가지 않는다)
    static let thumbnail: LinkThumbnailStore.Loader = { url in
        guard let index = links.firstIndex(where: { $0.image == url }) else { return MockShop.picture(url) }
        let size = CGSize(width: 400, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { _ in
            func fill(_ color: UIColor, _ path: UIBezierPath) {
                color.setFill()
                path.fill()
            }
            if index == 0 {
                // 가게 그림: 이어폰 두 알과 통
                fill(UIColor(red: 0.90, green: 0.94, blue: 0.99, alpha: 1), UIBezierPath(rect: CGRect(origin: .zero, size: size)))
                fill(UIColor(white: 1, alpha: 1), UIBezierPath(roundedRect: CGRect(x: 90, y: 190, width: 220, height: 130), cornerRadius: 56))
                fill(UIColor(red: 0.16, green: 0.20, blue: 0.30, alpha: 1), UIBezierPath(ovalIn: CGRect(x: 108, y: 84, width: 76, height: 76)))
                fill(UIColor(red: 0.16, green: 0.20, blue: 0.30, alpha: 1), UIBezierPath(ovalIn: CGRect(x: 216, y: 84, width: 76, height: 76)))
                fill(UIColor(red: 0.16, green: 0.20, blue: 0.30, alpha: 1), UIBezierPath(roundedRect: CGRect(x: 134, y: 140, width: 24, height: 70), cornerRadius: 12))
                fill(UIColor(red: 0.16, green: 0.20, blue: 0.30, alpha: 1), UIBezierPath(roundedRect: CGRect(x: 242, y: 140, width: 24, height: 70), cornerRadius: 12))
            } else {
                // 가격 비교 그림: 막대 넷
                fill(UIColor(red: 0.92, green: 0.97, blue: 0.93, alpha: 1), UIBezierPath(rect: CGRect(origin: .zero, size: size)))
                for (bar, height) in [150.0, 210.0, 120.0, 250.0].enumerated() {
                    let rect = CGRect(x: 70 + Double(bar) * 70, y: 320 - height, width: 44, height: height)
                    fill(UIColor(red: 0.18, green: 0.55, blue: 0.36, alpha: bar == 2 ? 1 : 0.45), UIBezierPath(roundedRect: rect, cornerRadius: 10))
                }
            }
        }
    }
}

/// 살 것을 찾는 작업의 가짜 결과 (D72. 물건·브랜드·가게·값 모두 지어낸 것이다. 주소는 실제로 없는 `.example`이다)
enum MockShop {
    static let answer = ["무선 이어폰 4개를 찾았어요."]

    /// 실제 서버가 걸러 낼 주소라 읽는 길(`AgentItem.make`)을 거치지 않고 바로 만든다. 마지막 것은 그림이 없는 상품이다
    static let items = [
        AgentItem(
            id: "i1", title: "소리콩 2 무선 이어폰 노이즈 캔슬링", price: 89_000, mall: "가상몰",
            url: URL(string: "https://shop.example/earbuds/sorikong-2")!, image: URL(string: "https://img.shop.example/items/sorikong-2.jpg"),
            brand: "소리콩"
        ),
        AgentItem(
            id: "i2", title: "소리콩 2 프로 무선 이어폰 (충전 케이스 포함)", price: 129_000, mall: "가상전자",
            url: URL(string: "https://store.example/p/20417")!, image: URL(string: "https://img.store.example/20417.jpg"),
            brand: "소리콩"
        ),
        AgentItem(
            id: "i3", title: "달빛음향 에어핏 오픈형 블루투스 이어폰", price: 54_900, mall: "가상마켓",
            url: URL(string: "https://market.example/goods/88120")!, image: URL(string: "https://cdn.market.example/88120.png"),
            brand: "달빛음향"
        ),
        AgentItem(
            id: "i4", title: "모아톤 버즈 라이트", price: 39_800, mall: "모아톤 공식몰",
            url: URL(string: "https://moatone.example/buds-lite")!, brand: "모아톤"
        )
    ]

    /// 가짜 상품 그림 (앱이 그린 것. 밖으로 나가지 않는다): 바탕색과 이어폰 두 알, 통
    static func picture(_ url: URL) -> Data? {
        guard let index = items.firstIndex(where: { $0.image == url }) else { return nil }
        let grounds = [
            UIColor(red: 0.90, green: 0.94, blue: 0.99, alpha: 1), UIColor(red: 0.95, green: 0.92, blue: 0.99, alpha: 1),
            UIColor(red: 0.99, green: 0.95, blue: 0.88, alpha: 1)
        ]
        let inks = [
            UIColor(red: 0.16, green: 0.20, blue: 0.30, alpha: 1), UIColor(red: 0.33, green: 0.24, blue: 0.55, alpha: 1),
            UIColor(red: 0.80, green: 0.45, blue: 0.16, alpha: 1)
        ]
        let size = CGSize(width: 400, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { _ in
            func fill(_ color: UIColor, _ path: UIBezierPath) {
                color.setFill()
                path.fill()
            }
            let ink = inks[index % inks.count]
            fill(grounds[index % grounds.count], UIBezierPath(rect: CGRect(origin: .zero, size: size)))
            fill(.white, UIBezierPath(roundedRect: CGRect(x: 90, y: 200, width: 220, height: 124), cornerRadius: index == 2 ? 28 : 56))
            for x in [108.0, 216.0] {
                fill(ink, UIBezierPath(ovalIn: CGRect(x: x, y: 84, width: 76, height: 76)))
                if index != 2 { fill(ink, UIBezierPath(roundedRect: CGRect(x: x + 26, y: 140, width: 24, height: 70), cornerRadius: 12)) }
            }
        }
    }
}

struct MockCaptures: Sendable {
    /// 답변 카드 (지어낸 결제 내역, D110)
    static let card = AgentReportCard(
        kind: .answer, title: "최근 결제 내역", subtitle: "가상페이 · 이번 주",
        blocks: [
            .stat(label: "이번 주 쓴 돈", value: "84,300원", note: "3건"),
            .list([
                SpaceBlock.Item(title: "달빛 서점", subtitle: "11월 15일", trailing: "32,000원"),
                SpaceBlock.Item(title: "가람 문구", subtitle: "11월 14일", trailing: "12,300원"),
                SpaceBlock.Item(title: "한빛 마트", subtitle: "11월 13일", trailing: "40,000원"),
            ]),
        ],
        actions: [AgentReportCard.Action(label: "가상페이에서 보기", url: URL(string: "https://pay.example.com/history"))]
    )

    /// 긴 답변 카드 (D133): 대화에서는 글을 자르지 않는다. 숫자·제목은 모두 지어낸 것이다
    static let longCard = AgentReportCard(
        kind: .answer, title: "이번 주 업무 정리", subtitle: "11/11 ~ 11/17 · 11/17 23:22 기준 · 회의 4건",
        blocks: [
            .pairs([
                SpaceBlock.Pair(label: "회의", value: "4건"), SpaceBlock.Pair(label: "끝낸 할 일", value: "9개"),
                SpaceBlock.Pair(label: "남은 할 일", value: "3개 (기한 지남 1)"), SpaceBlock.Pair(label: "보낸 메일", value: "12통"),
            ]),
            .list([
                SpaceBlock.Item(title: "가상 쇼핑몰 리뉴얼 시안 검토", subtitle: "금요일까지 · 디자인 팀과 함께 · 시안 2개 남음", trailing: "진행 중"),
                SpaceBlock.Item(title: "주간 보고서 보내기", subtitle: "어제 마감", trailing: "지남"),
                SpaceBlock.Item(title: "분기 예산 정리", subtitle: "다음 주 월요일", trailing: "예정"),
            ]),
            .text("""
            이번 주에는 회의가 화요일과 목요일에 몰려 있었어요. 회의에서 나온 할 일 12개 가운데 9개를 끝냈어요.
            주간 보고서는 어제가 마감이었는데 아직 보내지 않았어요. 초안은 메일 임시 보관함에 있어요.
            다음 주 월요일 오전에 분기 예산 회의가 있어요. 자료는 공유 폴더의 지난 분기 파일을 바탕으로 준비하면 좋겠어요.
            다음 주에 할 일 추천: 보고서 보내기 · 시안 의견 정리 · 예산 자료 모으기
            """),
        ],
        actions: []
    )

    enum Script: String, Sendable {
        /// 답을 읽은 화면을 붙인다 (로그인한 화면이라 가려 둔다)
        case normal
        /// 로그인이 풀려 멈췄다. 멈춘 화면(사이트가 돌려보낸 로그인 화면)을 붙인다
        case blocked
        /// 가리지 않아도 되는 화면이라고 알린다 (바로 보인다)
        case open
        /// 캡처를 붙였지만 맥이 이미 지웠다
        case gone
        /// 처음 한 번은 그림을 받지 못한다
        case flaky
        /// 로그인한 적이 없다: 작업을 만들지 않고 "로그인이 필요해요"라고 답한다 (로그인하면 읽힌다)
        case login
        /// 화면 두 장을 보고, 굵은 낱말이 든 문단 여럿으로 답한다 (D84)
        case pair
        /// 답을 답변 카드로 준다 (D110)
        case card
        /// 작업실 (D112): 단계 여럿 + 만든 영상과 그림
        case workroom
        /// 보안 확인 화면에서 막혀 못 했다: 부제 없는 "하지 못했어요" 카드와 같은 사이트의 근거 주소 (D118)
        case failcard
        /// 긴 글·이름값 넷·긴 부제가 든 답변 카드 (D133. 숫자·제목은 지어낸 것)
        case longcard
    }

    var script: Script = .normal

    init(script: Script = .normal) {
        self.script = script
    }

    /// 화면 확인용 (`-demoCapture` [`blocked|open|gone|flaky|login|pair|card|workroom|failcard|longcard`])
    init(demo: String?) {
        self.init(script: Script(rawValue: demo ?? "") ?? .normal)
    }

    /// 가상 답 (가게·금액 모두 지어낸 것이다). 모양은 실제 맥의 모델이 쓰는 것과 같다: 항목마다 한 줄, 칸은 `|`로 나눈다
    static let answer = """
    1. 이름: 가상문구 | 금액: 7,400원 | 날짜: 11. 10. 18:59 | 상태: 결제완료
    2. 이름: [가상서점] 처음 만나는 가상 도서(개정판 한정 표지) | 금액: 18,000원 | 날짜: 11. 8. 12:30 | 상태: 구매확정완료
    3. 이름: 가상카페 원두 | 금액: 4,500원 | 날짜: 11. 5. 09:12 | 상태: 결제완료
    """

    /// 문단 여럿으로 쓴 가상 답 (가게·금액 모두 지어낸 것이다): 결론과 짧은 줄 / 풀어 쓴 문단 / 다음에 할 일을 묻는 말.
    /// 굵게 할 낱말은 `**`로 감쌌다. 지금의 실제 맥은 이렇게 쓰지 않는다 (굵게도 빈 줄도 없다)
    static let briefing = """
    이번 달 가상페이 결제는 **4건, 62,800원**이에요.
    - 가장 큰 결제는 가상마트 **32,900원** (11월 2일)
    - 지난달 같은 기간보다 **8,200원** 적어요

    가게별로는 가상마트 **32,900원**, 가상서점 **18,000원**, 가상문구 **7,400원**, 가상카페 **4,500원**이에요.

    가상서점 주문은 아직 **배송 중**이에요. 배송 조회까지 확인해 볼까요?
    """

    static let pageSize = CGSize(width: 1280, height: 800)

    /// 화면 확인용 페이지 그림 (앱이 그린 가짜 웹 화면. 사이트·가게·금액 모두 지어낸 것이다)
    static func pageImage(loginPage: Bool, stats: Bool = false) -> Data {
        let size = pageSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
            let ink = UIColor(white: 0.12, alpha: 1)
            let soft = UIColor(white: 0.45, alpha: 1)
            let brand = UIColor(red: 0.13, green: 0.42, blue: 0.81, alpha: 1)
            func fill(_ color: UIColor, _ rect: CGRect, radius: CGFloat = 0) {
                color.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
            }
            func draw(_ text: String, x: CGFloat, y: CGFloat, size fontSize: CGFloat, weight: UIFont.Weight = .regular, color: UIColor, rightEdge: CGFloat? = nil) {
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize, weight: weight), .foregroundColor: color]
                let width = (text as NSString).size(withAttributes: attributes).width
                (text as NSString).draw(at: CGPoint(x: rightEdge.map { $0 - width } ?? x, y: y), withAttributes: attributes)
            }
            fill(UIColor(white: 0.96, alpha: 1), CGRect(origin: .zero, size: size))
            // 위 줄: 사이트 이름
            fill(.white, CGRect(x: 0, y: 0, width: size.width, height: 96))
            fill(brand, CGRect(x: 48, y: 28, width: 40, height: 40), radius: 10)
            draw("가상페이", x: 104, y: 26, size: 34, weight: .bold, color: ink)
            draw("보기용 가상 화면", x: 0, y: 34, size: 24, color: soft, rightEdge: size.width - 48)
            if stats, !loginPage {
                // 이용 통계: 꺾은선 하나와 오른쪽의 합계 칸 (값은 모두 지어낸 것이다)
                draw("이용 통계", x: 48, y: 136, size: 48, weight: .bold, color: ink)
                draw("최근 4주", x: 48, y: 204, size: 26, color: soft)
                fill(.white, CGRect(x: 48, y: 264, width: 800, height: 480), radius: 20)
                let heights: [CGFloat] = [0.18, 0.2, 0.16, 0.22, 0.2, 0.62, 0.34, 0.78, 0.42, 0.66, 0.5, 0.58]
                let line = UIBezierPath()
                for (index, height) in heights.enumerated() {
                    let point = CGPoint(x: 96 + CGFloat(index) * 62, y: 700 - height * 380)
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                brand.setStroke()
                line.lineWidth = 5
                line.lineJoinStyle = .round
                line.stroke()
                fill(UIColor(white: 0.9, alpha: 1), CGRect(x: 96, y: 702, width: 704, height: 2))
                for (index, box) in [("결제", "4건"), ("합계", "62,800원")].enumerated() {
                    let top = 264 + CGFloat(index) * 248
                    fill(.white, CGRect(x: 880, y: top, width: 352, height: 232), radius: 20)
                    draw(box.0, x: 916, y: top + 36, size: 26, color: soft)
                    draw(box.1, x: 916, y: top + 92, size: 52, weight: .bold, color: ink)
                }
            } else if loginPage {
                fill(.white, CGRect(x: 340, y: 168, width: 600, height: 520), radius: 24)
                draw("로그인", x: 396, y: 212, size: 44, weight: .bold, color: ink)
                draw("다시 로그인해 주세요", x: 396, y: 276, size: 26, color: soft)
                for (index, label) in ["아이디", "비밀번호"].enumerated() {
                    let top = 340 + CGFloat(index) * 100
                    fill(UIColor(white: 0.94, alpha: 1), CGRect(x: 396, y: top, width: 488, height: 76), radius: 14)
                    draw(label, x: 420, y: top + 22, size: 26, color: soft)
                }
                fill(brand, CGRect(x: 396, y: 556, width: 488, height: 80), radius: 14)
                draw("로그인", x: 600, y: 576, size: 30, weight: .semibold, color: .white)
            } else {
                draw("결제내역", x: 48, y: 136, size: 48, weight: .bold, color: ink)
                draw("최근 1개월", x: 48, y: 204, size: 26, color: soft)
                let rows = [("11월 10일", "가상문구", "7,400원"), ("11월 8일", "가상서점", "18,000원"), ("11월 5일", "가상카페", "4,500원"), ("11월 2일", "가상마트", "32,900원")]
                for (index, row) in rows.enumerated() {
                    let top = 264 + CGFloat(index) * 128
                    fill(.white, CGRect(x: 48, y: top, width: size.width - 96, height: 108), radius: 20)
                    draw(row.0, x: 84, y: top + 16, size: 24, color: soft)
                    draw(row.1, x: 84, y: top + 50, size: 34, weight: .semibold, color: ink)
                    draw(row.2, x: 0, y: top + 32, size: 38, weight: .bold, color: ink, rightEdge: size.width - 84)
                }
            }
        }
    }
}
// 작업실의 가짜 결과 (D112). 단계와 영상 모두 지어낸 것이다
extension MockCaptures {
    static let workroomSteps = [
        "자료를 읽고 쪽 구성을 정했어요", "report_plan.json", "표 만들기 · table.csv", "그래프 그리기 · chart.png",
        "요약 문단 쓰기", "머리말 다듬기", "문서로 엮기 · report.pdf", "소개 영상 만들기 승인을 받았어요",
        "영상 만들기 · intro.mp4", "자막 입히기 · ffmpeg -i intro.mp4", "결과 확인",
    ]

    /// 1초짜리 세로 영상 (앱이 만든 단색 화면. 재생 확인용)
    static func video() async throws -> Data {
        let file = URL.temporaryDirectory.appending(path: "mock-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let size = CGSize(width: 360, height: 640)
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let count = CVPixelBufferGetBytesPerRow(buffer) * Int(size.height)
                // 민트에서 짙은 색으로 (BGRA)
                let t = Double(frame) / 29
                for i in stride(from: 0, to: count, by: 4) {
                    bytes[i] = UInt8(163 * (1 - t) + 40 * t)
                    bytes[i + 1] = UInt8(217 * (1 - t) + 30 * t)
                    bytes[i + 2] = UInt8(67 * (1 - t) + 20 * t)
                    bytes[i + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return try Data(contentsOf: file)
    }
}


/// 가짜 목소리 조각: 0.1초짜리 조용한 wav (24kHz 모노 16bit)
enum MockVoice {
    static let wav: Data = {
        let samples = 2400
        var data = Data("RIFF".utf8)
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        data += le32(36 + samples * 2)
        data += Data("WAVEfmt ".utf8)
        data += le32(16) + le16(1) + le16(1) + le32(24_000) + le32(48_000) + le16(2) + le16(16)
        data += Data("data".utf8)
        data += le32(samples * 2)
        data += Data(count: samples * 2)
        return data
    }()
}

/// 기억하는 맥의 요약본과 보관함 (D151). 사람·일은 모두 지어낸 것이다
struct MockMemory: Sendable {
    struct Line: Sendable {
        let when: String
        let mine: Bool
        let text: String
        let next: String?
    }

    var profile: String
    var previous: [String] = []
    var source: AgentMemory.Source?
    var updatedAt: Date?
    var archive: [Line]

    /// `empty`: 아직 아무것도 기억하지 않은 맥
    init(demo: String?) {
        guard demo != "empty" else {
            profile = ""
            archive = []
            return
        }
        profile = """
        ## 나
        - 회의가 끝나면 할 일을 바로 정리받고 싶어 한다
        - 아침 9시 전에는 알림을 받지 않는다
        ## 사람
        - 김하늘: 디자인 팀장, 메일로 시안을 주고받는다
        ## 진행 중인 일
        - 가상 쇼핑몰 리뉴얼 시안 검토 (금요일까지)
        ## 좋아하는 것·자주 쓰는 조건
        - 답은 짧게, 결론부터
        ## 하지 말 것
        - 메일은 승인 없이 보내지 않는다
        """
        source = .digest
        updatedAt = Date(timeIntervalSince1970: 1_763_449_800)
        archive = [
            Line(when: "2026-11-11 20:10", mine: true, text: "리뉴얼 시안은 금요일까지 김하늘 팀장에게 보내면 돼", next: "네, 금요일 오전에 다시 알려 드릴게요."),
            Line(when: "2026-11-12 09:30", mine: false, text: "시안 검토 회의는 목요일 오후 2시로 잡았어요.", next: nil),
        ]
    }
}
#endif
