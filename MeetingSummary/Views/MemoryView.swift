import SwiftUI

/// 기억 화면 (D151, 맥의 D129, 내 정보 › 할 일과 맥 › 기억).
/// 맥이 대화에서 정리해 둔 요약본을 보고 고치고 되돌리고, 지난 대화를 찾고, 모두 지운다.
/// 요약본과 찾은 대화는 이 화면에만 그린다 (앱에 저장하지 않는다)
struct MemoryView: View {
    let model: MemoryModel

    @State private var editing = false
    @State private var query = ""
    @State private var confirmingClear = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
        List {
            if let notice = model.notice {
                Section {
                    Text(notice)
                        .font(DS.Settings.captionFont)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            if let memory = model.memory {
                profileSections(memory)
                actionsSection(memory)
                searchSection
                clearSection
            } else if model.isLoading || !model.hasLoaded {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    Text(model.isOffered ? "기억을 받지 못했어요. 맥 연결을 확인한 뒤 다시 열어 주세요." : "맥이 아직 기억 기능을 켜지 않았어요.")
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
        .settingsListStyle()
        #if DEBUG
        // 화면 확인용 (`-demoMemorySearch 말`): 그 말로 찾고 아래쪽을 보인다
        .task {
            guard let demo = DemoData.value(after: "-demoMemorySearch") else { return }
            try? await Task.sleep(for: .milliseconds(600))
            query = demo
            await model.search(demo)
            try? await Task.sleep(for: .milliseconds(300))
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
        #endif
        }
        .navigationTitle("기억")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $editing) {
            MemoryEditor(original: model.memory?.profile ?? "", model: model)
        }
        .alert("기억을 모두 지울까요?", isPresented: $confirmingClear) {
            Button("모두 지우기", role: .destructive) {
                Task { _ = await model.clearAll() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("맥에 있는 요약과 지난 대화 기록이 모두 지워져요. 되돌릴 수 없어요.")
        }
    }

    // MARK: - 요약

    @ViewBuilder
    private func profileSections(_ memory: AgentMemory) -> some View {
        let sections = MemorySection.sections(memory.profile)
        if sections.isEmpty {
            Section {
                Text("아직 기억한 것이 없어요. 대화에서 \"기억해 줘\"라고 말하거나 대화를 이어 가면 맥이 정리해 둬요.")
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } footer: {
                Text(Self.footer(memory))
            }
        } else {
            ForEach(sections) { section in
                Section {
                    ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(DS.Settings.titleFont)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                } header: {
                    if let title = section.title { Text(title) }
                } footer: {
                    // 맨 아래 묶음에만 언제 어떻게 정리됐는지
                    if section.id == sections.count - 1 { Text(Self.footer(memory)) }
                }
            }
        }
    }

    /// "대화에서 정리됨 · 11월 18일 오후 3:10" 같은 한 줄과 보관한 대화의 수
    static func footer(_ memory: AgentMemory) -> String {
        var parts: [String] = []
        let how: String? = switch memory.source {
        case .digest: "대화에서 정리됨"
        case .user: "직접 고침"
        case .undo: "되돌림"
        case nil: nil
        }
        if let how {
            parts.append(memory.updatedAt.map { "\(how) · \(Self.timeText($0))" } ?? how)
        }
        if memory.turns > 0 {
            parts.append(memory.since.map { "\(Self.dayText($0))부터 대화 \(memory.turns)개를 보관하고 있어요" } ?? "대화 \(memory.turns)개를 보관하고 있어요")
        }
        parts.append("대화가 15분 잠잠하면 맥이 다시 정리해요.")
        return parts.joined(separator: "\n")
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "a h:mm" : "M월 d일 a h:mm"
        return formatter.string(from: date)
    }

    /// "2026-11-11" → "11월 11일"
    static func dayText(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return day }
        return "\(parts[1])월 \(parts[2])일"
    }

    // MARK: - 고치기·되돌리기

    private func actionsSection(_ memory: AgentMemory) -> some View {
        Section {
            Button {
                editing = true
            } label: {
                SettingsActionLabel(title: "직접 고치기", icon: .fileText)
            }
            .disabled(model.isChanging)
            Button {
                Task { await model.undo() }
            } label: {
                SettingsActionLabel(title: "한 단계 되돌리기", icon: .history)
            }
            // 전 판이 있는지는 맥만 안다 (처음 쓴 요약에도 없다). 눌러 보고 없으면 그렇게 알린다
            .disabled(model.isChanging || memory.isEmpty)
        } footer: {
            Text("고친 글은 맥이 비밀번호·카드 번호 같은 값을 지우고 \(AgentMemory.savedLimit)자까지만 저장해요.")
        }
    }

    // MARK: - 지난 대화 찾기

    private var searchSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DS.Colors.textSecondary)
                    .accessibilityHidden(true)
                TextField("지난 대화에서 찾기", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { Task { await model.search(query) } }
                    .onChange(of: query) { _, new in
                        if String(new.prefix(MemoryModel.queryLimit)) != new { query = String(new.prefix(MemoryModel.queryLimit)) }
                        if new.isEmpty { model.clearSearch() }
                    }
                if model.isSearching { ProgressView().controlSize(.small) }
            }
            if model.searchFailed {
                Text("찾지 못했어요. 맥 연결을 확인한 뒤 다시 해 주세요.")
                    .font(DS.Settings.captionFont)
                    .foregroundStyle(DS.Colors.textSecondary)
            } else if let searched = model.searched, model.hits.isEmpty {
                Text("\"\(searched)\"가 나온 대화가 없어요.")
                    .font(DS.Settings.captionFont)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            ForEach(model.hits) { hit in
                MemoryHitRow(hit: hit)
            }
        } header: {
            Text("지난 대화 찾기")
        } footer: {
            Text("맥이 보관한 지난 대화에서 찾아요. 대화에서 \"지난주에 얘기한 … 뭐였지?\"라고 물어도 맥이 찾아 답해요.")
        }
    }

    // MARK: - 모두 지우기

    private var clearSection: some View {
        Section {
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                SettingsActionLabel(title: "기억 모두 지우기", icon: .trash, color: DS.Colors.danger)
            }
            .disabled(model.isChanging)
        } footer: {
            Text("요약과 지난 대화를 맥에서 모두 지워요. 되돌릴 수 없어요.")
        }
        .id(Self.bottomID)
    }

