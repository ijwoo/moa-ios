import SwiftData
import SwiftUI

/// 할 일 하나의 내용·담당자·기한 수정 (할 일 탭에서 길게 누르기)
struct TaskEditSheet: View {
    let item: ActionItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var task: String
    @State private var owner: String
    @State private var due: String

    init(item: ActionItem) {
        self.item = item
        _task = State(initialValue: item.task)
        _owner = State(initialValue: item.owner ?? "")
        _due = State(initialValue: item.dueText ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("할 일") {
                    TextField("할 일", text: $task, axis: .vertical)
                }
                Section {
                    TextField("담당자 없음", text: $owner)
                } header: {
                    Text("담당자")
                }
                Section {
                    TextField("기한 없음", text: $due)
                } header: {
                    Text("기한")
                } footer: {
                    if item.isAddedToReminders {
                        Text("이미 미리알림에 등록된 할 일입니다. 여기서 바꾼 내용은 미리알림에는 반영되지 않습니다.")
                    }
                }
            }
            .navigationTitle("할 일 수정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .disabled(SummaryDraft.clean(task) == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard let task = SummaryDraft.clean(task) else { return }
        item.task = task
        item.owner = SummaryDraft.clean(owner)
        let newDue = SummaryDraft.clean(due)
        if newDue != item.dueText {
            item.dueText = newDue
            item.dueDate = nil
        }
        try? modelContext.save()
        dismiss()
    }
}
