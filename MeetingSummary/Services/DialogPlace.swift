import Foundation
import Observation

/// 맥 에이전트가 "무엇을 할지"(답할지·되물을지·일로 만들지)를 어디서 정하는지 (D60).
///
/// 맥이 연결 확인(`health.features`)에 `dialog_cloud`를 알릴 때만 Claude다. 그때는 맥이 사용자의 말을 Claude API로 직접 보낸다
/// (앱의 중계 서버를 거치지 않는다). 무엇이 가고 무엇이 가지 않는지는 맥이 정하고 막는다 (local-ai-agent `docs/API.md` "대화 판단이 어디서 되나").
enum DialogPlace: String, Equatable {
    /// 맥의 로컬 모델. 외부로 나가지 않는다
    case local
    /// Claude. 맥이 직접 보낸다
    case cloud
}

/// 맥이 알린 대화 판단의 설정: 어디서 판단하는지와, Claude일 때 함께 켜진 것 (D61).
struct DialogSetup: Equatable {
    var place: DialogPlace
    /// 앱이 붙인 회의 자료의 내용이 Claude로 간다 (`dialog_context`). 아니면 "붙어 있다"는 사실만 간다
    var sendsContext = false
    /// 공개 정보를 웹 검색으로 찾는다 (`web_lookup`)
    var webLookup = false
    /// 맥을 거친 답의 말풍선마다 누가 썼는지 알려 준다 (`reply_by`, D62). 그러면 Claude가 쓴 답 아래에 "Claude 사용"이 붙는다
    var marksWriter = false
    /// "찾아 달라"는 말이 작업이 된다: 검색으로 답을 찾고 맥이 브라우저로 그 공개 페이지를 직접 연다 (`web_find`, D64·D65)
    var findsPages = false
    /// 그 답에 맥이 연 페이지의 카드(제목·주소·대표 그림)가 붙을 수 있다 (`report_links`, D64)
    var showsLinks = false
    /// 살 것을 찾아 달라는 말의 답에 상품 목록(이름·값·파는 곳·주소·그림)이 붙을 수 있다 (`report_items`, D72)
    var listsItems = false
    /// 그 작업이 페이지를 네이버 검색으로 찾는다 (`web_find_naver`, D65). 아니면 Anthropic의 웹 검색이다
    var findsWithNaver = false
    /// 그 작업에서 맥의 브라우저가 연 공개 페이지의 글을 Claude가 읽는다 (`web_find_reads_cloud`, D66). 맥의 기본은 꺼짐
    var pagesReadByCloud = false
    /// 날씨 물음에는 맥이 "어디·언제"만 정하고, 이 기기가 Apple 날씨에서 받아 카드로 그린다 (`weather_action`, D66)
    var showsWeather = false
    /// 맥이 알림을 보낼 수 있다 (`push`, D67). 대화 판단을 어디서 하는지와는 상관없다
    var sendsPush = false
    /// 알림에 띄울 실제 글을 맥이 따로 준다 (`push_text`, D73). 알림 확장이 맥에서 직접 받아 바꿔 띄운다
    var givesPushText = false
    /// 살 것을 말하면 앱 안의 쇼핑 화면을 열게 하고, "확인해 줘"를 누른 화면의 값을 받아 답한다 (`shop_view`, D74)
    var opensShop = false
    /// 살 것을 말하면 맥의 작업이 앱 안의 쇼핑 화면에 검색과 상품 열기를 시키고, 앱이 읽은 것을 받아 목록을 만든다 (`shop_drive`, D75)
    var drivesShop = false
    /// 정해진 기능에 없는 부탁을 맥의 브라우저로 직접 해 본다. 그 작업에서 연 공개 페이지의 화면 글을 Claude가 본다 (`web_browse`, D76)
    var browsesWeb = false
    /// 대화에 붙인 사진·PDF를 맥이 받아 Claude에게 직접 보여 준다 (`uploads`, D85)
    var takesUploads = false
    /// 승인하면 다른 사람에게도 메일을 보낸다 (`send_others`, D89). 아니면 내 주소로만 보낸다
    var sendsOthers = false

    static let local = DialogSetup(place: .local)

    /// 맥이 알린 기능 이름으로 정한다. `dialog_cloud`가 없으면 나머지는 보지 않는다
    init(agent: any AgentProviding) async {
        let push = await agent.supports(AgentFeature.push)
        let pushText = await push ? agent.supports(AgentFeature.pushText) : false
        guard await agent.supports(AgentFeature.dialogCloud) else {
            self = DialogSetup(place: .local, sendsPush: push, givesPushText: pushText)
            return
        }
        place = .cloud
        sendsPush = push
        givesPushText = pushText
        sendsContext = await agent.supports(AgentFeature.dialogContext)
        webLookup = await agent.supports(AgentFeature.webLookup)
        marksWriter = await agent.supports(AgentFeature.replyBy)
        findsPages = await agent.supports(AgentFeature.webFind)
        showsLinks = await agent.supports(AgentFeature.reportLinks)
        listsItems = await agent.supports(AgentFeature.reportItems)
        findsWithNaver = await findsPages ? agent.supports(AgentFeature.webFindNaver) : false
        pagesReadByCloud = await findsPages ? agent.supports(AgentFeature.webFindReadsCloud) : false
        showsWeather = await agent.supports(AgentFeature.weatherAction)
        opensShop = await agent.supports(AgentFeature.shopView)
        drivesShop = await opensShop ? agent.supports(AgentFeature.shopDrive) : false
        browsesWeb = await agent.supports(AgentFeature.webBrowse)
        takesUploads = await agent.supports(AgentFeature.uploads)
        sendsOthers = await agent.supports(AgentFeature.sendOthers)
    }

