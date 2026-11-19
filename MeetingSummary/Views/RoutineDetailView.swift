import SwiftUI

// 예약 하나의 상세 (D93): 주기 · 할 말 · 지침 · 날짜별 기록.
// 지침만 여기서 고친다 (맥의 `notes`). 이름·할 말·때는 대화로 바꾼다. 기록을 누르면 그 결과가 대화로 열린다.

struct RoutineDetailView: View {
    let model: RoutinesModel
    let session: AskSession
    let routineID: String
    /// 기록을 대화로 열었다 (대화로 돌아간다)
    let onOpened: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var opening: String?
    @State private var loaded = false

    private var routine: AgentRoutine? { model.routine(id: routineID) }
    private var runs: [RoutineRun] { model.history[routineID] ?? [] }

    var body: some View {
        ScrollView {
            if let routine {
                VStack(alignment: .leading, spacing: 0) {
                    if let notice = model.notice {
                        Label(notice, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 16)
                    }
                    header("주기", isFirst: true)
                    schedule(routine)
                    header("할 말")
                    Text(routine.prompt.isEmpty ? routine.title : routine.prompt)
                        .font(.body)
                        .foregroundStyle(DS.Chat.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .chatCard()
                    header("지침")
                    notes(routine)
                    header("기록")
                    history
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Chat.background)
        .navigationTitle(routine?.title ?? "예약")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            if let routine {
                RoutineNotesEditor(title: routine.title, notes: routine.notes) { text in
                    await model.setNotes(text, id: routineID)
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        // 지워진 예약이면(다른 곳에서 지웠거나 한 번짜리가 정리됐다) 목록으로 돌아간다
        .onChange(of: routine == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    private func load() async {
        await model.loadHistory(id: routineID)
        loaded = true
    }

    private func header(_ title: String, isFirst: Bool = false) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(DS.Chat.textSecondary)
            .padding(.horizontal, 4)
            .padding(.top, isFirst ? 0 : 24)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func schedule(_ routine: AgentRoutine) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(routine.whenText.isEmpty ? routine.group.title : routine.whenText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DS.Chat.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = routine.detail() {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if routine.canToggle {
                Toggle("켜기", isOn: Binding(get: { routine.enabled }, set: { on in Task { await model.setEnabled(on, id: routineID) } }))
                    .labelsHidden()
                    .tint(DS.Chat.accent)
                    .disabled(model.busy.contains(routineID) || model.loadFailed)
                    .accessibilityLabel("\(routine.title) 켜기")
            }
        }
        .chatCard()
    }

    private func notes(_ routine: AgentRoutine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if routine.notes.isEmpty {
                Text("지침이 없어요. 무엇을 어떻게 볼지 적어 두면, 돌 때마다 할 말 뒤에 붙여 건네요.")
                    .font(.subheadline)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(routine.notes)
                    .font(.body)
                    .foregroundStyle(DS.Chat.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Button(routine.notes.isEmpty ? "지침 적기" : "지침 고치기") { editing = true }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(DS.Chat.accent)
                .disabled(model.busy.contains(routineID) || model.loadFailed)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCard()
    }

    @ViewBuilder
    private var history: some View {
        if runs.isEmpty {
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if model.historyFailed.contains(routineID) {
                    Text("기록을 받지 못했어요. 아래로 당겨 다시 받아 보세요.")
                } else {
                    Text("아직 돈 적이 없어요.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(DS.Chat.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .chatCard()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(RoutineRun.byDay(runs).enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.day)
                            .font(.footnote)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(group.runs.enumerated()), id: \.element.id) { index, run in
                                if index > 0 { ChatHairline().padding(.leading, 14) }
                                RunRow(run: run, heading: run.ranAt.map { RoutineRun.timeText($0) } ?? "때를 알 수 없음", isOpening: opening == run.id) {
                                    open(run)
                                }
                            }
                        }
                        .chatCard(padding: 0)
                    }
                }
            }
        }
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

/// 지침을 고치는 곳. 저장하면 맥에 보내고, 맥이 받아들인 뒤에 닫는다
private struct RoutineNotesEditor: View {
    let title: String
    let notes: String
    /// 저장한다. 됐으면 true
    let onSave: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSaving = false
    @State private var failed = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isTooLong: Bool { trimmed.count > AgentRoutine.notesLimit }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("'\(title)'이 돌 때마다 할 말 뒤에 붙여 건네는 설명이에요. 비우고 저장하면 지워요.")
                    .font(.footnote)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(.body)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(DS.Chat.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("지침")
                HStack {
                    if failed {
                        Text("저장하지 못했어요. 맥이 켜져 있는지 확인한 뒤 다시 해 주세요.")
                            .foregroundStyle(DS.Chat.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(trimmed.count) / \(AgentRoutine.notesLimit)")
                        .monospacedDigit()
                        .foregroundStyle(isTooLong ? DS.Chat.warning : DS.Chat.textSecondary)
                }
                .font(.footnote)
            }
            .padding(16)
            .background(DS.Chat.background)
            .navigationTitle("지침")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .disabled(isSaving || isTooLong || trimmed == notes)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .tint(DS.Chat.accent)
        .onAppear {
            text = notes
            focused = true
        }
    }

    private func save() {
        isSaving = true
        failed = false
        Task {
            let saved = await onSave(trimmed)
            isSaving = false
            if saved { dismiss() } else { failed = true }
        }
    }
}
