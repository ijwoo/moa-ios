import SwiftUI

// 질문 탭의 맥 에이전트 화면 조각: 연결 안내, 선택지 버튼, 작업 카드, 승인 카드, 결과.
// 세부 단계 기록은 AgentTaskDetailView.

/// 맥에 연결되지 않을 때 입력창 위 안내. 그동안은 회의 질문(Claude)만 된다.
struct AgentOfflineBanner: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(DS.Chat.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("맥에 연결할 수 없어요")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Chat.textPrimary)
                Text("지금은 회의 질문만 답할 수 있어요. 아이폰의 Tailscale과 맥이 켜져 있는지 확인해 주세요.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.footnote)
                    .foregroundStyle(DS.Chat.textSecondary)
            }
            Spacer(minLength: 0)
            Button("다시 확인", action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(DS.Chat.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // 입력창과 같은 유리 면: 대화가 뒤로 지나가도 읽힌다
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
    }
}

/// 고르기 카드 (D111, D119에서 고침): 말풍선과 같은 면 안에 후보마다 한 단계 가라앉힌 줄. 번호와 파랑은 두지 않고,
/// 추천은 오른쪽의 흐린 엄지, 고른 줄은 체크로만 알린다. 후보의 그림이 있으면 왼쪽에 작게.
/// 맥이 되물으며 준 선택지와 답 뒤의 다음 말에 함께 쓴다. 누르면 그 글이 다음 메시지로 간다 (직접 써서 답해도 된다).
/// 여러 개 고르기(`multi`)면 줄을 눌러 체크하고 "보내기"로 고른 것들을 ", "로 이어 보낸다.
/// 그림은 맥이 실제로 연 공개 페이지의 대표 그림만 오고, 줄이 보일 때 받아 메모리에만 둔다
struct ChoiceButtons: View {
    let choices: [String]
    /// 맥이 권하는 후보 (D110): 엄지를 붙인다
    var recommended: String?
    /// 여러 개를 함께 고른다 (D111)
    var multi = false
    /// 후보마다의 그림 (D111)
    var images: [String: URL] = [:]
    /// 카드 위의 한 줄 ("이어서 더 확인해 볼까요?")
    var title: String?
    /// 맨 아래의 끝내기 줄 ("괜찮아요, 여기까지 볼게요")과 그 동작
    var closing: String?
    var onClose: (() -> Void)?
    let onChoose: (String) -> Void

