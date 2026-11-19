import SwiftData
import SwiftUI
import UIKit

/// 할 일 탭: 모든 회의의 할 일을 모아 보고 처리한다.
///
/// - 위: 진행 상황(할 일이 있을 때만) + 미리알림 바로가기(아직 없는 할 일이 있거나 권한이 꺼졌을 때만)
/// - 진행 중 / 완료 를 세그먼트로 나눈다. 진행 중은 출처 회의별, 완료는 최근 완료순.
/// - 오른쪽으로 밀기: 완료 / 되돌리기 (미리알림에 등록된 할 일은 미리알림도 함께)
/// - 왼쪽으로 밀기: 미리알림에 추가, 길게 누르기: 수정 메뉴. VoiceOver에서는 같은 동작을 사용자 지정 동작으로 제공.
/// - 미리알림 앱에서 완료하거나 지운 것은 화면을 열 때·앱으로 돌아올 때 가져온다.
struct TasksView: View {
    @Query private var items: [ActionItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var filter: Filter = .open
    @State private var exporting: ExportTarget?
    @State private var editing: ActionItem?
    @State private var completedTrigger = 0
    @State private var reminderPermission = PermissionStatus.reminders

    enum Filter: Hashable { case open, completed }

    struct ExportTarget: Identifiable {
        let id = UUID()
        let items: [ActionItem]
        /// 한 회의의 할 일만 열 때 그 제목. 여러 회의를 함께 열면 nil (항목마다 자기 회의 제목을 쓴다).
        let meetingTitle: String?
    }

    var body: some View {
        let overview = TaskOverview(items: items)

        NavigationStack {
            List {
                if overview.hasTasks {
                    Section {
                        ProgressCard(overview: overview)
                        reminderShortcut(overview)
                    }

                    Section {
                        Picker("보기", selection: $filter) {
                            Text("진행 중 \(overview.open)").tag(Filter.open)
                            Text("완료 \(overview.completed)").tag(Filter.completed)
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    switch filter {
                    case .open: openSections
                    case .completed: completedSection
                    }
                }
            }
            .listSectionSpacing(DS.Spacing.item)
            // 내 정보 탭과 같은 바탕색을 쓴다 (기본 시스템 바탕색과 어긋나지 않게)
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .overlay {
                if !overview.hasTasks {
                    ContentUnavailableView(
                        "할 일이 없어요",
                        systemImage: "checklist",
                        description: Text("회의를 녹음하면 요약에서 뽑은 할 일이 여기에 모여요.")
                    )
                }
            }
            .navigationTitle("할 일")
            .navigationSubtitle(overview.hasTasks ? "\(overview.open)개 남음 · \(overview.completed)개 완료" : "")
            .sensoryFeedback(.success, trigger: completedTrigger)
            .sheet(item: $exporting) { target in
                ReminderExportSheet(items: target.items, meetingTitle: target.meetingTitle)
            }
            .sheet(item: $editing) { item in
                TaskEditSheet(item: item)
            }
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
            }
            .onChange(of: exporting == nil) { _, closed in
                if closed { reminderPermission = PermissionStatus.reminders }
            }
        }
    }

    // MARK: - 미리알림 바로가기

    @ViewBuilder
    private func reminderShortcut(_ overview: TaskOverview) -> some View {
        if reminderPermission == .denied {
            HStack(spacing: 12) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(DS.Colors.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("미리알림 접근이 꺼져 있어요")
                    Text("할 일을 미리알림에 넣으려면 허용해 주세요.")
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                Spacer(minLength: 8)
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(minHeight: DS.minTouch)
        } else if !overview.pendingReminderItems.isEmpty {
            Button {
                exporting = ExportTarget(items: overview.pendingReminderItems, meetingTitle: nil)
            } label: {
                CardRow(
                    icon: "bell.badge",
                    iconColor: DS.Colors.reminder,
                    title: "미리알림에 아직 없는 할 일 \(overview.pendingReminderItems.count)개",
                    subtitle: "골라서 한 번에 추가할 수 있어요"
                ) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("미리알림에 추가할 할 일을 고르는 화면을 엽니다")
        }
    }

    // MARK: - 목록

    @ViewBuilder
    private var openSections: some View {
        let groups = openGroups
        if groups.isEmpty {
            Section {
                Label("남은 할 일이 없어요. 모두 끝냈어요!", systemImage: "checkmark.circle")
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(minHeight: DS.minTouch)
            }
        } else {
            ForEach(groups, id: \.meeting.id) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item, meeting: group.meeting, showsMeeting: false)
                    }
                } header: {
                    meetingHeader(group.meeting)
                }
            }
        }
    }

