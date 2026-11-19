import SwiftData
import SwiftUI

/// 회의 상세 상단의 요약 영역.
/// 상태에 따라: 요약 중 / 결과(편집·다시 요약) / 실패(다시 요약·직접 작성) / 짧음 / 요약하기
struct SummaryCard: View {
    let meeting: Meeting

    @Environment(\.modelContext) private var modelContext
    @State private var expanded = true
    @State private var isEditing = false
    @State private var confirmingResummarize = false
    @State private var exportingReminders = false

    private var summarizer: MeetingSummarizer { .shared }
    private var isSummarizable: Bool { SummaryRequest(meeting: meeting).isSummarizable }

    var body: some View {
        Group {
            if meeting.status == .processing || summarizer.isRunning(meeting) {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("요약하는 중…").font(.subheadline.weight(.semibold))
                        Text("결정 사항과 할 일을 정리하고 있습니다. 화면을 나가도 계속됩니다.")
                            .font(.caption).foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            } else if let summary = meeting.summary {
                result(summary)
            } else if meeting.status == .failed {
                VStack(alignment: .leading, spacing: 8) {
                    Label("요약하지 못했습니다", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Colors.warning)
                    if let message = meeting.failureMessage {
                        Text(message).font(.caption).foregroundStyle(DS.Colors.textSecondary)
                    }
                    Text("받아쓴 원문은 그대로 저장되어 있습니다.")
                        .font(.caption).foregroundStyle(DS.Colors.textSecondary)
                    HStack {
                        summarizeButton("다시 요약")
                        writeButton
                    }
                }
            } else if !isSummarizable {
                VStack(alignment: .leading, spacing: 8) {
                    Label("받아쓴 내용이 짧아 요약하지 않았습니다.", systemImage: "text.badge.minus")
                        .font(.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
                    writeButton
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("아직 요약하지 않은 회의입니다.")
                        .font(.subheadline)
                    HStack {
                        summarizeButton("요약하기")
                        writeButton
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 할 일·내 정보 카드와 같은 면·모서리·안쪽 여백
        .padding(DS.Spacing.card)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        #if DEBUG
        .onAppear {
            if DemoData.arguments.contains("-demoEdit") { isEditing = true }
            if DemoData.arguments.contains("-demoReminders") { exportingReminders = true }
        }
        #endif
        .sheet(isPresented: $isEditing) {
            SummaryEditorView(meeting: meeting)
        }
        .sheet(isPresented: $exportingReminders) {
            ReminderExportSheet(items: meeting.summary?.sortedActionItems ?? [], meetingTitle: meeting.title)
        }
        .confirmationDialog("다시 요약할까요?", isPresented: $confirmingResummarize, titleVisibility: .visible) {
            Button("다시 요약", role: .destructive) { startSummarizing() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("지금 요약(직접 수정한 내용 포함)이 새 요약으로 바뀝니다.")
        }
    }

    // MARK: - 버튼

    @ViewBuilder
    private func summarizeButton(_ title: String, prominent: Bool = true) -> some View {
        let button = Button {
            // 이미 요약이 있으면 덮어쓰기 전에 확인한다.
            if meeting.summary != nil { confirmingResummarize = true } else { startSummarizing() }
        } label: {
            Label(title, systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
        }
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// 요약이 없을 때 직접 작성
    private var writeButton: some View {
        Button {
            isEditing = true
        } label: {
            Label("직접 작성", systemImage: "square.and.pencil")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
    }

    private func startSummarizing() {
        Task { await summarizer.summarize(meeting, in: modelContext) }
    }

    // MARK: - 결과

    @ViewBuilder
    private func result(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Label(summary.topic.isEmpty ? "요약" : summary.topic, systemImage: "sparkles")
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
                .buttonStyle(.plain)

                Button("편집") { isEditing = true }
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 8)
            }

            if expanded {
                if !summary.body.isEmpty {
                    Text(summary.body)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }

                section("결정 사항", items: summary.decisions, icon: "checkmark.seal.fill", tint: DS.Colors.success)

                if !summary.sortedActionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("할 일 \(summary.actionItems.count)").font(.caption.weight(.semibold)).foregroundStyle(DS.Colors.textSecondary)
                            Spacer()
                            let pending = summary.actionItems.filter { !$0.isAddedToReminders && !$0.isCompleted }.count
                            if pending > 0 {
                                Button {
                                    exportingReminders = true
                                } label: {
                                    Label("미리알림에 추가", systemImage: "bell.badge")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .tint(DS.Colors.reminder)
                            }
                        }
                        ForEach(summary.sortedActionItems) { item in
                            TaskRow(item: item) {
                                withAnimation { ReminderService.shared.setCompleted(item, !item.isCompleted) }
                                try? modelContext.save()
                            }
                            .font(.subheadline)
                        }
                    }
                }

                section("미해결 질문", items: summary.openQuestions, icon: "questionmark.circle", tint: DS.Colors.warning)

                if meeting.status == .failed, let message = meeting.failureMessage {
                    Label("마지막 다시 요약은 실패했습니다: \(message)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.warning)
                }

                if isSummarizable {
                    summarizeButton("다시 요약", prominent: false)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [String], icon: String, tint: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title) \(items.count)").font(.caption.weight(.semibold)).foregroundStyle(DS.Colors.textSecondary)
                ForEach(items, id: \.self) { item in
                    Label {
                        Text(item).font(.subheadline)
                    } icon: {
                        Image(systemName: icon).foregroundStyle(tint)
                    }
                }
            }
        }
    }
}
