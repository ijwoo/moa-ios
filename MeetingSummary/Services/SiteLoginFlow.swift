import Foundation
import Observation

// 사이트 로그인의 진행 (D48).
//
// 맥의 에이전트 브라우저가 로그인 화면을 열고, 그 화면이 묻는 것(아이디·비밀번호, 보안문자, 인증 번호, 선택)을
// 앱이 사용자에게 받아 한 번 전한다. 2단계 인증 승인은 사용자가 자기 휴대폰에서 직접 한다 (앱이 대신하지 않는다).
//
// 아이디·비밀번호는 `submit`의 인자로 지나간다: 대화 기록·메시지·로그 어디에도 두지 않고,
// 대화 담당(모델)이나 Claude에게 가는 요청과도 다른 길이다. 맥에 남는 것은 브라우저의 로그인 상태뿐이다.
//
// 이 아이폰에 저장해 두기 (D78, 사용자가 정했다): 저장할 수 있는 기기에서는 보낸 아이디·비밀번호를
// 로그인이 끝날 때까지만 이 객체가 들고 있다가, 로그인됐고 사용자가 저장을 켜 두었을 때만 키체인에 넣는다 (`LoginVault`).
// 그 밖에는 끝나는 대로 버린다. 저장해 둔 값은 Face ID 확인 뒤에, 저장할 때와 같은 호스트의 화면에만 넣는다.

/// 화면에 쓰는 사이트 이름. 맥이 이름을 알려 줬으면 그것을 쓰고, 이것은 이름을 모를 때(대화의 카드)만 쓴다
/// 사이트 키("coupang-com")를 사람이 읽는 이름("쿠팡")으로 (D107).
/// 맥이 사이트 목록(`GET /v1/sites`)에 적어 준 이름을 먼저 쓰고, 없으면 앱이 아는 이름, 그것도 없으면 키에서 끝의 도메인 꼬리를 뗀 것
enum SiteName {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fromMac: [String: String] = [:]

    /// 맥이 알려 준 이름을 기억한다 (사이트 목록을 받을 때마다). 이름이 키와 같으면 기억하지 않는다
    static func remember(_ names: [String: String]) {
        lock.withLock {
            for (site, name) in names where !name.isEmpty && name != site { fromMac[site] = name }
        }
    }

    private static let known: [String: String] = [
        "naver": "네이버", "naver_mail": "네이버 메일 연결", "coupang": "쿠팡", "kakao": "카카오", "daum": "다음", "gmarket": "G마켓",
        "11st": "11번가", "auction": "옥션", "ssg": "SSG", "musinsa": "무신사", "baemin": "배달의민족", "toss": "토스",
        "saramin": "사람인", "jobkorea": "잡코리아", "vworld": "브이월드", "google": "구글", "github": "GitHub",
        "youtube": "유튜브", "claude": "Claude",
    ]

    /// 맥이 이름 자리에 주소("saramin.co.kr")를 적어 보내면, 아는 서비스는 서비스 이름("사람인")으로 바꾼다 (D142).
    /// 모르는 주소는 그대로 둔다 (맥이 서비스 이름을 보내면 그것이 보인다)
    static func service(_ name: String) -> String {
        let low = name.lowercased()
        guard SiteHost.isDomain(low) else { return name }
        let label = low.hasPrefix("www.") ? String(low.dropFirst(4)) : low
        return label.split(separator: ".").first.flatMap { known[String($0)] } ?? name
    }

    static func display(_ site: String) -> String {
        if let name = lock.withLock({ fromMac[site] }) { return name }
        if let name = known[site] { return name }
        // "coupang-com" · "www.coupang.com" · "vworld-kr" → 앞의 이름만
        let base = site.lowercased()
            .replacingOccurrences(of: "www.", with: "")
            .split(whereSeparator: { $0 == "-" || $0 == "." || $0 == "_" })
            .map(String.init)
            .filter { !["com", "co", "kr", "net", "org", "io", "www"].contains($0) }
        guard let first = base.first else { return site }
        return known[first] ?? first
    }
}

/// 이 흐름이 하는 일. 맥과는 둘 다 같은 형식(`/v1/sites/{site}/login`)으로 주고받지만, 남는 것이 달라 화면의 말도 다르다
enum SiteFlowKind: Equatable, Sendable {
    /// 사이트 로그인: 맥의 브라우저에 로그인 상태만 남는다
    case login
    /// 메일 연결: 로그인해 둔 브라우저로 맥이 메일 설정을 대신 누르고, 새로 만든 앱 비밀번호를 메일 계정으로 보관한다.
    /// 로그인이 아니므로 "로그인했어요", "아이디와 비밀번호는 맥에 저장하지 않았어요" 같은 말은 맞지 않는다.
    /// 이 아이폰에 저장해 두는 것(D78)도 로그인에만 있다
    case mailSetup

    private static let mailSetupSites: Set<String> = ["naver_mail"]

    static func of(_ site: String) -> SiteFlowKind {
        mailSetupSites.contains(site) ? .mailSetup : .login
    }
}

extension SiteStatus {
    var kind: SiteFlowKind { SiteFlowKind.of(site) }
}

/// 로그인 화면(`SiteLoginSheet`)에 앱이 정해 두고 쓰는 말. 흐름의 종류에 따라 다르다.
/// 맥이 준 말(`message`·`text`·입력칸 이름·선택지)은 여기를 거치지 않고 그대로 보인다
struct SiteLoginCopy: Equatable, Sendable {
    let kind: SiteFlowKind
    /// "네이버" · "네이버 메일 연결"
    let name: String

    init(kind: SiteFlowKind, name: String) {
        self.kind = kind
        self.name = name
    }

    /// 사이트 번호만 알 때 (대화의 카드): 이름은 앱이 아는 것으로
    init(site: String) {
        self.init(kind: .of(site), name: SiteName.display(site))
    }

    // MARK: 대화에 붙는 카드와 말

    /// 맥이 답을 비워 보냈을 때 대신 쓰는 말
    var chatOpening: String {
        switch kind {
        case .login: "\(name) 로그인 화면을 열게요."
        case .mailSetup: "\(name)을 시작할게요."
        }
    }

    var cardTitle: String {
        switch kind {
        case .login: "\(name) 로그인이 필요해요"
        case .mailSetup: name
        }
    }

    var cardBody: String {
        switch kind {
        case .login: "맥의 에이전트 브라우저에서 \(name)에 로그인해요. 아이디와 비밀번호를 넣고, 2단계 인증은 휴대폰에서 직접 승인해 주세요."
        case .mailSetup: "에이전트가 \(MailKeeper.name)의 브라우저에서 메일 설정을 대신 해요. 설정을 바꾸거나 비밀번호를 만들기 전에 물어봐요."
        }
    }