    @ViewBuilder
    private var completedSection: some View {
        let done = completedItems
        Section {
            if done.isEmpty {
                Text("아직 완료한 할 일이 없어요.")
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(minHeight: DS.minTouch)
            } else {
                ForEach(done) { item in
                    row(item, meeting: item.summary?.meeting, showsMeeting: true)
                }
            }
        } header: {
            if !done.isEmpty {
                Text("최근 완료순")
                    .textCase(nil)
            }
        }
    }

    private func meetingHeader(_ meeting: Meeting) -> some View {
        // 기본 제목("회의 11월 10일 오후 4:00")에는 이미 날짜가 있으므로, 제목에 날짜가 없을 때만 덧붙인다
        let monthDay = meeting.date.formatted(.dateTime.month().day())
        let showsDate = !meeting.title.contains(monthDay)
        return HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .accessibilityHidden(true)
            Text(meeting.title)
                .lineLimit(1)
            if showsDate {
                Text("· \(meeting.date.formatted(.dateTime.month().day().weekday()))")
                    .foregroundStyle(DS.Colors.textSecondary)
                    .layoutPriority(1)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(DS.Colors.textSecondary)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("출처 회의: \(meeting.title)")
    }

    private func row(_ item: ActionItem, meeting: Meeting?, showsMeeting: Bool) -> some View {
        TaskRow(item: item, meetingTitle: showsMeeting ? meeting?.title : nil) { toggle(item) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    toggle(item)
                } label: {
                    Label(item.isCompleted ? "되돌리기" : "완료", systemImage: item.isCompleted ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(item.isCompleted ? .gray : DS.Colors.success)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !item.isAddedToReminders {
                    Button {
                        exporting = ExportTarget(items: [item], meetingTitle: meeting?.title)
                    } label: {
                        Label("미리알림", systemImage: "bell.badge")
                    }
                    .tint(DS.Colors.reminder)
                }
            }
            .contextMenu {
                Button { editing = item } label: { Label("내용·담당자·기한 수정", systemImage: "pencil") }
                Button { toggle(item) } label: {
                    Label(item.isCompleted ? "완료 취소" : "완료", systemImage: "checkmark.circle")
                }
                if !item.isAddedToReminders {
                    Button {
                        exporting = ExportTarget(items: [item], meetingTitle: meeting?.title)
                    } label: {
                        Label("미리알림에 추가", systemImage: "bell.badge")
                    }
                }
            }
            // VoiceOver: 밀기·길게 누르기와 같은 동작
            .accessibilityAction(named: item.isCompleted ? "완료 취소" : "완료") { toggle(item) }
            .accessibilityAction(named: "수정") { editing = item }
            .accessibilityAction(named: "미리알림에 추가") {
                guard !item.isAddedToReminders else { return }
                exporting = ExportTarget(items: [item], meetingTitle: meeting?.title)
            }
    }

    // MARK: - 동작

    private func toggle(_ item: ActionItem) {
        withAnimation {
            ReminderService.shared.setCompleted(item, !item.isCompleted)
        }
        if item.isCompleted { completedTrigger += 1 }
        try? modelContext.save()
    }

    private func refresh() {
        reminderPermission = PermissionStatus.reminders
        if ReminderService.shared.sync(items) > 0 {
            try? modelContext.save()
        }
    }

    // MARK: - 묶기

    /// 미완료 할 일: 회의 최신순, 회의 안에서는 원래 순서대로
    private var openGroups: [(meeting: Meeting, items: [ActionItem])] {
        let open = items.filter { !$0.isCompleted && $0.summary?.meeting != nil }
        let byMeeting = Dictionary(grouping: open) { $0.summary!.meeting!.id }
        return byMeeting.values
            .compactMap { list -> (Meeting, [ActionItem])? in
                guard let meeting = list.first?.summary?.meeting else { return nil }
                return (meeting, list.sorted { $0.order < $1.order })
            }
            .sorted { $0.0.date > $1.0.date }
            .map { (meeting: $0.0, items: $0.1) }
    }

    private var completedItems: [ActionItem] {
        items
            .filter { $0.isCompleted && $0.summary?.meeting != nil }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
}

// MARK: - 진행 상황 카드

private struct ProgressCard: View {
    let overview: TaskOverview

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.item) {
            HStack(alignment: .firstTextBaseline) {
                Text("진행 상황")
                    .font(.headline)
                Spacer()
                Text(overview.progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .monospacedDigit()
            }
            ProgressView(value: overview.progress)
                .tint(DS.Colors.accent)

            // 글자가 커지면 세로로 쌓는다 (Dynamic Type)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { stats }
                VStack(alignment: .leading, spacing: 6) { stats }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stats: some View {
        Stat(label: "남은 할 일", value: overview.open)
        Stat(label: "완료", value: overview.completed)
        Stat(label: "미리알림", value: overview.linkedToReminders)
        if overview.overdue > 0 {
            Stat(label: "기한 지남", value: overview.overdue, color: DS.Colors.danger)
        }
    }

    private struct Stat: View {
        let label: String
        let value: Int
        var color: Color = .primary

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
    }
}

// MARK: - 할 일 행 (요약 카드에서도 사용)

struct TaskRow: View {
    let item: ActionItem
    /// 완료 목록처럼 회의별 묶음이 아닐 때 출처 회의를 함께 보여 준다
    var meetingTitle: String?
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isCompleted ? DS.Colors.success : .secondary)
                    .frame(width: DS.minTouch - 12, height: DS.minTouch - 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isCompleted ? "완료 취소" : "완료로 표시")

            VStack(alignment: .leading, spacing: 5) {
                Text(item.task)
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                metaLine
                    .font(.caption)
            }
            // 구분선을 할 일 글자 시작점에 맞춘다 (미리알림 앱과 같은 배치)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 2)
    }

    /// 담당자 · 기한 · 미리알림 · (출처 회의). 글자가 크면 줄바꿈된다.
    private var metaLine: some View {
        let overdue = TaskOverview.isOverdue(item)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { metaItems(overdue: overdue) }
            VStack(alignment: .leading, spacing: 3) { metaItems(overdue: overdue) }
        }
    }

    @ViewBuilder
    private func metaItems(overdue: Bool) -> some View {
        Meta(icon: "person", text: item.owner ?? "담당자 없음", tone: item.owner == nil ? .empty : .normal)
        Meta(
            icon: overdue ? "exclamationmark.circle" : "calendar",
            text: overdue ? "기한 지남 · \(dueText)" : dueText,
            tone: overdue ? .danger : (item.dueDate == nil && item.dueText == nil ? .empty : .normal)
        )
        if item.isAddedToReminders {
            Meta(icon: "bell.fill", text: "미리알림", tone: .reminder)
        }
        if let meetingTitle {
            Meta(icon: "text.bubble", text: meetingTitle, tone: .normal)
        }
    }

    private var dueText: String {
        if let date = item.dueDate { return date.formatted(.dateTime.month().day().weekday()) }
        return item.dueText ?? "기한 없음"
    }

    private struct Meta: View {
        enum Tone { case normal, empty, danger, reminder }
        let icon: String
        let text: String
        let tone: Tone

        var body: some View {
            HStack(spacing: 3) {
                Image(systemName: icon).imageScale(.small)
                Text(text).lineLimit(1)
            }
            .foregroundStyle(color)
        }

        private var color: AnyShapeStyle {
            switch tone {
            case .normal: AnyShapeStyle(DS.Colors.textSecondary)
            // "담당자 없음"도 읽을 수 있는 대비를 유지한다 (흐린 글자 대신 같은 보조색)
            case .empty: AnyShapeStyle(DS.Colors.textSecondary)
            case .danger: AnyShapeStyle(DS.Colors.danger)
            case .reminder: AnyShapeStyle(DS.Colors.reminder)
            }
        }
    }
}

#if DEBUG
#Preview("할 일") {
    TasksView()
        .modelContainer(PreviewData.container)
}
#endif
