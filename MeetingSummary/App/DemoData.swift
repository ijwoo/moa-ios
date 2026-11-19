#if DEBUG
import Foundation
import SwiftData

/// 개발용 데모 데이터. 시뮬레이터 스크린샷 확인용으로, 실행 인자 `-demo`를 줄 때만 동작한다.
/// (Release·TestFlight 빌드에는 포함되지 않는다)
///
/// - `-demo`: 데모 회의 2개를 넣는다. 음성은 Recordings/demo.m4a 가 있으면 연결된다.
/// - `-demoTab meetings|tasks|profile|space`: 시작 탭
/// - `-demoOpenDetail`: 회의 탭에서 첫 회의 상세를 바로 연다
/// - `-demoSearch 검색어`: 회의 탭 검색어
/// - `-demoSeek 초`: 상세 화면 재생 위치
/// - `-demoSummarize`: 상세 화면을 열면 바로 요약 요청 (실제 프록시 호출)
/// - `-demoRecording` [`-demoBookmark`]: 마이크 없이 녹음 화면을 가짜 진행으로 띄운다
/// - `-demoSummary`: 데모 회의에 요약·할 일(완료 1, 기한 지남 1 포함)을 미리 채운다
/// - `-demoPrivacy`: 내 정보에서 데이터 처리 방식 화면을 연다
///   `-demoDialogCloud [bare|web|by|find|naver|weather|react|shop|browse]`(react는 weather에 더해 내 말에 반응을 다는 맥, D70. shop은 react에 더해 살 것을 찾아 달라는 말에 상품 목록을 주는 맥, D72. `-demoPickItem N`: 그 목록의 N번째를 고른다. browse는 react에 더해 살 것을 말하면 앱 안의 쇼핑 화면을 열게 하는 맥, D74: `-demoAgentAsk "생수 2L 6개 사고 싶어"`): 대화 판단을 Claude에 맡긴 맥처럼. bare는 회의 자료의 내용을 보내지 않는 맥, web은 웹 검색도 하는 맥, by는 답을 누가 썼는지도 알리는 맥(Claude가 쓴 답 아래에 'Claude 사용'), find는 "찾아 달라"는 말에 검색으로 답을 찾고 브라우저로 연 페이지를 카드로 붙이는 맥, naver는 그 페이지를 네이버 검색으로 찾는 맥, weather는 find에 더해 날씨 물음에 앱이 날씨 카드를 그리게 하는 맥(`-demoAgentAsk "부산 내일 날씨 어때"`. 날씨는 앱이 만든 가상 값이고, `-demoWeather denied`면 위치 권한이 없는 기기처럼 답한다) (그 화면의 맥 에이전트 설명이 바뀐다. `-demoAgentOffline`과 함께면 "확인하지 못했다" 안내)
/// - `-demoShopOpen` [`-demoShopPage N` | `-demoShopCart` | `-demoShopBlocked`] [`-demoShopGuide` | `-demoShopCheck`]: 쇼핑 화면 카드가 나오면 가상 쇼핑몰(`DemoShop`)로 쇼핑 화면을 연다 (D74).
///   N번째 가상 상품 화면으로 / 읽지 않는 화면(장바구니)으로 / 앱 안에서 열지 않는 주소를 눌렀을 때의 안내를. 그리고 안내 시트를 열거나 / "이 화면 확인해 줘"를 누른다. 실제 쇼핑몰에는 접속하지 않는다
/// - `-demoPush ask|on|denied|real`: 알림을 보낼 수 있는 맥처럼 (`-demoAgent`와 함께). 권한은 가짜가 답한다: ask는 아직 묻지 않음, on은 허용, denied는 꺼짐.
///   real이면 권한만 실제 시스템에 묻는다 (시뮬레이터에 `xcrun simctl push`로 가상 알림을 보내 배너를 볼 때)
/// - `-demoBottom`: 내 정보를 맨 아래 묶음부터 보이게 연다
/// - `-demoProfileScreen appearance|tone|permissions|licenses`: 내 정보에서 그 화면을 연다
/// - `-demoIntegrations`: 내 정보에서 연동 센터를 연다 (`-demoSiteLogin logged_in`, `-demoAgentSend`와 함께 쓰면 카드가 찬다)
/// - `-demoReminders` [`-demoRemindersSave`]: 상세의 미리알림 추가 시트를 띄운다 (그리고 실제로 추가)
/// - `-demoAsk "질문"` [`-demoOpenCitation`]: 질문 탭에서 질문을 보내고 (첫 근거를 연다) — 실제 프록시 호출
/// - `-demoAskTop`: 질문 탭 대화를 맨 위로 올린다 (글이 입력창·탭 막대 뒤로 지나가는 모습, "맨 아래로" 버튼 확인용)
/// - `-demoDraft "글"`: 입력칸에 글을 써 둔 모습 (보내기 버튼 확인용)
/// - `-settings.replyTone formal|friendly`: 답변 말투 설정을 이 실행에서만 바꾼다 (UserDefaults 실행 인자)
/// - `-demoAgent` [`-demoAgentOffline`]: 질문 탭에 가짜 맥 에이전트를 붙인다 (연결 안 됨 상태)
/// - `-demoAgentBlip N`: 가짜 맥이 처음 N번의 연결 확인에만 실패한다 (잠깐 끊겼다 돌아오는 맥)
/// - `-demoAgentAsk "말"` [`-demoAgentThen "다음 말"`] [`-demoAgentReject "사유"` | `-demoAgentApprove`]: 입력창으로 보내고(맥이 답·되묻기·작업·Claude 중 정한다), 승인 카드가 나오면 거부/승인
///   부탁에 "참조"가 있으면 가짜 맥이 작업 도중에 묻는다 (`-demoAgentThen`이 그 답이 된다). `-demoAgentV1`: 이전 서버처럼(질문·진행 설명·보고 없음)
///   `-demoReplyTask "글"`: 마지막 작업에 답장을 보낸다. `-demoReplyTaskBar`: 마지막 작업에 답장하려는 상태 (D59)
/// - `-demoLongChat N`: 가짜 맥과 N번 주고받아 긴 대화를 만든다 (스크롤, "맨 아래로" 버튼 확인용)
/// - `-demoAgentDetail` [`-demoAgentDetailLarge`] [`-demoAgentDetailEnd`]: 작업 상세를 연다 (크게, 끝부터)
/// - `-demoSiteLogin` [`hold|captcha|receipt|code|choice|blocked|unsupported|unsupported_login|unknown_field|logged_in`]: 사이트 로그인을 지원하는 맥처럼 (`-demoAgentAsk "네이버 로그인해줘"`로 연다).
///   `-demoSiteLoginAuto "비밀번호"`: 첫 입력 화면을 가상 값으로 채워 보낸다 ("wrong"이 들어 있으면 틀린 것). `-demoSiteLoginCard`: 로그인 화면을 바로 열지 않고 카드만
/// - `-demoLoginVault` [`saved`]: 로그인 값을 이 아이폰에 저장할 수 있는 기기처럼 (D78. 메모리에만 있는 가짜 보관소라 키체인도 Face ID도 쓰지 않는다).
///   saved면 네이버의 가상 아이디·비밀번호가 이미 저장되어 있다. `-demoIntegrations`와 함께 쓰면 연동 센터에 "이 아이폰에 저장한 로그인"이 보인다
/// - `-demoShopLogin`: 가상 쇼핑몰의 상품 화면이 로그인 화면으로 넘어간다 (D79. `-demoDialogCloud drive`와 함께: 로그인 화면에서 멈추는 것을 찍을 때)
/// - `-demoMailSetup` [`imap|failed|not_logged_in`]: 메일 연결("네이버 메일 연결")도 해 주는 맥처럼 (연동 센터의 메일 계정 묶음에 줄이 생긴다.
///   `-demoAgentSend -demoAgentSendResult no_address`와 함께 쓰면 아직 연결되지 않은 상태). `-demoMailSetupAuto N`: 물음 N개에 가상 값으로 답한다
/// - `-demoSkills`: 가짜 맥이 "맡길 수 있는 일" 카드를 알린다 (준비 상태는 `-demoSiteLogin logged_in`, `-demoAgentSend`에 따라 달라진다).
///   `-demoSidebar` [`초`]: 질문 탭의 사이드바를 연 모습. `-demoScreen skills|tasks`: 사이드바에서 들어가는 화면(맡길 수 있는 일, 에이전트 작업)을 바로 연다
/// - `-demoSiteDo` [`allowed`]: 가짜 맥이 로그인한 사이트 안에서 해 준다 (D80. `-demoAgentAsk "todo.test에 할 일 추가해줘"`로 시작한다. 사이트도 할 일도 지어낸 것이다).
///   처음에는 그 화면을 Claude가 봐도 되는지 묻고(`-demoAgentThen "이번만"`이 그 답이 된다), `allowed`면 묻지 않고 "단추 누르기" 승인 카드까지 간다
/// - `-demoCapture` [`blocked|open|gone|flaky|login|pair|card|workroom`]: 가짜 맥이 보고에 화면 캡처를 붙인다 (`-demoAgentAsk "결제내역 알려줘"`로 시작한다).
///   그림은 앱이 그린 가상 웹 화면이다. `blocked`: 로그인이 풀려 멈춘 화면, `open`: 내 정보가 없다고 알린 화면,
///   `gone`: 맥이 이미 지움, `flaky`: 처음 한 번은 받지 못함, `pair`: 캡처 두 장 + 굵은 낱말이 든 문단 여럿의 답 (D84)
/// - `-demoAttach` [`one|two|pdf|mix`]: 가짜 맥이 사진·PDF를 받는다 (D85). 입력창에 **앱이 그린 가상의** 사진·PDF를 붙여 둔다
///   (`one`: 영수증 한 장, `two`: 영수증과 화이트보드, `pdf`: 안내문 PDF, `mix`: 사진 둘과 PDF).
///   `-demoAttachSend "말"`: 그 말과 함께 보낸다. `-demoAttachOnly`: 글 없이 보낸다. `-demoAttachSlow 초`: 올리는 데 그만큼 걸린다 (올리는 중의 모습)
/// - `-demoRoutines` [`empty`]: 예약을 하는 가짜 맥 (D91. 예약도 결과도 지어낸 것이다). `-demoScreen routines`: 예약 화면을 바로 연다.
///   `-demoRoutineRun`: 아침 브리핑이 돈 결과를 대화로 연 모습 (알림을 눌렀을 때와 같다)
/// - `-demoSiteLogin simple`: 간편인증 흐름 (D90. 인증 앱 고르기 → 이름·생년월일·휴대폰 번호 → 동의 → "인증 완료". 인증 앱 이름은 지어낸 것이다)
/// - `-demoContacts` [`ask|denied`]: 지어낸 주소록을 쓴다 (D89. 실제 연락처를 읽지 않고 권한도 묻지 않는다. `ask`: 아직 묻지 않은 기기, `denied`: 꺼 둔 기기).
///   `-demoAgentSend`와 함께 `-demoAgentAsk "김팀장한테 회의 정리 메일 보내줘"`로 다른 사람에게 보내는 승인 카드를 본다
/// - `-demoSpace` [`empty`]: 내 공간을 하는 가짜 맥 (D94. 카드도 내용도 지어낸 것이다). `-settings.space YES`로 탭을 켜고 `-demoTab space`로 그 탭을 연다.
///   `-demoSpaceSay "말"`: 그 말로 고친 모습 (카드가 바뀌고 알림이 뜬다). `-demoSpaceEdit`: 편집을 연 모습. `-demoCalendar ask|denied|none`: 오늘 일정 카드의 캘린더 (D95. 일정은 지어낸 것이다)
/// - `-demoOnboarding`: 처음 한 번 보이는 화면을 띄운다 (D97. 개발용 실행에서는 이 인자를 줄 때만 보인다)
@MainActor
enum DemoData {
    static let arguments = ProcessInfo.processInfo.arguments
    static var isEnabled: Bool { arguments.contains("-demo") }