    /// 로컬 판단일 때는 Claude가 쓰는 답이 없으므로 나머지 값은 모두 꺼 둔다
    init(
        place: DialogPlace, sendsContext: Bool = false, webLookup: Bool = false, marksWriter: Bool = false,
        findsPages: Bool = false, showsLinks: Bool = false, findsWithNaver: Bool = false, showsWeather: Bool = false,
        pagesReadByCloud: Bool = false, sendsPush: Bool = false, listsItems: Bool = false,
        givesPushText: Bool = false, opensShop: Bool = false, drivesShop: Bool = false, browsesWeb: Bool = false,
        takesUploads: Bool = false, sendsOthers: Bool = false
    ) {
        self.sendsOthers = sendsOthers
        // 붙인 것은 Claude가 본다: Claude 판단이 아니면 없다
        self.takesUploads = place == .cloud && takesUploads
        self.browsesWeb = place == .cloud && browsesWeb
        self.opensShop = place == .cloud && opensShop
        // 쇼핑 화면이 없으면 거기서 찾아 오는 일도 없다
        self.drivesShop = self.opensShop && drivesShop
        self.listsItems = place == .cloud && listsItems
        self.sendsPush = sendsPush
        // 알림이 없으면 알림의 글도 없다
        self.givesPushText = sendsPush && givesPushText
        self.showsWeather = place == .cloud && showsWeather
        self.place = place
        self.sendsContext = place == .cloud && sendsContext
        self.webLookup = place == .cloud && webLookup
        self.marksWriter = place == .cloud && marksWriter
        self.findsPages = place == .cloud && findsPages
        self.showsLinks = place == .cloud && showsLinks
        // 찾는 작업이 없으면 어디서 찾는지도 없다
        self.findsWithNaver = self.findsPages && findsWithNaver
        self.pagesReadByCloud = self.findsPages && pagesReadByCloud
    }

    /// 기기에 적어 두는 꼴: "v2 cloud context web by find links naver weather reads push items pushtext shopview shopdrive webbrowse uploads" 같은 낱말 줄. 사용자의 내용은 들어가지 않는다
    var stored: String {
        let words = ["v2", place.rawValue] + (sendsContext ? ["context"] : []) + (webLookup ? ["web"] : []) + (marksWriter ? ["by"] : [])
            + (findsPages ? ["find"] : []) + (showsLinks ? ["links"] : []) + (findsWithNaver ? ["naver"] : [])
            + (showsWeather ? ["weather"] : []) + (pagesReadByCloud ? ["reads"] : []) + (sendsPush ? ["push"] : []) + (listsItems ? ["items"] : [])
            + (givesPushText ? ["pushtext"] : []) + (opensShop ? ["shopview"] : []) + (drivesShop ? ["shopdrive"] : []) + (browsesWeb ? ["webbrowse"] : [])
            + (takesUploads ? ["uploads"] : []) + (sendsOthers ? ["sendothers"] : [])
        return words.joined(separator: " ")
    }

    /// 적어 둔 것을 읽는다. 모르는 값이면 nil.
    /// 예전(D60) 앱은 `local`·`cloud` 한 낱말만 적었다. 그때의 `cloud`는 회의 자료의 내용이 가는지 묻지 않고 적은 것이라,
    /// 간다고 본다(그때의 설명도 그랬고, 덜 말하는 것보다 더 말하는 쪽이 안전하다)
    init?(stored: String?) {
        guard let stored else { return nil }
        var words = stored.split(separator: " ").map(String.init)
        let isLegacy = words.first != "v2"
        if !isLegacy { words.removeFirst() }
        guard let first = words.first, let place = DialogPlace(rawValue: first), !isLegacy || words.count == 1 else { return nil }
        self.init(
            place: place, sendsContext: isLegacy ? true : words.contains("context"), webLookup: words.contains("web"),
            marksWriter: words.contains("by"), findsPages: words.contains("find"), showsLinks: words.contains("links"),
            findsWithNaver: words.contains("naver"), showsWeather: words.contains("weather"),
            pagesReadByCloud: words.contains("reads"), sendsPush: words.contains("push"), listsItems: words.contains("items"),
            givesPushText: words.contains("pushtext"), opensShop: words.contains("shopview"),
            drivesShop: words.contains("shopdrive"), browsesWeb: words.contains("webbrowse"),
            takesUploads: words.contains("uploads"), sendsOthers: words.contains("sendothers")
        )
    }
}