    private static let bottomID = "memory.bottom"
}

/// 찾은 말 한 줄: 때 · 누가, 그 말, 바로 뒤 상대의 말
private struct MemoryHitRow: View {
    let hit: MemoryHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(hit.when) · \(hit.isMine ? "나" : "모아")")
                .font(DS.Settings.captionFont)
                .foregroundStyle(DS.Colors.textSecondary)
            Text(hit.text)
                .font(DS.Settings.titleFont)
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let next = hit.next {
                Text("\(hit.isMine ? "모아" : "나"): \(next)")
                    .font(DS.Settings.captionFont)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// 요약본을 직접 고치는 화면. 저장하면 맥이 저장한 글로 바뀐다
private struct MemoryEditor: View {
    let original: String
    let model: MemoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.inner, style: .continuous))
                HStack {
                    Text("\"## 나\"처럼 #으로 묶음을, \"- \"로 항목을 써요.")
                    Spacer()
                    Text("\(draft.count)/\(AgentMemory.sendLimit)")
                        .monospacedDigit()
                        .foregroundStyle(draft.count > AgentMemory.sendLimit ? DS.Colors.danger : DS.Colors.textSecondary)
                }
                .font(DS.Settings.captionFont)
                .foregroundStyle(DS.Colors.textSecondary)
                if let notice = model.notice, !model.isChanging {
                    Text(notice)
                        .font(DS.Settings.captionFont)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .padding(16)
            .background(DS.Colors.background.ignoresSafeArea())
            .navigationTitle("기억 고치기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isChanging {
                        ProgressView()
                    } else {
                        Button("저장") {
                            Task {
                                if await model.save(draft) { dismiss() }
                            }
                        }
                        .disabled(draft == original || draft.count > AgentMemory.sendLimit)
                    }
                }
            }
        }
        .onAppear { draft = original }
        .interactiveDismissDisabled(draft != original)
    }
}

#if DEBUG
#Preview {
    NavigationStack { MemoryView(model: MemoryModel(agent: MockAgentClient(v2: true))) }
}
#endif
