import SwiftUI

/// 통화 화면 (D134): 가운데 둥근 빛이 지금 상태(듣기·생각·말하기)를 보여 준다.
/// 아래에는 음소거·끊기·대화 보기. 승인할 일이 생기면 카드로 가는 줄이 위에 뜬다 (승인은 목소리로 받지 않는다)
struct VoiceCallView: View {
    let call: VoiceCall
    /// 화면을 접고 대화를 본다 (통화는 이어진다)
    let onMinimize: () -> Void
    let onEnd: () -> Void
    @State private var choosingVoice = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    // 목소리 고르기 (D135)
                    Button {
                        choosingVoice = true
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DS.Chat.textPrimary)
                            .frame(width: 40, height: 40)
                            .background(DS.Chat.elevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                    .accessibilityLabel("목소리 고르기")
                }
            if call.needsScreen { approvalRow.padding(.top, 14) }
            Spacer(minLength: 20)
            VoiceOrb(phase: call.phase, level: call.level, muted: call.isMuted)
                .frame(width: 210, height: 210)
                .contentShape(Circle())
                .onTapGesture { call.tapCenter() }
                .accessibilityLabel(statusText)
                .accessibilityHint(call.phase == .speaking ? "누르면 말을 멈추고 듣습니다" : "누르면 지금까지 한 말을 보냅니다")
                .accessibilityAddTraits(.isButton)
            Text(statusText)
                .font(.headline)
                .foregroundStyle(DS.Chat.textSecondary)
                .contentTransition(.opacity)
                .padding(.top, 26)
            transcript
                .padding(.top, 18)
            Spacer(minLength: 20)
            controls
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Chat.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: call.phase)
        .animation(.easeInOut(duration: 0.25), value: call.needsScreen)
        .sheet(isPresented: $choosingVoice) {
            VoiceChoiceView(macVoice: call.macVoice)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: choosingVoice) { _, open in call.isChoosingVoice = open }
        #if DEBUG
        .task {
            // 화면 확인용: -demoVoices — 목소리 고르기를 바로 연다
            if DemoData.arguments.contains("-demoVoices") { choosingVoice = true }
        }
        #endif
    }

    // MARK: - 조각

    private var header: some View {
        VStack(spacing: 4) {
            Text("모아")
                .font(.title3.weight(.semibold))
                .foregroundStyle(DS.Chat.textPrimary)
            TimelineView(.periodic(from: call.startedAt, by: 1)) { context in
                Text(Self.clock(context.date.timeIntervalSince(call.startedAt)))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(DS.Chat.textSecondary)
            }
        }
        .padding(.top, 16)
    }

    private var approvalRow: some View {
        Button(action: onMinimize) {
            HStack(spacing: 12) {
                MoaStatusIcon(kind: .approval, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("승인할 일이 있어요")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Chat.textPrimary)
                    Text("카드를 눌러야 진행돼요")
                        .font(.footnote)
                        .foregroundStyle(MoaStatusIcon.orange)
                }
                Spacer(minLength: 8)
                Text("카드 보기")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(DS.Chat.userBubble, in: Capsule())
            }
            .padding(14)
            .background(DS.Chat.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 내가 한 말과 모아의 말: 듣는 동안은 지금 하는 말, 그 밖에는 방금 주고받은 말
    private var transcript: some View {
        VStack(spacing: 12) {
            let mine = call.phase == .listening ? call.heard : call.lastSaid
            if !mine.isEmpty {
                Text(mine)
                    .font(.body.weight(.medium))
                    .foregroundStyle(DS.Chat.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            if !call.lastReply.isEmpty, call.phase != .listening || call.heard.isEmpty {
                Text(call.lastReply)
                    .font(.callout)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .top)
    }

    private var controls: some View {
        HStack(spacing: 34) {
            CallButton(
                symbol: call.isMuted ? "mic.slash.fill" : "mic.fill", label: call.isMuted ? "음소거 끄기" : "음소거",
                active: call.isMuted, action: call.toggleMute
            )
            CallButton(symbol: "phone.down.fill", label: "끊기", tint: DS.Chat.danger, action: onEnd)
            CallButton(symbol: "text.bubble.fill", label: "대화 보기", action: onMinimize)
        }
    }

    private var statusText: String {
        switch call.phase {
        case .starting: "연결하는 중"
        case .listening: call.isMuted ? "음소거 중" : (call.heard.isEmpty ? "듣고 있어요" : "듣는 중…")
        case .thinking: "생각하고 있어요"
        case .speaking: "말하는 중"
        case .ended: "통화를 마쳤어요"
        case .failed(let text): text
        }
    }

    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 둥근 빛: 듣는 동안은 내 목소리 크기만큼 부풀고, 생각하는 동안은 천천히 숨 쉬고, 말하는 동안은 물결이 퍼진다
private struct VoiceOrb: View {
    let phase: VoiceCall.Phase
    let level: Float
    let muted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = reduceMotion ? 0 : (sin(t * 2.2) + 1) / 2
            let scale: CGFloat = switch phase {
            case .listening: muted ? 0.82 : 0.86 + CGFloat(level) * 0.22
            case .thinking: 0.84 + breathe * 0.06
            case .speaking: 0.92 + breathe * 0.04
            default: 0.82
            }
            ZStack {
                if phase == .speaking, !reduceMotion {
                    ForEach(0..<3, id: \.self) { i in
                        let p = (t * 0.6 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(MoaStatusIcon.mint.opacity(0.35 * (1 - p)), lineWidth: 2)
                            .scaleEffect(0.9 + p * 0.25)
                    }
                }
                Circle()
                    .fill(
                        RadialGradient(
                            colors: muted ? [Color.gray.opacity(0.5), Color.gray.opacity(0.25)]
                                : [MoaStatusIcon.mint.opacity(0.95), DS.Chat.userBubble.opacity(0.85)],
                            center: .init(x: 0.35, y: 0.3), startRadius: 4, endRadius: 140
                        )
                    )
                    .scaleEffect(scale)
                    .shadow(color: MoaStatusIcon.mint.opacity(muted ? 0 : 0.35), radius: 30)
                if phase == .thinking {
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(.white.opacity(0.9))
                                .frame(width: 9, height: 9)
                                .opacity(reduceMotion ? 1 : 0.35 + 0.65 * (sin(t * 5 - Double(i) * 0.8) + 1) / 2)
                        }
                    }
                } else if muted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
    }
}

/// 통화 화면 아래의 둥근 단추
private struct CallButton: View {
    let symbol: String
    let label: String
    var tint: Color? = nil
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint != nil ? .white : (active ? DS.Chat.background : DS.Chat.textPrimary))
                    .frame(width: 66, height: 66)
                    .background(tint ?? (active ? DS.Chat.textPrimary : DS.Chat.elevated), in: Circle())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(DS.Chat.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 통화 화면을 접었을 때 대화 위에 뜨는 알약: 누르면 통화 화면으로 돌아간다
struct VoiceCallPill: View {
    let call: VoiceCall
    let onOpen: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(MoaStatusIcon.mint)
                        .frame(width: 8, height: 8)
                    Text("모아와 통화 중")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Chat.textPrimary)
                    TimelineView(.periodic(from: call.startedAt, by: 1)) { context in
                        Text(VoiceCallView.clock(context.date.timeIntervalSince(call.startedAt)))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(DS.Chat.textSecondary)
                    }
                    Spacer(minLength: 4)
                    Text("돌아가기")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.Chat.userBubble)
                }
            }
            .buttonStyle(.plain)
            Button(action: onEnd) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(DS.Chat.danger, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("통화 끊기")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 42)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
    }
}