/// 데이터 처리 방식 화면이 쓰는 값: 지금 내 맥이 대화 판단을 어디서 하는지.
///
/// 맥에 닿을 때마다 새로 묻고, 마지막으로 확인한 값을 기기에 적어 둔다. 맥에 닿지 않는 동안에도
/// "외부로 보내지 않는다"는 틀린 설명이 보이지 않게 하기 위해서다. 적어 두는 것은 설정의 이름 몇 낱말뿐이다 (`DialogSetup.stored`).
@MainActor
@Observable
final class DialogPlaceModel {
    static let defaultsKey = "agent.dialogPlace"

    private let agent: (any AgentProviding)?
    @ObservationIgnored private let defaults: UserDefaults
    /// nil: 맥 에이전트가 없는 앱이거나, 한 번도 확인하지 못했다
    private(set) var setup: DialogSetup?
    var place: DialogPlace? { setup?.place }
    /// 방금 맥에 물어 확인한 값인지 (아니면 마지막으로 적어 둔 값)
    private(set) var isConfirmed = false
    /// 맥에 한 번 물어보았는지 (묻기 전에는 "확인하지 못했다"는 말을 하지 않는다)
    private(set) var hasChecked = false

    init(agent: (any AgentProviding)? = AgentClient.fromEnvironment(), defaults: UserDefaults = .standard) {
        self.agent = agent
        self.defaults = defaults
        // 맥 에이전트가 없는 앱에서는 예전에 적어 둔 값도 쓰지 않는다
        setup = agent == nil ? nil : DialogSetup(stored: defaults.string(forKey: Self.defaultsKey))
    }

    func load() async {
        guard let agent else { return }
        defer { hasChecked = true }
        guard await agent.isReachable() else {
            isConfirmed = false
            return
        }
        let now = await DialogSetup(agent: agent)
        setup = now
        isConfirmed = true
        defaults.set(now.stored, forKey: Self.defaultsKey)
    }

    /// 화면에 보일 설명
    var facts: MacAgentFacts {
        MacAgentFacts(setup: setup ?? .local, notice: notice)
    }

    /// 지금 값이 방금 확인한 것이 아닐 때 덧붙이는 말
    var notice: String? {
        guard agent != nil, hasChecked, !isConfirmed else { return nil }
        return setup == nil
            ? "맥에 연결되지 않아 맥의 지금 설정을 확인하지 못했어요. 맥에서 대화 판단을 Claude에 맡겨 두었다면, 연결된 뒤 이 설명이 바뀌어요."
            : "맥에 연결되지 않아, 마지막으로 연결했을 때의 설정으로 보여 드려요."
    }
}

/// 데이터 처리 방식 화면의 "맥 에이전트를 연결했다면" 묶음에 보이는 글. 실제 동작과 같아야 한다.
///
/// `cloud`의 "가는 것 / 가지 않는 것"은 맥이 정한 목록(local-ai-agent `docs/API.md`의 표)을 옮긴 것이다. 그 표가 바뀌면 여기도 고친다.
struct MacAgentFacts: Equatable {
    struct Fact: Equatable, Identifiable {
        let icon: Lucide
        let text: String
        var note: String?
        var id: String { text }
    }

    let setup: DialogSetup
    /// 방금 확인한 설정이 아닐 때의 안내
    var notice: String?
    var place: DialogPlace { setup.place }

    init(setup: DialogSetup, notice: String? = nil) {
        self.setup = setup
        self.notice = notice
    }

    /// "맡긴 일의 글은 모두 맥에서 만든다"에서 빼야 하는 것: Claude가 쓰는 작업의 글
    private static func cloudWritten(_ setup: DialogSetup) -> String {
        let parts = (setup.findsPages ? ["찾아 달라는 작업의 답"] : [])
            + (setup.drivesShop ? ["쇼핑 화면에서 찾아 온 상품을 견준 말"] : [])
            + (setup.browsesWeb ? ["사이트를 직접 열어 찾아보는 작업의 답·질문"] : [])
        return parts.isEmpty ? "" : parts.joined(separator: ", ") + " 말고는 "
    }