    // 작업이 로그인 때문에 멈췄을 때의 카드 (D57): 로그인하면 그 일을 이어서 한다

    func stoppedCardTitle(expired: Bool) -> String {
        expired ? "\(name) 로그인이 풀렸어요" : "\(name) 로그인이 필요해요"
    }

    func stoppedCardBody(expired: Bool) -> String {
        "\(expired ? "다시 로그인" : "로그인")하면 하던 일을 바로 이어서 할게요. 아이디와 비밀번호를 넣고, 2단계 인증은 휴대폰에서 직접 승인해 주세요."
    }

    var cardButton: String {
        switch kind {
        case .login: "\(name) 로그인"
        case .mailSetup: "연결 화면 열기"
        }
    }

    var cardButtonHint: String {
        switch kind {
        case .login: "아이디와 비밀번호를 넣는 화면을 엽니다"
        case .mailSetup: "연결을 진행하는 화면을 엽니다"
        }
    }

    var cardFooter: String {
        switch kind {
        case .login: "아이디와 비밀번호는 채팅이 아니라 따로 뜨는 화면에서 넣어요. 대화 기록에는 남지 않고, 저장은 내가 켰을 때만 이 아이폰의 키체인에 해요."
        case .mailSetup: "주소와 비밀번호는 채팅이 아니라 따로 뜨는 화면에서 넣어요. 비밀번호는 어디에도 저장하지 않고 대화 기록에도 남지 않아요."
        }
    }

    var doneCardTitle: String {
        switch kind {
        case .login: "\(name) 로그인 완료"
        case .mailSetup: "메일 계정 연결 완료"
        }
    }

    /// 끝난 것을 대화에 남기는 한 줄 (완료 카드로 그리고, 기록에는 이 글이 남는다)
    var chatDone: String {
        switch kind {
        case .login: "\(name)에 로그인했어요. 맥의 에이전트 브라우저에 로그인 상태만 남아 있고, 아이디와 비밀번호는 맥에 저장하지 않았어요."
        case .mailSetup: "\(doneTitle). \(doneDetail)"
        }
    }

    // MARK: 따로 뜨는 화면

    var title: String {
        switch kind {
        case .login: "\(name) 로그인"
        case .mailSetup: name
        }
    }

    var opening: String {
        switch kind {
        case .login: "맥에서 \(name) 로그인 화면을 열고 있어요"
        case .mailSetup: "맥에서 준비하고 있어요"
        }
    }

    var offline: String {
        switch kind {
        case .login: "맥에 연결이 잠시 끊겼어요. 맥에서는 로그인이 계속되고 있고, 다시 연결되면 이어서 보여 드려요."
        case .mailSetup: "맥에 연결이 잠시 끊겼어요. 맥에서는 작업이 계속되고 있고, 다시 연결되면 이어서 보여 드려요."
        }
    }

    /// 입력칸 아래의 안내: 넣은 값이 어디에 쓰이고 무엇이 남는지.
    /// `keeps`: 로그인되면 이 아이폰에 저장하도록 켜 두었다. `saved`: 전에 저장해 둔 값이 있다. `unlock`: "Face ID"
    func inputFooter(for login: SiteLogin, keeps: Bool = false, saved: Bool = false, unlock: String = "Face ID") -> String {
        // 간편인증의 본인 확인 칸 (D90): 로그인 정보가 아니다. 저장을 켜 두었어도 이 값은 저장하지 않는다
        if login.fields.contains(where: { SiteLogin.identityNames.contains($0.name) }) {
            return "이름·생년월일·휴대폰 번호는 맥의 브라우저에서 본인 확인 화면에 한 번 입력하는 데만 써요. "
                + "이 아이폰에 저장하지 않고, 보낸 뒤에는 화면에서도 지워요. 대화 기록이나 AI에게도 전달되지 않아요."
        }
        switch kind {
        case .login:
            if keeps {
                return "아이디와 비밀번호는 맥의 브라우저에 입력하는 데만 써요. 로그인되면 이 아이폰의 키체인에만 보관하고, \(unlock)로 확인한 뒤에만 꺼내요. 다른 기기로 옮겨지지 않아요. 맥에는 저장하지 않고, 대화 기록이나 AI에게도 전달되지 않아요."
            }
            if saved {
                return "지금 넣는 값은 저장하지 않아요. 전에 저장해 둔 값은 이 아이폰의 키체인에만 있고, \(unlock)로 확인한 뒤에만 꺼내요. 맥에는 저장하지 않고, 대화 기록이나 AI에게도 전달되지 않아요."
            }
            return "아이디와 비밀번호는 맥의 브라우저에 한 번 입력하는 데만 써요. 이 아이폰에도 맥에도 저장하지 않고, 대화 기록이나 AI에게도 전달되지 않아요. 맥에 남는 것은 로그인 상태뿐이에요."
        case .mailSetup:
            let names = Set(login.fields.map(\.name))
            if names.contains("password") {
                return "비밀번호는 맥의 브라우저에 한 번 입력하는 데만 써요. 이 아이폰에도 맥에도 저장하지 않고, 대화 기록이나 AI에게도 전달되지 않아요."
            }
            if names.contains("id") {
                return "연결이 끝나면 이 주소가 맥의 기본 메일 계정으로 등록돼요."
            }
            return "입력한 값은 맥의 브라우저에 한 번 입력하는 데만 써요."
        }
    }

    /// 입력을 보내는 버튼
    func submitTitle(for login: SiteLogin) -> String {
        let asksID = login.fields.contains { $0.name == "id" }
        switch kind {
        case .login: return asksID ? "로그인" : "확인"
        case .mailSetup: return asksID ? "다음" : "확인"
        }
    }

    var wrongInput: String {
        switch kind {
        case .login: "입력한 내용이 맞지 않아요. 다시 입력해 주세요. 여러 번 틀리면 로그인을 멈춰요."
        case .mailSetup: "입력한 내용이 맞지 않아요. 다시 입력해 주세요. 여러 번 틀리면 연결을 멈춰요."
        }
    }

    var approvalFallback: String {
        switch kind {
        case .login: "휴대폰의 \(name) 앱 알림에서 로그인을 승인해 주세요"
        case .mailSetup: "휴대폰에서 승인해 주세요"
        }
    }