    @Environment(LinkThumbnailStore.self) private var store: LinkThumbnailStore?
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(DS.Chat.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            } else if multi {
                Text("여러 개 고를 수 있어요")
                    .font(.footnote)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
            ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
                row(choice, number: index + 1)
            }
            if let closing, let onClose {
                Button(action: onClose) {
                    Text(closing)
                        .font(.subheadline)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if multi {
                Button {
                    let answer = AgentChoices.joined(picked, in: choices)
                    guard !answer.isEmpty else { return }
                    onChoose(answer)
                } label: {
                    Text(picked.isEmpty ? "골라 주세요" : "\(picked.count)개 보내기")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(picked.isEmpty ? DS.Chat.textSecondary : DS.Chat.onUserBubble)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(picked.isEmpty ? DS.Chat.inset : DS.Chat.userBubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(picked.isEmpty)
            }
        }
        .padding(10)
        .background(DS.Chat.bubble, in: RoundedRectangle(cornerRadius: DS.Chat.bubbleRadius, style: .continuous))
        .sensoryFeedback(.selection, trigger: picked)
    }

    private func row(_ choice: String, number: Int) -> some View {
        let isPicked = picked.contains(choice)
        let isRecommended = choice == recommended
        return Button {
            if multi {
                if isPicked { picked.remove(choice) } else { picked.insert(choice) }
            } else {
                picked = [choice]
                onChoose(choice)
            }
        } label: {
            HStack(spacing: 12) {
                if let image = images[choice] {
                    LinkThumbnail(url: image, store: store, side: 36, placeholder: "photo")
                }
                Text(choice)
                    .font(.subheadline)
                    .foregroundStyle(DS.Chat.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isRecommended {
                    Image(systemName: "hand.thumbsup.fill")
                        .font(.subheadline)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .accessibilityHidden(true)
                }
                if multi || isPicked {
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isPicked ? DS.Chat.userBubble : DS.Chat.textSecondary.opacity(0.5))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 48)
            .background(DS.Chat.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(number)번, \(choice)\(isRecommended ? ", 추천" : "")")
        .accessibilityValue(multi ? (isPicked ? "고름" : "고르지 않음") : "")
        .accessibilityHint(multi ? "눌러서 고르거나 빼요" : "이 답을 보냅니다")
    }
}

/// 맥에 연결되지 않아 Claude가 대신 답한 말 아래: 연결이 돌아오면 같은 글을 맥에 다시 보낼 수 있다
struct OfflineAnswerNote: View {
    let isBusy: Bool
    let onResend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("맥에 연결되지 않아 Claude가 답했어요. 메일 초안 같은 일은 맥에 다시 보내면 돼요.")
                .font(.footnote)
                .foregroundStyle(DS.Chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("맥에 다시 보내기", action: onResend)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(DS.Chat.accent)
                .disabled(isBusy)
        }
        .padding(.leading, 6)
    }
}

/// 답한 곳 표시: Claude가 쓴 답의 말풍선 아래에 붙인다 (맥이 있는 앱에서만).
/// 회의 질문의 답(중계 서버 → Claude)과, 맥을 거친 답 가운데 맥이 "Claude가 썼다"고 알린 답 (D62)
///
/// D107: 보이지 않게 했다 — 혼자 쓰는 앱이라 매번 알릴 필요가 없다는 사용자의 말("claude 사용 이런 문구나 … 다 빼줘").
/// 누가 썼는지는 맥이 계속 알려 주고(`replies[].by`) 대화 기록에도 남는다. 다시 보이려면 이 뷰만 되살리면 된다
struct ClaudeUsedLabel: View {
    var body: some View {
        EmptyView()
    }
}

/// 채팅 안의 에이전트 작업 하나: 확인 문장 → 작업 한 줄 → 결정할 일(승인·질문)·결과.
/// 열기·입력 같은 세부 단계는 채팅에 보이지 않고, 작업 줄을 누르면 나오는 작업 상세에 있다.
///
/// 모양 규칙 (D47을 D82에서 고침): 에이전트가 건넨 말과 답은 말풍선(내용만큼),
/// 내가 정해야 하는 것(승인·질문·로그인)과 승인한 초안은 카드(화면 폭, 가는 선).
/// 작업 자체는 카드가 아니라 한 줄이다: 답이 먼저 보이고, 어떻게 했는지는 궁금할 때 눌러서 본다.
struct AgentRunView: View {
    let state: AgentTaskState
    /// 승인·거부 요청을 보내는 중
    let isBusy: Bool
    let onDecide: (_ approve: Bool, _ reason: String?) -> Void
    /// 작업 담당의 질문에 답한다 (선택지 버튼)
    let onAnswer: (String) -> Void
    let onCancel: () -> Void
    let onOpenDetail: () -> Void
    /// 메일 계정 연결 화면을 연다. nil이면 이 작업에는 연결 안내를 붙이지 않는다
    var onConnectMail: (() -> Void)?
    /// 보낼 수 있는 내 주소가 하나도 정해져 있지 않다 (연결 버튼 대신 주소부터 정하라고 안내한다)
    var mailNeedsAddressSetup = false
    /// 사이트 로그인 화면을 연다. nil이면 이 작업에는 로그인 안내를 붙이지 않는다
    var onSiteLogin: (() -> Void)?
    /// 답변 카드의 "다시 로그인"이 가리키는 사이트의 로그인 화면을 연다 (D110. 이 작업과 묶이지 않은 새 로그인)
    var onOpenSite: ((String) -> Void)?
    @Environment(\.inChat) private var inChat

    var body: some View {
        // 이어진 조각(한 마디·작업 줄·카드)은 한 덩어리로 붙인다 (D119)
        VStack(alignment: .leading, spacing: DS.Chat.groupSpacing + 2) {
            if let ack = state.ack {
                AgentBubble(text: ack)
                // 일을 맡았다는 한 마디를 Claude가 썼으면 그 아래에 표시한다.
                // 답에도 표시가 붙는 작업이면 답 아래의 한 번으로 한다: 한 차례에 한 번만 보인다 (D83)
                if state.marksClaudeOnAck {
                    ClaudeUsedLabel()
                }
            }

            AgentTaskLine(state: state, action: onOpenDetail)

            // 끼워 넣은 내 말 (D152): 마지막 것 하나와 반영했는지
            if let steers = state.steers, let last = steers.last, !state.phase.isFinished {
                AgentSteerLine(note: last, count: steers.count)
            }

            ForEach(Array((state.answered ?? []).enumerated()), id: \.offset) { _, answered in
                AnsweredQuestion(answered: answered)
            }

            switch state.phase {
            case .running:
                Button(DemoText.t("멈추기"), role: .cancel) {
                    Haptic.tap()
                    onCancel()
                }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.leading, 4)
                    .accessibilityHint("진행 중인 단계가 끝나면 작업을 멈춥니다")
            case .awaitingApproval:
                if let draft = state.draft {
                    // 누르려는 단추가 있는 그 화면 (D93. 대화에서만): 무엇을 승인하는지 보고 정할 수 있게 카드 위에 둔다
                    if inChat, let capture = draft.attachment {
                        ReportCaptures(taskID: state.id, attachments: [capture])
                    }
                    ApprovalCard(draft: draft, isBusy: isBusy, onDecide: onDecide)
                }
            case .awaitingInput:
                // 답을 보낸 뒤에는 작업 카드가 "답을 받아 이어서 진행해요"로 바뀌고, 답은 위에 남는다
                if let question = state.openQuestion {
                    if inChat, let capture = question.attachment {
                        ReportCaptures(taskID: state.id, attachments: [capture])
                    }
                    QuestionCard(question: question, picksOnly: state.asksSitePermission, isBusy: isBusy, onAnswer: onAnswer)
                }
            case .sendPending:
                SendPendingCard(state: state, onCancel: onCancel)
            case .done:
                AgentResultView(state: state)
            case .needsInput:
                VStack(alignment: .leading, spacing: 6) {
                    AgentBubble(text: state.question ?? "조금 더 알려 주세요.")
                    Text("아래 입력창에 답하면 원래 부탁과 함께 다시 맡겨요.")
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .padding(.leading, 4)
                }
            case .canceled, .failed:
                // 끝내지 못했어도 한 일·못 한 일 보고가 있으면 보여 준다
                if state.needsMailAccount, let onConnectMail {
                    // 메일 계정 때문에 보내지 못했다: 채팅에서 바로 연결 화면을 열 수 있게 한다
                    MailConnectPrompt(reason: state.sendFailure, isBusy: isBusy, action: mailNeedsAddressSetup ? nil : onConnectMail)
                } else {
                    // 로그인 때문에 멈췄다: 대화에서 바로 로그인할 수 있게 한다 (로그인하면 이 부탁을 다시 맡긴다)
                    let login = state.needsSiteLogin ? onSiteLogin : nil
                    // 답변 카드가 있으면 (D110): 카드의 제목이 한 줄 까닭이고, 다시 로그인하는 단추도 카드에 있다
                    let card = inChat ? state.report?.card : nil
                    if let card {
                        // "다시 로그인": 이 작업이 멈춘 그 사이트면 로그인 뒤 이 부탁을 다시 맡기는 길로, 아니면 그 사이트의 새 로그인으로
                        ReportCardView(card: card, reason: state.cardReason(for: card)) { site in
                            if site == state.loginSite, let login { login() } else { onOpenSite?(site) }
                        }
                    }
                    // 멈춘 까닭 한 문장. 작업 줄은 "실패"·"취소됨"만 말하므로 까닭은 말로 한다.
                    // 바로 아래의 카드나 보고가 같은 말을 하면 하지 않는다 (`stopReason`, D82)
                    if card == nil, let reason = state.stopReason(showsLoginCard: login != nil && state.loginSite != nil) {
                        AgentBubble(text: reason)
                    }
                    if card == nil, let report = state.report {
                        // 로그인 카드가 같은 말을 하므로, "로그인이 풀렸어요" 한 줄뿐인 보고는 겹쳐 보이지 않게 뺀다
                        let onlyLoginLine = login != nil && report.done.isEmpty && report.blocked.count <= 1
                        if !(report.done.isEmpty && report.blocked.isEmpty), !onlyLoginLine { ReportBubble(report: report) }
                    }
                    // 로그인 카드는 멈춘 이유 바로 아래에 둔다 (캡처에 밀려 내려가면 무엇을 하면 되는지가 늦게 보인다)
                    if let login, let site = state.loginSite, !(card?.actions.contains { $0.site != nil } ?? false) {
                        SiteLoginCard(
                            copy: SiteLoginCopy(site: site), isBusy: isBusy, stoppedExpired: state.loginExpired ?? false,
                            quickUnlock: SiteLoginFlow.quickUnlock(for: site), action: login
                        )
                    }
                    // 어디서 멈췄는지 보여 주는 화면 캡처 (대화에서만. 작업 상세에는 붙이지 않는다). 이 아래에는 "열기" 줄이 없다
                    if inChat, let attachments = state.report?.attachments {
                        ReportCaptures(taskID: state.id, attachments: attachments)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(DS.Chat.accent)
        .animation(.easeOut(duration: 0.25), value: state.phase)
        // 작업 소식 (D114): 내가 정할 일이 오면 알림처럼, 끝나면 성공, 못 하면 실패. 처음 그릴 때(지난 대화를 열 때)는 울리지 않는다
        .sensoryFeedback(trigger: state.phase) { old, new in
            guard old != new else { return nil }
            switch new {
            case .awaitingApproval, .awaitingInput, .needsInput: return .warning
            case .done: return .success
            case .failed: return .error
            default: return nil
            }
        }
    }
}

/// 카드 맨 위 한 줄 (무엇을 정해야 하는지)
private struct CardHeader: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        // D119: 색은 아이콘의 작은 점 하나로 줄이고, 제목은 본문 글자색으로 (참고 앱처럼 색이 적게)
        Label {
            Text(title).foregroundStyle(DS.Chat.textPrimary)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
    }
}

/// 작업 담당의 질문: 선택지가 있으면 버튼으로, 없거나 다른 답이면 아래 입력창으로 답한다.
/// 답하면 새 작업을 만들지 않고 같은 작업이 이어진다.
private struct QuestionCard: View {
    let question: AgentQuestion
    /// 선택지의 글 그대로만 답이 되는 질문인지 (사이트 화면을 Claude가 봐도 되는지 묻는 허락, D80)
    var picksOnly = false
    let isBusy: Bool
    let onAnswer: (String) -> Void
    @Environment(CaptureStore.self) private var captures: CaptureStore?
    @State private var showingBrowser = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                title: DemoText.t(question.handover == nil ? "확인할 것이 있어요" : "직접 해 주셔야 해요"),
                icon: question.handover == nil ? "questionmark.circle.fill" : "hand.point.up.left.fill", color: DS.Chat.accent
            )

            Text(question.text)
                .lineSpacing(4)
                .foregroundStyle(DS.Chat.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            // 손 넘기기 (D123): 맥의 브라우저 화면을 폰에 띄워 직접 푼다. 답을 받은 뒤에는 열지 않는다
            if let handover = question.handover, question.received != true, let agent = captures?.handoverAgent {
                Button { showingBrowser = true } label: {
                    Label(DemoText.t("브라우저 열기"), systemImage: "macbook.and.iphone").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Chat.userBubble)
                .controlSize(.large)
                .accessibilityHint("맥의 브라우저 화면을 띄워 직접 누르고 씁니다")
                .fullScreenCover(isPresented: $showingBrowser) {
                    HandoverView(agent: agent, handover: handover, choices: question.choices, onAnswer: onAnswer)
                }
                #if DEBUG
                // 데모 영상 (-demoReel): 카드를 잠깐 보인 뒤 브라우저를 연다
                .task {
                    guard DemoData.arguments.contains("-demoReel") else { return }
                    try? await Task.sleep(for: .seconds(2.2))
                    showingBrowser = true
                }
                #endif
            }

            if !question.choices.isEmpty {
                ChoiceButtons(choices: question.choices, onChoose: onAnswer)
                    .padding(.leading, -4)
            }

            Text(hint)
                .font(.footnote)
                .foregroundStyle(DS.Chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(isBusy)
        .chatCard()
    }

    /// 어떻게 답하는지. 허락 질문은 맥이 선택지의 글만 허락으로 받으므로, 입력창으로 답하라고 하지 않는다
    private var hint: String {
        if question.handover != nil, DemoText.english {
            return "The agent waits while you do this. Tap “\(question.choices.first ?? "Done")” when you're finished. The screen isn't saved on your phone."
        }
        if question.handover != nil { return "에이전트는 그동안 누르지 않아요. 다 하셨으면 \"\(question.choices.first ?? "다 했어요")\"를 눌러 주세요. 받은 화면은 폰에 저장하지 않아요." }
        if question.choices.isEmpty { return "아래 입력창에 답해 주세요. 답하면 하던 작업을 이어서 해요." }
        if picksOnly { return "단추로 골라 주세요. 입력창에 쓴 글은 허락으로 받지 않아서, 하지 않고 끝나요." }
        return "골라 주시거나 아래 입력창에 직접 답해 주세요. 답하면 하던 작업을 이어서 해요."
    }
}

/// 메일 계정이 없거나 로그인되지 않아 보내지 못했을 때: 연결 화면으로 가는 카드.
/// 앱 비밀번호는 채팅 입력창이 아니라 따로 뜨는 화면에서만 받는다 (대화 기록에 남지 않게)
private struct MailConnectPrompt: View {
    let reason: String?
    let isBusy: Bool
    /// nil이면 보낼 수 있는 내 주소가 아직 없는 것이다: 앱에서 연결할 수 없으니 버튼을 두지 않는다
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                title: action == nil ? "내 메일 주소를 먼저 정해야 해요" : "메일 계정 연결이 필요해요",
                icon: "envelope.badge.fill", color: DS.Chat.accent
            )

            Text(message)
                .lineSpacing(4)
                .foregroundStyle(DS.Chat.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let action {
                Button(action: action) {
                    Text("메일 계정 연결").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Chat.userBubble)
                .controlSize(.large)
                .accessibilityHint("앱 비밀번호를 넣는 화면을 엽니다")

                Text("앱 비밀번호는 채팅이 아니라 따로 뜨는 화면에서 넣어요. 대화 기록에는 남지 않아요.")
                    .font(.footnote)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(isBusy)
        .chatCard()
    }
}

/// 맥이 사이트 로그인이 필요하다고 했을 때: 로그인 화면으로 가는 카드 (D48).
/// 아이디·비밀번호는 채팅 입력창이 아니라 따로 뜨는 화면에서만 받는다 (대화 기록에 남지 않게).
/// 글은 흐름의 종류(로그인 · 메일 연결)에 따라 다르다 (D52)
struct SiteLoginCard: View {
    let copy: SiteLoginCopy
    let isBusy: Bool
    /// 작업이 로그인 때문에 멈춘 자리에 붙는 카드면 그 까닭 (풀렸는지). 로그인하면 그 일을 이어서 한다고 알려 준다
    var stoppedExpired: Bool?
    /// 이 아이폰에 그 사이트의 값을 저장해 두었으면 "Face ID" (D122): 단추가 "Face ID로 다시 로그인"이 된다
    var quickUnlock: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                title: stoppedExpired.map(copy.stoppedCardTitle) ?? copy.cardTitle,
                icon: copy.kind == .login ? "person.badge.key.fill" : "envelope.badge.fill", color: DS.Chat.accent
            )

            Text(stoppedExpired.map(copy.stoppedCardBody) ?? copy.cardBody)
                .lineSpacing(4)
                .foregroundStyle(DS.Chat.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: action) {
                if let quickUnlock {
                    Label(copy.quickRelogin(unlock: quickUnlock), systemImage: quickUnlock == "Touch ID" ? "touchid" : "faceid")
                        .frame(maxWidth: .infinity)
                } else {
                    Text(copy.cardButton).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Chat.userBubble)
            .controlSize(.large)
            .accessibilityHint(quickUnlock.map(copy.quickReloginHint) ?? copy.cardButtonHint)

            Text(copy.cardFooter)
                .font(.footnote)
                .foregroundStyle(DS.Chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(isBusy)
        .chatCard()
    }
}

/// 앱에서 사이트 로그인을 마쳤을 때: 로그인 카드가 있던 자리에 붙는 완료 카드 (D49).
/// 누르면 내 정보의 연동 센터로 간다 (지금 무엇이 연동되어 있는지 거기서 본다)
struct SiteLoggedInCard: View {
    let copy: SiteLoginCopy
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    CardHeader(title: copy.doneCardTitle, icon: "checkmark.circle.fill", color: DS.Chat.success)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.Chat.textSecondary)
                        .accessibilityHidden(true)
                }

                // 무엇이 어디에 남았는지의 설명 문장은 대화 카드에 두지 않는다 (D107). 연동 센터에서 볼 수 있다
                Text("연동 센터에서 연동 상태 보기")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(DS.Chat.accent)
            }
            .chatCard()
            .contentShape(RoundedRectangle(cornerRadius: DS.Chat.cardRadius, style: .continuous))
        }
        .buttonStyle(ChatCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("내 정보의 연동 센터를 엽니다")
    }
}

/// 카드 전체가 버튼일 때: 누르는 동안만 살짝 흐리게
private struct ChatCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension MailConnectPrompt {
    private var message: String {
        if action == nil { return MailKeeper.addressSetupGuide + " 그다음에 여기서 앱 비밀번호를 넣어 연결할 수 있어요." }
        return reason == "auth_failed"
            ? "메일 계정에 로그인하지 못했어요. 앱 비밀번호를 다시 넣어 연결하면 같은 부탁을 이어서 해요."
            : "메일을 보내려면 내 메일 계정을 한 번 연결해야 해요. 연결하면 같은 부탁을 이어서 해요."
    }
}

/// 보내기를 승인한 뒤 잠깐 기다리는 동안: 남은 시간과 보낼 메일, 그리고 취소.
/// 이 시간이 지나면 메일이 나가고 되돌릴 수 없다. 취소가 받아들여졌는지는 맥이 정한다 (늦으면 보낸 결과가 온다)
private struct SendPendingCard: View {
    let state: AgentTaskState
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                CardHeader(title: Self.title(state.sendWait?.remaining(at: context.date)), icon: "paperplane.fill", color: DS.Chat.accent)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }

            if let mail = state.outgoing {
                // 카드 안에 카드를 두지 않는다: 메일 내용은 이 카드의 본문이다
                DraftCard(draft: mail, header: "보낼 메일", embedded: true)
                ChatHairline()
            }

            Button(role: .cancel, action: onCancel) {
                Text("보내기 취소").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("아직 보내지 않았으면 보내지 않고 끝냅니다")

            Text("취소하면 메일은 보내지 않아요. 보낸 뒤에는 되돌릴 수 없어요.")
                .font(.footnote)
                .foregroundStyle(DS.Chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .chatCard()
    }

    static func title(_ left: Int?) -> String {
        guard let left else { return "곧 보내요" }
        return left > 0 ? "\(left)초 뒤에 보내요" : "보내는 중이에요"
    }
}

/// 이미 답한 질문과 내 답 (작업 카드 아래에 남는다)
private struct AnsweredQuestion: View {
    let answered: AgentAnswered

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(answered.question)
                .foregroundStyle(DS.Chat.textSecondary)
            Text(DemoText.english ? "Your answer: \(answered.answer)" : "내 답: \(answered.answer)")
                .fontWeight(.semibold)
                .foregroundStyle(DS.Chat.textPrimary)
            if !answered.delivered {
                Text("질문 시간이 지나 이 답은 전달되지 않았어요.")
                    .foregroundStyle(DS.Chat.warning)
            }
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
    }
}

/// 에이전트의 말 (왼쪽 회색 말풍선)
struct AgentBubble: View {
    let text: String
    @Environment(\.inChat) private var inChat