    var rows: [Fact] {
        let sent = Fact(icon: .monitor, text: "질문 탭에 쓴 글과 관련 회의 발췌(최대 8000자), 방금 받은 회의 답을 Tailscale로 내 맥에 먼저 보내요")
        let kept = Fact(icon: .inbox, text: "맥은 회의 발췌를 저장하지 않고, 대화 기록은 맥의 메모리에만 있다가 하루 뒤나 맥 에이전트를 다시 켤 때 사라져요")
        // 알림 (D67): 맥과 맞춘 것 그대로. 알림은 Apple의 서버를 지나므로 정해진 문장과 번호만 싣는다 (`PushNotice`)
        let push = setup.sendsPush ? [Fact(
            icon: .bell, text: "알림을 허용하면, 맡긴 일이 승인을 기다리거나 끝났을 때 맥이 Apple의 알림 서버를 거쳐 이 아이폰에 알려요",
            note: "알림에 실리는 것은 정해진 문장 하나(예: '\(PushNotice.Kind.approvalNeeded.body)')와 일·대화의 번호뿐이에요. "
                + "일의 제목, 초안, 받는 사람, 사이트 이름, 읽은 결과는 실리지 않고, 내용은 앱을 열면 맥에서 직접 받아요. "
                + "알림을 받으려고 이 아이폰의 알림 주소(Apple이 준 기기 토큰)를 맥에 등록해 두고, 아이폰 설정에서 알림을 끄면 다음에 앱을 열 때 지워요."
                // 맥과 맞춘 것 (D73): 실제 글은 Apple을 거치지 않는다. 알림이 도착하면 이 아이폰이 맥에 직접 물어 받아 바꿔 띄운다
                + (setup.givesPushText
                    ? " 알림에 보이는 실제 글(일의 제목과, 승인할 메일의 제목·질문·결과의 앞부분)은 Apple을 거치지 않아요. "
                        + "알림이 도착하면 이 아이폰이 맥에서 직접 받아 바꿔 띄우고, 받지 못하면 정해진 문장이 떠요. "
                        + "로그인한 화면에서 읽은 결과의 앞부분도 알림에 보일 수 있어요. 잠금 화면에서 가리려면 아이폰 설정 → 알림 → 미리보기에서 정해 주세요."
                    : "")
        )] : []
        // 연락처 (D89): 주소록 전체가 아니라 내 말에 이름이 나온 사람만 맥으로 간다. 찾는 일은 이 아이폰 안에서 한다
        let contacts = Fact(
            icon: .circleUserRound, text: "메일 받을 사람을 이름으로 말하면, 연락처에서 그 사람만 찾아 이름과 메일 주소를 내 맥에 보내요",
            note: "연락처를 허용했을 때만 해요. 주소록 전체는 보내지 않아요. 내가 쓴 말에 이름이 나온 사람을 이 아이폰 안에서 찾고, 그 사람의 이름과 메일 주소만 Tailscale로 내 맥에 가요. "
                + "그 사람에게 메일 주소가 없으면 이름만 가요. 맥이 주소를 되물을 수 있게요. "
                + "연락처에서 읽는 것은 이름, 별명, 회사 이름, 메일 주소뿐이에요. 전화번호, 주소, 메모는 읽지 않아요. "
                + "맥이 Claude에 물어 정하는 방식이면 그 이름은 Claude도 보고, 메일 주소는 가려요. "
                + "읽은 연락처는 이 아이폰에도 저장하지 않고, 대화 기록에도 남기지 않아요. 아이폰 설정에서 연락처를 끄면 읽지 않아요."
        )
        switch place {
        case .local:
            return [
                sent,
                Fact(icon: .cpu, text: "맥의 로컬 모델이 직접 답하거나 작업으로 만들어요. 이때는 외부 서비스로 보내지 않아요"),
                Fact(icon: .cloud, text: "맥이 회의 내용 질문이라고 판단한 글만 위의 '질문할 때'처럼 Claude로 보내요")
            ] + [contacts] + push + [kept]
        case .cloud:
            // 회의 자료: 맥이 내용을 보낸다고 알릴 때만 "간다"에 넣는다. 아니면 붙어 있다는 사실만 가고, 내용은 "가지 않는다"에 넣는다
            let context = setup.sendsContext ? "함께 보낸 회의 발췌" : "회의 발췌가 붙어 있다는 사실(내용은 아니에요)"
            let held = setup.sendsContext ? "" : "함께 보낸 회의 발췌의 내용, "
            var rows = [
                sent,
                Fact(
                    icon: .cloud, text: "답할지, 되물을지, 일로 만들지는 맥이 Anthropic Claude에 직접 물어서 정해요. 중계 서버는 거치지 않아요",
                    note: "Claude로 가는 것: 내가 쓴 글(메일 주소는 가려요), Claude가 쓴 답, 맡긴 일의 제목과 끝났는지·멈췄는지, 읽은 결과의 이름(내용은 아니에요), "
                        + "연락처의 이름, \(context), 지금 날짜와 시각, 사이트 로그인 여부, 메일 계정 연결 여부"
                ),
                Fact(
                    icon: .shieldCheck, text: "이런 것은 Claude로 가지 않아요",
                    note: "\(held)사이트에서 읽은 결과와 화면 글·캡처, 받은 메일의 제목·보낸 사람·본문, 메일 주소, 아이디·비밀번호 같은 로그인 정보, 맡긴 일의 진행 과정과 승인 내용"
                        // 맥이 알린 것 (D76): 직접 해 보는 작업에서는 화면 글을 봐야 무엇을 누를지 정할 수 있다
                        + (setup.browsesWeb
                            ? ". 다만 사이트를 직접 열어 찾아보는 작업은 달라요. 그 작업에서 맥의 브라우저가 연 공개 페이지의 화면 글과 진행 과정은 Claude로 가요(아래에 적었어요)"
                            : "")
                ),
                contacts,
            ]
            if setup.webLookup {
                rows.append(Fact(
                    // 날씨 카드를 쓰는 맥이면 날씨는 검색으로 가지 않는다 (미세먼지·태풍 소식은 여전히 검색이다)
                    icon: .globe,
                    text: "\(setup.showsWeather ? "가격·뉴스·미세먼지" : "날씨·가격·뉴스") 같은 공개 정보를 물으면, Claude가 검색할 물음 한 문장을 만들어 Anthropic의 웹 검색으로 찾아요",
                    note: "검색에는 그 한 문장과 지금 시각만 가요. 대화 기록, 회의 발췌, 읽은 결과, 메일 주소는 가지 않아요. "
                        + "연락처에 있는 사람의 이름이나 회의 자료의 문장은 검색어에 넣지 않도록 지시하지만, 코드로 막지는 못해요. "
                        + "찾은 답은 대화 기록에 남아서 다음 말을 판단할 때 Claude가 다시 봐요."
                ))
            }
            if setup.showsWeather {
                // 맥과 맞춘 것 (D66): 맥은 "날씨 물음이다, 어디·언제"만 정한다. 날씨는 이 기기가 Apple에서 받는다.
                // 이 기기의 위치는 맥으로도 Claude로도 가지 않는다. 카드에 보인 한 줄만 다음 말과 함께 맥에 알린다
                rows.append(Fact(
                    icon: .sunMoon, text: "날씨를 물으면 Claude는 어디·언제인지만 정하고, 날씨는 이 아이폰이 Apple 날씨에서 받아 카드로 보여 드려요",
                    note: "Apple로 가는 것: 날씨를 볼 곳의 좌표, 그리고 지역을 말했으면 그 이름(Apple 지도에서 좌표를 찾아요). "
                        + "지역을 말하지 않았으면 지금 위치를 쓰는데, 약 1km 단위로 줄인 좌표만 보내요. 위치 권한은 그때 처음 물어요. "
                        + "이 아이폰의 위치는 맥으로도 Claude로도 가지 않고, 저장하지도 않아요. "
                        + "카드에 보인 날씨 한 줄(예: '부산 내일: 비, 12~18도')은 다음 말을 보낼 때 맥에 알리고, 대화 기록에 남아서 Claude가 다시 봐요. "
                        + "지금 위치의 날씨였다면 그 줄에 날씨 값은 있지만 어디인지는 쓰지 않아요."
                ))
            }
            if setup.findsPages {
                // 맥이 정한 목록 그대로: 검색에 가는 것, 페이지의 글은 가지 않는 것, 끝난 답은 공개 정보라 Claude가 다시 보는 것.
                // 답을 누가 쓰는지는 어디서 찾느냐로 갈린다 (D65): Anthropic의 웹 검색이면 그 검색 결과로 Claude가 쓰고(브라우저는 그 답에 나온 페이지를 연다),
                // 네이버 검색이면 검색은 페이지만 찾아 주므로 맥의 브라우저가 연 페이지를 맥의 로컬 모델이 읽고 쓴다
                let how = setup.findsWithNaver
                    ? "검색할 물음 한 문장이 네이버 검색으로 가요. 맥의 브라우저가 그렇게 찾은 페이지를 열고, 맥의 로컬 모델이 읽어서 답을 써요. "
                    : "검색할 물음 한 문장이 Anthropic의 웹 검색으로 가고, 그 검색 결과로 Claude가 답을 써요. "
                        + "맥의 브라우저는 그 답에 나온 페이지를 열어 제목과 대표 그림의 주소를 가져와요(연 화면의 캡처가 붙기도 해요). "
                rows.append(Fact(
                    icon: .monitor, text: "무엇을 찾아 달라고 하면 작업으로 만들어, 검색으로 답을 찾고 맥의 브라우저가 공개 페이지를 직접 열어 봐요",
                    note: how
                        + (setup.pagesReadByCloud
                            ? "맥의 브라우저가 연 공개 페이지의 글은 Claude가 읽어요. "
                            : "맥의 브라우저가 연 페이지의 글은 Claude로 가지 않아요. ")
                        + "이 브라우저는 로그인 없이 뜨고, 네이버 로그인을 실은 브라우저와 다른 것이에요. "
                        + "이렇게 찾은 답과 함께 보여 준 링크의 제목·사이트 이름은 공개 정보라, 사이트에서 읽은 다른 결과와 달리 대화 기록에 남아서 다음 말을 판단할 때 Claude가 다시 봐요."
                ))
            }
            if setup.browsesWeb {
                // 맥이 알린 것 (D76, 맥의 코드로 확인한 사실): Claude로 가는 것은 화면 글뿐이고 캡처는 가지 않는다.
                // 운전하는 Claude는 할 일 한 문장과 날짜·시각만 받는다. 브라우저는 작업마다 새로 뜨는 격리 브라우저다.
                // 코드로 막는 것은 비밀번호 칸 입력과 신청·결제·제출 단추. 로그인 화면에서 멈추는 것은 지시다
                rows.append(Fact(
                    icon: .monitor, text: "정해진 기능에 없는 일을 부탁하면, 맥의 브라우저로 공개 사이트를 직접 열어 찾아봐요. 이때는 그 화면의 글을 Claude가 봐요",
                    note: "이 작업에서 맥의 브라우저가 연 공개 페이지의 화면 글(주소, 제목, 누르거나 입력할 수 있는 것의 이름, 보이는 글)이 Claude로 가요. "
                        + "화면을 보고 무엇을 누를지 Claude가 정하기 때문이에요. 화면 캡처(그림)는 가지 않아요. "
                        + "조작하는 Claude가 그 밖에 받는 것은 할 일을 풀어 쓴 한 문장(메일 주소는 빼요)과 지금 날짜·시각뿐이에요. 대화 기록, 연락처의 이름, 회의 발췌는 받지 않아요. "
                        + "그 사이트의 검색칸과 조회 칸(날짜·지역 등)에 Claude가 글을 넣고 고르는 상자에서 골라요. 그래서 내가 말에 쓴 낱말(가게 이름, 날짜, 지역 등)이 그 사이트로 갈 수 있어요. "
                        + "신청·결제·제출·예약 같은 단추는 누르지 않고, 비밀번호 칸에는 넣지 못해요(둘 다 맥이 막아요). "
                        + "로그인이나 본인 확인 화면을 만나면 아무것도 넣지 말고 멈추도록 지시하고, 못 했다고 알려요. 그 화면의 글은 Claude가 봐요. "
                        + "이 브라우저는 로그인 없이 작업마다 새로 뜨고 닫을 때 지워져요. 네이버 로그인을 실은 브라우저와 다른 것이에요. 검색 사이트와 네이버는 이 길로 열지 않아요. "
                        + "사이트가 막으면 그 사이트로 더 가지 않아요. 직접 확인하지 못하면 검색으로 찾은 답으로 대신하고, 답의 첫 줄에 그렇다고 적어요. "
                        + "답과 되묻는 질문은 Claude가 써요. 화면 글은 맥에 저장하지 않아요. "
                        + "답과, 답과 함께 보여 준 링크의 제목·사이트 이름은 대화 기록에 남아서 다음 말을 판단할 때 Claude가 다시 봐요."
                ))
            }
            if setup.showsLinks {
                // 그림과 링크는 맥이나 Claude를 거치지 않는다: 이 아이폰이 그 사이트에 직접 접속한다
                rows.append(Fact(
                    icon: .link, text: "찾은 페이지는 그림과 함께 카드로 보여 드려요. 링크는 눌렀을 때만 열어요",
                    note: "카드의 그림은 그 페이지가 대표 그림으로 적어 둔 것이에요. 카드가 화면에 보일 때 이 아이폰이 그 사이트에서 직접 받아 오고(쿠키 없이), 저장하지 않아요. "
                        + "링크를 열 때에도 이 아이폰이 그 사이트에 직접 접속해요."
                ))
            }
            if setup.listsItems {
                // 맥과 맞춘 것 (D72): 상품의 이름·값·파는 곳은 맥이 받은 값 그대로이고(모델이 쓰지 않는다), 공개 정보라 맥의 대화 기록에 남는다.
                // 상품 페이지와 그림은 이 아이폰이 직접 연다. 앱은 주문하지 않는다
                rows.append(Fact(
                    icon: .listChecks, text: "살 것을 찾아 달라고 하면 찾은 상품을 목록으로 보여 드려요. 주문은 하지 않아요",
                    note: "상품의 이름·값·파는 곳은 맥이 찾은 값 그대로예요. 값은 찾은 때의 값이라, 실제 값과 배송비는 상품 페이지에서 확인해 주세요. "
                        + "상품을 누르면 이 아이폰이 그 페이지에 직접 접속하고, 그림도 목록이 화면에 보일 때 그 사이트에서 직접 받아 와요(쿠키 없이, 저장하지 않아요). "
                        + "'고르기'를 누르면 '이걸로 할게요: 상품 이름'을 내 말로 보내고, 고른 상품의 번호가 맥으로 함께 가요. "
                        + "찾은 상품 목록은 공개 정보라 대화 기록에 남아서 다음 말을 판단할 때 Claude가 다시 봐요."
                ))
            }
            if setup.opensShop {
                // 맥과 맞춘 것 (D74): 맥은 검색어만 정한다. 쇼핑 화면은 이 아이폰이 직접 열고, 맥은 쇼핑 사이트에 접속하지 않는다.
                // 읽은 값은 "확인해 줘"를 누를 때만 맥으로 가고, 상품의 공개 정보라 맥의 대화 기록에 남아 Claude가 본다
                rows.append(Fact(
                    icon: .globe, text: "살 것을 말하면 앱 안의 쇼핑 화면에서 같이 봐요. 화면은 이 아이폰이 네이버 쇼핑에 직접 접속해서 열어요",
                    note: "Claude는 검색어만 정하고, 주소는 앱이 만들어요. 앱 안에서는 네이버 쇼핑 검색, 스마트스토어·브랜드스토어의 상품, 네이버 로그인 화면만 열고, "
                        + "주문서·결제와 그 밖의 주소는 열지 않아요. "
                        + "로그인은 그 화면에 내가 직접 입력해요. 앱은 아이디·비밀번호를 읽지도, 저장하지도, 보내지도 않아요. "
                        + "로그인된 상태(쿠키)는 이 아이폰의 앱 안 쇼핑 화면에만 남고, 쇼핑 화면의 메뉴에서 지울 수 있어요. 맥의 브라우저 로그인과는 따로예요. "
                        + "앱은 화면을 읽기만 하고 아무것도 누르지 않아요. 누르는 것은 모두 내가 해요. "
                        + (setup.drivesShop ? "내가 직접 둘러볼 때는 " : "") + "'확인해 줘'를 누를 때만, 그 화면에서 읽은 상품 정보(이름·가격·배송비·판매처·도착·재고·펼쳐 둔 옵션, 검색 결과면 상품 8개까지의 이름·가격·판매처)와 "
                        + "그 화면의 주소(호스트와 경로)가 맥으로 가요. 화면을 옮길 때마다 가지 않아요. "
                        + "이 값은 상품의 공개 정보라 대화 기록에 남아서 Claude가 봐요. "
                        + "로그인·장바구니·주문·내 정보 같은 화면은 읽지도 보내지도 않고, 배송지나 이름이 섞인 줄은 빼요."
                ))
            }
            if setup.drivesShop {
                // 맥과 맞춘 것 (D75, 맥의 코드로 확인): 맥의 작업은 검색어와 "목록의 몇 번째"만 정한다. 주소는 주지 않는다.
                // 앱은 주소를 열기만 하고 누르지 않는다. 읽은 것은 그 작업을 하는 동안 누르지 않아도 맥으로 간다.
                // 어느 것을 열지 고르는 것과 견준 말은 Claude가 한다. Claude에는 상품 정보만 가고 상품 주소는 가지 않는다
                rows.append(Fact(
                    icon: .globe, text: "살 것을 말하면 앱이 쇼핑 화면에서 직접 찾아 와요. 내가 보는 앞에서 검색 결과와 상품 화면을 열어 읽어요",
                    note: "이때는 '확인해 줘'를 누르지 않아도, 그 일을 하는 동안 앱이 연 검색 결과와 상품 화면에서 읽은 상품 정보와 그 화면의 주소(호스트와 경로)가 맥으로 가요. "
                        + "맥은 검색어와 '목록의 몇 번째 상품'만 정하고, 주소는 앱이 만들어요. "
                        + "목록에서 어느 상품을 열지는 Claude가 골라요. "
                        + "앱은 주소를 여는 것까지만 해요. 옵션·담기·구매·동의 같은 단추는 누르지 않고, 로그인 화면에서는 아무것도 하지 않아요. "
                        + "상품 화면은 한 번에 셋, 한 번 찾을 때 여섯까지만 열고, 검색은 두 번까지만 해요. 광고나 다른 사이트를 거치는 링크는 열지 않아요. "
                        + "사이트가 접속을 제한하면 그 자리에서 멈추고 다시 시도하지 않아요. 브라우저를 사람처럼 꾸미지 않아요. "
                        + "'멈추기'를 누르면 바로 멈추고 작업을 취소해요. "
                        + "읽어 온 상품은 대화에 목록으로 남고, 상품의 공개 정보라 대화 기록에 남아서 Claude가 봐요. "
                        + "고르고 견줄 때 Claude가 보는 것은 검색어, 내가 한 그 말, 읽어 온 상품의 이름·가격·판매처·배송·옵션·도착 안내예요(재고와 원래 가격은 이 길에서 쓰지 않아요). 상품 화면의 주소는 Claude로 가지 않아요(대화 기록에도 넣지 않아요). "
                        + "카드의 값은 화면에서 읽은 그대로이고, 내 조건과 견준 말은 Claude가 써요. "
                        + "읽지 않은 숫자(합계 같은 것)가 든 말은 맥이 버리고 정해 둔 문장으로 바꿔요."
                ))
            }
            if setup.takesUploads {
                // 맥과 맞춘 것 (D85, 맥의 문서와 코드로 확인): 붙인 것은 맥의 메모리에만 있고 쓰이지 않으면 30분 뒤 지워진다.
                // Claude에게는 그 대화의 답을 쓸 때만 보이고, 같은 대화의 다음 다섯 번까지 다시 보인다.
                // Claude에 닿지 못하면 맥의 로컬 모델에게 넘기지 않는다. 앱은 사진을 다시 만들어 보내고, 기록에는 종류와 PDF 이름만 둔다
                rows.append(Fact(
                    icon: .fileText, text: "입력창의 +로 붙인 사진과 PDF는 내 맥을 거쳐 Claude가 직접 봐요",
                    note: "내가 붙인 것만, 그 대화의 답을 쓰는 데만 써요. 같은 대화에서는 이어서 물을 수 있게 다음 다섯 번의 말까지 Claude가 다시 봐요. "
                        + "붙인 것은 Tailscale로 내 맥에 가고, 맥에서 Claude로 가요. 앱의 중계 서버는 거치지 않아요. "
                        + "사진은 보내기 전에 이 아이폰에서 JPEG로 다시 만들어요(긴 변 2,000픽셀까지). 이때 사진에 들어 있던 찍은 위치·시각·기기 정보는 빠지고, 사진의 파일 이름도 보내지 않아요. "
                        + "카메라로 찍어 붙인 사진도 같아요. 찍은 사진을 사진 보관함에 저장하지 않아요. "
                        + "PDF는 파일 그대로 가고, 파일 이름도 함께 가요. PDF 안에 든 정보는 앱이 가리지 못해요. "
                        + "맥은 붙인 것을 메모리에만 두고 파일로 저장하지 않아요. 쓰이지 않은 채 30분이 지나거나 맥 에이전트를 다시 켜면 지워져요. "
                        + "Claude에 연결되지 않으면 맥의 로컬 모델에게 대신 보여 주지 않고, 볼 수 없다고 알려요. "
                        + "이 아이폰도 붙인 것을 메모리에만 둬요. 대화 기록에는 '사진 2장' 같은 종류와 PDF의 파일 이름만 남고, 앱을 다시 켜면 그림은 보이지 않아요. "
                        + "붙인 것을 보고 Claude가 쓴 답은 다른 답처럼 대화 기록에 남아요."
                ))
            }
            return rows + [
                Fact(
                    icon: .cpu, text: "읽은 결과로 쓰는 답과 글은 맥의 로컬 모델이 쓰고, 브라우저·메일·로그인도 맥이 해요",
                    note: setup.browsesWeb
                        ? "사이트를 직접 열어 찾아보는 작업은 달라요. 브라우저는 맥에서 뜨지만 무엇을 누를지는 Claude가 정하고, 답도 Claude가 써요."
                        : nil
                ),
                Fact(icon: .info, text: "내가 글에 직접 쓴 이름이나 금액 같은 내용은 가리지 못하고 그대로 가요"),
                // 맥이 말풍선마다 누가 썼는지 알릴 때만 "표시한다"고 쓴다. 아니면 앱은 가릴 수 없다
                setup.marksWriter
                    ? Fact(
                        icon: .messageCircleQuestion, text: "회의 내용 질문은 위의 '질문할 때'처럼 중계 서버를 거쳐 Claude가 답해요",
                        // D107: 답 아래의 "Claude 사용" 표시는 보이지 않게 했다. 누가 썼는지는 대화 기록에 남는다
                        note: "맥을 거친 답은 Claude가 쓴 것과 맥의 로컬 모델이 쓴 것이 섞여 있어요. 누가 썼는지는 화면에 따로 표시하지 않아요. "
                            + "맡긴 일의 보고·초안·질문은 \(Self.cloudWritten(setup))모두 맥에서 만들어요."
                    )
                    : Fact(
                        icon: .messageCircleQuestion, text: "회의 내용 질문은 위의 '질문할 때'처럼 중계 서버를 거쳐 Claude가 답해요",
                        note: "맥을 거친 답은 Claude가 쓴 것과 맥의 로컬 모델이 쓴 것이 섞여 있고, 따로 표시하지 않아요."
                    )
            ] + push + [kept]
        }
    }

    var footer: String {
        // 맥이 다른 사람에게도 보낸다고 알릴 때만 그렇게 말한다 (D89). 받는 사람은 연락처의 이름이거나 내가 직접 쓴 주소뿐이다
        let approvals = setup.sendsOthers
            ? "초안은 승인해야 저장되고, 메일은 승인해야 보내요. 받는 사람은 내 주소이거나, 연락처에 있는 사람·내가 직접 쓴 주소예요. 삭제는 하지 않아요."
            : "초안은 승인해야 저장되고, 메일은 승인하면 내 주소로만 보내요. 다른 사람에게 보내기·삭제는 하지 않아요."
        let offline = "맥에 연결되지 않으면 쓴 글은 회의 질문으로 Claude에 보내요."
        let body = switch place {
        case .local: "\(approvals) 맥이 답한 말과 맥에서 만든 초안은 Claude로 보내지 않아요. \(offline)"
        case .cloud: "Claude에 닿지 않으면 그 말 한 번만 맥의 로컬 모델이 판단해요. \(approvals) \(offline)"
        }
        return [body, notice].compactMap { $0 }.joined(separator: "\n\n")
    }
}