    var approvalFooter: String {
        switch kind {
        case .login: "승인은 직접 하셔야 해요. 앱이나 에이전트가 대신하지 않아요. \(name) 앱에 다녀오는 동안에도 맥에서는 로그인이 이어져요."
        case .mailSetup: "승인은 직접 하셔야 해요. 앱이나 에이전트가 대신하지 않아요. 다녀오는 동안에도 맥에서는 작업이 이어져요."
        }
    }

    /// 고르는 화면 아래의 안내: 누가 묻는 것인지. 로그인에는 두지 않는다 (D107 — 사이트 화면의 물음만 보인다).
    /// 메일 연결은 맥이 설정을 바꾸기 전에 묻는 것이라 남긴다
    var choiceFooter: String? {
        switch kind {
        case .login: nil
        case .mailSetup: "에이전트가 설정을 바꾸기 전에 묻는 것이에요. 고른 대로 맥의 브라우저에서 눌러요."
        }
    }

    /// 고르는 화면의 글: (굵은 물음, 설명). 로그인은 사이트 화면의 글만 보인다.
    /// 메일 연결은 맥이 물음(`message`)과 설명(`text`)을 따로 준다
    /// 손 넘기기 물음의 안내 (D149, 작업 질문 카드와 같은 말)
    func handoverFooter(for login: SiteLogin) -> String {
        "에이전트는 그동안 누르지 않아요. 다 푸셨으면 \"\(login.choices.first ?? "다 했어요")\"를 눌러 주세요. 받은 화면은 폰에 저장하지 않아요."
    }

    func choiceTexts(for login: SiteLogin) -> (headline: String?, body: String) {
        guard kind == .mailSetup, let text = login.text, !login.message.isEmpty, login.message != text else {
            return (nil, login.text ?? login.message)
        }
        return (login.message, text)
    }

    var doneTitle: String {
        switch kind {
        case .login: "\(name)에 로그인했어요"
        case .mailSetup: "메일 계정을 연결했어요"
        }
    }

    /// 끝난 뒤 무엇이 남았는지 (대화의 완료 카드처럼, 이 아이폰에 저장했는지 모르는 자리에 쓴다)
    var doneDetail: String {
        switch kind {
        case .login: "맥의 에이전트 브라우저에 로그인 상태만 남아 있어요. 아이디와 비밀번호는 맥에 저장하지 않았어요."
        case .mailSetup: "새로 만든 앱 비밀번호는 \(MailKeeper.store)에만 보관돼요. 계정 비밀번호는 저장하지 않았어요."
        }
    }

    /// 로그인이 끝났을 때 이 아이폰에 남은 것
    enum PhoneKeeping: Equatable, Sendable {
        /// 저장해 둔 것이 없다
        case nothing
        /// 방금 저장했다 (바꿔 넣은 것도)
        case saved
        /// 전에 저장해 둔 것이 그대로 있다
        case unchanged
        /// 저장하려 했지만 하지 못했다
        case failed
    }

    /// 로그인 화면에서 끝난 뒤 무엇이 남았는지: 맥에 남은 것과 이 아이폰에 남은 것
    func doneDetail(phone: PhoneKeeping, unlock: String = "Face ID") -> String {
        guard kind == .login else { return doneDetail }
        let mac = "맥의 에이전트 브라우저에 로그인 상태만 남아 있어요."
        switch phone {
        case .nothing:
            return "\(mac) 아이디와 비밀번호는 저장하지 않았어요."
        case .saved:
            return "\(mac) 아이디와 비밀번호는 이 아이폰의 키체인에 보관했고, \(unlock)로 확인한 뒤에만 꺼내요. 맥에는 저장하지 않았어요."
        case .unchanged:
            return "\(mac) 전에 저장해 둔 아이디와 비밀번호는 이 아이폰의 키체인에 그대로 있어요. 맥에는 저장하지 않았어요."
        case .failed:
            return "\(mac) 아이디와 비밀번호를 이 아이폰에 저장하지 못했어요. 맥에도 저장하지 않았어요."
        }
    }

    // MARK: 이 아이폰에 저장해 두기 (D78)

    var keepToggle: String { "로그인되면 이 아이폰에 저장" }

    /// 저장해 둔 값을 꺼내는 버튼. 화면의 칸을 모두 채우면 바로 보내고, 아니면 채워만 준다
    func savedButton(fillsAll: Bool) -> String {
        fillsAll ? "저장해 둔 값으로 로그인" : "저장해 둔 값 넣기"
    }

    func savedButtonHint(unlock: String, fillsAll: Bool) -> String {
        fillsAll ? "\(unlock)로 확인한 뒤에 저장해 둔 값을 보냅니다" : "\(unlock)로 확인한 뒤에 저장해 둔 값을 칸에 넣습니다"
    }

    /// 얼굴 확인 창에 보이는 까닭
    var unlockReason: String { "저장해 둔 \(name) 로그인 값을 꺼내요" }

    /// 저장해 둔 값이 있을 때 로그인 카드·연동 센터의 단추 (D122): 누르면 얼굴 확인 뒤 바로 넣어 보낸다
    func quickRelogin(unlock: String) -> String { "\(unlock)로 다시 로그인" }
    func quickReloginHint(unlock: String) -> String { "\(unlock)로 확인한 뒤 이 아이폰에 저장해 둔 아이디와 비밀번호로 \(name)에 다시 로그인합니다" }

    /// 저장 스위치를 켜지 않고 로그인됐을 때 묻는 말 (D122)
    var keepAskTitle: String { "이 사이트 로그인 정보를 폰에 저장할까요?" }
    func keepAskDetail(unlock: String) -> String {
        "다음에 로그인이 풀리면 \(unlock)로 바로 다시 로그인해요. 이 아이폰에만 두고, 맥에는 로그인할 때만 보내요."
    }

    var savedRejected: String { "저장해 둔 값을 넣어 보낸 입력이 맞지 않았어요. 이번에는 직접 입력해 주세요." }

    func savedGone(unlock: String) -> String {
        "저장해 둔 값을 더 꺼낼 수 없어서 지웠어요. \(unlock) 등록이 바뀌면 그래요. 직접 입력해 주세요."
    }

    var savedUnreadable: String { "저장해 둔 값을 꺼내지 못했어요. 직접 입력하거나 다시 해 주세요." }

    var startFailedTitle: String {
        switch kind {
        case .login: "로그인을 시작하지 못했어요"
        case .mailSetup: "연결을 시작하지 못했어요"
        }
    }

    var unsupportedDetail: String {
        switch kind {
        case .login: "\(name)가 앱이 다룰 줄 모르는 것을 물어봐서 로그인을 멈췄어요. 로그인은 되지 않았어요."
        case .mailSetup: "앱이 다룰 줄 모르는 것을 물어봐서 멈췄어요. 메일은 연결되지 않았어요."
        }
    }

