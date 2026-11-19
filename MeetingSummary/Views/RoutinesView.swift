import SwiftUI

// 예약해 둔 일 (D91): 반복 · 일회성 · 일시 중지로 묶은 목록. 켜고 끄고 지운다.
// 새로 만드는 것은 입력 화면 없이 대화로 한다 — "+"는 대화에 한마디를 보내고, 맥이 할 일과 때를 되묻는다.

struct RoutinesView: View {
    let model: RoutinesModel
    let session: AskSession
    /// 이 말을 대화에 보내고 대화로 돌아간다
    let onAsk: (String) -> Void
    /// 실행 결과를 대화로 열었다 (대화로 돌아간다)
    let onOpened: () -> Void

    @State private var deleting: AgentRoutine?
    @State private var opening: String?

    /// 지금은 새로 만들 수 없는 까닭 (만들 수 있으면 nil)
    private var blockedReason: String? {
        if model.loadFailed { return "맥에 연결되지 않아 지금은 바꿀 수 없어요." }
        return session.requestBlocker
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let text = model.notice ?? (model.routines.isEmpty ? nil : blockedReason) {
                    Label(text, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 16)
                }
                ForEach(Array(AgentRoutine.grouped(model.routines).enumerated()), id: \.offset) { index, section in
                    header(section.group.title, isFirst: index == 0)
                    VStack(spacing: 10) {
                        ForEach(section.routines) { routine in
                            RoutineRow(
                                routine: routine, isBusy: model.busy.contains(routine.id), isLocked: model.loadFailed,
                                detail: RoutineDetailView(model: model, session: session, routineID: routine.id, onOpened: onOpened),
                                onToggle: { on in Task { await model.setEnabled(on, id: routine.id) } },
                                onDelete: { deleting = routine }
                            )
                        }
                    }
                }
                let runs = model.runs.filter(\.canOpen)
                if !runs.isEmpty {
                    header("최근 결과", isFirst: model.routines.isEmpty)
                    VStack(spacing: 0) {
                        ForEach(Array(runs.prefix(10).enumerated()), id: \.element.id) { index, run in
                            if index > 0 { ChatHairline().padding(.leading, 14) }
                            RunRow(run: run, isOpening: opening == run.id) { open(run) }
                        }
                    }
                    .chatCard(padding: 0)
                }
            }
            // 목록이 비어도 화면 너비를 다 쓴다 (비면 스크롤 뷰가 좁아져 가운데 안내가 잘린다)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Chat.background)
        .overlay {
            if model.routines.isEmpty, model.runs.filter(\.canOpen).isEmpty {
                if !model.hasLoaded || model.isLoading {
                    ProgressView()
                } else if model.loadFailed {
                    ContentUnavailableView {
                        Label("맥에 연결되지 않았어요", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    } description: {
                        Text("맥이 켜져 있는지 확인한 뒤 다시 시도해 주세요.")
                    } actions: {
                        Button("다시 확인") { Task { await model.load() } }
                    }
                } else {
                    ContentUnavailableView {
                        Label("예약해 둔 일이 없어요", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("오른쪽 위 +를 누르거나, 대화에서 \"매일 아침 8시에 메일 요약해줘\"처럼 말해 보세요.")
                    }
                }
            }
        }
        .navigationTitle("예약")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onAsk(RoutinesModel.newPrompt)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(blockedReason != nil)
                .accessibilityLabel("새 예약 만들기")
                .accessibilityHint("대화로 가서 무엇을 언제 할지 정합니다")
            }
        }
        .confirmationDialog(
            deleting.map { "'\($0.title)' 예약을 지울까요?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("지우기", role: .destructive) {
                if let id = deleting?.id { Task { await model.delete(id: id) } }
                deleting = nil
            }
            Button("취소", role: .cancel) { deleting = nil }
        }
        .refreshable { await model.load() }
        // 들어올 때마다 새로 받는다: 대화로 만들거나 그 사이 돌았을 수 있다
        .task { await model.load() }
    }

    private func header(_ title: String, isFirst: Bool) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(DS.Chat.textSecondary)
            .padding(.horizontal, 4)
            .padding(.top, isFirst ? 0 : 24)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func open(_ run: RoutineRun) {
        guard opening == nil else { return }
        opening = run.id
        Task {
            let result = await session.open(run)
            opening = nil
            if result == .opened { onOpened() } else { model.notice = result.notice }
        }
    }
}

/// 예약 하나: 이름 · 언제 · 건넬 말 · 켜고 끄는 스위치
private struct RoutineRow: View {
    let routine: AgentRoutine
    let isBusy: Bool
    /// 맥에 닿지 않아 바꿀 수 없다
    let isLocked: Bool
    /// 줄을 누르면 가는 상세 화면 (할 말 · 지침 · 주기 · 기록, D93)
    let detail: RoutineDetailView
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink {
                detail
            } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(routine.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DS.Chat.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !routine.whenText.isEmpty {
                    Text(routine.whenText)
                        .font(.subheadline)
                        .foregroundStyle(DS.Chat.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 이름이 곧 건넬 말이면 두 번 적지 않는다
                if !routine.prompt.isEmpty, routine.prompt != routine.title {
                    Text("\u{201C}\(routine.prompt)\u{201D}")
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = routine.detail() {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("할 말, 지침, 기록을 봅니다")

            VStack(alignment: .trailing, spacing: 6) {
                if routine.canToggle {
                    Toggle("켜기", isOn: Binding(get: { routine.enabled }, set: onToggle))
                        .labelsHidden()
                        .tint(DS.Chat.accent)
                        .disabled(isBusy || isLocked)
                        .accessibilityLabel("\(routine.title) 켜기")
                }
                Menu {
                    Button("지우기", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DS.Chat.textSecondary)
                        .frame(width: DS.minTouch, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(isBusy || isLocked)
                .accessibilityLabel("\(routine.title) 더 보기")
            }
        }
        .chatCard()
        .opacity(isBusy ? 0.6 : 1)
    }
}

/// 예약이 한 번 돈 기록 한 줄. 누르면 그 결과를 대화로 연다
struct RunRow: View {
    let run: RoutineRun
    /// 윗줄에 쓸 글 (없으면 예약의 이름)
    var heading: String?
    let isOpening: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading ?? run.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(DS.Chat.textPrimary)
                        .lineLimit(1)
                    Text([heading == nil ? run.ranAt.map { AgentRoutine.dayAndTime($0) } : nil, run.statusText].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isOpening {
                    ProgressView()
                } else if run.canOpen {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.Chat.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 답 없이 끝난 실행(놓침 등)은 열어 볼 것이 없다
        .disabled(!run.canOpen)
        .accessibilityHint(run.canOpen ? "이 결과를 대화로 엽니다" : "")
    }
}
