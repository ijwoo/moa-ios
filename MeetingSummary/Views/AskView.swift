import PhotosUI
import SwiftData
import SwiftUI

/// 질문 탭 (첫 화면): 지난 회의에 대해 묻는 채팅 + 녹음 버튼.
///
/// - 답변 아래 근거 카드를 누르면 그 회의 상세로 가서 해당 말풍선으로 스크롤·강조한다.
/// - 대화는 저장되어 앱을 다시 열어도 남는다. 왼쪽 위 단추로 사이드바를 열어 지난 대화를 다시 연다 (D53).
/// - 입력창은 하나다. 맥 에이전트가 설정되어 있으면 맥이 답할지, 작업으로 만들지, Claude에게 넘길지 정한다.
///   Claude가 답한 말풍선에는 "Claude 사용"이 붙는다.
struct AskView: View {
    /// 대화. 사이드바(최상위 화면)와 함께 쓰므로 밖에서 받는다
    let session: AskSession
    /// 사이드바가 열려 있는지와, 거기서 고른 화면
    @Bindable var sidebar: ChatSidebarModel
    /// 맡길 수 있는 일 목록
    let skills: SkillsModel
    let onRecord: () -> Void
    /// 내 정보의 연동 센터를 연다 (로그인 완료 카드를 눌렀을 때)
    var onOpenIntegrations: () -> Void = {}
    /// 알림을 눌러 들어온 작업 (D67). 그 카드로 간 뒤 비운다
    var pushedTaskID: Binding<String?> = .constant(nil)
    /// 다른 탭에서 넘어온 말 (내 공간 카드의 단추, D99). 새 대화에서 보낸 뒤 비운다
    var pendingAsk: Binding<String?> = .constant(nil)

    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Environment(\.modelContext) private var modelContext
    @State private var question = ""
    @State private var target: CitationTarget?
    /// 에이전트 작업 목록에서 고른 작업 카드. 대화로 돌아오면 그 자리로 간다
    @State private var jumpTarget: AskSession.Message.ID?
    /// 개인비서 알림 (D127): "모아"를 꾹 누르면
    @State private var showingNews = false
    /// 모아와의 통화 (D134). 접어 두어도 이어진다
    @State private var call: VoiceCall?
    @State private var showingCall = false
    /// 연결된 맥이 통화를 받는지
    @State private var callAvailable = false
    /// 펼쳐 본 통화의 받아쓰기 (D137)
    @State private var openedCall: CallTranscript?
    @State private var detail: AgentDetailTarget?
    /// 메일 계정 연결 화면 (계정 때문에 보내지 못한 작업에서 연다)
    @State private var connecting: MailConnectTarget?
    /// 사이트 로그인 화면 (맥이 로그인이 필요하다고 했을 때 연다)
    @State private var loggingIn: SiteLoginTarget?
    /// 답장하려고 고른 말 (입력창 위에 보인다)
    @State private var replying: AskSession.Quote?
    /// 대화를 왼쪽으로 미는 손길: 말풍선 위에서는 답장, 빈 곳에서는 보낸 시각 (D68)
    @State private var swipe = ChatSwipeModel()
    /// 앱 안의 쇼핑 화면 (D74). 닫았다 열어도 보던 화면 그대로다
    @State private var shopBrowser = ShopBrowser.forApp()
    /// 글 일부만 고르는 화면 (길게 눌러 "선택")
    @State private var selecting: SelectTarget?
    /// 붙일 것을 고르는 화면 (D85): 사진 보관함, 파일
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    /// 카메라로 찍어 붙이는 중 (D87)
    @State private var takingPhoto = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool
    /// 대화를 위로 올려 보고 있는지 (맨 아래로 버튼 표시)
    @State private var awayFromBottom = false
    /// 이만큼(pt) 넘게 올라가 있어야 버튼을 보인다. 말풍선 한두 개 높이로는 나타나지 않게
    private static let awayThreshold: CGFloat = 160
    /// 사용자가 스크롤을 멈춘 자리가 맨 아래가 아닌지. 참이면 작업 상태가 바뀌어도 끌어내리지 않는다
    @State private var readingAbove = false
    /// "맨 아래로" 버튼이 쓰는 스크롤 위치 (관성 스크롤 중에 눌러도 맨 아래까지 옮길 수 있다)
    @State private var scrollPosition = ScrollPosition()
    /// 화면이 막 나타난 직후: 내용 높이와 아래 여백(입력창·탭 막대)이 자리 잡는 동안 맨 아래를 따라간다 (손을 대면 끝)
    @State private var settlingAtBottom = false
    /// "이전 대화 보기"를 눌러 위에 말이 더 그려지는 중 (보고 있던 자리를 지킨다)
    @State private var keepsPlace = false
    /// 키보드가 오르내릴 때 맨 아래가 아닌 자리에서도 대화를 같이 옮긴다 (D54)
    @State private var keyboardFollow = KeyboardFollow()

    private static func isAway(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height - geometry.visibleRect.maxY > awayThreshold
    }
    @Environment(\.scenePhase) private var scenePhase
    /// 기다리는 작업을 여는 중 (D113)
    @State private var openingWaiting = false
    #if DEBUG
    @State private var demoScreenOpened = false
    /// 개발용 실행 인자로 보내는 말은 한 번만 보낸다 (다른 화면에 다녀오면 `.task`가 다시 돌기 때문)
    @State private var demoSent: Set<String> = []
    #endif

    /// 작업 상세로 볼 작업 (상태는 대화에서 계속 새로 읽는다)
    struct AgentDetailTarget: Identifiable { let id: String }

    struct SelectTarget: Identifiable {
        let id = UUID()
        let text: String
    }

    struct MailConnectTarget: Identifiable {
        /// 연결한 뒤 다시 맡길 작업
        let id: String
        var provider: MailProvider = .naver
        var address = ""
    }

    struct SiteLoginTarget: Identifiable {
        let id = UUID()
        let flow: SiteLoginFlow
    }

    struct CitationTarget: Hashable {
        let meeting: Meeting
        let utteranceID: UUID?
    }