    var lostTitle: String {
        switch kind {
        case .login: "로그인 기록이 사라졌어요"
        case .mailSetup: "진행 기록이 사라졌어요"
        }
    }

    /// 끝까지 가지 못하고 끝났을 때 (`failed`·`expired`·`cancelled`).
    /// 메일 연결은 맥이 준 말을 그대로 보인다: 어디까지 바꿨고 무엇을 지워야 하는지가 거기에만 있다.
    /// 로그인도 까닭이 맥의 말에만 있는 실패는 그 말을 보인다 (`SiteLoginFlow.failure`, D83)
    func stopped(_ login: SiteLogin) -> (title: String, detail: String, canRetry: Bool) {
        switch (kind, login.state) {
        case (.login, .expired):
            ("시간이 지나 로그인이 끝났어요", "로그인은 되지 않았어요. 다시 시도해 주세요.", true)
        case (.login, .cancelled):
            ("로그인을 취소했어요", "로그인은 되지 않았어요.", true)
        case (.login, _):
            SiteLoginFlow.failure(login.reason, siteName: name, message: login.message)
        case (.mailSetup, .expired):
            ("시간이 지나 끝났어요", "메일은 연결되지 않았어요. 다시 시도해 주세요.", true)
        case (.mailSetup, .cancelled):
            ("연결을 취소했어요", login.message.isEmpty ? "메일은 연결되지 않았어요." : login.message, true)
        case (.mailSetup, _):
            (
                "메일을 연결하지 못했어요",
                login.message.isEmpty ? "메일은 연결되지 않았어요. 잠시 뒤에 다시 시도해 주세요." : login.message,
                login.reason != "blocked"
            )
        }
    }

    func startProblem(for error: Error) -> String {
        switch (kind, error as? AgentError) {
        case (.mailSetup, .rateLimited): "짧은 시간에 여러 번 시작했어요. 10분쯤 뒤에 다시 해 주세요."
        case (.mailSetup, .conflict), (.mailSetup, .unknownSite): "지금 연결된 맥에서는 이 기능을 아직 쓸 수 없어요."
        default: SiteLoginFlow.startProblem(for: error)
        }
    }
}

@MainActor
@Observable
final class SiteLoginFlow {
    /// 화면이 보여 줄 것
    enum Screen: Equatable {
        /// 맥이 로그인 화면을 여는 중
        case opening
        /// 맥이 확인하는 중 (입력을 보낸 뒤 등)
        case working(String)
        /// 입력칸을 채워야 한다
        case input(SiteLogin)
        /// 휴대폰에서 승인해야 한다
        case approval(SiteLogin)
        /// 사이트가 물어본 것을 골라야 한다
        case choice(SiteLogin)
        case done
        /// 로그인하지 못하고 끝났다
        case stopped(title: String, detail: String, canRetry: Bool)
    }

    let site: String
    let siteName: String
    /// 화면에 쓰는 고정 문구 (로그인 / 메일 연결)
    let copy: SiteLoginCopy
    private let agent: any AgentProviding
    private let pollInterval: Duration
    /// 로그인까지 된 뒤 한 번 부른다
    var onLoggedIn: () -> Void = {}

    private(set) var login: SiteLogin?
    /// 시작하지 못한 까닭
    private(set) var startProblem: String?
    private(set) var isStarting = false
    /// 입력을 보내는 중
    private(set) var isSending = false
    /// 입력칸 위에 보여 줄 알림 (전달되지 않았을 때)
    private(set) var inputNotice: String?
    /// 이 로그인에서 비밀번호를 이미 한 번 냈는지 (값이 아니라 냈다는 사실만). 사이트가 로그인 칸을 또 보여 줄 때 까닭을 알리는 데 쓴다
    private(set) var passwordSent = false
    /// 조회가 잇달아 실패하는 중 (맥에서는 로그인이 계속된다)
    private(set) var isOffline = false
    /// 실패로 끝난 시각 (처리할 줄 모르는 화면이었을 때 알릴 수 있게)
    private(set) var stoppedAt: Date?

    /// 입력을 보냈는데 답을 받지 못한 화면 번호 (들어갔는지 아직 모른다)
    private var unconfirmedStep: Int?
    /// 앱이 그릴 수 없는 화면을 만나 멈췄다
    private var unsupported = false
    /// 서버가 이 로그인을 잊었고, 로그인된 것도 아니다
    private var lost = false
    /// 입력을 보낼 때마다 올라간다. 그 전에 떠난 조회의 답은 지난 화면이라 버린다
    private var sequence = 0
    private var failures = 0
    private var pollTask: Task<Void, Never>?
    private var notified = false
    /// 화면을 닫았다 (여는 중에 닫으면, 열린 뒤에 맥에서도 그만두게 한다)
    private var closed = false

    // 이 아이폰에 저장해 두기 (D78)

    /// 로그인 값을 두는 곳 (로그인 흐름에만 있다. 메일 연결은 저장하지 않는다)
    private let vault: (any LoginVault)?
    /// "Face ID" · "Touch ID"
    let unlockName: String
    /// 이 기기에서 저장하고 꺼낼 수 있는지 (Face ID나 Touch ID가 켜져 있을 때)
    private(set) var canKeep = false
    /// 로그인되면 아이디·비밀번호를 이 아이폰에 저장할지. 사용자가 켠다 (저장해 둔 것이 있으면 켜진 채로 시작한다)
    var keeps = false
    /// 저장해 둔 것이 무엇인지 (값 없이)
    private(set) var savedInfo: SavedLoginInfo?
    /// 얼굴 확인을 기다리는 중
    private(set) var isUnlocking = false
    /// 꺼낸 값을 넣어 보낸 입력을 사이트가 맞지 않다고 했다. 이 로그인에서는 더 권하지 않는다 (계정이 잠기지 않게)
    private(set) var savedRejected = false
    /// 저장해 둔 값에 대해 알릴 말
    private(set) var vaultNotice: String?
    /// 저장을 해 봤으면 그 결과 (true: 넣었다, false: 넣지 못했다)
    private var saveResult: Bool?
    /// 이 로그인에서 보낸 아이디·비밀번호. 로그인이 끝날 때까지만 여기(메모리)에 있고, 저장을 켰을 때만 키체인에 넣는다
    private var pending: [String: SavedLogin.Entry] = [:]
    /// 얼굴 확인으로 꺼낸 값. 이 로그인이 끝날 때까지만 든다 (같은 로그인에서 두 번 묻지 않게)
    private var unlocked: SavedLogin?
    /// 꺼낸 값을 넣어 보낸 화면 번호 (그 입력이 틀렸다고 돌아오는지 본다)
    private var savedSentStep: Int?
    /// 시작하거나 닫을 때마다 올라간다. 얼굴 확인을 하는 사이에 흐름이 바뀌었으면 꺼낸 값을 쓰지 않는다
    private var generation = 0
    /// "Face ID로 다시 로그인"을 눌러 연 로그인 (D122): 첫 아이디·비밀번호 화면에서 사용자가 다시 누르지 않아도 얼굴 확인을 띄워 넣어 보낸다.
    /// 맥이 답하며 저절로 연 로그인 화면에서는 켜지 않는다 (사용자가 누른 적 없이 얼굴 확인이 뜨지 않게)
    var autoUsesSaved = false
    /// 저절로 꺼내기는 이 흐름에서 한 번만 (틀렸다고 오면 다시 넣지 않는다)
    private var autoTried = false
    /// 저장 스위치를 켜지 않고 로그인됐다: 지금 저장할지 묻는 중 (D122)
    private(set) var asksToKeep = false
    /// 물어보는 동안만 메모리에 드는 값. 답하거나 닫으면 버린다
    private var offered: SavedLogin?