    static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func seed(into context: ModelContext) {
        guard isEnabled, (try? context.fetchCount(FetchDescriptor<Meeting>())) == 0 else { return }

        let legacy = Meeting(
            title: "채용 계획 회의",
            date: .now.addingTimeInterval(-3600 * 3),
            duration: 1453,
            transcript: "다음 분기 채용 계획을 이야기했습니다. 프론트엔드 한 명을 먼저 뽑고 면접 일정은 다음 주에 다시 정하기로 했습니다. (말풍선 기능 이전 방식으로 받아쓴 가상 예시)"
        )
        legacy.isRecordingComplete = true
        context.insert(legacy)

        let meeting = Meeting(title: "주간 회의 11월 10일 오후 4:00", duration: 33.5)
        meeting.isRecordingComplete = true
        meeting.audioFileName = "demo.m4a"
        let lines: [(Double, Double, String)] = [
            (0.00, 6.78, "첫 번째 문장입니다. 오늘 회의에서는 베타 출시 일정을 논의합니다."),
            (6.78, 13.62, "두 번째 문장입니다. 디자인 시안은 금요일까지 확정하기로 했습니다."),
            (13.62, 21.24, "세 번째 문장입니다. 서버 부하 테스트는 다음 주 화요일에 진행합니다."),
            (21.24, 28.80, "네 번째 문장입니다. 결제 연동 방식은 아직 정하지 못했습니다."),
            (28.80, 33.51, "다섯 번째 문장입니다. 다음 회의는 목요일 오후 2시입니다."),
        ]
        context.insert(meeting)
        for (start, end, text) in lines {
            meeting.appendUtterance(Utterance(start: start, end: end, text: text))
        }
        // 파형은 일부러 넣지 않는다: 상세 화면이 음성 파일에서 파형을 뽑는 경로를 확인하기 위해
        meeting.bookmarks = [Bookmark(time: 12.5), Bookmark(time: 30)]

        // -demoSummary: 요약·할 일까지 미리 채운다 (할 일·내 정보 화면 확인용, API 호출 없음)
        if arguments.contains("-demoSummary") {
            let calendar = Calendar.current
            let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))
            let friday = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: .now))
            let done = ActionItem(task: "베타 출시일 공지 초안 작성", owner: "이서연", dueText: "어제", dueDate: yesterday, order: 0)
            done.isCompleted = true
            done.completedAt = .now
            let late = ActionItem(task: "디자인 시안 확정", owner: "김지원", dueText: "어제까지", dueDate: yesterday, isAddedToReminders: true, order: 1)
            let soon = ActionItem(task: "서버 부하 테스트 진행", dueText: "다음 주 화요일", order: 2)
            let open = ActionItem(task: "결제 연동 방식 비교 자료 정리", owner: "박민수", dueText: "금요일", dueDate: friday, isAddedToReminders: true, order: 3)
            meeting.summary = Summary(
                topic: "베타 출시 일정 점검",
                body: "베타 출시 일정과 준비 작업을 점검했습니다.",
                decisions: ["베타 출시일 12월 첫째 주로 확정"],
                actionItems: [done, late, soon, open],
                openQuestions: ["결제 연동 방식 미정"]
            )
            try? meeting.transition(to: .processing)
            try? meeting.transition(to: .ready)
        }
        try? context.save()
    }
}
#endif
