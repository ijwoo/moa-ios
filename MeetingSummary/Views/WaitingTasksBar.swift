import SwiftUI

/// 맥에서 내 답을 기다리는 작업 (D113): 입력창 위의 한 줄. 앱을 열 때 맥에 묻고, 지금 대화에 카드로 보이지 않는 것만 띄운다.
/// 맥이 직접 만든 대화(작업실·예약 등)의 승인은 기기에 없는 대화라, 알림을 놓치면 찾을 곳이 없었다.
/// 누르면 그 작업을 그 대화에서 연다 (기기에 없는 대화면 새 대화에 놓는다)
struct WaitingTasksBar: View {
    let tasks: [AgentWaitingTask]
    let isOpening: Bool
    let onOpen: (AgentWaitingTask) -> Void
    let onDismiss: () -> Void

    var body: some View {
        if let first = tasks.first {
            HStack(spacing: 10) {
                // 동그란 주황 바탕의 흰 기호 (D130: 크게 칠한 손 그림이 이모지처럼 보였다)
                MoaStatusIcon(kind: first.isApproval ? .approval : .reply, size: 28)
                Button {
                    onOpen(first)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DS.Chat.textPrimary)
                        Text(first.title)
                            .font(.footnote)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isOpening)
                .accessibilityHint("그 작업의 대화를 열어요")
                if isOpening {
                    ProgressView().controlSize(.small)
                } else {
                    Button("열기") { onOpen(first) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(DS.Chat.userBubble)
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.Chat.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("나중에")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private var headline: String {
        if tasks.count > 1 { return "내 답을 기다리는 작업 \(tasks.count)개" }
        return tasks[0].isApproval ? "승인을 기다리는 작업이 있어요" : "답을 기다리는 작업이 있어요"
    }
}
