import SwiftData
import SwiftUI

/// 요약 편집: 제목·주제·요약·결정 사항·할 일·미해결 질문을 수정·삭제·추가한다.
/// 사본(`SummaryDraft`)을 고치고 "저장"할 때만 반영한다.
struct SummaryEditorView: View {
    let meeting: Meeting

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SummaryDraft
    @State private var original: SummaryDraft
    @State private var confirmingDiscard = false

    init(meeting: Meeting) {
        self.meeting = meeting
        let draft = SummaryDraft(meeting: meeting)
        _draft = State(initialValue: draft)
        _original = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("회의 제목") {
                    TextField("회의 제목", text: $draft.title)
                }

                Section("요약") {
                    TextField("주제", text: $draft.topic)
                        .font(.headline)
                    TextField("요약 내용", text: $draft.body, axis: .vertical)
                        .lineLimit(3...12)
                }

                lineSection("결정 사항", lines: $draft.decisions, placeholder: "결정 사항", addTitle: "결정 사항 추가")

                Section {
                    ForEach($draft.actionItems) { $item in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("할 일", text: $item.task, axis: .vertical)
                            HStack(spacing: 8) {
                                Label {
                                    TextField("담당자 없음", text: $item.owner)
                                } icon: {
                                    Image(systemName: "person.fill").foregroundStyle(DS.Colors.textSecondary)
                                }
                                Label {
                                    TextField("기한 없음", text: $item.due)
                                } icon: {
                                    Image(systemName: "calendar").foregroundStyle(DS.Colors.textSecondary)
                                }
                            }
                            .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { draft.actionItems.remove(atOffsets: $0) }
                    .onMove { draft.actionItems.move(fromOffsets: $0, toOffset: $1) }

                    Button {
                        withAnimation { draft.actionItems.append(.init()) }
                    } label: {
                        Label("할 일 추가", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("할 일")
                } footer: {
                    Text("담당자와 기한은 비워 두면 \"없음\"으로 표시됩니다. 왼쪽으로 밀어 삭제합니다.")
                }

                lineSection("미해결 질문", lines: $draft.openQuestions, placeholder: "미해결 질문", addTitle: "질문 추가")
            }
            .navigationTitle("요약 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        if draft == original { dismiss() } else { confirmingDiscard = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        draft.apply(to: meeting, in: modelContext)
                        try? modelContext.save()
                        dismiss()
                    }
                    .disabled(draft == original)
                }
            }
            .confirmationDialog("수정한 내용을 버릴까요?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("버리기", role: .destructive) { dismiss() }
                Button("계속 편집", role: .cancel) {}
            }
            .interactiveDismissDisabled(draft != original)
        }
    }

    private func lineSection(
        _ title: String, lines: Binding<[SummaryDraft.Line]>, placeholder: String, addTitle: String
    ) -> some View {
        Section(title) {
            ForEach(lines) { $line in
                TextField(placeholder, text: $line.text, axis: .vertical)
            }
            .onDelete { lines.wrappedValue.remove(atOffsets: $0) }
            .onMove { lines.wrappedValue.move(fromOffsets: $0, toOffset: $1) }

            Button {
                withAnimation { lines.wrappedValue.append(.init()) }
            } label: {
                Label(addTitle, systemImage: "plus.circle.fill")
            }
        }
    }
}

#if DEBUG
#Preview {
    let container = PreviewData.container
    let meeting = try! container.mainContext.fetch(FetchDescriptor<Meeting>()).first!
    SummaryEditorView(meeting: meeting)
        .modelContainer(container)
}
#endif