    private var suggestions: [String] {
        var list = [
            "지난 회의에서 정한 결정 사항이 뭐였지?",
            "아직 해결 안 된 질문 정리해줘",
            "담당자가 정해진 할 일만 알려줘",
        ]
        // 맥이 연결되어 있을 때만 부탁 예시를 보여 준다
        if session.hasAgent, session.agentReachable != false {
            list[1] = "지난 회의 할 일로 팀 공유 메일 초안 써줘"
        }
        return list
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // 그리는 말을 모두 한꺼번에 놓는다 (D69). 필요할 때 만드는 목록(LazyVStack)은 아직 만들지 않은 말의 높이를 어림하는데,
                    // 키보드가 오르내릴 때 그 어림이 크게 흔들려 대화가 통째로 비거나 키보드 높이만큼 떠 있었다.
                    // 대신 긴 대화는 최근 것만 그린다 (`shownRows`)
                    // 간격은 말마다 다르다: 같은 쪽이 이어서 한 말은 붙이고, 차례가 바뀌면 띄운다
                    VStack(alignment: .leading, spacing: 0) {
                        if session.messages.isEmpty {
                            emptyState
                        }
                        if session.earlierCount > 0 {
                            EarlierMessagesButton(count: session.earlierCount) { showEarlier() }
                        }
                        let calls = CallFold(rows: shownRows.map(\.element))
                        ForEach(shownRows, id: \.element.id) { index, message in
                            // 통화 중에 주고받은 말은 카드 하나로 접는다 (D137). 작업·승인 카드는 그대로 둔다
                            if let callID = message.callID {
                                if calls.hosts.contains(message.id) {
                                    CallCard(
                                        messages: calls.messages(of: callID, in: session.messages),
                                        isLive: call != nil && session.callID == callID
                                    ) {
                                        openedCall = CallTranscript(id: callID, messages: calls.messages(of: callID, in: session.messages))
                                    }
                                    .padding(.top, spacing(before: index))
                                    .id(message.id)
                                    .chatAppear()
                                }
                            } else {
                            MessageView(
                                message: message,
                                showsSource: session.hasAgent,
                                marksClaude: AskSession.marksClaude(at: index, in: session.messages),
                                canResendToAgent: session.resendableMessageID == message.id,
                                onResendToAgent: { Task { await session.resendToAgent(message.id, meetings: meetings) } },
                                canOpen: { citation in meetings.contains { $0.id == citation.meetingID } },
                                onOpen: open,
                                onRetry: retry,
                                onResume: { Task { await session.resumeAgent() } },
                                isBusy: session.isBusy(message),
                                onDecide: decide,
                                onAnswer: { id, answer in
                                    dismissKeyboard()
                                    Task { await session.answer(id, with: answer) }
                                },
                                onCancel: { id in Task { await session.cancelAgent(id) } },
                                onOpenDetail: { id in
                                    dismissKeyboard()
                                    detail = AgentDetailTarget(id: id)
                                },
                                onConnectMail: session.mailConnectTaskID == message.agent?.id ? { connectMail(for: message.agent) } : nil,
                                mailNeedsAddressSetup: session.mailNeedsAddressSetup,
                                onSiteLogin: siteLoginAction(for: message),
                                onOpenSite: { site in openSiteLogin(site) },
                                resumesAfterLogin: session.siteLoginPrompt?.messageID == message.id && session.siteLoginPrompt?.request != nil,
                                onOpenIntegrations: {
                                    dismissKeyboard()
                                    onOpenIntegrations()
                                },
                                onReact: { session.react(message.id, with: $0) },
                                onReply: canReply ? { reply(to: message.id) } : nil,
                                canReplyToTask: session.canReplyToTask,
                                onJump: { jump(to: $0, with: proxy) },
                                steerTarget: message.steer.flatMap { steer in session.messages.first { $0.agent?.id == steer.taskID }?.id }
                            )
                            .chatSwipeRow(id: message.id, date: message.date)
                            .padding(.top, spacing(before: index))
                            .id(message.id)
                            .chatAppear()
                            }
                        }
                        if !session.pendingChoices.isEmpty {
                            ChoiceButtons(
                                choices: session.pendingChoices, recommended: session.pendingRecommended,
                                multi: session.pendingMulti, images: session.pendingChoiceImages
                            ) { send($0) }
                                // 다른 되물음이면 고른 표시를 새로 시작한다
                                .id(session.messages.last?.id)
                                .padding(.top, 10)
                        } else if let next = session.pendingFollowUps {
                            // 답 뒤의 다음 말 (D111): 고르지 않고 그냥 다른 말을 해도 된다
                            ChoiceButtons(
                                choices: next.choices, recommended: next.recommended,
                                title: "이어서 더 확인해 볼까요?", closing: "괜찮아요, 여기까지 볼게요",
                                onClose: { withAnimation(.snappy(duration: 0.2)) { session.dismissFollowUps() } }
                            ) { send($0) }
                                .id(session.messages.last?.id)
                                .padding(.top, 10)
                        }
                        if session.showsThinking {
                            ThinkingIndicator()
                                .padding(.top, session.messages.last?.role == .user ? DS.Chat.turnSpacing : 10)
                                .id("thinking")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    // 빈 곳을 왼쪽으로 밀면 대화 전체가 밀리고 오른쪽에서 보낸 시각이 나온다 (D68)
                    .chatTimeShift()
                    .sidebarDragShield(sidebar)
                    .background(KeyboardFollow.Probe(follow: keyboardFollow))
                    // 대화 안에서만 대화 모양을 쓴다. 시트(작업 상세)는 이 값을 받지 않아 원래 모양이다
                    .environment(\.inChat, true)
                    .chatDesk(itemPicker: itemPicker, shop: shopDesk)
                    // 보고에 붙은 화면 캡처, 찾은 페이지 카드의 대표 그림, 내 말에 붙여 보낸 사진 (모두 메모리에만 있다)
                    .chatImages(of: session)
                    .environment(swipe)
                    .environment(\.selectText) { text in
                        dismissKeyboard()
                        selecting = SelectTarget(text: text)
                    }
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.12), value: session.messages.count)
                }
                .scrollPosition($scrollPosition)
                // 사이드바를 끄는 동안과 열려 있는 동안은 대화를 굴리지 않고 스크롤 선도 감춘다:
                // 옆으로 끄는 손길이 대화의 스크롤과 함께 받아져, 조금 비스듬히 끌면 스크롤 선이 나타나 화면을 따라다녔다
                // (D148: 사이드바 값은 이 수식어 안에서만 읽는다. 여기 body가 읽으면 끄는 동안 대화 전체를 매 순간 다시 그렸다)
                .sidebarScrollLock(sidebar, inPanel: false)
                // 키보드가 오르내리면 보이는 높이가 바뀐다. 그때 아래쪽을 붙잡아, 대화가 입력창과 한 몸으로 같이 움직인다
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollDismissesKeyboard(.interactively)
                // 바탕은 키보드 뒤까지 깐다. 키보드의 둥근 위쪽 모서리 뒤로 창의 검은 바탕이 비치지 않게
                .background(ChatBackdrop())
                // 대화가 짧아 스크롤할 수 없을 때도 빈 곳을 누르면 키보드를 내린다
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                // 대화를 오른쪽으로 밀면 사이드바가 손가락을 따라 나온다 (D55). 세로로 미는 것은 그대로 스크롤이다
                .sidebarDrag(sidebar) { dismissKeyboard() }
                // 왼쪽으로 밀면: 말풍선 위에서는 그 말에 답장, 빈 곳에서는 보낸 시각 (D68). 사이드바가 열려 있으면 닫는 손길이라 받지 않는다
                .chatSwipe(swipe, isEnabled: { !sidebar.isOpen && !sidebar.isDragging }) { id in
                    if canReply { reply(to: id) }
                }
                // 맨 아래에서 꽤 올라가 있으면 "맨 아래로" 버튼을 보인다 (입력창 바로 위 오른쪽)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    Self.isAway(geometry)
                } action: { _, away in
                    withAnimation(.easeOut(duration: 0.2)) { awayFromBottom = away }
                }
                // 화면이 막 나타난 직후에는 내용 높이·아래 여백이 바뀔 때마다 맨 아래로 다시 맞춘다 (`settlingAtBottom`)
                .onScrollGeometryChange(for: [CGFloat].self) { geometry in
                    [geometry.contentSize.height, geometry.contentInsets.bottom, geometry.containerSize.height]
                } action: { _, _ in
                    if settlingAtBottom { scrollPosition.scrollTo(edge: .bottom) }
                }
                // 맨 아래가 아닌 자리에서 키보드가 오르내리면, 보이는 높이가 바뀐 만큼 대화를 같이 옮긴다 (`KeyboardFollow`)
                .onScrollGeometryChange(for: KeyboardFollow.Snapshot.self) { geometry in
                    KeyboardFollow.Snapshot(geometry)
                } action: { old, new in
                    keepPlace(old: old, new: new)
                    followKeyboard(to: keyboardFollow.visibleHeightChanged(old: old, new: new))
                    // 맨 아래를 지나 멈춰 있으면(키보드는 내려갔는데 대화가 떠 있는 것) 돌려놓는다 (D69)
                    keyboardFollow.note(new)
                    keyboardFollow.correctAfterSettling { followKeyboard(to: $0) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                    followKeyboard(to: keyboardFollow.keyboardWillMove(timing: KeyboardFollow.Timing(note)))
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                    followKeyboard(to: keyboardFollow.keyboardWillMove(timing: KeyboardFollow.Timing(note)))
                }
                // 스크롤이 멈춘 자리로 "읽는 중"을 정한다. 내용이 늘어난 것만으로는 바뀌지 않아, 맨 아래에 있던 사람은 계속 따라간다
                .onScrollPhaseChange { _, phase, context in
                    // 손을 대면 따라가기를 그만둔다 (읽으려고 올리는 것을 끌어내리지 않는다)
                    if phase == .interacting { settlingAtBottom = false }
                    keyboardFollow.isIdle = phase == .idle
                    guard phase == .idle else { return }
                    keyboardFollow.correctAfterSettling { followKeyboard(to: $0) }
                    readingAbove = Self.isAway(context.geometry)
                }
                .overlay(alignment: .bottomTrailing) {
                    if awayFromBottom { scrollToBottomButton(proxy) }
                }
                .onChange(of: session.epoch) {
                    awayFromBottom = false
                    readingAbove = false
                }
                .onChange(of: session.messages.count) {
                    withAnimation { scrollPosition.scrollTo(edge: .bottom) }
                }
                .onChange(of: session.isLoading) {
                    withAnimation { scrollPosition.scrollTo(edge: .bottom) }
                }
                .onChange(of: session.messages.last?.agent) {
                    // 작업 상태는 몇 초마다 바뀐다. 사용자가 위로 올려 읽는 중이면 끌어내리지 않는다 ("맨 아래로" 버튼으로 돌아온다)
                    guard !readingAbove else { return }
                    withAnimation { scrollPosition.scrollTo(edge: .bottom) }
                }
                .onAppear {
                    // 작업 목록에서 고른 카드로 가는 중이면 맨 아래로 내리지 않는다
                    guard jumpTarget == nil else { return }
                    scrollPosition.scrollTo(edge: .bottom)
                    // 앱을 켠 직후에는 입력창·탭 막대만큼의 아래 여백이 이 스크롤보다 늦게 잡힌다.
                    // 그대로 두면 마지막 말이 입력창 뒤에 가려진 채로 시작하므로, 자리가 잡히는 잠깐 동안 맨 아래를 따라간다
                    settlingAtBottom = true
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        settlingAtBottom = false
                    }
                }
                // 에이전트 작업 목록에서 고른 카드로 간다. 대화가 바뀌었으면 스크롤 뷰가 새로 만들어진 뒤에 다시 돈다
                .task(id: jumpTarget) {
                    guard let id = jumpTarget else { return }
                    settlingAtBottom = false
                    // 아직 그리지 않은 이전 말이면 거기까지 그린 다음에 간다
                    if session.reveal(id) { try? await Task.sleep(for: .milliseconds(50)) }
                    proxy.scrollTo(id, anchor: .center)
                    // 목록 화면이 물러나는 동안 한 번 더 맞춘다 (그 사이 아래 여백이 다시 잡힌다)
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    settlingAtBottom = false
                    // 작업 상태가 새로 와도 맨 아래로 끌어내리지 않게 "읽는 중"으로 둔다
                    readingAbove = true
                    proxy.scrollTo(id, anchor: .center)
                    jumpTarget = nil
                }
                #if DEBUG
                .task {
                    // 개발용: -demoAskTop — 대화를 맨 위로 올려, 글이 입력창과 탭 막대 뒤로 지나가는 모습을 캡처한다
                    guard DemoData.arguments.contains("-demoAskTop") else { return }
                    try? await Task.sleep(for: .seconds(8))
                    if let first = shownRows.first { proxy.scrollTo(first.element.id, anchor: .top) }
                }
                #endif
                // 다른 대화로 바뀌면 스크롤 뷰를 새로 만든다. 긴 대화에서 짧은 대화로 바뀔 때
                // 이전 스크롤 위치가 남아 화면이 비어 보이는 일을 막는다
                .id(session.epoch)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 가운데: 지금 무엇을 기다리는지, 평소에는 누가 답하는지 (유리 알약 하나)
                ToolbarItem(placement: .principal) {
                    HeaderStatus(status: session.status, hasAgent: session.hasAgent, agentReachable: session.agentReachable)
                        // 누르면 개인비서 알림 (D127·D128): 내 답을 기다리는 일과 맥이 최근에 한 일, 누르면 그 대화로
                        .contentShape(Capsule())
                        .onTapGesture {
                            Haptic.tap()
                            dismissKeyboard()
                            showingNews = true
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("누르면 개인비서 알림을 봅니다")
                }
                // 왼쪽: 사이드바 (새 대화, 맡길 수 있는 일, 에이전트 작업, 최근 대화)
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismissKeyboard()
                        sidebar.isOpen = true
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .accessibilityLabel("사이드바 열기")
                        // 위 막대의 단추는 강조색으로 물들이지 않고 글자색으로 (D144: 탭 막대에 준 강조색이 여기까지 내려온다)
                        .tint(DS.Chat.textPrimary)
                }
                // 오른쪽: 모아에게 전화 걸기 (D134, 맥이 받을 때만)
                if callAvailable, call == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            startCall()
                        } label: {
                            Image(systemName: "phone")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel("모아에게 전화 걸기")
                        // 위 막대의 단추는 강조색으로 물들이지 않고 글자색으로 (D144: 탭 막대에 준 강조색이 여기까지 내려온다)
                        .tint(DS.Chat.textPrimary)
                        .disabled(session.isLoading)
                    }
                }
                if !session.messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            session.reset()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel("새 대화")
                        // 위 막대의 단추는 강조색으로 물들이지 않고 글자색으로 (D144: 탭 막대에 준 강조색이 여기까지 내려온다)
                        .tint(DS.Chat.textPrimary)
                        .disabled(!session.canSwitchConversation)
                    }
                }
            }
            // 대화는 입력창과 탭 막대 뒤로 흐리게 비치며 지나간다 (D88: D83에서 막았던 것을 사용자 요청으로 되돌렸다).
            // 흐림은 시스템이 하고, 그 위에 바탕색을 엷게 입혀 비친 글이 옅게만 보이게 한다 (`ChatBarBackdrop`)
            .safeAreaBar(edge: .bottom) { inputBar }
            // 통화 화면을 접었을 때: 대화 위에 "통화 중" 알약 (누르면 돌아간다)
            .safeAreaInset(edge: .top) {
                if let call, !showingCall {
                    VoiceCallPill(call: call, onOpen: { showingCall = true }, onEnd: endCall)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .fullScreenCover(isPresented: $showingCall) {
                if let call {
                    VoiceCallView(call: call, onMinimize: { minimizeCall() }, onEnd: endCall)
                }
            }
            .task(id: session.agentReachable) {
                callAvailable = await session.supportsVoiceCall()
                #if DEBUG
                if DemoData.arguments.contains("-demoCallFold"), !session.messages.contains(where: { $0.callID != nil }) {
                    try? await Task.sleep(for: .seconds(1))
                    session.insertDemoCall()
                }
                if DemoData.arguments.contains("-demoCall"), call == nil {
                    callAvailable = true
                    try? await Task.sleep(for: .seconds(1))
                    let demo = VoiceCall(session: session, meetings: { [] })
                    demo.startDemo(approval: DemoData.value(after: "-demoCall") == "approval")
                    call = demo
                    showingCall = !DemoData.arguments.contains("-demoCallPill")
                }
                #endif
            }
            .sheet(item: $openedCall) { transcript in
                CallTranscriptView(transcript: transcript)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingNews) {
                AssistantNewsView(session: session) { taskID in
                    // 그 작업의 카드로 간다 (대화가 바뀌었으면 스크롤 뷰가 새로 만들어진 뒤에 돈다)
                    if let taskID, let message = session.messages.last(where: { $0.agent?.id == taskID }) { jumpTarget = message.id }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            // 위쪽은 선 없이 흐리게 사라진다 (D127, 참고 앱처럼). 시스템이 진한 띠와 선으로 끊던 것을 부드러운 흐림으로
            .scrollEdgeEffectStyle(.soft, for: .all)
            .navigationDestination(item: $target) { target in
                MeetingDetailView(meeting: target.meeting, focusUtteranceID: target.utteranceID)
            }
            .navigationDestination(item: $sidebar.screen) { screen in
                sidebarScreen(screen)
            }
            .sheet(isPresented: $sidebar.showingHistory) {
                ConversationHistorySheet(session: session)
            }
            .onChange(of: session.epoch) {
                // 다른 대화로 바뀌면 앞 대화의 말에 달던 답장은 버린다
                replying = nil
            }
            .sheet(item: $connecting) { target in
                // 앱 비밀번호는 이 화면에서 맥으로 바로 간다. 채팅 입력창·대화 기록을 거치지 않는다
                MailConnectSheet(provider: target.provider, address: target.address) { provider, address, password in
                    try await session.connectMail(provider: provider, address: address, password: password)
                } onConnected: {
                    Task { await session.retryAfterMailConnect(target.id, meetings: meetings) }
                }
            }
            .sheet(item: $loggingIn) { target in
                // 아이디·비밀번호는 이 화면에서 맥으로 바로 간다. 채팅 입력창·대화 기록을 거치지 않는다
                SiteLoginSheet(flow: target.flow)
            }
            // "로그인이 풀린 사이트가 있어요" 알림을 눌렀다 (D122): 저장해 둔 값으로 그 사이트에 다시 로그인한다 (얼굴 확인 한 번)
            .onChange(of: session.reloginSite, initial: true) { _, site in
                guard let site else { return }
                session.reloginSite = nil
                openSiteLogin(site, auto: true)
            }
            .onChange(of: session.siteLoginPrompt) { old, new in
                // 맥이 "로그인 화면을 열게요"라고 답하면 바로 연다. 닫은 뒤에는 카드의 버튼으로 다시 연다
                #if DEBUG
                // 화면 확인용: 카드만 보이게 로그인 화면을 바로 열지 않는다
                if DemoData.arguments.contains("-demoSiteLoginCard") { return }
                #endif
                if let new, old?.messageID != new.messageID { openSiteLogin(for: new) }
            }
            // 쇼핑 화면 (D74). 내비게이션 바깥에 단다 (`shopCover`)
            .shopCover(shopDesk)
            .sheet(item: $selecting) { target in
                TextSelectSheet(text: target.text)
            }
            .sheet(item: $detail) { target in
                if let state = session.messages.first(where: { $0.agent?.id == target.id })?.agent {
                    AgentTaskDetailView(state: state) {
                        Task { await session.cancelAgent(target.id) }
                    }
                }
            }
            .task {
                await session.checkAgent()
                // 앱을 다시 열었을 때: 끝나지 않은 작업을 이어서 확인한다
                session.attach(modelContext)
                await session.resumeAgent()
                await session.resumeMessage(meetings: meetings)
                // 다른 대화(맥이 직접 만든 대화 포함)에서 내 답을 기다리는 작업 (D113)
                await session.checkWaitingTasks()
            }
            .task(id: session.mailConnectTaskID) {
                // 연결 안내가 붙으면 계정 목록을 받아 둔다 (주소 미리 채우기, 주소가 없을 때의 안내)
                if session.mailConnectTaskID != nil { await session.loadMailAccounts() }
            }
            .onChange(of: scenePhase) { _, phase in
                // 다른 앱에 다녀온 사이에도 맥에서는 작업이 계속된다. 맥 연결도 다시 확인한다
                if phase == .active {
                    Task {
                        await session.checkAgent()
                        await session.resumeAgent()
                        // 뒤에 가 있는 동안 답을 놓친 메시지가 있으면 같은 번호로 다시 받는다
                        await session.resumeMessage(meetings: meetings)
                        await session.checkWaitingTasks()
                        await session.refreshConversationNews()
                    }
                } else if phase == .background {
                    // 캡처는 내 실제 화면이다: 앱이 뒤로 가면 받은 그림을 버리고 다시 가린다
                    session.captures.clear()
                    // 찾은 페이지의 그림도 버린다 (돌아오면 보이는 카드만 다시 받는다)
                    session.thumbnails.clear()
                }
            }
            .onChange(of: session.conversation?.id) {
                Task { await session.resumeAgent() }
            }
            .onChange(of: pendingAsk.wrappedValue, initial: true) {
                guard let text = pendingAsk.wrappedValue else { return }
                pendingAsk.wrappedValue = nil
                askInNewChat(text)
            }
            .onChange(of: pushedTaskID.wrappedValue, initial: true) {
                guard let taskID = pushedTaskID.wrappedValue else { return }
                pushedTaskID.wrappedValue = nil
                if let message = session.messages.last(where: { $0.agent?.id == taskID }) { jumpTarget = message.id }
            }
            .onAppear {
                session.attach(modelContext)
                #if DEBUG
                if DemoData.arguments.contains("-demoHistory") { sidebar.showingHistory = true }
                // -demoScreen skills|tasks: 사이드바에서 들어가는 화면을 바로 연다
                // (대화로 돌아올 때도 이 자리가 다시 불리므로 처음 한 번만)
                if !demoScreenOpened {
                    demoScreenOpened = true
                    switch DemoData.value(after: "-demoScreen") {
                    case "skills": sidebar.screen = .skills
                    case "tasks": sidebar.screen = .agentTasks
                    case "routines": sidebar.screen = .routines
                    default: break
                    }
                }
                if DemoData.arguments.contains("-demoFocusInput") { inputFocused = true }
                demoRoutineRun()
                if let draft = DemoData.value(after: "-demoDraft") {
                    // 화면이 자리 잡은 뒤에 넣는다 (바로 넣으면 입력칸이 글보다 크게 잡힌다)
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        question = draft
                    }
                }
                // -demoNewChat만 주면 빈 대화 화면 (처음 모습 캡처용)
                if DemoData.arguments.contains("-demoNewChat"), DemoData.value(after: "-demoAsk") == nil { session.reset() }
                #endif
            }
            #if DEBUG
            .task {
                // 데모 영상 (-demoReel "명령"): 입력창에 한 글자씩 쓰고 보낸다
                guard let demo = DemoData.value(after: "-demoReel"), demoSent.insert("-demoReel").inserted else { return }
                try? await Task.sleep(for: .seconds(1.2))
                for character in demo {
                    question.append(character)
                    try? await Task.sleep(for: .milliseconds(70))
                }
                try? await Task.sleep(for: .milliseconds(500))
                submit()
            }
            .task {
                // 개발용: -demoSteerSay "말": 몇 초 뒤 한 마디 더 보낸다 (도는 작업에 끼어들기, D152)
                guard let demo = DemoData.value(after: "-demoSteerSay"), demoSent.insert("-demoSteerSay").inserted else { return }
                try? await Task.sleep(for: .seconds(6))
                await session.send(demo, meetings: meetings)
            }
            .task {
                // 개발용: -demoAsk "질문" [-demoOpenCitation]
                guard let demo = DemoData.value(after: "-demoAsk"), demoSent.insert("-demoAsk").inserted else { return }
                try? await Task.sleep(for: .seconds(1))
                if DemoData.arguments.contains("-demoNewChat") { session.reset() }
                await session.send(demo, meetings: meetings)
                if DemoData.arguments.contains("-demoOpenCitation"),
                   let citation = session.messages.last?.citations.first {
                    try? await Task.sleep(for: .seconds(1.5))
                    open(citation)
                }
            }
            .task {
                // 개발용: -demoLongChat N [-demoVaried], -demoSay "말" [-demoSayAfter 초], -demoAttach (아래 `demoLongChat`, `demoSay`, `demoAttach`)
                async let say: Void = demoSay()
                async let attach: Void = demoAttach()
                await demoLongChat()
                await say
                await attach
            }
            .task {
                // 개발용: -demoAgent -demoAgentAsk "부탁" … (아래 `demoAgentAsk`. 본문이 길어 따로 뺐다: 이 화면의 식이 너무 커지지 않게)
                await demoAgentAsk()
            }
            #endif
        }
    }

    #if DEBUG
    /// 개발용: -demoAgent -demoAgentAsk "부탁" [-demoAgentThen "다음 말"] [-demoAgentReject "사유" | -demoAgentApprove]
    private func demoAgentAsk() async {
        guard let demo = DemoData.value(after: "-demoAgentAsk"), demoSent.insert("-demoAgentAsk").inserted else { return }
        try? await Task.sleep(for: .seconds(1))
        session.reset()
        await session.send(demo, meetings: meetings)
        // -demoPickItem N: 끝난 작업의 상품 목록에서 N번째를 고른다 (D72)
        if let number = DemoData.value(after: "-demoPickItem").flatMap(Int.init), let task = session.messages.last?.agent,
           let item = task.report?.items?.dropFirst(number - 1).first {
            try? await Task.sleep(for: .seconds(1))
            await session.pick(item, from: task.id, meetings: meetings)
        }
        if let next = DemoData.value(after: "-demoAgentThen") {
            try? await Task.sleep(for: .seconds(6))
            await session.send(next, meetings: meetings)
        }
        // -demoReact "👍": 마지막 답과 첫 질문에 반응을 붙인다. -demoReplyBar: 마지막 답에 답장하려는 상태.
        // -demoReplyText "글": 마지막 답에 답장을 보낸다. -demoSelect: 마지막 답의 글 고르기 화면
        if let emoji = DemoData.value(after: "-demoReact") {
            if let answer = session.messages.last(where: { $0.role == .assistant }), answer.reaction != emoji {
                session.react(answer.id, with: emoji)
            }
            if let first = session.messages.first(where: { $0.role == .user }), first.reaction == nil {
                session.react(first.id, with: "❤️")
            }
        }
        if let answer = session.messages.last(where: { $0.role == .assistant }) {
            if let text = DemoData.value(after: "-demoReplyText") {
                try? await Task.sleep(for: .seconds(1))
                await session.send(text, meetings: meetings, replyTo: session.quote(for: answer.id))
            }
            if DemoData.arguments.contains("-demoReplyBar") { reply(to: session.messages.last(where: { $0.role == .assistant })?.id ?? answer.id) }
            if DemoData.arguments.contains("-demoSelect") { selecting = SelectTarget(text: answer.text) }
        }
        // -demoReplyTask "글": 마지막 작업에 답장을 보낸다. -demoReplyTaskBar: 마지막 작업에 답장하려는 상태
        if let task = session.messages.last(where: { $0.role == .agent }) {
            if let text = DemoData.value(after: "-demoReplyTask") {
                try? await Task.sleep(for: .seconds(1))
                await session.send(text, meetings: meetings, replyTo: session.quote(for: task.id))
            }
            if DemoData.arguments.contains("-demoReplyTaskBar") { reply(to: task.id) }
        }
        // -demoSwipe times: 보낸 시각이 나온 상태. -demoSwipe reply: 마지막 답을 답장으로 밀고 있는 상태
        switch DemoData.value(after: "-demoSwipe") {
        case "times": swipe.demo(.times)
        case "reply": if let answer = session.messages.last(where: { $0.role == .assistant }) { swipe.demo(.reply(answer.id)) }
        default: break
        }
        guard let id = session.messages.last?.agent?.id else { return }
        if DemoData.arguments.contains("-demoAgentDetail") { detail = AgentDetailTarget(id: id) }
        // 승인 카드를 캡처할 수 있게 잠시 둔다
        try? await Task.sleep(for: .seconds(8))
        if let reason = DemoData.value(after: "-demoAgentReject") {
            await session.decide(id, approve: false, reason: reason)
        } else if DemoData.arguments.contains("-demoAgentApprove") {
            // -demoAgentCancelSend: 보내기 전 기다리는 동안 취소한다
            if DemoData.arguments.contains("-demoAgentCancelSend") {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    await session.cancelAgent(id)
                }
            }
            await session.decide(id, approve: true)
        } else if DemoData.arguments.contains("-demoMailConnect") {
            // 메일 계정 연결 화면 (계정 때문에 보내지 못한 작업에서)
            connectMail(for: session.messages.last?.agent)
        }
    }
    #endif

    // MARK: - 첫 대화 화면

    @ViewBuilder
    private var emptyState: some View {
        if meetings.isEmpty {
            ContentUnavailableView {
                Label("첫 회의를 녹음해 보세요", systemImage: "waveform")
            } description: {
                Text("빨간 버튼을 누르면 대화를 받아쓰고 결정 사항과 할 일을 정리해 드립니다.")
            }
            .padding(.top, 120)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.hasAgent ? "무엇부터 시작할까요?" : "무엇이 궁금하세요?")
                        .font(.title.weight(.bold))
                        .foregroundStyle(DS.Chat.textPrimary)
                    Text(session.hasAgent
                         ? "회의 내용을 묻거나 메일 초안 같은 일을 맡겨 보세요. 바꾸는 일은 승인한 뒤에만 해요."
                         : "지난 회의에서 찾아 근거와 함께 답해 드려요.")
                        .font(.subheadline)
                        .lineSpacing(3)
                        .foregroundStyle(DS.Chat.textSecondary)
                }
                // 예시는 한 묶음(목록)으로: 떠 있는 알약 여러 개보다 조용하고, 누르는 곳은 줄 전체다
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                        if index > 0 { ChatHairline().padding(.leading, 16) }
                        Button {
                            send(suggestion)
                        } label: {
                            HStack(spacing: 10) {
                                Text(suggestion)
                                    .font(.subheadline)
                                    .foregroundStyle(DS.Chat.textPrimary)
                                    .multilineTextAlignment(.leading)
                                    // 큰 글자에서 두 줄이 되어도 줄이 잘리지 않게
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.left")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("이 글을 보냅니다")
                    }
                }
                .chatCard(padding: 0)
            }
            .padding(.top, 48)
        }
    }

    // MARK: - 입력창

    private var inputBar: some View {
        VStack(spacing: 8) {
            if session.hasAgent, session.agentReachable == false {
                AgentOfflineBanner { Task { await session.checkAgent() } }
            } else if !session.waitingElsewhere.isEmpty {
                WaitingTasksBar(
                    tasks: session.waitingElsewhere, isOpening: openingWaiting,
                    onOpen: openWaiting, onDismiss: { withAnimation { session.dismissWaiting() } }
                )
            }
            inputRow
        }
        // 위 여백: 바탕이 다 덮인 뒤에 입력창이 시작한다 (스며드는 글이 입력창 테두리에 닿지 않게)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(alignment: .top) { ChatBarBackdrop() }
    }

    private var placeholder: String {
        if !canType { return "회의를 녹음하면 질문할 수 있어요" }
        if session.hasPendingApproval { return "위 승인 요청에 먼저 답해 주세요" }
        if replying != nil { return "답장 보내기" }
        if !session.uploads.draft.isEmpty { return "붙인 것에 대해 물어보기" }
        if session.pendingAgentQuestion != nil || session.openQuestionTask != nil || !session.pendingChoices.isEmpty {
            return "질문에 답하기"
        }
        return session.hasAgent && session.agentReachable != false ? "물어보거나 부탁하기" : "회의 내용 물어보기"
    }

    /// 회의가 없어도 맥이 연결되어 있으면 대화와 부탁은 할 수 있다
    private var canType: Bool {
        !meetings.isEmpty || (session.hasAgent && session.agentReachable != false)
    }

    private var hasText: Bool { !question.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 보내기 단추를 둘지: 글을 썼거나, 붙여 둔 것이 있을 때 (붙인 것만 보내도 된다)
    private var canSubmit: Bool { hasText || !session.uploads.draft.isEmpty }

    /// 붙인 것 줄을 둘지: 붙여 둔 것, 손질하는 중인 것, 붙이지 못했다는 말이 있을 때
    private var showsAttachTray: Bool {
        !session.uploads.draft.isEmpty || session.uploads.preparing > 0 || session.uploads.notice != nil
    }

    /// "+"를 누를 수 있는지. 맥에 연결되어 있고, 승인·질문에 답할 일이 없고, 아직 4개가 안 될 때
    private var canAttachMore: Bool { canType && session.canAttachNow && session.uploads.room > 0 }

    /// 붙이기 (D85): 사진 보관함과 파일에서 고른다. 사진 보관함은 고른 것만 앱에 오므로 권한을 묻지 않는다.
    /// 카메라(D87)는 카메라가 있는 기기에서만 나오고, 처음 누를 때 권한을 묻는다
    private var attachMenu: some View {
        Menu {
            if CameraGate.isAvailable {
                Button {
                    openCamera()
                } label: {
                    Label("카메라", systemImage: "camera")
                }
            }
            Button {
                pickingPhotos = true
            } label: {
                Label("사진 보관함", systemImage: "photo.on.rectangle")
            }
            Button {
                pickingFiles = true
            } label: {
                Label("파일", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(canAttachMore ? DS.Chat.textPrimary : DS.Chat.textSecondary.opacity(0.5))
                .frame(width: DS.minTouch, height: DS.minTouch)
                .contentShape(Rectangle())
        }
        .disabled(!canAttachMore)
        .accessibilityLabel("사진이나 파일 붙이기")
    }

    /// 카메라를 연다. 권한을 아직 묻지 않았으면 묻고, 꺼 두었으면 열지 않고 알린다
    private func openCamera() {
        Task {
            if await CameraGate.mayOpen() {
                takingPhoto = true
            } else {
                session.uploads.notice = CameraGate.blockedNotice
            }
        }
    }

    /// 찍은 사진을 붙인다 (취소했으면 아무것도 하지 않는다)
    private func attach(photo: UIImage?) {
        takingPhoto = false
        guard let photo else { return }
        Task {
            guard let data = await Task.detached(priority: .userInitiated, operation: { CameraGate.data(from: photo) }).value else {
                session.uploads.fail(.unreadable)
                return
            }
            await session.uploads.attach(data)
        }
    }

    /// 사진 보관함에서 고른 것을 붙인다
    private func attach(_ picked: [PhotosPickerItem]) {
        guard !picked.isEmpty else { return }
        pickedPhotos = []
        Task {
            for item in picked {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    session.uploads.fail(.unreadable)
                    continue
                }
                await session.uploads.attach(data)
            }
        }
    }

    /// 파일 앱에서 고른 것을 붙인다
    private func attach(files: [URL]) {
        Task {
            for url in files {
                switch await Task.detached(priority: .userInitiated, operation: { UploadPrep.read(file: url) }).value {
                case .success(let data): await session.uploads.attach(data, name: url.lastPathComponent)
                case .failure(let failure): session.uploads.fail(failure)
                }
            }
        }
    }

    /// 입력칸과 녹음 버튼을 한 면에 묶는다 (D43). 글을 쓰면 오른쪽 끝에 보내기가 나타난다.
    /// 녹음(빨간 기호)과 보내기(파란 면)는 색과 모양이 달라 헷갈리지 않는다
    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let replying {
                ReplyBar(quote: replying) {
                    withAnimation(.snappy(duration: 0.2)) { self.replying = nil }
                }
                .padding(.leading, 18)
                .padding(.trailing, 2)
                .padding(.top, 8)
                .transition(.opacity)
            }
            if showsAttachTray {
                AttachTray(store: session.uploads)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 0) {
                // 사진·PDF를 받는 맥일 때만 "+"를 둔다 (D85). 아니면 입력창은 전과 같다
                if session.canAttach { attachMenu }
                TextField(placeholder, text: $question, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { submit() }
                    .disabled(!canType || session.hasPendingApproval)
                    .tint(DS.Chat.accent)
                    // 한 줄일 때 버튼(44)과 가운데가 맞게
                    .padding(.vertical, 11)
                Button(action: onRecord) {
                    // 평소에는 빨간 기호만. 녹음 중 강조는 녹음 화면이 맡는다.
                    Image(systemName: "record.circle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(DS.Chat.danger)
                        .frame(width: DS.minTouch, height: DS.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("새 회의 녹음")
                if canSubmit {
                    Button {
                        submit()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DS.Chat.onUserBubble)
                            .frame(width: 34, height: 34)
                            .background(session.isLoading ? DS.Chat.textSecondary.opacity(0.45) : DS.Chat.userBubble, in: Circle())
                            .frame(width: DS.minTouch, height: DS.minTouch)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isLoading)
                    .accessibilityLabel("보내기")
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.leading, session.canAttach ? 2 : 18)
            .padding(.trailing, 2)
            .padding(.vertical, 2)
        }
        .animation(.snappy(duration: 0.2), value: canSubmit)
        .animation(.snappy(duration: 0.2), value: showsAttachTray)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
        .photosPicker(
            isPresented: $pickingPhotos, selection: $pickedPhotos, maxSelectionCount: max(1, session.uploads.room), matching: .images
        )
        .onChange(of: pickedPhotos) { _, picked in attach(picked) }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(files: urls) }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { attach(photo: $0) }
                .ignoresSafeArea()
        }
    }

    /// 대화를 위로 올려 읽고 있을 때만 보이는 "맨 아래로" 버튼
    private func scrollToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            // 스르륵 내려간다. 손을 뗀 뒤 관성으로 흘러가는 중에 눌러도 맨 아래까지 간다:
            // `proxy.scrollTo`는 관성 스크롤 중에는 무시될 때가 있어 (눌러도 그대로 흘러간다) 스크롤 위치(`ScrollPosition`)로 옮긴다.
            // 움직임 줄이기를 켠 사람에게는 움직임 없이 바로 옮긴다
            if reduceMotion {
                scrollPosition.scrollTo(edge: .bottom)
            } else {
                withAnimation { scrollPosition.scrollTo(edge: .bottom) }
            }
        } label: {
            // 보이는 크기는 작게, 누르는 자리는 그대로 (D83): 말풍선 오른쪽 여백에 놓여 읽던 글을 덜 가린다
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Chat.textPrimary)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: Circle())
                .frame(width: DS.minTouch, height: DS.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("맨 아래로")
        .padding(.trailing, 8)
        .padding(.bottom, 6)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    // MARK: - 동작

    /// 예시·선택지를 눌러 보낸다 (답장 인용은 붙이지 않는다)
    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !session.isLoading else { return }
        question = ""
        Haptic.tap()
        Task { await session.send(text, meetings: meetings) }
    }

    /// 입력창에 쓴 글을 보낸다. 답장 중이면 인용을 함께 붙인다
    private func submit() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploads = session.uploads
        // 붙인 것을 손질하는 중에는 기다린다 (덜 붙은 채로 가지 않게)
        guard !session.isLoading, uploads.preparing == 0 else { return }
        var attached: [ChatUpload] = []
        if !uploads.draft.isEmpty {
            if session.canAttachNow {
                attached = uploads.takeDraft()
            } else {
                // 지금은 붙인 것이 갈 수 없다: 글만 보내고 붙인 것은 입력창에 남겨 둔다 (말없이 버리지 않는다)
                uploads.notice = session.agentReachable == false
                    ? "맥에 연결되면 붙인 것을 보낼 수 있어요."
                    : "붙인 것은 위 질문에 답한 뒤에 보낼 수 있어요."
            }
        }
        guard !text.isEmpty || !attached.isEmpty else { return }
        let quote = replying
        question = ""
        withAnimation(.snappy(duration: 0.2)) { replying = nil }
        Haptic.tap()
        Task { await session.send(text, meetings: meetings, replyTo: quote, uploads: attached) }
    }

    /// 지금 답장을 쓸 수 있는지 (입력할 수 없을 때는 메뉴에 답장을 두지 않는다)
    private var canReply: Bool { canType && !session.hasPendingApproval }

    private func reply(to id: AskSession.Message.ID) {
        guard let quote = session.quote(for: id) else { return }
        withAnimation(.snappy(duration: 0.2)) { replying = quote }
        inputFocused = true
    }

    /// 그리는 말들과 대화 안에서의 차례 (D69). 긴 대화는 최근 것만 그린다 (`AskSession.earlierCount`)
    private var shownRows: [(offset: Int, element: AskSession.Message)] {
        Array(session.messages.enumerated().dropFirst(session.earlierCount))
    }

    /// 이전 말을 한 묶음 더 그린다. 보고 있던 말은 그 자리에 둔다 (`keepPlace`)
    private func showEarlier() {
        keepsPlace = true
        session.showEarlier()
    }

    /// 이전 말이 위에 더 그려져 내용이 길어졌으면, 길어진 만큼 내려서 보고 있던 말을 제자리에 둔다
    private func keepPlace(old: KeyboardFollow.Snapshot, new: KeyboardFollow.Snapshot) {
        guard keepsPlace, new.contentHeight != old.contentHeight else { return }
        keepsPlace = false
        scrollPosition.scrollTo(y: new.offset + new.topInset + new.contentHeight - old.contentHeight)
    }

    /// 답장에 붙은 원래 말로 간다. 아직 그리지 않은 이전 말이면 거기까지 그린 다음에 간다
    private func jump(to id: UUID, with proxy: ScrollViewProxy) {
        guard session.reveal(id) else {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// 앞 말과의 간격
    private func spacing(before index: Int) -> CGFloat {
        // 목록이 줄어든 직후에는 예전 번호로 불릴 수 있다
        let messages = session.messages
        guard index > 0, index < messages.count else { return 0 }
        return Self.spacing(previous: messages[index - 1], current: messages[index])
    }

    /// 차례가 바뀌면 넓게(12), 같은 쪽이 말풍선을 이어 붙이면 바짝(2), 사이에 카드·덧말이 끼면 그 중간(10) (D150, 참고 앱을 재서 맞췄다)
    static func spacing(previous: AskSession.Message, current: AskSession.Message) -> CGFloat {
        if (previous.role == .user) != (current.role == .user) { return DS.Chat.turnSpacing }
        return endsWithBubble(previous) && startsWithBubble(current) ? DS.Chat.groupSpacing : DS.Chat.blockSpacing
    }

    /// 이 말의 맨 아래가 말풍선인지 (반응·근거·"Claude 사용" 같은 덧말이나 카드가 붙지 않았는지)
    private static func endsWithBubble(_ message: AskSession.Message) -> Bool {
        guard message.callID == nil, message.reaction == nil, message.agentReaction == nil else { return false }
        switch message.role {
        case .user:
            return message.shopView == nil && message.steer == nil
        case .assistant:
            return startsWithBubble(message) && message.citations.isEmpty && message.engine != .cloud
                && message.siteLogin == nil && message.shopQuery == nil
        default:
            return false
        }
    }

    /// 이 말의 맨 위가 말풍선인지 (카드·상태 줄·통화 카드가 아닌지)
    private static func startsWithBubble(_ message: AskSession.Message) -> Bool {
        guard message.callID == nil else { return false }
        switch message.role {
        case .user: return true
        case .assistant: return !message.isStatus && message.siteLoggedIn == nil && message.weather == nil
        default: return false
        }
    }

    /// "맡길 수 있는 일"에서 고른 말을 내 말로 보내고 대화로 돌아온다
    #if DEBUG
    /// 개발용: -demoRoutineRun — 예약이 돈 결과를 대화로 연다 (알림을 눌렀을 때와 같은 길)
    private func demoRoutineRun() {
        guard DemoData.arguments.contains("-demoRoutineRun"), session.messages.isEmpty || session.agentConversationID != "conv-routine-1" else { return }
        Task {
            await session.routines.load()
            _ = await session.openRoutineRun(id: MockRoutines.briefingRunID)
        }
    }
    #endif

    /// 사이드바에서 고른 화면 (`body`가 무거워지지 않게 따로 둔다)
    @ViewBuilder
    private func sidebarScreen(_ screen: ChatSidebarModel.Screen) -> some View {
        switch screen {
        case .skills: SkillsView(skills: skills, session: session, onAsk: ask)
        case .agentTasks: AgentTasksView(session: session, onOpen: openTask)
        case .routines: RoutinesView(model: session.routines, session: session, onAsk: askInNewChat) { sidebar.screen = nil }
        }
    }

    /// 기다리는 작업 줄을 눌렀다 (D113): 그 대화를 열고 그 카드로 간다
    private func openWaiting(_ task: AgentWaitingTask) {
        guard !openingWaiting else { return }
        openingWaiting = true
        Task {
            let result = await session.openWaiting(task)
            openingWaiting = false
            if result == .opened {
                sidebar.screen = nil
                pushedTaskID.wrappedValue = task.id
            }
        }
    }

    /// 새 대화에서 이 말을 보낸다 (예약 만들기: 보고 있던 대화에 섞이지 않게. D91)
    private func askInNewChat(_ prompt: String) {
        if !session.messages.isEmpty, session.canSwitchConversation { session.reset() }
        ask(prompt)
    }

    private func ask(_ prompt: String) {
        sidebar.screen = nil
        send(prompt)
    }

    /// 에이전트 작업 목록에서 고른 작업: 그 대화를 열고 그 카드로 간다
    private func openTask(_ entry: AgentTaskEntry) {
        if let conversation = entry.conversation, session.conversation?.id != conversation.id {
            // 답을 받는 중에는 다른 대화로 옮기지 않는다 (목록에서도 그 줄은 눌리지 않는다)
            guard session.canSwitchConversation else { return }
            session.open(conversation)
        }
        if session.messages.contains(where: { $0.id == entry.id }) { jumpTarget = entry.id }
        sidebar.screen = nil
    }

    #if DEBUG
    /// 개발용: -demoAgent -demoLongChat N — 가짜 맥과 N번 주고받아 긴 대화를 만든다 (스크롤, "맨 아래로" 버튼 확인용)
    private func demoLongChat() async {
        guard let count = DemoData.value(after: "-demoLongChat").flatMap({ Int($0) }), count > 0,
              demoSent.insert("-demoLongChat").inserted else { return }
        try? await Task.sleep(for: .seconds(1))
        session.reset()
        // -demoVaried: 말마다 높이가 다르게 (실제 대화처럼. 0~5줄이 더 붙는다)
        let varied = DemoData.arguments.contains("-demoVaried")
        for index in 1...count {
            let extra = varied ? String(repeating: "\n회의 자료를 다시 보고 정리해 둘게", count: (index * 7) % 6) : ""
            await session.send("안녕 \(index)\(extra)", meetings: meetings)
        }
    }

    /// 개발용: -demoAttach [one|two|pdf|mix] [-demoAttachSend "말" | -demoAttachOnly] — 앱이 그린 가상의 사진·PDF를 붙인다 (D85)
    private func demoAttach() async {
        guard DemoData.arguments.contains("-demoAttach"), demoSent.insert("-demoAttach").inserted else { return }
        try? await Task.sleep(for: .seconds(1))
        if DemoData.value(after: "-demoAgentAsk") == nil { session.reset() }
        for file in DemoUploads.files(DemoData.value(after: "-demoAttach")) {
            await session.uploads.attach(file.data, name: file.name)
        }
        let say = DemoData.value(after: "-demoAttachSend")
        guard say != nil || DemoData.arguments.contains("-demoAttachOnly") else { return }
        await session.send(say ?? "", meetings: meetings, uploads: session.uploads.takeDraft())
    }

    /// 개발용: -demoSay "말" [-demoSayAfter 초] — 다른 데모와 따로, 조금 뒤에 한마디 보낸다
    /// (긴 대화에 새 말이 올 때의 움직임, 작업이 도는 동안 말 걸기 확인용)
    private func demoSay() async {
        guard let say = DemoData.value(after: "-demoSay"), demoSent.insert("-demoSay").inserted else { return }
        let delay = DemoData.value(after: "-demoSayAfter").flatMap { Double($0) } ?? 8
        try? await Task.sleep(for: .seconds(delay))
        await session.send(say, meetings: meetings)
    }
    #endif

    /// 키보드가 움직이는 동안 대화를 `y` 자리로 같이 옮긴다 (옮길 일이 없으면 nil)
    private func followKeyboard(to y: CGFloat?) {
        // 화면이 막 나타나 자리를 잡는 중이거나 고른 카드로 가는 중에는 그쪽이 스크롤을 정한다
        guard let y, !settlingAtBottom, jumpTarget == nil else { return }
        // 키보드와 같은 움직임에 태운다. 그럴 수 없을 때만 비슷하게 맞춘 움직임으로 옮긴다
        if keyboardFollow.scrollWithKeyboard(to: y) {
            // 스크롤 뷰만 옮기면 SwiftUI는 옛 자리를 기억하고 있다가 되돌려 놓는다. 같은 자리를 SwiftUI에도 알려 둔다
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollPosition.scrollTo(y: y) }
            return
        }
        withAnimation(KeyboardFollow.animation) { scrollPosition.scrollTo(y: y) }
    }

    /// 키보드를 내린다.
    /// 입력칸을 직접 눌러 올린 키보드는 `inputFocused`에 잡히지 않는다 (입력칸이 `safeAreaBar` 안에 있어, 값이 거짓인 채로 키보드만 올라와 있다).
    /// 그때는 값을 거짓으로 바꿔도 아무 일도 일어나지 않으므로, 글을 받고 있는 칸에 직접 그만 받으라고 알린다
    // MARK: - 통화 (D134)

    private func startCall() {
        dismissKeyboard()
        Haptic.tap()
        let meetings = self.meetings
        let new = VoiceCall(session: session, meetings: { meetings })
        call = new
        showingCall = true
        Task { await new.start() }
    }

    /// 통화 화면을 접고 대화를 본다. 승인할 일이 있으면 그 카드로 간다
    private func minimizeCall() {
        showingCall = false
        if let message = session.messages.last(where: { $0.agent?.phase == .awaitingApproval }) { jumpTarget = message.id }
    }

    private func endCall() {
        call?.end()
        showingCall = false
        withAnimation { call = nil }
    }

    private func dismissKeyboard() {
        inputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func retry(_ text: String, _ engine: AskSession.Engine?) {
        Task { await session.send(text, meetings: meetings, engine: engine) }
    }

    /// 메일 계정 연결 화면을 연다. 작업이 쓰려던 주소가 있으면 미리 채워 둔다
    private func connectMail(for state: AgentTaskState?) {
        guard let state else { return }
        dismissKeyboard()
        // 작업에 주소가 없으면("나한테 보내 줘") 연결이 필요한 계정의 주소를 채운다
        let suggestion = session.mailConnectSuggestion
        let address = state.brief?.targets?.first { $0.contains("@") } ?? suggestion?.address ?? ""
        let provider = MailProvider.guess(from: address) ?? suggestion.flatMap { MailProvider(rawValue: $0.provider) } ?? .naver
        connecting = MailConnectTarget(id: state.id, provider: provider, address: address)
    }

    /// 이 말에 붙일 로그인 버튼: 맥이 "로그인이 필요해요"라고 답한 말이거나, 로그인 때문에 멈춘 작업일 때
    /// 상품 목록의 "고르기" (D72). 맥이 상품 목록을 알 때만 둔다
    /// 쇼핑 화면 (D74). 읽은 화면은 "확인해 줘"를 누를 때만 이 대화로 보낸다
    private var shopDesk: ShopDesk {
        ShopDesk(browser: shopBrowser, session: session) { view in
            await session.checkShop(view, meetings: meetings)
        }
    }

    private var itemPicker: ItemPicker? {
        guard session.showsItemPick else { return nil }
        return ItemPicker(isEnabled: session.canPickItemNow) { item, taskID in
            dismissKeyboard()
            Task { await session.pick(item, from: taskID, meetings: meetings) }
        }
    }

    private func siteLoginAction(for message: AskSession.Message) -> (() -> Void)? {
        // 카드의 단추를 눌렀다: 저장해 둔 값이 있으면 얼굴 확인까지 한 번에 (D122)
        if let prompt = session.siteLoginPrompt, prompt.messageID == message.id {
            return { openSiteLogin(for: prompt, auto: true) }
        }
        if let task = session.siteLoginTask, task.taskID == message.agent?.id {
            return { openSiteLogin(task.site, auto: true) { await session.retryAfterSiteLogin(task.taskID, meetings: meetings) } }
        }
        return nil
    }

    /// 맥의 답에 붙은 로그인 안내에서 로그인 화면을 연다 (답이 오면 저절로, 카드를 누르면 다시).
    /// 로그인이 없어서 하지 못한 부탁이면, 로그인되는 대로 그 부탁을 다시 보낸다 (D58)
    /// `auto`: 사용자가 단추를 눌러 열었다 — 저장해 둔 값이 있으면 얼굴 확인을 바로 띄운다 (D122). 맥의 답으로 저절로 열 때는 false
    private func openSiteLogin(for prompt: AskSession.SiteLoginPrompt, auto: Bool = false) {
        guard prompt.request != nil else { return openSiteLogin(prompt.site, auto: auto) }
        openSiteLogin(prompt.site, auto: auto) { await session.retryAfterSiteLoginPrompt(prompt.messageID, meetings: meetings) }
    }

    /// 사이트 로그인 화면을 연다 (열리면 맥이 로그인 화면을 띄운다).
    /// `resume`: 로그인 때문에 하지 못한 부탁에서 열었으면, 로그인되는 대로 그 부탁을 다시 맡긴다
    private func openSiteLogin(_ site: String?, auto: Bool = false, resume: (@MainActor () async -> Void)? = nil) {
        guard loggingIn == nil, let site, let flow = session.siteLoginFlow(for: site) else { return }
        dismissKeyboard()
        flow.autoUsesSaved = auto
        if let resume {
            let loggedIn = flow.onLoggedIn
            flow.onLoggedIn = {
                loggedIn()
                Task { await resume() }
            }
        }
        loggingIn = SiteLoginTarget(flow: flow)
    }

    private func decide(_ taskID: String, approve: Bool, reason: String?) {
        dismissKeyboard()
        Task { await session.decide(taskID, approve: approve, reason: reason) }
    }

    private func open(_ citation: AskSession.Citation) {
        guard let meeting = meetings.first(where: { $0.id == citation.meetingID }) else { return }
        dismissKeyboard()
        target = CitationTarget(meeting: meeting, utteranceID: citation.utteranceID)
    }
}

// MARK: - 메시지

private struct MessageView: View {
    let message: AskSession.Message
    /// 답한 곳을 표시할지 (맥 에이전트가 있는 앱에서만 "Claude 사용"을 붙인다)
    let showsSource: Bool
    /// 맥을 거친 답 가운데 Claude가 쓴 답의 마지막 말풍선인지 (맥이 알려 줄 때만. D62)
    var marksClaude = false
    /// 맥에 연결되지 않아 Claude가 대신 답한 말이고, 지금은 맥에 다시 보낼 수 있는지
    let canResendToAgent: Bool
    let onResendToAgent: () -> Void
    let canOpen: (AskSession.Citation) -> Bool
    let onOpen: (AskSession.Citation) -> Void
    let onRetry: (String, AskSession.Engine?) -> Void
    let onResume: () -> Void
    let isBusy: Bool
    let onDecide: (_ taskID: String, _ approve: Bool, _ reason: String?) -> Void
    let onAnswer: (_ taskID: String, _ answer: String) -> Void
    let onCancel: (_ taskID: String) -> Void
    let onOpenDetail: (_ taskID: String) -> Void
    /// 메일 계정 연결 화면 열기 (이 메시지에 연결 안내를 붙일 때만)
    var onConnectMail: (() -> Void)?
    var mailNeedsAddressSetup = false
    /// 사이트 로그인 화면 열기 (이 말에 로그인 카드를 붙일 때만)
    var onSiteLogin: (() -> Void)?
    /// 답변 카드의 "다시 로그인": 그 사이트의 로그인 화면을 연다 (D110)
    var onOpenSite: ((String) -> Void)?
    /// 로그인 카드가 "로그인하면 하던 일을 이어서 한다"고 말할지 (로그인이 없어서 하지 못한 부탁에 붙은 카드)
    var resumesAfterLogin = false
    /// 연동 센터 열기 (로그인 완료 카드)
    var onOpenIntegrations: () -> Void = {}
    /// 길게 눌러 붙이는 반응 (같은 것을 다시 고르면 지운다)
    let onReact: (String) -> Void
    /// nil이면 지금은 답장할 수 없다
    let onReply: (() -> Void)?
    /// 맡긴 일에도 답장할 수 있는지 (맥이 답장으로 가리킨 작업을 받을 때만)
    var canReplyToTask = false
    /// 인용을 누르면 원래 말로 간다
    let onJump: (AskSession.Message.ID) -> Void
    /// 내 말이 간 작업의 말 (D152). 표시를 누르면 그 작업으로 간다
    var steerTarget: AskSession.Message.ID?

    var body: some View {
        switch message.role {
        case .agent:
            if let state = message.agent {
                AgentRunView(
                    state: state, isBusy: isBusy,
                    onDecide: { approve, reason in onDecide(state.id, approve, reason) },
                    onAnswer: { answer in onAnswer(state.id, answer) },
                    onCancel: { onCancel(state.id) },
                    onOpenDetail: { onOpenDetail(state.id) },
                    onConnectMail: onConnectMail,
                    mailNeedsAddressSetup: mailNeedsAddressSetup,
                    onSiteLogin: onSiteLogin,
                    onOpenSite: onOpenSite
                )
                // 이 작업의 말풍선·결과 카드를 길게 누르면 이 작업에 답장한다 ("이거 메일로 보내줘")
                .environment(\.replyToTask, canReplyToTask ? onReply : nil)
                // 왼쪽으로 밀어도 이 작업에 답장한다
                .chatSwipeTarget(message.id, isEnabled: canReplyToTask && onReply != nil)
            }
        case .user:
            // 내 말: 오른쪽, 내용만큼만. 화면 폭의 대부분을 넘지 않게 왼쪽을 비운다
            VStack(alignment: .trailing, spacing: 0) {
                // 붙여 보낸 사진·PDF (D85). 글 없이 보낸 말이면 이것이 그 말이다 (길게 누르기와 답장도 여기서 받는다)
                if let uploads = message.uploads {
                    if uploads.textless, message.replyTo == nil {
                        UploadTiles(uploads: uploads)
                            .messageActions(text: message.text, reaction: message.reaction, onReact: onReact, onReply: onReply)
                            .chatSwipeTarget(message.id, isEnabled: onReply != nil)
                    } else {
                        UploadTiles(uploads: uploads).padding(.bottom, 4)
                    }
                }
                if message.uploads?.textless != true || message.replyTo != nil {
                // 답장이면 위에 무엇에 답했는지, 선 하나, 그 아래 내가 쓴 말
                QuoteStack {
                    if let quote = message.replyTo {
                        QuoteInset(quote: quote) { onJump(quote.messageID) }
                        QuoteDivider()
                    }
                    Text(message.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DS.Chat.onUserBubble)
                .padding(.horizontal, DS.Chat.bubblePaddingH)
                .padding(.vertical, DS.Chat.bubblePaddingV)
                .background(DS.Chat.userBubble, in: RoundedRectangle(cornerRadius: DS.Chat.bubbleRadius, style: .continuous))
                .messageActions(text: message.text, reaction: message.reaction, onReact: onReact, onReply: onReply)
                .chatSwipeTarget(message.id, isEnabled: onReply != nil)
                }
                // 끼어들기 (D152): 내 말이 새 작업이 아니라 이미 있던 작업으로 갔다
                if let steer = message.steer {
                    Button {
                        if let steerTarget { onJump(steerTarget) }
                    } label: {
                        Label(steer.note, systemImage: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundStyle(DS.Chat.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(steerTarget == nil)
                    .padding(.top, 4)
                    .padding(.trailing, 6)
                    .accessibilityHint(steerTarget == nil ? "" : "그 작업으로 갑니다")
                }
                // "확인해 줘"로 보낸 말이면, 그때 화면에서 읽어 맥에 보낸 것을 그대로 보여 준다 (D74)
                if let view = message.shopView {
                    ShopReadCard(view: view).padding(.top, 6)
                }
                // 반응: 대화 담당이 단 것(D70)이 왼쪽, 내가 붙인 것이 오른쪽
                if message.agentReaction != nil || message.reaction != nil {
                    HStack(spacing: 4) {
                        if let received = message.agentReaction {
                            AgentReactionBadge(emoji: received)
                        }
                        if let reaction = message.reaction {
                            ReactionBadge(emoji: reaction) { onReact(reaction) }
                        }
                    }
                }
            }
            .animation(.snappy(duration: 0.2), value: message.reaction)
            .animation(.snappy(duration: 0.25), value: message.agentReaction)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 56)
        case .assistant:
            if message.isStatus {
                // 한 줄로 끝난 일 (D110): 말풍선 대신 작은 상태 줄
                Label(message.text, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(DS.Chat.textSecondary)
                    .padding(.leading, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let site = message.siteLoggedIn {
                // 로그인 완료는 말풍선이 아니라 카드로 (로그인 카드가 있던 자리에 붙는다)
                SiteLoggedInCard(copy: SiteLoginCopy(site: site), action: onOpenIntegrations)
            } else if let weather = message.weather {
                // 날씨는 말풍선이 아니라 카드로 (맥의 한마디 아래에 붙는다, D66)
                WeatherCardView(card: weather)
            } else {
            VStack(alignment: .leading, spacing: 10) {
            // 답변: 왼쪽 조용한 말풍선. 근거는 그 아래 한 묶음, 답한 곳 표시는 가장 약하게
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    ChatText(text: message.text)
                        .foregroundStyle(message.found ? DS.Chat.textPrimary : DS.Chat.textSecondary)
                        .tint(DS.Chat.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        // 근거 묶음이 붙으면 말풍선도 같은 폭으로 맞춘다 (오른쪽 끝이 어긋나 보이지 않게)
                        .frame(maxWidth: message.citations.isEmpty ? nil : .infinity, alignment: .leading)
                        .chatBubble(DS.Chat.bubble)
                        .messageActions(text: message.text, reaction: message.reaction, onReact: onReact, onReply: onReply)
                        .chatSwipeTarget(message.id, isEnabled: onReply != nil)
                    if let reaction = message.reaction {
                        ReactionBadge(emoji: reaction) { onReact(reaction) }
                    }
                }
                .animation(.snappy(duration: 0.2), value: message.reaction)
                if !message.citations.isEmpty {
                    CitationList(citations: message.citations, canOpen: canOpen, onOpen: onOpen)
                }
                if showsSource, message.engine == .cloud || marksClaude {
                    ClaudeUsedLabel()
                }
                if canResendToAgent {
                    OfflineAnswerNote(isBusy: isBusy, onResend: onResendToAgent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 36)
            // 로그인 카드는 에이전트 카드처럼 폭을 다 쓴다
            if let onSiteLogin, let site = message.siteLogin {
                SiteLoginCard(
                    copy: SiteLoginCopy(site: site), isBusy: isBusy, stoppedExpired: resumesAfterLogin ? false : nil,
                    quickUnlock: SiteLoginFlow.quickUnlock(for: site), action: onSiteLogin
                )
            }
            // 쇼핑 화면을 여는 카드 (D74). 누를 때만 열린다
            if let query = message.shopQuery {
                ShopOpenCard(query: query)
            }
            }
            }
        case .error:
            VStack(alignment: .leading, spacing: 8) {
                Label(message.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(DS.Chat.warning)
                if let question = message.retryQuestion {
                    Button("다시 시도") { onRetry(question, message.retryEngine) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if message.resumeTaskID != nil {
                    Button("다시 확인", action: onResume)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isBusy)
                }
            }
            .padding(.leading, 4)
        }
    }
}

/// 화면 위 가운데 (D119): 앱의 얼굴(모아 로고와 이름). 연결 상태는 이름 옆의 작은 점으로만,
/// 기다리는 것이 있으면 이름 뒤에 그 상태를 짧게 붙인다. 유리 알약 하나라 대화가 뒤로 지나가도 글자가 겹쳐 보이지 않는다
private struct HeaderStatus: View {
    let status: AskSession.Status?
    let hasAgent: Bool
    let agentReachable: Bool?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 7) {
            MoaLogoMarkV4(
                width: 20, mintColor: SpaceBrand.mint,
                leafColor: colorScheme == .dark ? .white : Color(red: 0.086, green: 0.098, blue: 0.118),
                showGuide: false, step1: true, step2: true, step3: true, step4: true, ripple: false
            )
            .accessibilityHidden(true)
            Text("모아")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(DS.Chat.textPrimary)
            switch status {
            case .thinking, .working, .sending:
                ProgressView().controlSize(.mini)
            case .needsApproval, .needsAnswer:
                Circle().fill(DS.Chat.warning).frame(width: 6, height: 6)
            case nil:
                if hasAgent, let agentReachable {
                    Circle().fill(agentReachable ? SpaceBrand.mint : DS.Chat.warning).frame(width: 6, height: 6)
                }
            }
            if let text {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .contentTransition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 13)
        .frame(height: 36)
        .glassEffect(.regular, in: Capsule())
        .animation(.easeOut(duration: 0.2), value: text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("모아, \(text ?? (agentReachable == false ? "맥 연결 안 됨" : hasAgent ? "맥 연결됨" : ""))")
    }

    /// 이름 뒤에 붙이는 짧은 상태 (평소에는 없다. 맥에 닿지 않을 때만 그렇다고 말한다)
    private var text: String? {
        switch status {
        case .thinking: "생각 중"
        case .working: "작업 중"
        case .needsApproval: "승인 필요"
        case .needsAnswer: "답변 필요"
        case .sending: "보내기 대기"
        case nil: hasAgent && agentReachable == false ? "맥 연결 안 됨" : nil
        }
    }
}

/// 답변의 근거: 카드 하나에 줄로 묶는다 (줄마다 그 회의의 해당 부분으로 간다)
private struct CitationList: View {
    let citations: [AskSession.Citation]
    let canOpen: (AskSession.Citation) -> Bool
    let onOpen: (AskSession.Citation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("근거 \(citations.count)", systemImage: "quote.opening")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.Chat.textSecondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                if index > 0 { ChatHairline().padding(.leading, 14) }
                CitationCard(citation: citation, isAvailable: canOpen(citation)) { onOpen(citation) }
            }
        }
        .chatCard(padding: 0)
    }
}

private struct CitationCard: View {
    let citation: AskSession.Citation
    let isAvailable: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(citation.text)
                        .font(.subheadline)
                        .foregroundStyle(DS.Chat.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(citation.meetingTitle).lineLimit(1)
                        if let start = citation.start {
                            Text("· \(MeetingText.timestamp(start))").monospacedDigit()
                        }
                        if !isAvailable { Text("· 삭제된 회의") }
                    }
                    .font(.caption)
                    .foregroundStyle(DS.Chat.textSecondary)
                }
                Spacer(minLength: 0)
                if isAvailable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: DS.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityHint("그 회의의 해당 부분으로 이동합니다")
    }
}

/// 답을 기다리는 동안 보여 주는 말풍선 (점 세 개가 차례로 살짝 오른다. "동작 줄이기"에서는 밝기만 바뀐다)
private struct ThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 상태값 애니메이션 대신 매 프레임 시간으로 계산해야 반복 동작이 끊기지 않는다
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.2 : nil)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    // 1.1초 주기, 점마다 0.16초씩 늦게
                    let phase = (t / 1.1 - Double(i) * 0.16).truncatingRemainder(dividingBy: 1)
                    let lift = phase < 0.45 ? sin(phase / 0.45 * .pi) : 0
                    Circle()
                        .fill(DS.Chat.textSecondary)
                        .frame(width: 7, height: 7)
                        .offset(y: reduceMotion ? 0 : -3 * lift)
                        .opacity(0.4 + 0.6 * lift)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(DS.Chat.bubble, in: RoundedRectangle(cornerRadius: DS.Chat.bubbleRadius, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
        .accessibilityLabel("답변을 찾는 중")
    }
}

// MARK: - 대화 기록

private struct ConversationHistorySheet: View {
    let session: AskSession

    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(conversations) { conversation in
                    Button {
                        session.open(conversation)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if conversation.usesAgent {
                                    Image(systemName: "desktopcomputer")
                                        .font(.caption)
                                        .foregroundStyle(DS.Colors.textSecondary)
                                        .accessibilityLabel("맥 에이전트 사용")
                                }
                                Text(conversation.title)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                            }
                            Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(DS.Colors.textSecondary)
                        }
                    }
                    .listRowBackground(session.conversation?.id == conversation.id ? DS.Colors.accentSoft : nil)
                    // 답을 받는 중에는 다른 대화로 옮기지 않고, 그 대화를 지우지도 않는다 (답이 엉뚱한 대화에 붙는다)
                    .disabled(!session.canSwitchConversation && session.conversation?.id != conversation.id)
                    .deleteDisabled(!session.canSwitchConversation && session.conversation?.id == conversation.id)
                }
                .onDelete { offsets in
                    offsets.map { conversations[$0] }.forEach(session.delete)
                }
            }
            .overlay {
                if conversations.isEmpty {
                    ContentUnavailableView("대화 기록이 없습니다", systemImage: "clock")
                }
            }
            .navigationTitle("대화 기록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#if DEBUG
#Preview("질문 - 회의 없음") {
    AskView(session: AskSession(), sidebar: ChatSidebarModel(), skills: SkillsModel(), onRecord: {})
        .modelContainer(for: Meeting.self, inMemory: true)
}

#Preview("질문 - 회의 있음") {
    AskView(session: AskSession(), sidebar: ChatSidebarModel(), skills: SkillsModel(), onRecord: {})
        .modelContainer(PreviewData.container)
}
#endif