    /// `name`: 맥이 알려 준 이름 ("네이버 메일 연결"). 모르면 앱이 아는 이름을 쓴다
    init(
        site: String, name: String? = nil, agent: any AgentProviding, pollInterval: Duration = .milliseconds(1500),
        vault: (any LoginVault)? = LoginVaults.current
    ) {
        self.site = site
        let siteName = name?.isEmpty == false ? name! : SiteName.display(site)
        self.siteName = siteName
        self.copy = SiteLoginCopy(kind: SiteFlowKind.of(site), name: siteName)
        self.agent = agent
        self.pollInterval = pollInterval
        let vault = SiteFlowKind.of(site) == .login ? vault : nil
        self.vault = vault
        self.unlockName = vault?.unlockName ?? "Face ID"
        self.canKeep = vault?.isAvailable ?? false
        self.savedInfo = vault?.info(site: site)
        self.keeps = canKeep && savedInfo != nil
    }

    var isFinished: Bool { login?.state.isFinished == true || unsupported || lost }
    /// 맥에서 로그인이 진행 중인지 (닫으려면 취소해야 한다)
    var isActive: Bool { login != nil && !isFinished }

    var screen: Screen {
        if let startProblem { return .stopped(title: copy.startFailedTitle, detail: startProblem, canRetry: true) }
        if unsupported {
            return .stopped(title: "이 화면은 앱에서 처리할 수 없어요", detail: copy.unsupportedDetail, canRetry: true)
        }
        if lost {
            return .stopped(title: copy.lostTitle, detail: "맥의 에이전트가 다시 시작됐을 수 있어요. 다시 시도해 주세요.", canRetry: true)
        }
        guard let login else { return .opening }
        switch login.state {
        case .starting:
            return .opening
        case .working, .unknown:
            return .working(login.message.isEmpty ? "확인하고 있어요" : login.message)
        case .needInput:
            if isSending || unconfirmedStep == login.step { return .working("확인하고 있어요") }
            return .input(login)
        case .needApproval:
            return .approval(login)
        case .needChoice:
            if isSending || unconfirmedStep == login.step { return .working("확인하고 있어요") }
            return .choice(login)
        case .loggedIn:
            return .done
        case .failed, .expired, .cancelled:
            let (title, detail, canRetry) = copy.stopped(login)
            return .stopped(title: title, detail: detail, canRetry: canRetry)
        }
    }

    /// 로그인이 실패한 까닭을 사용자에게 보여 줄 말로 (메일 연결은 `SiteLoginCopy.stopped`).
    ///
    /// 앱이 까닭을 종류만으로 말할 수 있는 실패(입력이 틀림, 시간 초과 …)는 앱의 말로 한다.
    /// 무엇이 막았는지·왜 이 사이트는 안 되는지가 맥의 말(`message`)에만 있는 실패는 그 말을 그대로 보인다 (D83):
    /// 막힘(`blocked`)은 누가 어떻게 막았는지가 사이트마다 다르고, `unsupported_login`은 다시 해도 같은 결과라
    /// "다시 시도"를 내놓지 않는다. 맥의 말이 비면 앱이 아는 말로 돌아간다.
    /// 이 말은 맥이 정해 둔 문장이고(사이트 화면의 글이 아니다) 화면에만 보인다 — 기록하지 않는다.
    nonisolated static func failure(
        _ reason: String?, siteName: String, message: String = ""
    ) -> (title: String, detail: String, canRetry: Bool) {
        let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
        switch reason {
        case "wrong_input":
            return ("로그인하지 못했어요", "입력한 내용이 여러 번 맞지 않아 멈췄어요. 아이디와 비밀번호를 확인한 뒤 다시 시도해 주세요.", true)
        case "blocked":
            if !said.isEmpty { return ("로그인이 막혔어요", said, false) }
            return ("\(siteName)가 로그인을 막았어요", "\(siteName) 앱이나 웹에서 계정 보호 안내를 먼저 확인해 주세요. 여기서 계속 시도하지 않는 것이 좋아요.", false)
        case "unsupported_login":
            return (
                "이 사이트는 아직 로그인해 둘 수 없어요",
                said.isEmpty ? "\(siteName)의 로그인 화면은 에이전트가 아직 다루지 못해요. 로그인은 되지 않았어요." : said,
                false
            )
        case "unsupported_page":
            return ("처리할 줄 모르는 화면이 나왔어요", "\(siteName)가 에이전트가 아직 다룰 줄 모르는 화면을 보여 줘서 멈췄어요. 로그인은 되지 않았어요.", true)
        case "timeout":
            return ("시간 안에 끝나지 않았어요", "로그인은 되지 않았어요. 다시 시도해 주세요.", true)
        case "browser_error":
            return ("맥의 브라우저에 문제가 생겼어요", "로그인은 되지 않았어요. 잠시 뒤에 다시 시도해 주세요.", true)
        default:
            // 그 밖의 까닭(`host_refused`·`not_https`, 앱이 모르는 새 종류): 맥이 까닭을 말했으면 그 말을 보인다
            return ("로그인하지 못했어요", said.isEmpty ? "로그인은 되지 않았어요. 잠시 뒤에 다시 시도해 주세요." : said, true)
        }
    }

