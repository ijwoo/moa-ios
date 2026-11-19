import SwiftUI

/// 맡길 수 있는 일 (D53): 맥이 지금 할 수 있는 일을 카드로 보여 준다. 사이드바에서 들어온다.
///
/// "부탁하기"를 누르면 카드에 적힌 말이 내 말로 대화에 보내진다 (그래서 보낼 말을 카드에 그대로 적어 둔다).
/// 준비가 덜 된 일은 무엇이 필요한지와, 그 준비를 시작하는 단추를 대신 보여 준다.
struct SkillsView: View {
    let skills: SkillsModel
    let session: AskSession
    /// 이 말을 대화에 보내고 대화로 돌아간다
    let onAsk: (String) -> Void

    /// 지금은 맡길 수 없는 까닭 (맡길 수 있으면 nil)
    private var blockedReason: String? {
        // 맥에 닿지 않으면 보낸 말이 맥이 아니라 Claude에게 간다. 그래서 막는다
        if skills.loadFailed { return "맥에 연결되지 않아 지금은 맡길 수 없어요." }
        return session.requestBlocker
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 카드가 없으면 가운데 안내가 대신 말한다
                if let blockedReason, !skills.skills.isEmpty {
                    Label(blockedReason, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 16)
                }
                ForEach(Array(AgentSkill.grouped(skills.skills).enumerated()), id: \.offset) { index, group in
                    if !group.category.isEmpty {
                        Text(group.category)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DS.Chat.textSecondary)
                            .padding(.horizontal, 4)
                            .padding(.top, index == 0 ? 0 : 24)
                            .padding(.bottom, 8)
                            .accessibilityAddTraits(.isHeader)
                    }
                    VStack(spacing: 10) {
                        ForEach(group.skills) { skill in
                            SkillCard(skill: skill, isBlocked: blockedReason != nil, onAsk: onAsk)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(DS.Chat.background)
        .overlay {
            if skills.skills.isEmpty {
                if !skills.hasLoaded || skills.isLoading {
                    ProgressView()
                } else if skills.loadFailed {
                    ContentUnavailableView {
                        Label("맥에 연결되지 않았어요", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    } description: {
                        Text("맥이 켜져 있는지 확인한 뒤 다시 시도해 주세요.")
                    } actions: {
                        Button("다시 확인") { Task { await skills.load() } }
                    }
                } else {
                    ContentUnavailableView(
                        "지금 맡길 수 있는 일이 없어요", systemImage: "square.grid.2x2",
                        description: Text("맥이 할 수 있는 일이 생기면 여기에 보여요.")
                    )
                }
            }
        }
        .navigationTitle("맡길 수 있는 일")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await skills.load() }
        // 들어올 때마다 새로 받는다: 로그인·메일 연결을 마치고 돌아오면 준비 상태가 바뀌어 있다
        .task { await skills.load() }
    }
}

/// 맡길 수 있는 일 하나: 이름 · 설명 · 보낼 말 · 단추
private struct SkillCard: View {
    let skill: AgentSkill
    /// 지금은 어떤 것도 맡길 수 없다 (맥 연결 안 됨, 대화에서 답을 기다리는 중)
    let isBlocked: Bool
    let onAsk: (String) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(skill.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(DS.Chat.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if skill.isBeta {
                        // 일부만 확인된 일
                        Text("시험 중")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(DS.Chat.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(DS.Chat.elevated, in: Capsule())
                    }
                }
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.subheadline)
                        .lineSpacing(2)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let blocker = skill.blocker {
                actionRow {
                    Label(blocker.message, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(DS.Chat.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } button: {
                    if !blocker.prompt.isEmpty {
                        Button(blocker.buttonTitle) { onAsk(blocker.prompt) }
                            .buttonStyle(SkillButtonStyle(isProminent: false))
                            .disabled(isBlocked)
                            .accessibilityHint("대화에 \u{201C}\(blocker.prompt)\u{201D}라고 보냅니다")
                    }
                }
            } else {
                actionRow {
                    // 누르면 내 말로 보내지는 글을 그대로 보여 준다
                    Text("\u{201C}\(skill.prompt)\u{201D}")
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("보내는 말: \(skill.prompt)")
                } button: {
                    Button("부탁하기") { onAsk(skill.prompt) }
                        .buttonStyle(SkillButtonStyle(isProminent: true))
                        .disabled(isBlocked)
                        .accessibilityHint("대화에 이 말을 보냅니다")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCard(padding: 16, bordered: false)
    }

    /// 아랫줄: 왼쪽에 글, 오른쪽에 단추. 글자를 아주 크게 쓰면 위아래로 쌓는다
    @ViewBuilder
    private func actionRow(@ViewBuilder text: () -> some View, @ViewBuilder button: () -> some View) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                text()
                button()
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                text()
                Spacer(minLength: 0)
                button()
            }
        }
    }
}

/// 카드의 단추: 알약 모양. 맡기는 단추는 채우고, 준비를 시작하는 단추는 옅게 깐다
private struct SkillButtonStyle: ButtonStyle {
    let isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isProminent ? DS.Chat.onUserBubble : DS.Chat.accent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .background(isProminent ? DS.Chat.userBubble : DS.Chat.accent.opacity(0.14), in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            // 보이는 것은 36이어도 누르는 곳은 44
            .frame(minHeight: DS.minTouch)
            .contentShape(Rectangle())
    }
}
