import SwiftData
import SwiftUI

/// 맥에 맡긴 일 하나 (대화 기록에 저장된 작업 카드에서 만든다)
struct AgentTaskEntry: Identifiable {
    /// 대화 속 그 작업 카드의 번호 (그 자리로 갈 때 쓴다)
    let id: UUID
    let state: AgentTaskState
    let date: Date
    let conversation: Conversation?
    /// 저장된 상태가 "하는 중"인데 지금 화면에서 따라가고 있는 일이 아니다.
    /// 그 뒤로 끝났거나 멈췄을 수 있어 "진행 중"이라고 하지 않는다 (그 대화를 열면 맥에 다시 물어 고친다)
    var isUnconfirmed = false

    /// 저장된 말 가운데 작업만 골라 새것부터 늘어놓는다. 읽을 수 없는 기록은 뺀다.
    /// `live`: 지금 열려 있는 대화의 작업 상태 (저장된 것보다 새것이라 이것을 쓴다)
    static func entries(from records: [ChatRecord], live: [UUID: AgentTaskState] = [:]) -> [AgentTaskEntry] {
        records
            .compactMap { record -> AgentTaskEntry? in
                guard record.roleRaw == "agent", let data = record.agentData,
                      let stored = try? JSONDecoder().decode(AgentTaskState.self, from: data) else { return nil }
                if let state = live[record.id] {
                    return AgentTaskEntry(id: record.id, state: state, date: record.createdAt, conversation: record.conversation)
                }
                return AgentTaskEntry(
                    id: record.id, state: stored, date: record.createdAt, conversation: record.conversation,
                    isUnconfirmed: stored.phase == .running || stored.phase == .sendPending
                )
            }
            .sorted { $0.date > $1.date }
    }

    /// 줄에 보일 상태 글
    var statusLabel: String { isUnconfirmed ? "열어서 확인" : state.statusLabel }
}

/// 에이전트 작업 (D53): 지금까지 맥에 맡긴 일을 한곳에 모아 보여 준다. 사이드바에서 들어온다.
///
/// 새로 받는 것은 없다. 대화마다 저장해 둔 작업 카드를 모은 것이라, 줄을 누르면 그 대화의 그 카드로 간다.
/// 상태는 마지막으로 그 대화를 봤을 때의 것이다 (대화를 열면 맥에 다시 물어 고친다).
/// 그때 "하는 중"이던 일은 지금 어떤지 알 수 없으므로 "열어서 확인"이라고 보여 준다.
struct AgentTasksView: View {
    /// 지금 열려 있는 대화의 작업은 저장된 것보다 화면의 상태가 새것이다
    let session: AskSession
    let onOpen: (AgentTaskEntry) -> Void

    @Query(filter: #Predicate<ChatRecord> { $0.roleRaw == "agent" }, sort: \ChatRecord.createdAt, order: .reverse)
    private var records: [ChatRecord]

    private var entries: [AgentTaskEntry] {
        let live = Dictionary(session.messages.compactMap { message in message.agent.map { (message.id, $0) } }) { first, _ in first }
        return AgentTaskEntry.entries(from: records, live: live)
    }

    /// 다른 대화에 있는 일인데 지금은 그 대화로 옮길 수 없다 (답을 받는 중)
    private func isLocked(_ entry: AgentTaskEntry) -> Bool {
        guard !session.canSwitchConversation, let conversation = entry.conversation else { return false }
        return session.conversation?.id != conversation.id
    }

    var body: some View {
        let entries = entries
        ScrollView {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if entries.contains(where: isLocked) {
                        Label("답을 기다리는 중이에요. 끝나면 다른 대화의 작업을 열 수 있어요.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                    // 맡긴 일이 많아도 보이는 줄만 만든다
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { ChatHairline().padding(.leading, 60) }
                            AgentTaskRow(entry: entry) { onOpen(entry) }
                                .disabled(isLocked(entry))
                                .opacity(isLocked(entry) ? 0.45 : 1)
                        }
                    }
                    .chatCard(padding: 0, bordered: false)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .background(DS.Chat.background)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "아직 맡긴 일이 없어요", systemImage: "desktopcomputer",
                    description: Text("대화에서 맥에 일을 맡기면 여기에 모여요.")
                )
            }
        }
        .navigationTitle("에이전트 작업")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 맡긴 일 한 줄: 상태 표시 · 제목 · 상태와 날짜. 누르면 그 대화의 작업 카드로 간다
private struct AgentTaskRow: View {
    let entry: AgentTaskEntry
    let action: () -> Void

    var body: some View {
        let state = entry.state
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if entry.isUnconfirmed {
                        // 지금도 하는 중인지 모른다: 도는 표시 대신 "다시 확인" 그림
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Chat.textSecondary)
                    } else {
                        AgentPhaseIcon(state: state)
                    }
                }
                .frame(width: 34, height: 34)
                .background((entry.isUnconfirmed ? DS.Chat.textSecondary : state.chatTone).opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Chat.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(entry.statusLabel)
                            .fontWeight(.semibold)
                            .foregroundStyle(entry.isUnconfirmed ? DS.Chat.textSecondary : state.chatTone)
                        Text("· \(SidebarText.dayTime(entry.date))")
                            .foregroundStyle(DS.Chat.textSecondary)
                    }
                    .font(.caption)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.title), \(entry.statusLabel), \(SidebarText.dayTime(entry.date))")
        .accessibilityHint("그 대화의 작업으로 이동합니다")
    }
}