    var body: some View {
        if inChat {
            // 대화 안: 답변 말풍선과 같은 면. 길게 누르면 복사·선택
            Text(text)
                .foregroundStyle(DS.Chat.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .chatBubble(DS.Chat.bubble)
                .messageActions(text: text)
                .padding(.trailing, 36)
        } else {
            Text(text)
                .lineSpacing(6)
                .foregroundStyle(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(DS.Colors.secondarySurface, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

extension AgentTaskState {
    /// 상태의 색: 진행·질문은 파랑, 결정이 필요하거나 실패하면 주황, 끝나면 초록, 취소는 회색
    var chatTone: Color {
        switch phase {
        case .running, .sendPending, .awaitingInput, .needsInput: DS.Chat.accent
        case .awaitingApproval, .failed: DS.Chat.warning
        case .done: DS.Chat.success
        case .canceled: DS.Chat.textSecondary
        }
    }
}

/// 작업 한 줄 (D82): 상태 표시 · 제목 · (끝나지 않았으면) 상태 이름. 눌러서 작업 상세를 연다.
/// 맥이 일하는 동안에만 그 아래에 지금 하는 일 한 문장이 붙는다. 끝난 작업은 한 줄만 남는다:
/// 대화에서 먼저 보여야 하는 것은 답이고, 어떻게 했는지는 보고 싶은 사람만 눌러서 본다.
private struct AgentTaskLine: View {
    let state: AgentTaskState
    let action: () -> Void

    private static let iconWidth: CGFloat = 18
    private static let iconGap: CGFloat = 8

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Self.iconGap) {
                    AgentPhaseIcon(state: state, size: 13)
                        .frame(width: Self.iconWidth)
                    HStack(spacing: 4) {
                        // D119: 작업 줄은 답 사이의 작은 덧말이다 — 흐리고 작게
                        Text(state.title)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .lineLimit(1)
                        if let status = state.lineStatus {
                            Text("· \(status)")
                                .fontWeight(.semibold)
                                .foregroundStyle(state.chatTone)
                                .lineLimit(1)
                                .layoutPriority(1)
                                .contentTransition(.opacity)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .font(.footnote)
                }
                if let activity = state.lineActivity {
                    Text(activity)
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .contentTransition(.opacity)
                        .padding(.leading, Self.iconWidth + Self.iconGap)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .frame(minHeight: 32)
            // 보이는 것은 한 줄이지만 누르는 자리는 위아래로 조금 넓게 받는다
            .contentShape(Rectangle().inset(by: -6))
            .animation(.easeOut(duration: 0.25), value: state.lineActivity)
            .animation(.easeOut(duration: 0.25), value: state.statusLabel)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("맥 에이전트 작업, \(state.statusLabel). \(state.title). \(state.currentStatus)")
        .accessibilityHint("작업 기록을 봅니다")
    }
}

/// 작업 상태 표시 (진행 중이면 돌아가는 표시)
struct AgentPhaseIcon: View {
    let state: AgentTaskState
    /// 표시의 크기. 대화의 작업 줄은 글자 크기에 맞춰 작게 쓴다
    var size: CGFloat = 15

    var body: some View {
        // 모아의 상태 그림 (D130). 멈춘 것(취소)만 시스템 기호로 둔다
        if let kind = Self.kind(state) {
            MoaStatusIcon(kind: kind, size: size + 5)
        } else {
            Image(systemName: "xmark")
                .font(.system(size: size - 2, weight: .medium))
                .foregroundStyle(DS.Chat.textSecondary)
                .frame(width: size + 5, height: size + 5)
        }
    }

    static func kind(_ state: AgentTaskState) -> MoaStatusIcon.Kind? {
        switch state.phase {
        case .running, .sendPending: .running
        case .awaitingApproval: .approval
        case .done: .done
        case .awaitingInput: state.isWorking ? .running : .reply
        case .needsInput: state.loginSite != nil ? .login : .reply
        case .canceled: nil
        // 로그인이 없어 멈춘 일은 "로그인 필요"로 (내가 할 일)
        case .failed: state.loginSite != nil ? .login : .failed
        }
    }
}

/// 끝난 작업의 결과: 보고, 보낸 메일·저장한 초안, 보냄·저장 여부 한 줄, 처리한 곳 링크.
/// 보내거나 저장한 내용은 에이전트의 보고가 아니라 승인한 초안으로 보여 주고,
/// 보냈는지·도착했는지는 맥이 직접 확인한 값(`report.sent`)으로만 말한다.
/// 맥이 한 일·못 한 일을 나눠 보내면(`report`) 한 문단 보고 대신 그것으로 보여 준다.
struct AgentResultView: View {
    let state: AgentTaskState
    @Environment(\.inChat) private var inChat
    @Environment(\.itemPicker) private var itemPicker

    /// 열어 볼 곳: 보고에 확인한 곳이 있으면 그 주소들(사이트마다 한 줄). 맥이 비워 보냈으면 두지 않는다 (`openLinks`).
    /// 대화의 답변 카드에 같은 사이트를 여는 단추가 있으면 아래 줄로 또 두지 않는다 (D118)
    private var links: [AgentLink] { state.openLinks.filter { !cardSites.contains($0.host) } }

    /// 답변 카드의 단추가 여는 사이트 (대화에서만)
    private var cardSites: Set<String> {
        guard inChat, let card = state.report?.card else { return [] }
        return Set(card.actions.compactMap { $0.url.map { AgentLink(title: "", url: $0).host } })
    }

    /// 맥의 브라우저가 실제로 연 페이지 (`report.links`, D64). 대화에서는 "○○ 열기" 줄 대신 카드로 그린다.
    /// 작업 상세에서는 지금처럼 줄로 둔다 (그림을 받지 않는다)
    private var pages: [AgentLink] {
        guard inChat else { return [] }
        // 상품 카드로 이미 보여 준 주소는 페이지 카드로 또 그리지 않는다
        let shown = Set(items.map(\.url))
        return (state.report?.links ?? []).filter { !shown.contains($0.url) && !cardSites.contains($0.host) }
    }

    /// 찾은 상품 (`report.items`, D72). 대화에서만 카드로 그린다
    private var items: [AgentItem] {
        inChat ? state.report?.items ?? [] : []
    }

    /// 보여 줄 보고 (한 일도 못 한 일도 없으면 없다)
    private var report: AgentReport? {
        guard let report = state.report, !(report.done.isEmpty && report.blocked.isEmpty) else { return nil }
        return report
    }

    /// 대화에서는 초안이 결과의 본문이다. 못 한 일이 없는 보고(한 일 목록)는 같은 말의 반복이라
    /// 초안과 확인 줄 아래에 약하게 둔다. 못 한 일이 있거나 초안이 없으면 보고가 먼저다
    private var reportIsMinor: Bool { inChat && state.reportFollowsDrafts }

    /// 같은 결과에 "○○ 열기" 줄이나 페이지 카드로 이미 보이는 사이트. 캡처의 설명에서 그 주소를 되풀이하지 않는다 (D83)
    private var linkedSites: Set<String> {
        if !pages.isEmpty { return Set(pages.map(\.host)) }
        return items.isEmpty ? Set(links.map(\.host)) : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: inChat ? DS.Chat.groupSpacing + 2 : 8) {
            // 답을 읽은 화면의 캡처: 답 위에 작은 그림으로 (D84. 대화에서만. 작업 상세에는 붙이지 않는다)
            if inChat, let attachments = state.report?.attachments {
                ReportCaptures(taskID: state.id, attachments: attachments, linkedSites: linkedSites)
            }
            if let report {
                if inChat, let card = report.card {
                    // 답변 카드 (D110): 맥이 카드를 주었으면 줄글 대신 카드로 (끝난 작업이라 다시 로그인할 일은 없다)
                    ReportCardView(card: card, reason: state.cardReason(for: card))
                } else if !reportIsMinor {
                    ReportBubble(report: report)
                    // 이 답을 Claude가 썼다고 맥이 알렸으면 그 아래에 표시한다 ("찾아 달라"는 작업, D65). 작업 상세에는 붙이지 않는다
                    if inChat, state.marksClaudeOnResult {
                        ClaudeUsedLabel()
                    }
                }
            } else if let result = state.result, !result.isEmpty {
                if inChat { ResultTextBubble(text: result) } else { AgentBubble(text: result) }
            }
            ForEach(Array(state.sentDrafts.enumerated()), id: \.offset) { _, draft in
                DraftCard(draft: draft, header: "보낸 메일", isSent: true)
            }
            ForEach(Array(state.savedDrafts.enumerated()), id: \.offset) { _, draft in
                DraftCard(draft: draft, header: "저장한 초안")
            }
            verification
            if let report, reportIsMinor {
                ReportBubble(report: report, minor: true)
            }
            if !items.isEmpty {
                ReportItemCards(
                    items: items, canPick: itemPicker?.isEnabled == true,
                    onPick: itemPicker.map { picker in { picker.pick($0, state.id) } },
                    opensInShop: state.usedShop == true
                )
            }
            if !pages.isEmpty {
                ReportLinkCards(links: pages)
            } else if items.isEmpty {
                ForEach(links, id: \.url) { link in
                    Link(destination: link.url) {
                        Label("\(link.title) 열기", systemImage: "arrow.up.right.square")
                            // 대화에서는 답 아래에 붙는 덧말이라 한 단계 작게 (D82)
                            .font((inChat ? Font.footnote : Font.subheadline).weight(.semibold))
                    }
                    .padding(.leading, 4)
                    .accessibilityHint("사파리에서 엽니다")
                }
            }
        }
    }

    /// 보냈는지·도착했는지·저장했는지: 맥이 직접 확인한 값으로만 말한다.
    /// 문장과 조건은 대화와 작업 상세가 같다 (모양만 다르다)
    @ViewBuilder
    private var verification: some View {
        if state.cancelMissed == true, !state.sentDrafts.isEmpty {
            line("취소가 늦어 메일은 이미 보내졌어요.", icon: "exclamationmark.circle.fill", ok: false)
        }
        ForEach(Array(state.sent.enumerated()), id: \.offset) { _, sent in
            if sent.verified == .delivered {
                line("메일을 보냈고, 받은편지함에 도착한 것을 확인했어요.", icon: "checkmark.circle.fill", ok: true)
            } else if sent.external == true {
                // 다른 사람에게 보낸 메일 (D89): 받는 분의 받은편지함은 볼 수 없다. "아직"이라고 하지 않는다
                line("메일을 보냈어요. 메일 서버가 받았어요. 받는 분의 받은편지함은 확인할 수 없어요.", icon: "info.circle.fill", ok: false)
            } else {
                line("메일을 보냈어요. 메일 서버가 받았지만, 받은편지함에 도착했는지는 아직 확인하지 못했어요.", icon: "info.circle.fill", ok: false)
            }
        }
        if state.sent.isEmpty, !state.sentDrafts.isEmpty {
            line("메일을 보냈어요. 도착 확인 결과는 받지 못했어요.", icon: "info.circle.fill", ok: false)
        }
        if let approved = state.approvedActionsLine {
            // 로그인한 사이트 안에서 한 일: 내가 승인한 단추의 이름 (D80). 한 일은 위의 보고가 말한다
            line(approved, icon: "checkmark.circle.fill", ok: true)
        }
        if !state.savedDrafts.isEmpty {
            line("초안 \(state.savedDrafts.count)개를 저장했어요. 보내지는 않았어요.", icon: "checkmark.circle.fill", ok: true)
        } else if state.typedWithoutSaving {
            // 실사용에서 확인: 입력만 하고 저장 없이 끝났는데 보고는 "작성했다"인 경우가 있다
            line("저장된 초안은 없어요. 위 보고와 실제 저장 내용이 다를 수 있어요.", icon: "info.circle.fill", ok: false)
        }
    }

    /// `ok`: 확인된 결과인지 (아니면 주의해서 읽을 말). 대화에서는 한 단계 작은 글자로 초안 아래에 붙는다
    private func line(_ text: String, icon: String, ok: Bool) -> some View {
        Label {
            Text(text)
                .foregroundStyle(inChat ? DS.Chat.textPrimary : DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(inChat ? (ok ? DS.Chat.success : DS.Chat.warning) : (ok ? DS.Colors.success : DS.Colors.warning))
        }
        .font(inChat ? .footnote : .subheadline)
        .padding(.leading, 4)
    }
}

/// 한 문단으로 온 작업 결과 (대화 안). 답이므로 보통의 답 말풍선으로 그린다 (D82)
private struct ResultTextBubble: View {
    let text: String

    var body: some View {
        AnswerBubbles(parts: AnswerText.bubbles(text), copyText: text)
    }
}

/// 답 말풍선들 (D84): 빈 줄로 갈린 문단마다 하나씩, 바짝 붙여 놓는다. 어느 것을 길게 눌러도 답 전체가 복사된다
private struct AnswerBubbles: View {
    let parts: [String]
    let copyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Chat.groupSpacing) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                AnswerText(text: part)
                    .foregroundStyle(DS.Chat.textPrimary)
                    .chatBubble(DS.Chat.bubble)
                    .messageActions(text: copyText)
                    .padding(.trailing, 36)
            }
        }
    }
}

/// 맥의 보고: 한 일과 하지 못한 일을 나눠서 보여 준다 (말풍선 하나)
/// 답변 카드 (D110): 아이콘과 제목(·부제) → 블록 셋까지 → 단추 둘까지. 모든 답이 같은 꼴이다.
/// 블록은 내 공간의 블록 그대로 그린다. 주소 단추는 누를 때만 그 페이지를 앱 안에서 연다
struct ReportCardView: View {
    let card: AgentReportCard
    /// 부제가 없는 카드에 대신 붙일 한 줄 (D118: 못 한 일의 까닭)
    var reason: String?
    /// 사이트 단추를 눌렀을 때 (그 사이트의 로그인 화면을 연다). nil이면 사이트 단추는 눌리지 않는다
    var onSiteLogin: ((String) -> Void)?
    @State private var opened: OpenedPage?

    private struct OpenedPage: Identifiable {
        let url: URL
        var id: URL { url }
    }

    /// 머리의 그림 (D130: 이모지 대신 모아의 상태 그림)
    private var badge: MoaStatusIcon {
        MoaStatusIcon(kind: card.kind == .failed ? .failed : .done, size: 26)
    }

    /// 블록을 그리는 데 쓰는 자리 (내 공간의 넓은 카드와 같은 크기)
    private var space: SpaceCard { SpaceCard(id: "report", kind: .custom, size: .large, title: card.title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.headline)
                        .foregroundStyle(DS.Chat.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle = card.subtitle ?? reason {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(Array(card.blocks.enumerated()), id: \.offset) { index, block in
                SpaceBlockView(block: block, card: space, first: index == 0, full: true)
            }
            // 단추 대신 누르는 줄 (D119): 한 단계 가라앉힌 면에 이름과 ↗/›
            ForEach(Array(card.actions.enumerated()), id: \.offset) { _, action in
                actionRow(action)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCard()
        .messageActions(text: ([card.title] + [card.subtitle ?? reason].compactMap { $0 }).joined(separator: "\n"))
        .sheet(item: $opened) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func actionRow(_ action: AgentReportCard.Action) -> some View {
        let enabled = action.url != nil || (action.site != nil && onSiteLogin != nil)
        Button {
            if let url = action.url {
                opened = OpenedPage(url: url)
            } else if let site = action.site {
                onSiteLogin?(site)
            }
        } label: {
            HStack(spacing: 8) {
                Text(action.label)
                    .font(.subheadline)
                    .foregroundStyle(DS.Chat.textPrimary)
                Spacer(minLength: 4)
                Image(systemName: action.url != nil ? "arrow.up.right" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.Chat.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .background(DS.Chat.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityHint(action.url != nil ? "웹 페이지를 엽니다" : "다시 로그인합니다")
    }
}

struct ReportBubble: View {
    let report: AgentReport
    /// 대화에서 초안 아래에 붙는 한 일 목록: 면 없이 작은 글자로 (같은 결과를 다시 강조하지 않는다)
    var minor = false
    @Environment(\.inChat) private var inChat

    private var copyText: String {
        (report.done + report.blocked).joined(separator: "\n")
    }

    var body: some View {
        if inChat, minor {
            groups.padding(.leading, 4)
        } else if inChat, let parts = answerParts {
            // 답이 문단 여럿으로 왔다: 문단마다 말풍선 (D84)
            AnswerBubbles(parts: parts, copyText: copyText)
        } else if inChat {
            // 대화 안: 보고는 맥의 답이다. 보통의 답 말풍선으로 그린다 (D82. 전에는 테두리 카드였다).
            // 한 건씩 나눠 그리는 답(결제내역 등)은 금액을 오른쪽 끝에 맞추므로 폭을 다 쓴다
            groups
                .frame(maxWidth: hasRecords ? .infinity : nil, alignment: .leading)
                .chatBubble(DS.Chat.bubble)
                .messageActions(text: copyText)
                .padding(.trailing, hasRecords ? 0 : 36)
        } else {
            groups
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(DS.Colors.secondarySurface, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    /// 답 하나가 빈 줄로 갈린 문단 여럿이면 그 문단들 (D84). 한 건씩 나눠 그리는 답과,
    /// 한 일·하지 못한 일로 갈리는 보고는 나누지 않는다 (지금처럼 말풍선 하나다)
    private var answerParts: [String]? {
        guard isPlainAnswer, !hasRecords, let answer = report.done.first else { return nil }
        let parts = AnswerText.bubbles(answer)
        return parts.count > 1 ? parts : nil
    }

    /// 번호 붙은 항목으로 나눠 그리는 답이 있는지
    private var hasRecords: Bool {
        (report.done + report.blocked).contains { ReportRecords.parse($0) != nil }
    }

    /// 대화의 답 말풍선에서 한 일 앞의 체크 표시를 뺄지: 답이 하나뿐이고 하지 못한 일도 없으면 그 글이 곧 답이다.
    /// 여러 가지를 했거나 하지 못한 일과 나란히 놓일 때는 표시가 있어야 갈려 보인다
    private var isPlainAnswer: Bool {
        inChat && !minor && report.done.count == 1 && report.blocked.isEmpty
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: minor ? 6 : 10) {
            if isPlainAnswer, let answer = report.done.first {
                if let records = ReportRecords.parse(answer) {
                    ReportRecordList(records: records, icon: nil, color: DS.Chat.success)
                } else {
                    AnswerText(text: answer).foregroundStyle(DS.Chat.textPrimary)
                }
            } else if !report.done.isEmpty {
                group(report.blocked.isEmpty ? nil : "한 일", report.done, icon: "checkmark", color: inChat ? DS.Chat.success : DS.Colors.success)
            }
            if !report.blocked.isEmpty {
                group("하지 못한 일", report.blocked, icon: "exclamationmark", color: inChat ? DS.Chat.warning : DS.Colors.warning)
            }
        }
    }

    private func group(_ title: String?, _ items: [String], icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: minor ? 4 : 6) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(inChat ? DS.Chat.textSecondary : DS.Colors.textSecondary)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                // 번호 붙은 항목 여러 줄로 온 답(결제내역 등)은 한 건씩 나눠 보여 준다. 그 모양이 아니면 글 그대로
                if inChat, !minor, let records = ReportRecords.parse(item) {
                    ReportRecordList(records: records, icon: icon, color: color)
                } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon)
                        .font((minor ? Font.caption2 : Font.footnote).weight(.bold))
                        .foregroundStyle(minor ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    if inChat, !minor {
                        // 맥이 "- "로 쓴 짧은 줄은 목록 꼴로 (D82)
                        AnswerText(text: item).foregroundStyle(DS.Chat.textPrimary)
                    } else if inChat {
                        Text(item)
                            .font(.footnote)
                            .lineSpacing(2)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(item)
                            .lineSpacing(4)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                }
            }
        }
    }
}

/// 번호 붙은 항목으로 온 답 (D57): 한 건에 한 칸. 이름은 왼쪽, 금액은 오른쪽, 날짜·상태는 그 아래 작은 글씨.
/// 글자는 맥이 쓴 그대로다 (나눠 놓기만 한다). 길게 눌러 복사하면 원래 글이 그대로 복사된다
private struct ReportRecordList: View {
    let records: ReportRecords
    /// 앞글 앞에 붙는 표시. nil이면 붙이지 않는다 (답이 하나뿐인 말풍선)
    let icon: String?
    let color: Color
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !records.intro.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(color)
                            .frame(width: 14)
                            .accessibilityHidden(true)
                    }
                    note(records.intro)
                }
                .padding(.bottom, 10)
            }
            ForEach(records.records) { record in
                if record.id > 1 || !records.intro.isEmpty { ChatHairline() }
                row(record)
                    .padding(.top, record.id == 1 && records.intro.isEmpty ? 0 : 10)
                    .padding(.bottom, record.id == records.records.count && records.outro.isEmpty ? 0 : 10)
            }
            if !records.outro.isEmpty {
                ChatHairline()
                note(records.outro).padding(.top, 10)
            }
        }
    }

    private func note(_ lines: [String]) -> some View {
        Text(lines.joined(separator: "\n"))
            .lineSpacing(4)
            .foregroundStyle(DS.Chat.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ record: ReportRecords.Record) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(record.id)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(DS.Chat.textSecondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                if typeSize.isAccessibilitySize {
                    // 큰 글씨: 금액을 이름 아래로 내린다 (옆에 두면 이름이 한두 글자씩 접힌다)
                    title(record)
                    if let amount = record.amount { self.amount(amount) }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        title(record)
                        Spacer(minLength: 0)
                        if let amount = record.amount { self.amount(amount).layoutPriority(1) }
                    }
                }
                if !record.details.isEmpty {
                    Text(record.details.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(record.spoken)
    }

    private func title(_ record: ReportRecords.Record) -> some View {
        Text(record.title)
            .font(.body.weight(.medium))
            .lineSpacing(3)
            .foregroundStyle(DS.Chat.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func amount(_ text: String) -> some View {
        Text(text)
            .font(.body.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(DS.Chat.textPrimary)
            .lineLimit(1)
    }
}

/// 초안 내용 (받는 사람 등 + 제목 + 본문, 길면 접어서)
struct DraftCard: View {
    let draft: AgentDraft
    let header: String
    /// 다른 카드의 본문으로 들어간다 (승인·보내기 대기). 자기 면과 테두리를 그리지 않는다
    private let embedded: Bool
    /// 이미 보낸 메일 (다른 사람에게 보낸 것이면 "확인해 주세요" 대신 보냈다고만 말한다)
    private let isSent: Bool
    @State private var expanded: Bool
    @Environment(\.inChat) private var inChat

    /// `showsAll`: 승인할 초안은 처음부터 전체를 보여 준다 (승인하는 내용을 가리지 않는다)
    init(draft: AgentDraft, header: String, showsAll: Bool = false, embedded: Bool = false, isSent: Bool = false) {
        self.draft = draft
        self.header = header
        self.embedded = embedded
        self.isSent = isSent
        _expanded = State(initialValue: showsAll)
    }

    /// 대화 모양으로 그리는지 (작업 상세에서는 예전 모양)
    private var chat: Bool { inChat || embedded }
    private var primary: Color { chat ? DS.Chat.textPrimary : DS.Colors.textPrimary }
    private var secondary: Color { chat ? DS.Chat.textSecondary : DS.Colors.textSecondary }
    /// 제목·본문 글자색. 작업 상세에서는 예전처럼 색을 따로 주지 않는다 (시스템 기본 글자색)
    private var bodyStyle: AnyShapeStyle { chat ? AnyShapeStyle(DS.Chat.textPrimary) : AnyShapeStyle(.primary) }

    var body: some View {
        if embedded {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else if inChat {
            content.chatCard()
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                // 선 없이 면만 (D117). 어두운 화면에서도 보이게 가라앉은 면을 깐다
                .background(DS.Colors.secondarySurface, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(header)
                // 보내는 메일은 제목("보낼 메일"·"보낸 메일")이 이미 동작을 말한다
                if !draft.isSend { Text("· \(draft.action)") }
                if draft.revision > 1 { Text("· 수정본 \(draft.revision - 1)") }
            }
            .font(chat ? .caption.weight(.semibold) : .caption)
            .foregroundStyle(secondary)

            if draft.isExternal {
                // 다른 사람에게 보내는 메일 (D89): 보내면 되돌릴 수 없다. 누구에게 가는지부터 보게 한다
                Label(
                    isSent ? "다른 사람에게 보낸 메일이에요." : "다른 사람에게 보내는 메일이에요. 받는 사람을 확인해 주세요.",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(chat ? DS.Chat.warning : DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(draft.otherFields, id: \.label) { field in
                let marked = draft.isExternal && field.label == AgentDraft.recipientLabel
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(field.label)
                        .foregroundStyle(secondary)
                    Text(field.value.isEmpty ? "(비어 있음)" : field.value)
                        .fontWeight(marked ? .semibold : .regular)
                        .foregroundStyle(field.value.isEmpty ? secondary : primary)
                        .textSelection(.enabled)
                }
                .font(marked ? .subheadline : .footnote)
            }
            if let title = draft.title {
                Text(title.isEmpty ? "(제목 없음)" : title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(bodyStyle)
                    .padding(.top, chat ? 2 : 0)
            }
            if let body = draft.body {
                Text(body)
                    .font(.subheadline)
                    .lineSpacing(4)
                    .foregroundStyle(bodyStyle)
                    .lineLimit(expanded ? nil : 6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if body.count > 160 || body.filter({ $0 == "\n" }).count > 5 {
                    Button(expanded ? "접기" : "전체 보기") { withAnimation { expanded.toggle() } }
                        .font(.footnote.weight(.semibold))
                }
            }
            if let hash = draft.shortHash {
                // 승인 카드와 저장한 초안의 번호가 같으면 승인한 내용 그대로 저장된 것이다
                Label("확인 번호 \(hash)", systemImage: "lock.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(secondary)
                    .accessibilityLabel("내용 확인 번호 \(hash)")
            }
        }
    }
}

/// 단추 누르기 승인의 내용 (맥의 `site_do`, D80): 누를 단추, 어느 사이트의 화면인지, 그 화면에 입력된 값.
/// 받은 값을 그대로 보여 준다. 초안 카드의 모양(제목·본문 자리, "확인할 초안")을 쓰지 않는다
private struct ActionApprovalBody: View {
    let draft: AgentDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                caption("누를 단추")
                Text(draft.action.isEmpty ? "(이름 없는 단추)" : draft.action)
                    .font(.headline)
                    .foregroundStyle(DS.Chat.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 어느 사이트의 단추인지 (호스트만. 로그인한 화면의 주소 전체는 보이지 않는다)
            Label(draft.site.map { "\($0) 화면에서 눌러요" } ?? "어느 사이트의 화면인지는 받지 못했어요", systemImage: "globe")
                .font(.footnote)
                .foregroundStyle(DS.Chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !draft.fields.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    caption("화면에 입력된 값")
                    ForEach(Array(draft.fields.enumerated()), id: \.offset) { _, field in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(field.label)
                                .foregroundStyle(DS.Chat.textSecondary)
                            Text(field.value.isEmpty ? "(비어 있음)" : field.value)
                                .foregroundStyle(field.value.isEmpty ? DS.Chat.textSecondary : DS.Chat.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.footnote)
                    }
                }
            }
            if let hash = draft.shortHash {
                Label("확인 번호 \(hash)", systemImage: "lock.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.Chat.textSecondary)
                    .accessibilityLabel("내용 확인 번호 \(hash)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(DS.Chat.textSecondary)
    }
}

/// 승인 대기: 초안을 보여 주고 승인 또는 거부(사유)를 받는다.
/// 카드 하나에 차례로 담는다 (무엇을 정하는지 → 그 내용 → 승인하면 일어나는 일 → 버튼). 카드 안에 카드를 두지 않는다
private struct ApprovalCard: View {
    let draft: AgentDraft
    let isBusy: Bool
    let onDecide: (_ approve: Bool, _ reason: String?) -> Void

    @State private var rejecting = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(
                title: draft.isSend ? "보내기 승인이 필요해요" : (draft.isAction ? "단추 누르기 승인이 필요해요" : "승인이 필요해요"),
                icon: draft.isSend ? "paperplane.fill" : (draft.isAction ? "hand.tap.fill" : "hand.raised.fill"), color: DS.Chat.warning
            )

            if draft.isAction {
                // 초안이 아니라 단추 하나를 누르는 승인: 초안의 말을 쓰지 않는다 (D80)
                ActionApprovalBody(draft: draft)
            } else {
                DraftCard(draft: draft, header: draft.isSend ? "보낼 메일" : "확인할 초안", showsAll: true, embedded: true)
            }

            ChatHairline()

            Text(explanation)
                .font(.footnote)
                .foregroundStyle(DS.Chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if draft.received != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(draft.received == "approve" ? "승인을 전달했어요. 처리하고 있어요." : "거부를 전달했어요. 처리하고 있어요.")
                        .font(.subheadline)
                        .foregroundStyle(DS.Chat.textSecondary)
                }
            } else if rejecting {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("무엇을 고칠까요? 비우면 작업을 끝내요", text: $reason, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($reasonFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(DS.Chat.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    HStack {
                        Button("돌아가기") {
                            rejecting = false
                            reason = ""
                        }
                        .buttonStyle(.bordered)
                        .tint(DS.Chat.textPrimary)
                        Spacer()
                        Button(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "작업 끝내기" : "고쳐 달라고 하기") {
                            Haptic.tap()
                            onDecide(false, reason)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DS.Colors.danger : DS.Chat.userBubble)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        rejecting = true
                        reasonFocused = true
                    } label: {
                        Text("거부").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    // 파랑 대신 회색 (D119: 진한 색은 승인 단추 하나만)
                    .tint(DS.Chat.textPrimary)
                    Button {
                        // 승인은 되돌릴 수 없는 일을 정하는 것이라 조금 더 또렷하게
                        Haptic.firm()
                        onDecide(true, nil)
                    } label: {
                        Text(draft.isSend ? "보내기" : "승인").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Chat.userBubble)
                }
                .controlSize(.large)
            }
        }
        .disabled(isBusy)
        // 경고색은 제목·아이콘에만. 카드 자체는 중립 면
        .chatCard()
        .onChange(of: draft.revision) {
            rejecting = false
            reason = ""
        }
    }

    /// 승인하면 무슨 일이 일어나는지. 보내는 메일은 저장과 달리 되돌릴 수 없으므로 따로 쓴다
    private var explanation: String {
        if draft.isSend {
            // 받는 사람이 누구인지는 맥이 알린 대로만 말한다 (D89: 다른 사람에게도 보낼 수 있다)
            return "승인하면 잠깐 기다린 뒤 이 내용 그대로 보내요. 기다리는 동안에는 취소할 수 있고, 보낸 뒤에는 되돌릴 수 없어요. "
                + (draft.isExternal ? "받는 사람은 내 주소가 아니에요." : "받는 사람은 내 주소예요.")
        }
        if draft.isAction {
            // 단추 누르기: 저장·보내기의 말을 쓰지 않는다. 무엇이 일어나는지는 그 단추가 정하므로 "이 단추만 누른다"까지만 말한다.
            // 맥은 단추의 이름에 정해 둔 낱말(저장·삭제·제출 등)이 있을 때만 승인을 묻는다 — "바꾸는 단추는 모두 다시 묻는다"고 쓰지 않는다
            let button = draft.action.isEmpty ? "이 단추" : "'\(draft.action)' 단추"
            let again = "저장·삭제·제출처럼 이름으로 알 수 있는 바꾸는 단추는 누르기 전에 다시 여쭤요."
            return draft.approvalHash == nil
                ? "승인하면 \(button)를 눌러요. \(again)"
                : "승인하면 보여 드린 내용 그대로일 때만 \(button)를 눌러요. 달라졌으면 누르지 않아요. \(again)"
        }
        return draft.approvalHash == nil
            ? "승인하면 이 내용 그대로 '\(draft.action)'만 해요. 보내지는 않아요."
            : "승인하면 이 내용과 똑같을 때만 '\(draft.action)'해요. 달라졌으면 저장하지 않아요. 보내지는 않아요."
    }
}

/// 작업에 끼워 넣은 내 말 한 줄 (D152): "덧붙인 말 · “그래프는 막대로 바꿔 줘” · 반영함"
struct AgentSteerLine: View {
    let note: AgentSteerNote
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2.weight(.semibold))
                .accessibilityHidden(true)
            Text(DemoText.english ? (count > 1 ? "\(count) notes · “\(note.text)”" : "Note · “\(note.text)”")
                 : count > 1 ? "덧붙인 말 \(count)개 · “\(note.text)”" : "덧붙인 말 · “\(note.text)”")
                .lineLimit(1)
                .truncationMode(.tail)
            Text(DemoText.t(note.applied ? "반영함" : "반영 전"))
                .fontWeight(.semibold)
                .foregroundStyle(note.applied ? DS.Chat.success : DS.Chat.textSecondary)
                .fixedSize()
        }
        .font(.footnote)
        .foregroundStyle(DS.Chat.textSecondary)
        .padding(.leading, 26)
        .accessibilityElement(children: .combine)
    }
}

