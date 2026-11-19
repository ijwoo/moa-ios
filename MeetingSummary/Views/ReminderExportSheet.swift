import SwiftData
import SwiftUI
import UIKit

/// 할 일을 미리알림에 추가하는 시트 (하나 또는 여러 개).
///
/// 기한 문구("금요일")는 날짜로 바꾼 **제안**을 보여 주고, 사용자가 켠 경우에만 날짜를 넣는다.
struct ReminderExportSheet: View {
    let items: [ActionItem]
    /// 한 회의의 할 일만 열 때 그 제목. nil이면 항목마다 자기 회의 제목을 쓴다(여러 회의를 함께 열 때).
    let meetingTitle: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var rows: [Row]
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var addedCount = 0

    struct Row: Identifiable {
        let id: UUID
        var include: Bool
        var useDate: Bool
        var date: Date
        let suggested: Date?
        let alreadyAdded: Bool
    }

    init(items: [ActionItem], meetingTitle: String?) {
        self.items = items
        self.meetingTitle = meetingTitle
        _rows = State(initialValue: items.map { item in
            let suggested = item.dueDate ?? DueDateSuggester.suggest(from: item.dueText)
            let alreadyAdded = item.isAddedToReminders
            return Row(
                id: item.id,
                include: !alreadyAdded && !item.isCompleted,
                useDate: suggested != nil,
                date: suggested ?? Calendar.current.startOfDay(for: .now),
                suggested: suggested,
                alreadyAdded: alreadyAdded
            )
        })
    }

    private var selectedCount: Int { rows.filter(\.include).count }

    /// 아직 미리알림에 없는 할 일 (고를 수 있는 것)
    private var selectable: [Row] { rows.filter { !$0.alreadyAdded } }
    private var alreadyAdded: [Row] { rows.filter(\.alreadyAdded) }

