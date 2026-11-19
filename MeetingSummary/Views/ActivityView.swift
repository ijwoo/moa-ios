import SwiftData
import SwiftUI

/// 활동 탭 (D120): 맨 위 "기다리는 일"(승인·질문 대기), 그 아래 끝난 작업 · 예약 실행 · 녹음한 회의를 날짜 묶음으로.
/// 맥의 활동은 `/v1/activity`에서, 회의는 이 기기에서. 줄을 누르면 그 대화(질문 탭)나 회의로 간다.
/// 회의 목록 전체는 오른쪽 위 단추로 연다 (회의 탭이 없어졌다)
struct ActivityView: View {
    let session: AskSession
    let model: ActivityModel
    /// 대화 탭으로 가서 그 작업의 카드로 간다 (작업 번호가 없으면 대화만)
    let onOpenChat: (String?) -> Void

    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Environment(\.scenePhase) private var scenePhase
    @State private var opening: String?
    @State private var notice: String?
    @State private var showingMeetings = false

    /// 기다리는 일: 맥이 알려 준 승인·질문 대기 (보내기 대기는 사람이 할 일이 아니라 넣지 않는다)
    private var waiting: [AgentWaitingTask] { session.waitingTasks }

    private var timeline: [ActivityItem] {
        let mac = model.entries.filter { !$0.isWaiting }.map(ActivityItem.mac)
        return mac + meetings.map(ActivityItem.meeting)
    }

    var body: some View {
        NavigationStack {
            List {
                if let notice {
                    Section {
                        Label(notice, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
                if !waiting.isEmpty {
                    Section("기다리는 일 \(waiting.count)") {
                        ForEach(waiting) { task in
                            Button { openWaiting(task) } label: {
                                ActivityRow(
                                    icon: nil, title: task.title, line: task.isApproval ? "승인 필요" : "답 필요",
                                    lineIsWarning: true, time: nil, isOpening: opening == task.id, status: task.isApproval ? .approval : .reply
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                ForEach(ActivityItem.days(timeline), id: \.title) { day in
                    Section(day.title) {
                        ForEach(day.items) { item in
                            row(item)
                        }
                    }
                }
            }
            .settingsListStyle()
            .overlay {
                if waiting.isEmpty, timeline.isEmpty, model.hasLoaded {
                    ContentUnavailableView(
                        "아직 활동이 없어요", systemImage: "clock",
                        description: Text("회의를 녹음하거나 맥에 일을 맡기면 여기에 쌓여요.")
                    )
                }
            }
            .navigationTitle("활동")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Meeting.self) { meeting in
                MeetingDetailView(meeting: meeting)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingMeetings = true
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .accessibilityLabel("회의 목록")
                    // 위 막대의 단추는 글자색으로 (D144: 탭 막대의 강조색이 여기까지 내려온다)
                    .tint(DS.Colors.textPrimary)
                }
            }
            .sheet(isPresented: $showingMeetings) {
                MeetingsView()
                    .presentationDragIndicator(.visible)
            }
            .refreshable { await refresh() }
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
        }
    }

    private func refresh() async {
        async let waiting: Void = session.checkWaitingTasks()
        async let mac: Void = model.load()
        _ = await (waiting, mac)
    }

    @ViewBuilder
    private func row(_ item: ActivityItem) -> some View {
        switch item {
        case .meeting(let meeting):
            NavigationLink(value: meeting) {
                ActivityRow(
                    icon: "mic", title: meeting.title, line: Self.meetingLine(meeting), lineIsWarning: false,
                    time: Self.time(meeting.date), isOpening: false
                )
            }
        case .mac(let entry):
            Button { open(entry) } label: {
                ActivityRow(
                    icon: nil, title: entry.title, line: entry.line ?? (entry.kind == .routine ? "예약" : nil), lineIsWarning: AssistantNewsView.needsMe(entry),
                    time: Self.time(entry.at), isOpening: opening == entry.id, status: AssistantNewsView.kind(entry)
                )
            }
            .buttonStyle(.plain)
        }
    }

    static func meetingLine(_ meeting: Meeting) -> String {
        let minutes = max(1, Int((meeting.duration / 60).rounded()))
        let tasks = meeting.summary?.actionItems.count ?? 0
        return tasks > 0 ? "회의 \(minutes)분 · 할 일 \(tasks)" : "회의 \(minutes)분"
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Locale(identifier: "ko_KR")).hour().minute())
    }

    private func openWaiting(_ task: AgentWaitingTask) {
        guard opening == nil else { return }
        opening = task.id
        Task {
            let result = await session.openWaiting(task)
            opening = nil
            finish(result, taskID: task.id)
        }
    }

    private func open(_ entry: ActivityEntry) {
        guard opening == nil else { return }
        opening = entry.id
        Task {
            let result: AskSession.RoutineOpening
            switch entry.kind {
            case .task:
                result = await session.openTaskInItsConversation(id: entry.id, conversationID: entry.conversationID)
            case .routine:
                if let task = entry.taskID {
                    result = await session.openTaskInItsConversation(id: task, conversationID: entry.conversationID)
                } else {
                    result = await session.openRoutineRun(id: entry.id)
                }
            case .routineDefinition:
                result = .nothingToShow
            }
            opening = nil
            finish(result, taskID: entry.kind == .task ? entry.id : entry.taskID)
        }
    }

    private func finish(_ result: AskSession.RoutineOpening, taskID: String?) {
        if result == .opened {
            notice = nil
            onOpenChat(taskID)
        } else {
            notice = result == .notFound ? "맥에 이 기록이 남아 있지 않아요." : result.notice
        }
    }
}

/// 활동 한 줄: (그림) 이름 / 한 줄 · 시각
struct ActivityRow: View {
    let icon: String?
    let title: String
    let line: String?
    let lineIsWarning: Bool
    let time: String?
    let isOpening: Bool
    /// 모아의 상태 그림 (D130). 있으면 `icon` 대신 그린다
    var status: MoaStatusIcon.Kind? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let status {
                MoaStatusIcon(kind: status, size: 24)
                    .frame(width: 30, height: 30)
            } else if let icon {
                // 상자 없이 가는 기호로 (D130: 옆 줄의 상태 그림과 같은 결)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
            } else {
                Circle().fill(DS.Chat.warning).frame(width: 8, height: 8).frame(width: 30)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                if let line {
                    Text(line)
                        .font(.footnote.weight(lineIsWarning ? .semibold : .regular))
                        .foregroundStyle(lineIsWarning ? MoaStatusIcon.orange : DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if isOpening {
                ProgressView().controlSize(.small)
            } else if let time {
                Text(time)
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
