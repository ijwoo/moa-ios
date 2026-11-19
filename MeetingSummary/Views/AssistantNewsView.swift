import SwiftUI

/// 개인비서 알림 (D127, 모양은 D128): 대화 화면 위의 "모아"를 누르면 올라온다.
/// 맨 위에 내 답을 기다리는 일(승인·질문)을 카드로 크게, 다른 대화에서 도는 일, 그 아래 맥이 최근에 한 일을 날짜로 묶어.
/// 줄을 누르면 그 일이 있는 대화로 가서 그 카드를 보여 준다.
/// 내 공간의 "지금 가져오기"처럼 대화 밖에서 시킨 일이 어느 대화에 붙었는지 몰라도 여기서 찾아 간다
struct AssistantNewsView: View {
    let session: AskSession
    /// 그 작업의 카드로 간다 (작업 번호)
    let onOpened: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var opening: String?
    @State private var notice: String?
    @State private var loading = true

    private var waiting: [AgentWaitingTask] { session.waitingTasks }

    /// 맥의 최근 기록 (기다리는 것은 위에 따로 있으니 뺀다)
    private var recent: [ActivityEntry] {
        Array(session.activity.entries.filter { !$0.isWaiting }.prefix(Self.recentLimit))
    }

    static let recentLimit = 15

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .padding(.horizontal, 4)
                }
                if !waiting.isEmpty {
                    section("나를 기다리는 일") {
                        VStack(spacing: 8) {
                            ForEach(waiting) { task in
                                Button { open(waiting: task) } label: { waitingCard(task) }
                                    .buttonStyle(NewsPressStyle())
                            }
                        }
                    }
                }
                if session.workingElsewhere > 0 {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("다른 대화에서 작업 \(session.workingElsewhere)개가 맥에서 돌고 있어요")
                            .font(.subheadline)
                            .foregroundStyle(DS.Chat.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(DS.Chat.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                ForEach(ActivityItem.days(recent.map(ActivityItem.mac)), id: \.title) { day in
                    section(day.title) {
                        VStack(spacing: 0) {
                            ForEach(Array(day.items.enumerated()), id: \.element.id) { index, item in
                                if case .mac(let entry) = item {
                                    if index > 0 { ChatHairline().padding(.leading, 60) }
                                    Button { open(entry) } label: { recentRow(entry) }
                                        .buttonStyle(NewsPressStyle(radius: 0))
                                        .disabled(entry.kind == .routineDefinition)
                                }
                            }
                        }
                        .background(DS.Chat.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                }
                if loading, waiting.isEmpty, recent.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if waiting.isEmpty, recent.isEmpty, session.workingElsewhere == 0 {
                    empty
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(DS.Chat.background.ignoresSafeArea())
        .task {
            async let waiting: Void = session.checkWaitingTasks()
            async let news: Void = session.refreshConversationNews()
            _ = await (waiting, news)
            loading = false
        }
    }

    // MARK: - 조각

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("알림")
                    .font(.title2.bold())
                    .foregroundStyle(DS.Chat.textPrimary)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.Chat.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(DS.Chat.card, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("닫기")
        }
        .padding(.horizontal, 4)
    }

    /// 머리 아래 한 줄
    private var summary: String {
        if loading, waiting.isEmpty, recent.isEmpty { return "맥에서 받아 오는 중" }
        if !waiting.isEmpty { return "확인할 일이 \(waiting.count)개 있어요" }
        return recent.isEmpty ? "새 소식이 없어요" : "맥이 최근에 한 일이에요"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.Chat.textSecondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func waitingCard(_ task: AgentWaitingTask) -> some View {
        HStack(spacing: 14) {
            MoaStatusIcon(kind: task.isApproval ? .approval : .reply, size: 30)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DS.Chat.textPrimary)
                    .lineLimit(1)
                Text(task.isApproval ? "승인을 기다려요" : "답을 기다려요")
                    .font(.footnote)
                    .foregroundStyle(MoaStatusIcon.orange)
            }
            Spacer(minLength: 8)
            if opening == task.id {
                ProgressView().controlSize(.small)
            } else {
                Text("열기")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(DS.Chat.userBubble, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(DS.Chat.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func recentRow(_ entry: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            MoaStatusIcon(kind: Self.kind(entry), size: 26)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Chat.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if opening == entry.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(ActivityView.time(entry.at))
                            .font(.caption)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .monospacedDigit()
                    }
                }
                if let line = Self.line(entry) {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(Self.needsMe(entry) ? MoaStatusIcon.orange : DS.Chat.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DS.Chat.textSecondary)
            Text("새 알림이 없어요")
                .font(.headline)
                .foregroundStyle(DS.Chat.textPrimary)
            Text(session.activity.isOffered ? "맥이 한 일과 내 답을 기다리는 일이 여기에 모여요." : "맥과 연결되면 맥이 한 일이 여기에 모여요.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(DS.Chat.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - 줄의 말과 그림

    static func needsMe(_ entry: ActivityEntry) -> Bool {
        ["needs_login", "needs_reply"].contains(entry.status ?? "")
    }

    /// 줄의 상태 그림 (D130)
    static func kind(_ entry: ActivityEntry) -> MoaStatusIcon.Kind {
        if entry.status == "needs_login" { return .login }
        if entry.status == "needs_reply" { return .reply }
        if entry.isFailed { return .failed }
        return entry.kind == .routine ? .scheduled : .done
    }

    /// 아랫줄: 맥이 쓴 한 줄이 있으면 그것, 없으면 상태
    static func line(_ entry: ActivityEntry) -> String? {
        if needsMe(entry) { return entry.status == "needs_login" ? "로그인 필요" : "답 필요" }
        if let line = entry.line { return line }
        if entry.isFailed { return "끝내지 못했어요" }
        return entry.kind == .routine ? "예약 실행" : "끝났어요"
    }

    // MARK: - 열기

    private func open(waiting task: AgentWaitingTask) {
        guard opening == nil else { return }
        opening = task.id
        Task {
            let result = await session.openWaiting(task)
            finish(result, taskID: task.id)
        }
    }

    private func open(_ entry: ActivityEntry) {
        guard opening == nil else { return }
        opening = entry.id
        Task {
            let result: AskSession.RoutineOpening
            if entry.kind == .routine, entry.taskID == nil {
                result = await session.openRoutineRun(id: entry.id)
            } else {
                result = await session.openTaskInItsConversation(id: entry.taskID ?? entry.id, conversationID: entry.conversationID)
            }
            finish(result, taskID: entry.kind == .task ? entry.id : entry.taskID)
        }
    }

    private func finish(_ result: AskSession.RoutineOpening, taskID: String?) {
        opening = nil
        if result == .opened {
            Haptic.select()
            onOpened(taskID)
            dismiss()
        } else {
            withAnimation { notice = result == .notFound ? "맥에 이 기록이 남아 있지 않아요." : result.notice }
        }
    }
}

/// 누르는 동안 살짝 눌린 모양
private struct NewsPressStyle: ButtonStyle {
    var radius: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DS.Chat.textPrimary.opacity(configuration.isPressed ? 0.06 : 0))
            )
            .scaleEffect(configuration.isPressed && radius > 0 ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
