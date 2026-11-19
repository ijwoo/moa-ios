import SwiftData
import SwiftUI

/// 회의 결과 화면 (읽기 전용). 편집·미리알림 등록은 4·5단계에서 추가한다.
struct SummaryView: View {
    let meeting: Meeting

    var body: some View {
        List {
            if let summary = meeting.summary {
                Section("요약") {
                    Text(summary.body)
                }

                Section("결정 사항") {
                    ForEach(summary.decisions, id: \.self) { decision in
                        Label(decision, systemImage: "checkmark.seal.fill")
                    }
                }

                Section("할 일") {
                    ForEach(summary.sortedActionItems) { item in
                        ActionItemRow(item: item)
                    }
                }

                Section("미해결 질문") {
                    ForEach(summary.openQuestions, id: \.self) { question in
                        Label(question, systemImage: "questionmark.circle")
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            } else {
                Section {
                    LabeledContent("녹음 길이", value: MeetingText.timestamp(meeting.duration))
                    if meeting.status == .recording {
                        Text("요약은 아직 만들어지지 않았습니다. (요약 기능은 3단계에서 연결됩니다)")
                            .font(.footnote)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
                if !meeting.recognitionLog.isEmpty {
                    Section {
                        DisclosureGroup("인식 구간 기록") {
                            Text(meeting.recognitionLog)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                Section("원본 텍스트") {
                    if meeting.transcript.isEmpty {
                        Text("저장된 텍스트가 없습니다.")
                            .foregroundStyle(DS.Colors.textSecondary)
                    } else {
                        Text(meeting.transcript)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ActionItemRow: View {
    let item: ActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.task)
                .font(.body.weight(.medium))
            HStack(spacing: 8) {
                ChipLabel(text: item.owner ?? "담당자 없음", systemImage: "person.fill")
                ChipLabel(text: item.dueText ?? "기한 없음", systemImage: "calendar")
            }
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview("요약") {
    let container = PreviewData.container
    let meeting = try! container.mainContext.fetch(FetchDescriptor<Meeting>()).first!
    return NavigationStack {
        SummaryView(meeting: meeting)
    }
    .modelContainer(container)
}
#endif