/// 통화 목소리 (D140): 모아 목소리 하나만 보인다. 누르면 그 목소리로 한 마디 들려준다
struct VoiceChoiceView: View {
    /// 모아 목소리를 만들어 주는 맥 (D136). 없으면 아이폰 목소리로 대신 읽는다고 알린다
    var macVoice: (any AgentProviding)?
    @State private var speaker = VoiceSpeaker()
    @State private var macPlayer = MacVoicePlayer()
    @State private var preparing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Haptic.select()
                        if let macVoice { preview(with: macVoice) } else { Task { await speaker.speak(VoiceChoice.sample) } }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("모아")
                                    .foregroundStyle(DS.Chat.textPrimary)
                                Text(macVoice == nil ? "맥이 꺼져 있어 지금은 아이폰 목소리로 읽어요" : "누르면 한 마디 들려줘요")
                                    .font(.footnote)
                                    .foregroundStyle(DS.Chat.textSecondary)
                            }
                            Spacer()
                            if preparing { ProgressView().controlSize(.small) }
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(DS.Chat.userBubble)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isSelected)
                } footer: {
                    Text("모아 목소리는 맥이 만들어요. 맥이 늦거나 꺼져 있으면 아이폰 목소리로 대신 읽어요.")
                }
            }
            .navigationTitle("목소리")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .onDisappear {
                speaker.stop()
                macPlayer.stop()
            }
        }
    }

    /// 맥이 내 목소리로 한 마디 들려준다 (못 받으면 조용히 넘어간다)
    private func preview(with source: any AgentProviding) {
        speaker.stop()
        macPlayer.stop()
        preparing = true
        Task {
            defer { preparing = false }
            guard let id = try? await source.voiceCreate(text: VoiceChoice.sample) else { return }
            preparing = false
            _ = await macPlayer.play(id: id, from: source)
        }
    }
}

