import SwiftUI

/// 작업 상세: 부탁 → 맥이 이해한 내용 → 한 일들 → 지금 상태·결과가 위에서 아래로 한 줄로 이어진다.
///
/// 채팅에는 결정할 일만 보이고, "무엇을 열고 무엇을 눌렀는지"는 여기서 확인한다.
/// 승인·거부와 질문의 답은 채팅에서만 한다 (같은 결정을 두 곳에서 받지 않는다).
/// 카드로 나누지 않는다: 단계는 왼쪽 아이콘과 그 사이를 잇는 선으로 구분한다.
struct AgentTaskDetailView: View {
    let state: AgentTaskState
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// 단계가 많을 때 앞의 것을 펼쳤는지 (D112)
    @State private var showsAllSteps = false
    @State private var detent: PresentationDetent = Self.demo("-demoAgentDetailLarge") ? .large : .medium

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.section) {
                    header
                    flow
                    if state.phase == .running || state.phase == .awaitingInput {
                        Button("작업 멈추기", role: .destructive, action: onCancel)
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .accessibilityHint("진행 중인 단계가 끝나면 작업을 멈춥니다")
                    }
                }
                .padding(.horizontal, DS.Spacing.card)
                .padding(.bottom, 32)
            }
            .defaultScrollAnchor(Self.demo("-demoAgentDetailEnd") ? .bottom : .top)
            .background(DS.Colors.background)
            .navigationTitle("작업 상세")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    /// 개발용 캡처 인자: `-demoAgentDetailLarge`(크게 열기), `-demoAgentDetailEnd`(끝부터 보기)
    private static func demo(_ flag: String) -> Bool {
        #if DEBUG
        DemoData.arguments.contains(flag)
        #else
        false
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.title)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(state.statusLabel) · \(state.currentStatus)")
                .font(.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 이어진 단계

    private var flow: some View {
        let events = state.timeline
        let closing = self.closing(hasEvents: !events.isEmpty)
        // 일하는 중이면 마지막 기록이 "지금 하는 일"이다
        let currentID = state.isWorking && !state.isQueued ? events.last?.id : nil

        return VStack(alignment: .leading, spacing: 0) {
            AgentFlowRow(icon: .symbol("text.bubble"), isLast: false) {
                titled("부탁한 내용") { paragraph(state.request ?? state.task) }
            }
            if let brief = state.brief, !brief.isEmpty {
                // 대화 담당이 작업 담당에게 넘긴 내용. 부탁을 어떻게 이해했는지 확인할 수 있다
                AgentFlowRow(icon: .symbol("desktopcomputer"), isLast: false) {
                    titled("맥이 이해한 내용") {
                        VStack(alignment: .leading, spacing: 8) {
                            briefRow("목적", brief.purpose)
                            briefRow("대상", brief.targets?.joined(separator: ", "))
                            briefRow("할 일", brief.instructions)
                        }
                    }
                }
            }
            // 단계가 많으면(작업실은 수십 개) 마지막 몇 개만 보이고 앞의 것은 접는다 (D112)
            let hidden = showsAllSteps ? 0 : AgentTaskState.foldedStepCount(events.count)
            if hidden > 0 {
                AgentFlowRow(icon: .symbol("ellipsis"), isLast: false) {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { showsAllSteps = true }
                    } label: {
                        Text("앞의 단계 \(hidden)개 보기")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(DS.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(events.dropFirst(hidden)) { event in
                AgentFlowRow(
                    icon: event.id == currentID ? .spinner : .symbol(Self.symbol(for: event)),
                    isLast: closing == nil && event.id == events.last?.id
                ) {
                    eventLine(event, isCurrent: event.id == currentID)
                }
            }
            if let closing {
                AgentFlowRow(icon: closing.icon, isLast: true) { closing.content }
            }
        }
    }

    /// 맨 아래 단계: 지금 사용자가 할 일, 또는 끝난 결과. 일하는 중이면 마지막 기록이 그 자리를 맡는다
    private func closing(hasEvents: Bool) -> (icon: AgentFlowIcon, content: AnyView)? {
        switch state.phase {
        case .running:
            if hasEvents, !state.isQueued { return nil }
            return (.spinner, AnyView(statusLine(state.isQueued ? (state.waitReason ?? "앞 작업이 끝나기를 기다리고 있어요") : "곧 시작해요")))
        case .awaitingApproval:
            return (.tinted("hand.raised.fill", DS.Colors.warning), AnyView(
                state.draft?.isSend == true
                    ? titledStatus("보내기 승인이 필요해요", "채팅에서 보낼 메일을 확인하고 보내거나 거부해 주세요.")
                    : state.draft?.isAction == true
                    // 단추 누르기 승인 (D80): 초안이 아니다. 글만 다르다
                    ? titledStatus("단추 누르기 승인이 필요해요", "채팅에서 누를 단추를 확인하고 승인하거나 거부해 주세요.")
                    : titledStatus("승인이 필요해요", "채팅에서 초안을 확인하고 승인하거나 거부해 주세요.")
            ))
        case .sendPending:
            return (.tinted("paperplane.fill", DS.Colors.accent), AnyView(
                titledStatus("곧 메일을 보내요", "그 전에는 채팅에서 취소할 수 있어요. 보낸 뒤에는 되돌릴 수 없어요.")
            ))
        case .awaitingInput:
            guard let question = state.openQuestion else { return nil }
            return (.tinted("questionmark.circle.fill", DS.Colors.accent), AnyView(
                titledStatus(question.text, "채팅에서 답해 주세요. 답하면 하던 작업을 이어서 해요.")
            ))
        case .needsInput:
            return (.tinted("questionmark.circle.fill", DS.Colors.accent), AnyView(
                titledStatus(state.question ?? "정보가 더 필요해요", "채팅 입력창에 답하면 원래 부탁과 함께 다시 맡겨요.")
            ))
        case .done:
            return (.tinted("checkmark.circle.fill", DS.Colors.success), AnyView(
                titled("결과") { AgentResultView(state: state) }
            ))
        case .canceled:
            return (.tinted("xmark.circle.fill", DS.Colors.textSecondary), AnyView(ending))
        case .failed:
            return (.tinted("exclamationmark.triangle.fill", DS.Colors.warning), AnyView(ending))
        }
    }

    /// 끝내지 못한 작업: 이유 한 문장 + (있으면) 한 일·못 한 일
    private var ending: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine(state.currentStatus)
            if let report = state.report {
                ReportBubble(report: report)
            }
        }
    }

    private func eventLine(_ event: AgentEvent, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.text)
                .font(.subheadline.weight(isCurrent || event.kind == .milestone ? .semibold : .regular))
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let time = event.time {
                Text(time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .frame(minHeight: AgentFlowMetrics.icon, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCurrent ? "지금 하는 일, \(event.text)" : event.text)
    }

    private func statusLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(DS.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: AgentFlowMetrics.icon, alignment: .center)
    }

    private func titledStatus(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            statusLine(title)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func titled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(minHeight: AgentFlowMetrics.icon, alignment: .center)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .lineSpacing(4)
            .foregroundStyle(DS.Colors.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func briefRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                paragraph(value)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// 기록 한 줄의 아이콘. 글 내용으로 고른다 (서버가 정해진 문장으로 쓴다). 모르는 문장은 점
    nonisolated static func symbol(for event: AgentEvent) -> String {
        let text = event.text
        let rules: [(String, String)] = [
            // 단계 기록 (진행 설명이 없는 이전 서버)
            (AgentEvent.approvalRequested, "hand.raised"),
            (AgentEvent.feedbackApplied, "arrow.uturn.backward"),
            ("열기", "globe"),
            ("입력", "square.and.pencil"),
            ("누르기", "hand.tap"),
            ("화면 확인", "doc.text.magnifyingglass"),
            ("내용 읽기", "doc.text.magnifyingglass"),
            ("선택", "checklist"),
            ("스크롤", "arrow.up.arrow.down"),
            ("질문 준비", "questionmark.bubble"),
            ("마무리", "checkmark.circle"),
        ]
        if event.kind != .narration {
            return rules.first { text.hasPrefix($0.0) }?.1 ?? "circle.fill"
        }
        let narration: [(String, String)] = [
            ("시작했어요", "play.circle"),
            ("열었어요", "globe"),
            ("눌렀어요", "hand.tap"),
            ("채웠어요", "square.and.pencil"),
            ("골랐어요", "checklist"),
            ("읽었어요", "doc.text.magnifyingglass"),
            ("넘겨 봤어요", "arrow.up.arrow.down"),
            ("다른 방법", "arrow.triangle.branch"),
            ("승인을 기다리고", "hand.raised"),
            ("승인받았어요", "clock"),
            ("메일을 보냈어요", "paperplane"),
            ("도착", "tray.and.arrow.down"),
            ("메일 계정", "person.crop.circle.badge.checkmark"),
            ("썼어요", "square.and.pencil"),
            ("질문을 보냈어요", "questionmark.bubble"),
            ("답이 없어", "clock"),
            ("답을 받아", "arrow.turn.down.right"),
            ("마쳤어요", "checkmark.circle"),
            ("멈췄어요", "pause.circle"),
            ("취소했어요", "xmark.circle"),
            ("끝내지 못했어요", "exclamationmark.triangle"),
        ]
        return narration.first { text.contains($0.0) }?.1 ?? "circle.fill"
    }
}

enum AgentFlowMetrics {
    /// 아이콘 자리 (한 줄 글의 높이와 맞춘다)
    static let icon: CGFloat = 24
    /// 단계 사이 간격 (이 안에 연결선이 보인다)
    static let gap: CGFloat = 18
}

enum AgentFlowIcon {
    /// 지나간 단계 (흐린 아이콘)
    case symbol(String)
    /// 지금 상태·결과 (색이 있는 아이콘)
    case tinted(String, Color)
    /// 지금 하는 일
    case spinner
}

/// 이어진 단계 한 줄: 왼쪽에 아이콘, 그 아래로 다음 단계까지 이어지는 선.
struct AgentFlowRow<Content: View>: View {
    let icon: AgentFlowIcon
    /// 마지막 단계면 아래로 선을 긋지 않는다
    let isLast: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.item) {
            VStack(spacing: 4) {
                mark
                    .frame(width: AgentFlowMetrics.icon, height: AgentFlowMetrics.icon)
                if !isLast {
                    Capsule()
                        .fill(DS.Colors.border)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.bottom, 4)
                }
            }
            .accessibilityHidden(true)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : AgentFlowMetrics.gap)
        }
        // 선이 글 높이만큼만 늘어나게 한다
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var mark: some View {
        switch icon {
        case .symbol(let name):
            if name == "circle.fill" {
                Circle().fill(DS.Colors.textSecondary).frame(width: 6, height: 6)
            } else {
                Image(systemName: name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        case .tinted(let name, let color):
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
        case .spinner:
            ProgressView().controlSize(.small)
        }
    }
}