    nonisolated static func startProblem(for error: Error) -> String {
        switch error as? AgentError {
        case .unreachable, .slow: "맥에 연결할 수 없어요. 맥이 켜져 있고 연결되어 있는지 확인한 뒤 다시 해 주세요."
        case .rateLimited: "짧은 시간에 로그인을 여러 번 시작했어요. 10분쯤 뒤에 다시 해 주세요."
        case .busy: "맥의 브라우저가 다른 일을 하고 있어요. 잠시 뒤에 다시 해 주세요."
        case .conflict, .unknownSite: "지금 연결된 맥에서는 앱으로 로그인하는 기능을 아직 쓸 수 없어요."
        case .unauthorized: "맥 에이전트 토큰이 맞지 않아요. 앱 설정을 확인해 주세요."
        default: "잠시 뒤에 다시 해 주세요."
        }
    }

    // MARK: - 진행

    /// 로그인을 시작한다 (맥이 로그인 화면을 연다). "다시 시도"도 이것이다
    func start() async {
        guard !isStarting, !isActive else { return }
        stopPolling()
        login = nil
        startProblem = nil
        inputNotice = nil
        passwordSent = false
        unconfirmedStep = nil
        unsupported = false
        lost = false
        isOffline = false
        failures = 0
        stoppedAt = nil
        sequence += 1
        closed = false
        finishKeeping(loggedIn: false)
        generation += 1
        savedRejected = false
        vaultNotice = nil
        saveResult = nil
        canKeep = vault?.isAvailable ?? false
        savedInfo = vault?.info(site: site)
        isStarting = true
        defer { isStarting = false }
        do {
            // 화면이 닫혀도 이 요청은 끝까지 간다: 맥이 연 로그인의 번호를 알아야 그만두게 할 수 있다
            let agent = agent, site = site
            let fresh = try await Task { try await agent.startSiteLogin(site: site, method: SiteLogin.passwordMethod) }.value
            if closed {
                _ = try? await agent.cancelSiteLogin(site: site, id: fresh.id)
                return
            }
            apply(fresh)
            startPolling()
        } catch {
            if !closed { startProblem = copy.startProblem(for: error) }
        }
    }

    /// 지금 화면의 입력칸 값을 보낸다. 같은 화면에는 한 번만 보낸다.
    /// 답을 받지 못하면 다시 보내지 않고 지금 상태부터 물어본다 (비밀번호가 두 번 들어가 계정이 잠기지 않게)
    func submit(_ values: [String: String]) async {
        guard let current = login, current.state == .needInput, current.canRenderInput, !isSending, unconfirmedStep == nil,
              Set(values.keys) == Set(current.fields.map(\.name)),
              values.values.allSatisfy({ !$0.isEmpty && $0.count <= Self.maxValueLength }) else { return }
        // 저장할 수 있는 기기에서는 보낸 아이디·비밀번호를 로그인이 끝날 때까지 들고 있는다 (저장은 로그인된 뒤, 켜 두었을 때만).
        // 칸마다 마지막에 보낸 값만 남긴다. 호스트를 읽지 못한 화면의 값은 들지 않는다
        for name in SavedLogin.names {
            guard let value = values[name] else { continue }
            pending[name] = canKeep && !current.hostUnreadable ? SavedLogin.Entry(value: value, host: current.host) : nil
        }
        await send(values, for: current)
    }

    /// 손 넘기기 화면이 맥에 화면을 묻고 손짓을 보낼 때 쓴다 (D149)
    var handoverAgent: any AgentProviding { agent }

    /// 손 넘기기 물음의 "그만하기" (두 번째 선택지). 이것은 답으로 보내지 않고 로그인을 취소한다 (D149)
    func isHandoverStop(_ choice: String, in login: SiteLogin) -> Bool {
        login.handover != nil && login.choices.count > 1 && login.choices.dropFirst().first == choice
    }

    /// 사이트가 물어본 것에 답한다 (서버가 준 선택지 가운데 하나만)
    func choose(_ choice: String) async {
        guard let current = login, current.state == .needChoice, current.choices.contains(choice), !isSending, unconfirmedStep == nil else { return }
        await send([SiteLogin.choiceName: choice], for: current)
    }

    /// 서버가 받는 값의 길이 한도
    static let maxValueLength = 256

    private func send(_ values: [String: String], for current: SiteLogin) async {
        isSending = true
        inputNotice = nil
        sequence += 1
        defer { isSending = false }
        // 꺼낸 값이 들어간 입력인지 적어 둔다 (값이 아니라 화면 번호만)
        let usesSaved = unlocked.map { saved in
            SavedLogin.names.contains { name in values[name] != nil && values[name] == saved.entries[name]?.value }
        } ?? false
        savedSentStep = usesSaved ? current.step : nil
        do {
            let fresh = try await agent.sendSiteLoginInput(site: site, id: current.id, step: current.step, values: values)
            sequence += 1
            noteReachable()
            if values["password"] != nil { passwordSent = true }
            apply(fresh)
        } catch let error as AgentError where error == .staleStep {
            // 화면이 이미 넘어갔다. 값은 들어가지 않았다
            await refresh()
        } catch let error as AgentError where error == .loginLost {
            await recoverLostLogin()
        } catch let error as AgentError where error == .unreachable || error == .slow {
            // 들어갔는지 모른다. 지금 상태를 물어보고, 같은 화면이 그대로면 그때 다시 받는다
            unconfirmedStep = current.step
            await refresh()
        } catch {
            // 서버가 받지 않았다 (형식이 맞지 않는 값 등). 값은 들어가지 않았다
            inputNotice = "입력을 보내지 못했어요. 다시 입력해 주세요."
        }
    }

    /// 지금 상태를 한 번 받는다 (주기적으로, 그리고 앱이 앞으로 돌아왔을 때)
    func refresh() async {
        guard let current = login, !isFinished else { return }
        let asked = sequence
        do {
            let fresh = try await agent.siteLogin(site: site, id: current.id)
            guard asked == sequence else { return }
            noteReachable()
            apply(fresh)
        } catch let error as AgentError where error == .loginLost {
            guard asked == sequence else { return }
            await recoverLostLogin()
        } catch {
            guard asked == sequence else { return }
            failures += 1
            if failures >= 3 { isOffline = true }
        }
    }

    /// 닫을 때: 끝나지 않은 로그인은 맥에서도 그만두게 한다
    func close() {
        closed = true
        stopPolling()
        // 떠나 있던 조회의 답이 닫은 뒤에 들어오지 않게 한다
        sequence += 1
        // 들고 있던 값은 버린다
        finishKeeping(loggedIn: false)
        generation += 1
        guard let current = login, isActive else { return }
        login?.state = .cancelled
        let agent = agent, site = site
        Task { _ = try? await agent.cancelSiteLogin(site: site, id: current.id) }
    }

