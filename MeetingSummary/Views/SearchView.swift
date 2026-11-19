import SwiftData
import SwiftUI

/// 전역 검색 (D120): 탭 막대 오른쪽의 동그란 검색. 회의(제목·요약·원문)·할 일·대화는 이 기기에서,
/// 맥 기록(끝난 작업·예약 실행·예약)은 맥에서 받아 한 목록에. 회의 탭·할 일 탭이 없어진 뒤로 지난 것은 여기서 찾는다
struct SearchView: View {
    let session: AskSession
    let activity: ActivityModel
    /// 대화 탭으로 가서 그 작업의 카드로 간다
    let onOpenChat: (String?) -> Void
    /// 새 대화에서 이 말을 보낸다 (예약 화면의 "+")
    let onAsk: (String) -> Void

    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query private var actionItems: [ActionItem]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var macResults: [ActivityEntry] = []
    @State private var macSearching = false
    @State private var opening: String?
    @State private var notice: String?

    enum Scope: String, CaseIterable, Identifiable {
        case all = "전체", meetings = "회의", tasks = "할 일", chats = "대화", mac = "맥 기록"
        var id: String { rawValue }
    }

    private var words: String { query.trimmingCharacters(in: .whitespaces) }

    private var foundMeetings: [Meeting] {
        words.isEmpty ? [] : meetings.filter { MeetingText.matches($0, query: words) }
    }

    private var foundTasks: [ActionItem] {
        guard !words.isEmpty else { return [] }
        return actionItems
            .filter { $0.task.localizedCaseInsensitiveContains(words) || ($0.owner?.localizedCaseInsensitiveContains(words) ?? false) }
            .sorted { ($0.summary?.meeting?.date ?? .distantPast) > ($1.summary?.meeting?.date ?? .distantPast) }
    }

    private var foundChats: [Conversation] { SidebarText.matching(conversations, query: words) }

    private func shows(_ section: Scope) -> Bool { scope == .all || scope == section }

    private var isEmptyResult: Bool {
        (shows(.meetings) ? foundMeetings.isEmpty : true) && (shows(.tasks) ? foundTasks.isEmpty : true)
            && (shows(.chats) ? foundChats.isEmpty : true) && (shows(.mac) ? macResults.isEmpty : true)
    }