// MARK: - 대화 속 통화 카드 (D137)

/// 대화에서 통화 카드를 어디에 둘지: 그리는 줄 가운데 그 통화의 첫 말 자리에 하나
struct CallFold {
    /// 카드를 그릴 말 (그 통화에서 처음 보이는 말)
    let hosts: Set<UUID>

    init(rows: [AskSession.Message]) {
        var seen = Set<UUID>()
        var hosts = Set<UUID>()
        for message in rows {
            guard let call = message.callID, seen.insert(call).inserted else { continue }
            hosts.insert(message.id)
        }
        self.hosts = hosts
    }

    func messages(of call: UUID, in all: [AskSession.Message]) -> [AskSession.Message] {
        all.filter { $0.callID == call }
    }

    /// "통화 · 오전 1:36 · 3분" (말 수는 쓰지 않는다: 사용자 요청)
    nonisolated static func line(_ messages: [AskSession.Message], live: Bool) -> String {
        guard let first = messages.first?.date else { return "통화" }
        let start = first.formatted(.dateTime.hour().minute())
        let minutes = Int(((messages.last?.date ?? first).timeIntervalSince(first) / 60).rounded(.up))
        var parts = [live ? "통화 중" : "통화", start]
        if !live { parts.append(minutes <= 1 ? "1분" : "\(minutes)분") }
        return parts.joined(separator: " · ")
    }
}

/// 펼쳐 볼 통화
struct CallTranscript: Identifiable {
    let id: UUID
    let messages: [AskSession.Message]
}

/// 대화 속 통화 카드: 누르면 그 통화의 받아쓰기 전체
struct CallCard: View {
    let messages: [AskSession.Message]
    let isLive: Bool
    let onOpen: () -> Void

    /// 마지막으로 내가 한 말 (무슨 통화였는지 한 줄로)
    private var lastSaid: String? { messages.last { $0.role == .user }?.text }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: isLive ? "phone.connection.fill" : "phone.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(isLive ? DS.Chat.userBubble : MoaStatusIcon.mint, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(CallFold.line(messages, live: isLive))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Chat.textPrimary)
                        .monospacedDigit()
                    if let lastSaid {
                        Text("“\(lastSaid)”")
                            .font(.footnote)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text("받아쓰기")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.Chat.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.Chat.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(DS.Chat.card, in: RoundedRectangle(cornerRadius: DS.Chat.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.Chat.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("누르면 통화의 받아쓰기를 봅니다")
    }
}

/// 통화의 받아쓰기 전체 (이 기기에 있는 그 통화의 말풍선)
struct CallTranscriptView: View {
    let transcript: CallTranscript
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(transcript.messages) { message in
                        let mine = message.role == .user
                        HStack {
                            if mine { Spacer(minLength: 48) }
                            Text(message.text)
                                .font(.body)
                                .foregroundStyle(mine ? DS.Chat.onUserBubble : DS.Chat.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(mine ? DS.Chat.userBubble : DS.Chat.bubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .textSelection(.enabled)
                            if !mine { Spacer(minLength: 48) }
                        }
                    }
                }
                .padding(16)
            }
            .background(DS.Chat.background.ignoresSafeArea())
            .navigationTitle(CallFold.line(transcript.messages, live: false))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}