    private func noteReachable() {
        failures = 0
        isOffline = false
    }

    private func apply(_ fresh: SiteLogin) {
        if let step = unconfirmedStep {
            unconfirmedStep = nil
            if fresh.step == step, fresh.state == login?.state, !fresh.state.isFinished {
                inputNotice = "입력이 맥에 닿지 않았어요. 다시 입력해 주세요."
            }
        } else if fresh.step != login?.step {
            inputNotice = nil
        }
        login = fresh
        // 꺼낸 값을 넣어 보낸 입력의 결과가 나왔다: 틀렸다고 하면 이 로그인에서는 더 권하지 않는다
        if savedSentStep != nil, ![.starting, .working, .unknown].contains(fresh.state) {
            savedSentStep = nil
            if (fresh.state == .needInput && fresh.wasWrongInput) || (fresh.state == .failed && fresh.reason == "wrong_input") {
                savedRejected = true
                vaultNotice = copy.savedRejected
            }
        }
        if fresh.state.isFinished {
            stopPolling()
            finishKeeping(loggedIn: fresh.state == .loggedIn)
            if fresh.state != .loggedIn { stoppedAt = .now }
        }
        if fresh.state == .loggedIn, !notified {
            notified = true
            onLoggedIn()
        }
        // 앱이 그릴 수 없는 것을 물으면 받지 않고 그만둔다
        let cannotRender = (fresh.state == .needInput && !fresh.canRenderInput) || (fresh.state == .needChoice && fresh.choices.isEmpty)
        if cannotRender {
            unsupported = true
            stoppedAt = .now
            stopPolling()
            finishKeeping(loggedIn: false)
            let agent = agent, site = site
            Task { _ = try? await agent.cancelSiteLogin(site: site, id: fresh.id) }
        }
    }

    /// 서버가 이 로그인을 잊었을 때: 사이트 상태를 물어 로그인됐는지만 확인한다
    private func recoverLostLogin() async {
        stopPolling()
        // 로그인된 것으로 나오더라도, 보낸 값으로 된 것인지 알 수 없으니 저장하지 않는다
        finishKeeping(loggedIn: false)
        let status = (try? await agent.sites())?.first { $0.site == site }?.status
        if status == .loggedIn {
            login?.state = .loggedIn
            if !notified {
                notified = true
                onLoggedIn()
            }
        } else {
            lost = true
            stoppedAt = .now
        }
    }

    // MARK: - 이 아이폰에 저장해 두기 (D78)

    /// "Face ID로 다시 로그인"을 보일지 (D122): 로그인 흐름이고, 이 기기가 얼굴 확인을 쓸 수 있고, 그 사이트에 저장해 둔 값이 있을 때. 단추의 "Face ID" 낱말을 준다
    static func quickUnlock(for site: String, vault: (any LoginVault)? = LoginVaults.current) -> String? {
        guard SiteFlowKind.of(site) == .login, let vault, vault.isAvailable, vault.info(site: site) != nil else { return nil }
        return vault.unlockName
    }

    /// 이 화면에서 저장해 둔 값을 저절로 꺼낼지 (D122). 그렇다고 답하면 다시는 그렇다고 하지 않는다
    func takesSavedAutomatically(_ login: SiteLogin) -> Bool {
        guard autoUsesSaved, !autoTried, !isUnlocking, !login.wasWrongInput, savedFillsAll(login) else { return false }
        autoTried = true
        return true
    }

    /// 물어본 것에 "저장"이라고 답했다
    func keepOffered() {
        defer {
            offered = nil
            asksToKeep = false
        }
        guard let offered, let vault else { return }
        do {
            try vault.save(offered, site: site)
            saveResult = true
        } catch {
            saveResult = false
        }
        savedInfo = vault.info(site: site)
    }

    /// "저장 안 함"
    func declineKeeping() {
        offered = nil
        asksToKeep = false
    }

    /// 로그인이 끝난 뒤 이 아이폰에 남은 것 (완료 화면의 말을 고른다)
    var phoneKeeping: SiteLoginCopy.PhoneKeeping {
        switch saveResult {
        case .some(true): .saved
        case .some(false): .failed
        case nil: savedInfo == nil ? .nothing : .unchanged
        }
    }

    /// 이 화면에 "로그인되면 저장" 스위치를 보일지: 저장할 수 있는 기기이고, 아이디나 비밀번호를 묻는 화면일 때
    func offersKeeping(for login: SiteLogin) -> Bool {
        canKeep && !login.hostUnreadable && login.fields.contains { SavedLogin.names.contains($0.name) }
    }

    /// 지금 화면의 칸 가운데 저장해 둔 값을 넣을 수 있는 것 (값 없이).
    /// 호스트가 저장할 때와 다르거나, 이 로그인에서 이미 맞지 않았으면 비어 있다
    func savedNames(for login: SiteLogin) -> Set<String> {
        guard canKeep, !savedRejected, login.state == .needInput, login.canRenderInput, let savedInfo else { return [] }
        return savedInfo.names(for: login)
    }

    /// 저장해 둔 값이 이 화면의 칸을 모두 채우는지 (그러면 꺼내서 바로 보낼 수 있다)
    func savedFillsAll(_ login: SiteLogin) -> Bool {
        let names = savedNames(for: login)
        return !names.isEmpty && names == Set(login.fields.map(\.name))
    }

    /// 저장해 둔 값을 얼굴 확인 뒤에 꺼내, 지금 화면에 넣을 것만 돌려준다 (칸 이름 → 값). 넣을 수 없으면 비어 있다.
    /// 한 로그인에서는 한 번만 확인한다. 확인하는 사이에 화면이 넘어갔으면 넣지 않는다
    func savedValues(for login: SiteLogin) async -> [String: String] {
        guard !savedNames(for: login).isEmpty, let vault, !isUnlocking else { return [:] }
        if unlocked == nil {
            let asked = generation
            isUnlocking = true
            let read = await vault.read(site: site, reason: copy.unlockReason)
            isUnlocking = false
            guard asked == generation else { return [:] }
            switch read {
            case .value(let saved):
                unlocked = saved
                vaultNotice = nil
            case .cancelled:
                return [:]
            case .gone:
                savedInfo = vault.info(site: site)
                vaultNotice = copy.savedGone(unlock: unlockName)
                return [:]
            case .failed:
                vaultNotice = copy.savedUnreadable
                return [:]
            }
        }
        guard let current = self.login, current.id == login.id, current.step == login.step, current.state == .needInput,
              !isSending, unconfirmedStep == nil else { return [:] }
        return unlocked?.values(for: current) ?? [:]
    }