    var body: some View {
        NavigationStack {
            List {
                if !words.isEmpty {
                    Section {
                        scopes
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if let notice {
                    Section {
                        Label(notice, systemImage: "info.circle").font(.footnote).foregroundStyle(DS.Colors.textSecondary)
                    }
                }
                if shows(.meetings), !foundMeetings.isEmpty {
                    Section("회의 \(foundMeetings.count)") {
                        ForEach(foundMeetings.prefix(scope == .all ? 5 : 50)) { meeting in
                            NavigationLink(value: meeting) {
                                ActivityRow(
                                    icon: "mic", title: meeting.title, line: ActivityView.meetingLine(meeting), lineIsWarning: false,
                                    time: SidebarText.day(meeting.date), isOpening: false
                                )
                            }
                        }
                    }
                }
                if shows(.tasks), !foundTasks.isEmpty {
                    Section("할 일 \(foundTasks.count)") {
                        ForEach(foundTasks.prefix(scope == .all ? 5 : 50)) { item in
                            if let meeting = item.summary?.meeting {
                                NavigationLink(value: meeting) { taskRow(item) }
                            } else {
                                taskRow(item)
                            }
                        }
                    }
                }
                if shows(.chats), !foundChats.isEmpty {
                    Section("대화 \(foundChats.count)") {
                        ForEach(foundChats.prefix(scope == .all ? 5 : 50)) { conversation in
                            Button { open(conversation) } label: {
                                ActivityRow(
                                    icon: "bubble.left", title: conversation.title, line: conversation.previewText, lineIsWarning: false,
                                    time: SidebarText.rowTime(conversation.updatedAt), isOpening: false
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!session.canSwitchConversation && session.conversation?.id != conversation.id)
                        }
                    }
                }
                if shows(.mac), !words.isEmpty, activity.isOffered || !macResults.isEmpty {
                    Section {
                        if macSearching, macResults.isEmpty {
                            HStack { ProgressView().controlSize(.small); Text("맥에서 찾는 중…").font(.footnote).foregroundStyle(DS.Colors.textSecondary) }
                        }
                        ForEach(macResults.prefix(scope == .all ? 5 : 30)) { entry in
                            macRow(entry)
                        }
                    } header: {
                        Text(macResults.isEmpty ? "맥 기록" : "맥 기록 \(macResults.count)")
                    }
                }
            }
            .settingsListStyle()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "회의, 할 일, 대화, 맥 기록")
            .overlay {
                if words.isEmpty {
                    ContentUnavailableView(
                        "무엇을 찾을까요?", systemImage: "magnifyingglass",
                        description: Text("회의 제목·요약·대화 내용, 할 일, 대화, 맥이 한 일을 함께 찾아요.")
                    )
                } else if isEmptyResult, !macSearching {
                    ContentUnavailableView.search(text: words)
                }
            }
            .navigationTitle("검색")
            .navigationDestination(for: Meeting.self) { meeting in
                MeetingDetailView(meeting: meeting)
            }
            .navigationDestination(for: RoutinesScreen.self) { _ in
                RoutinesView(model: session.routines, session: session, onAsk: onAsk) { onOpenChat(nil) }
            }
            // 맥 쪽은 치는 동안 잠깐 기다렸다가 묻는다
            .task(id: words) {
                notice = nil
                guard !words.isEmpty else {
                    macResults = []
                    return
                }
                macSearching = true
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                if !activity.hasLoaded { await activity.load() }
                let found = await activity.search(words)
                guard !Task.isCancelled else { return }
                macResults = found
                macSearching = false
            }
            #if DEBUG
            .onAppear {
                if let demo = DemoData.value(after: "-demoGlobalSearch"), query.isEmpty { query = demo }
            }
            #endif
        }
    }

    /// 예약 목록으로 가는 길 (검색에서 예약을 눌렀을 때)
    struct RoutinesScreen: Hashable {}

    private var scopes: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Scope.allCases) { item in
                    Button {
                        scope = item
                        Haptic.select()
                    } label: {
                        Text(item.rawValue)
                            .font(.subheadline.weight(scope == item ? .bold : .regular))
                            .foregroundStyle(scope == item ? DS.Colors.background : DS.Colors.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(scope == item ? DS.Colors.textPrimary : DS.Colors.secondarySurface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(scope == item ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func taskRow(_ item: ActionItem) -> some View {
        let parts = [item.owner, item.dueText, item.isCompleted ? "완료" : nil].compactMap { $0 }.filter { !$0.isEmpty }
        return ActivityRow(
            icon: item.isCompleted ? "checkmark.circle" : "circle", title: item.task,
            line: parts.isEmpty ? item.summary?.meeting?.title : parts.joined(separator: " · "), lineIsWarning: false,
            time: nil, isOpening: false
        )
    }

    @ViewBuilder
    private func macRow(_ entry: ActivityEntry) -> some View {
        let row = ActivityRow(
            icon: "clock", title: entry.title, line: entry.snippet ?? entry.line ?? Self.kindText(entry), lineIsWarning: false,
            time: SidebarText.day(entry.at), isOpening: opening == entry.id,
            // 예약 자체는 시계, 맥의 기록은 상태 그림 (D130)
            status: entry.kind == .routineDefinition ? .scheduled : AssistantNewsView.kind(entry)
        )
        if entry.kind == .routineDefinition {
            NavigationLink(value: RoutinesScreen()) { row }
        } else {
            Button { open(entry) } label: { row }
                .buttonStyle(.plain)
        }
    }

    private static func kindText(_ entry: ActivityEntry) -> String {
        switch entry.kind {
        case .task: "맥이 한 일"
        case .routine: "예약 실행"
        case .routineDefinition: "예약"
        }
    }

    private func open(_ conversation: Conversation) {
        guard session.conversation?.id == conversation.id || session.canSwitchConversation else { return }
        if session.conversation?.id != conversation.id { session.open(conversation) }
        onOpenChat(nil)
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
            opening = nil
            if result == .opened {
                onOpenChat(entry.kind == .task ? entry.id : entry.taskID)
            } else {
                notice = result == .notFound ? "맥에 이 기록이 남아 있지 않아요." : result.notice
            }
        }
    }
}