    private func item(for row: Row) -> ActionItem? { items.first { $0.id == row.id } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.section) {
                    if !selectable.isEmpty {
                        CardSection(
                            title: "추가할 할 일",
                            footer: "기한 날짜는 회의에서 나온 표현(예: \"금요일\")을 날짜로 바꾼 제안입니다. 맞는지 확인하고, 아니면 끄거나 바꿔 주세요.",
                            spacing: 0,
                            verticalPadding: DS.Spacing.cardRows
                        ) {
                            ForEach(selectable) { row in
                                if let item = item(for: row), let index = rows.firstIndex(where: { $0.id == row.id }) {
                                    if row.id != selectable.first?.id { RowDivider() }
                                    rowView(item: item, row: $rows[index])
                                }
                            }
                        }
                    }
                    if !alreadyAdded.isEmpty {
                        CardSection(title: "이미 미리알림에 있음", spacing: 0, verticalPadding: DS.Spacing.cardRows) {
                            ForEach(alreadyAdded) { row in
                                if let item = item(for: row) {
                                    if row.id != alreadyAdded.first?.id { RowDivider() }
                                    addedRow(item: item)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, DS.Spacing.item)
                .padding(.bottom, DS.Spacing.section)
            }
            .background(DS.Colors.background)
            .navigationTitle("미리알림에 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
            .safeAreaBar(edge: .bottom) {
                Button {
                    Task { await save() }
                } label: {
                    Group {
                        if isSaving {
                            ProgressView()
                        } else {
                            Label("미리알림에 \(selectedCount)개 추가", systemImage: "checklist")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedCount == 0 || isSaving)
                .padding(.horizontal)
                .padding(.vertical, DS.Spacing.item)
            }
            .sensoryFeedback(.success, trigger: addedCount)
            #if DEBUG
            .task {
                // 개발용: -demoRemindersSave 면 시트를 띄운 뒤 그대로 추가한다 (실제 미리알림에 등록)
                guard DemoData.arguments.contains("-demoRemindersSave") else { return }
                try? await Task.sleep(for: .seconds(2.5))
                await save()
            }
            #endif
            .alert("미리알림에 추가하지 못했습니다", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                if ReminderService.shared.isDenied {
                    Button("설정 열기") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                Button("확인", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// 고를 수 있는 할 일 한 줄: 선택 표시 + 할 일 + 담당자, 골랐을 때만 그 아래에 기한 줄
    private func rowView(item: ActionItem, row: Binding<Row>) -> some View {
        let included = row.wrappedValue.include
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                row.wrappedValue.include.toggle()
            } label: {
                HStack(alignment: .center, spacing: DS.Spacing.item) {
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(included ? DS.Colors.accent : DS.Colors.textSecondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.task)
                            .fontWeight(included ? .medium : .regular)
                            .strikethrough(item.isCompleted)
                            .foregroundStyle(item.isCompleted ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let meta = metaText(for: item) {
                            Text(meta)
                                .font(.footnote)
                                .foregroundStyle(DS.Colors.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .frame(minHeight: DS.minTouch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(included ? .isSelected : [])

            if included {
                dueRows(item: item, row: row)
                    .padding(.leading, 28 + DS.Spacing.item)
                    .padding(.bottom, 4)
            }
        }
    }

    /// 할 일 아래 작은 글: 담당자, 완료 여부
    private func metaText(for item: ActionItem) -> String? {
        let parts = [item.owner, item.isCompleted ? "완료한 할 일" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 기한 줄: 날짜를 넣을지(스위치)와, 넣는다면 어느 날짜인지.
    /// 카드 안에 면을 또 두지 않는다. 할 일 글자 시작점에 맞춘 들여쓰기와 한 단계 작은 글자로 딸린 설정임을 보인다
    private func dueRows(item: ActionItem, row: Binding<Row>) -> some View {
        let isSuggestion = row.wrappedValue.suggested.map { Calendar.current.isDate($0, inSameDayAs: row.wrappedValue.date) } ?? false
        return VStack(spacing: 0) {
            Toggle(isOn: row.useDate) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("기한 날짜 넣기")
                        .font(.subheadline)
                    if let due = item.dueText {
                        Text("회의에서 \"\(due)\"")
                            .font(.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            }
            .tint(DS.Colors.accent)
            .frame(minHeight: DS.minTouch)

            if row.wrappedValue.useDate {
                let label = HStack(spacing: 8) {
                    Text("날짜")
                        .font(.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
                    if isSuggestion { StatusBadge(text: "제안") }
                }
                .fixedSize()
                let picker = DatePicker("날짜", selection: row.date, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                // 글자가 크면 날짜를 아래 줄로 내린다
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        label
                        Spacer(minLength: 8)
                        picker
                    }
                    .frame(minHeight: DS.minTouch)
                    VStack(alignment: .leading, spacing: 6) {
                        label
                        picker
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    /// 이미 등록된 할 일: 고를 수 없어서 흐린 한 줄로만 보인다
    private func addedRow(item: ActionItem) -> some View {
        HStack(spacing: DS.Spacing.item) {
            Image(systemName: "bell.fill")
                .font(.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(item.task)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(minHeight: DS.minTouch)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let exports = rows.compactMap { row -> ReminderService.Export? in
            guard row.include, let item = items.first(where: { $0.id == row.id }) else { return nil }
            return .init(item: item, due: row.useDate ? Calendar.current.startOfDay(for: row.date) : nil)
        }
        // 미리알림 메모에 넣을 회의 제목별로 나눠 기존 서비스를 그대로 호출한다
        let byMeeting = Dictionary(grouping: exports) { export in
            meetingTitle ?? export.item.summary?.meeting?.title ?? "회의"
        }
        do {
            var count = 0
            for (title, group) in byMeeting {
                count += try await ReminderService.shared.add(group, meetingTitle: title)
            }
            try? modelContext.save()
            addedCount += count
            try? await Task.sleep(for: .milliseconds(350))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