    /// 끝났을 때: 로그인됐고 저장을 켜 두었으면 보낸 값을 키체인에 넣는다. 어느 쪽이든 들고 있던 값은 버린다
    private func finishKeeping(loggedIn: Bool) {
        defer {
            pending = [:]
            unlocked = nil
            savedSentStep = nil
        }
        if !loggedIn {
            offered = nil
            asksToKeep = false
        }
        // 스위치를 켜지 않았고 저장해 둔 것도 없는 사이트: 로그인된 지금 저장할지 묻는다 (D122). 비밀번호를 보냈을 때만
        if loggedIn, !keeps, canKeep, vault != nil, savedInfo == nil, unlocked == nil, pending["password"] != nil {
            offered = SavedLogin(entries: pending)
            asksToKeep = true
            return
        }
        guard loggedIn, keeps, canKeep, let vault, !pending.isEmpty else { return }
        // 꺼내 쓴 것이 있으면 그 위에 이번에 보낸 값을 덮는다 (이번에 묻지 않은 칸은 그대로 둔다)
        var entries = unlocked?.entries ?? [:]
        entries.merge(pending) { _, new in new }
        let login = SavedLogin(entries: entries)
        // 꺼내 쓴 그대로면 다시 쓰지 않는다
        guard login != unlocked else { return }
        do {
            try vault.save(login, site: site)
            saveResult = true
        } catch {
            saveResult = false
        }
        savedInfo = vault.info(site: site)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self, !self.isFinished else { return }
                await self.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

/// 연동 센터가 쓰는 목록 (브라우저 로그인, 그리고 메일 계정 묶음의 "메일 연결"). 맥이 사이트 로그인을 지원한다고 알릴 때만 카드가 나타난다
@MainActor
@Observable
final class SiteAccountsModel {
    private let agent: (any AgentProviding)?
    private(set) var isSupported = false
    private(set) var sites: [SiteStatus] = []
    /// 맥이 저장된 로그인을 실제로 열어 보는 중인 사이트
    private(set) var checking: String?
    /// 로그아웃하는 중인 사이트
    private(set) var loggingOut: String?
    private(set) var loadFailed = false
    private(set) var problem: String?

    /// 이 아이폰의 키체인에 로그인 값을 저장해 둔 사이트 (D78). 값은 여기로 오지 않는다
    struct SavedSite: Equatable, Identifiable, Sendable {
        let site: String
        /// "아이디·비밀번호"
        let summary: String
        var id: String { site }
    }

    private let vault: (any LoginVault)?
    private(set) var savedSites: [SavedSite] = []

    init(agent: (any AgentProviding)? = AgentClient.fromEnvironment(), vault: (any LoginVault)? = LoginVaults.current) {
        self.agent = agent
        self.vault = vault
        loadSaved()
    }

    /// 저장해 둔 것은 맥에 묻지 않고 이 아이폰에서 바로 안다
    /// 맥의 브라우저가 본 그 사이트의 아이콘 (D132). 없거나 묻지 못하면 nil
    func macIcon(_ site: String) async -> Data? {
        guard let agent else { return nil }
        return try? await agent.siteIcon(site: site)
    }

    func loadSaved() {
        guard let vault else { return }
        savedSites = vault.sites().filter { SiteFlowKind.of($0) == .login }.map { site in
            SavedSite(site: site, summary: vault.info(site: site)?.summary ?? "")
        }
    }

    /// 저장해 둔 로그인 값을 이 아이폰에서 지운다 (맥의 로그인 상태는 그대로다)
    func forgetSaved(_ site: String) {
        vault?.remove(site: site)
        loadSaved()
    }

    /// 화면에 쓰는 이름: 맥이 알려 준 것이 있으면 그것을, 없으면 앱이 아는 것을
    func name(for site: String) -> String {
        sites.first { $0.site == site }?.name ?? SiteName.display(site)
    }

    /// 브라우저 로그인 묶음에 보이는 사이트
    var loginSites: [SiteStatus] { sites.filter { $0.kind == .login } }
    /// 메일 계정 묶음에 "연결" 줄로 보이는 것: 앱에서 시작할 수 있고 아직 연결되지 않은 메일 연결.
    /// 연결된 뒤에는 메일 계정 줄이 그 자리를 대신한다 (맥에서 이것의 확인·로그아웃은 하는 일이 없다)
    var mailSetups: [SiteStatus] { sites.filter { $0.kind == .mailSetup && $0.status != .loggedIn && $0.canLogInFromApp } }

    var isBusy: Bool { checking != nil || loggingOut != nil }

    func load() async {
        loadSaved()
        guard let agent, !isBusy else { return }
        guard await agent.isReachable() else {
            loadFailed = isSupported
            return
        }
        isSupported = await agent.supports(AgentFeature.siteLogin)
        guard isSupported else { return }
        do {
            sites = try await agent.sites()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// 저장된 로그인이 살아 있는지 맥이 지금 열어 본다 (10~20초)
    func check(_ site: String) async {
        guard let agent, !isBusy else { return }
        checking = site
        problem = nil
        defer { checking = nil }
        do {
            sites = try await agent.checkSite(site: site)
            loadFailed = false
        } catch {
            problem = Self.problem(for: error, doing: "확인")
        }
    }

    func logout(_ site: String) async {
        guard let agent, !isBusy else { return }
        loggingOut = site
        problem = nil
        defer { loggingOut = nil }
        do {
            sites = try await agent.siteLogout(site: site)
            loadFailed = false
        } catch {
            problem = Self.problem(for: error, doing: "로그아웃")
        }
    }

    /// 로그인 화면을 띄울 때 쓴다. 이름은 맥이 알려 준 것을 쓴다
    func flow(for site: String) -> SiteLoginFlow? {
        guard let agent else { return nil }
        let flow = SiteLoginFlow(site: site, name: sites.first { $0.site == site }?.name, agent: agent, vault: vault)
        flow.onLoggedIn = { [weak self] in Task { await self?.load() } }
        return flow
    }

    static func problem(for error: Error, doing: String) -> String {
        switch error as? AgentError {
        case .unreachable, .slow: "맥에 연결할 수 없어 \(doing)하지 못했어요."
        case .busy: "맥의 브라우저가 다른 일을 하고 있어요. 잠시 뒤에 다시 해 주세요."
        default: "\(doing)하지 못했어요. 잠시 뒤에 다시 해 주세요."
        }
    }
}
