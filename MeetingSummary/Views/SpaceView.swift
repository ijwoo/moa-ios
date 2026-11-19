import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

/// 내 공간 탭 (D94, 모양은 D98): 말한 대로 카드를 모아 둔 한 화면.
///
/// 구성(어떤 카드를 어떤 크기로 어느 차례에)은 맥이 주고, 그리는 것은 여기 있는 카드·블록이다.
/// 일정·날씨·회의의 할 일은 이 기기의 데이터로 채우고(맥으로 가지 않는다. 일정은 D95), 메일·예약 결과·말로 만든 카드는 맥이 준 내용을 그린다.
/// 받은 내용은 화면이 떠 있는 동안 메모리에만 있다.
///
/// 평소에는 카드만 보인다 (입력창이 없다). 오른쪽 위의 "편집"을 누르면 아래에 입력창이 나오고,
/// 말로 고치면 실제 카드가 그 자리에서 바뀌며 위에 한 줄 알림("…바꿨어요 · 되돌리기")이 뜬다.
struct SpaceView: View {
    let model: SpaceModel
    let weather: any WeatherProviding
    let calendar: any DayEventsProviding
    /// 할 일 탭으로 간다 (할 일 카드의 "더 보기")
    var onOpenTasks: () -> Void = {}
    /// 카드의 단추가 대화로 보내는 말 (맥이 준 것, D99)
    var onSay: (String) -> Void = { _ in }
    /// 돌린 예약이 이어진 대화를 연다 (D128)
    var onOpenRun: (RoutineRun) -> Void = { _ in }

    @State private var draft = ""
    @State private var isEditing = false
    @State private var confirmsClear = false
    /// 끌어 옮기는 중인 카드 (편집 중, D100)
    @State private var dragging: String?
    /// 크기 핸들을 끄는 중인 카드와, 끌기 시작할 때의 크기 (D104: 끄는 동안 카드가 실제 크기와 내용으로 바뀐다)
    @State private var resizing: (id: String, from: SpaceCard.Size)?
    @FocusState private var typing: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // 머리와 편집 줄은 내용 위에 떠 있다: 다른 탭처럼 그 뒤로 카드가 흐리게 비치고, 가르는 선이 없다 (D100)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if isEditing, model.isOffered { editBar }
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .background(DS.Chat.background.ignoresSafeArea())
        .animation(.snappy(duration: 0.45), value: model.space)
        // 구성이나 내용이 바뀌면 홈 화면 위젯도 다시 묻게 한다 (D109)
        .onChange(of: model.space) { WidgetCenter.shared.reloadTimelines(ofKind: "SpaceWidget") }
        .animation(.snappy(duration: 0.3), value: isEditing)
        .task {
            await model.load()
            await model.refreshStale()
            #if DEBUG
            // 개발용: -demoSpaceSay "말" — 말로 고친 모습. -demoSpaceEdit — 편집을 연 모습
            if let say = DemoData.value(after: "-demoSpaceSay"), model.isOffered {
                try? await Task.sleep(for: .seconds(1))
                send(say)
            } else if DemoData.arguments.contains("-demoSpaceEdit"), model.isOffered {
                startEditing(focus: false)
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // 다른 앱에 다녀온 사이 내용이 오래됐을 수 있다
            if phase == .active { Task { await model.reload() } }
        }
        // 다른 탭에 다녀왔다 (D105): 대화에서 "내 공간에 환율 카드 넣어줘"처럼 말해 구성이 바뀌었을 수 있다 — 다시 받는다.
        // 처음 들어올 때는 위의 `task`가 받는다. 편집 중에는 받지 않는다 (고치던 것을 덮지 않게)
        .onAppear {
            guard model.hasLoaded, !isEditing else { return }
            Task {
                await model.load()
                await model.refreshStale()
            }
        }
        .confirmationDialog("내 공간을 비울까요?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("비우기", role: .destructive) { Task { await model.clear() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("카드가 모두 빠져요. 바로 뒤에는 되돌릴 수 있어요.")
        }
    }

    // MARK: - 머리

    private var header: some View {
        HStack(alignment: .center) {
            // 제목("오늘의 모아")은 두지 않는다 (D102): 날짜 한 줄만. 어느 탭인지는 탭 막대가 말해 준다
            Text(Self.dayText(.now))
                .font(.headline)
                .foregroundStyle(SpaceBrand.accent)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("내 공간, \(Self.dayText(.now))")
            Spacer()
            if model.isOffered, !model.space.cards.isEmpty || isEditing {
                Button {
                    // 편집을 켤 때 키보드를 올리지 않는다 (D104): 카드를 손으로 고치는 자리를 가리지 않게. 입력칸을 누르면 올라온다
                    if isEditing { stopEditing() } else { startEditing(focus: false) }
                } label: {
                    HStack(spacing: 8) {
                        Text(isEditing ? "완료" : "편집")
                            .font(.subheadline.weight(.semibold))
                        if !isEditing {
                            Circle()
                                .fill(SpaceBrand.mint)
                                .frame(width: 9, height: 9)
                        }
                    }
                    .foregroundStyle(isEditing ? SpaceBrand.onMint : DS.Chat.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background(isEditing ? SpaceBrand.mint : DS.Chat.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(isEditing ? .clear : DS.Chat.hairline))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isEditing ? "편집 마치기" : "내 공간 편집")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        // 편집 단추가 없을 때(빈 화면)도 머리의 키가 같게
        .frame(minHeight: 56)
    }

    /// "11월 16일 월요일"
    static func dayText(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(locale: Locale(identifier: "ko_KR"), calendar: calendar, timeZone: calendar.timeZone).month(.wide).day().weekday(.wide))
    }

    // MARK: - 본문

    @ViewBuilder
    private var content: some View {
        if !model.hasAgent {
            SpaceNotice(symbol: "desktopcomputer", title: "맥과 연결되어 있지 않아요", detail: "내 공간은 \(MailKeeper.name)가 화면을 짜 줘요. 맥과 연결된 뒤에 쓸 수 있어요.")
        } else if !model.hasLoaded {
            ProgressView()
                .tint(SpaceBrand.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("불러오는 중")
        } else if model.loadFailed, model.space.cards.isEmpty {
            SpaceNotice(symbol: "wifi.slash", title: "맥에 연결되지 않았어요", detail: "맥이 켜져 있는지 확인한 뒤 다시 해 주세요.") {
                Button("다시 시도") { Task { await model.reload() } }
                    .buttonStyle(.bordered)
                    .tint(SpaceBrand.accent)
            }
        } else if !model.isOffered {
            SpaceNotice(symbol: "square.grid.2x2", title: "이 맥은 아직 내 공간을 몰라요", detail: "맥의 에이전트를 최신으로 올리면 쓸 수 있어요.")
        } else if model.space.cards.isEmpty {
            empty
        } else {
            cards
        }
    }

    private var cards: some View {
        let rows = model.space.rows
        // 작은 카드는 늘 반 칸 타일이다 (D106): 옆에 짝이 없어도 반 칸만 쓴다 — 편집을 켜고 끌 때 크기가 달라 보이지 않게
        let halves = Set(model.space.cards.filter { $0.size == .small }.map(\.id))
        // "카드 추가하기"는 편집 중에만 보인다 (D101): 맨 끝 줄에 반 칸 카드가 혼자 있으면 그 옆의 타일로, 아니면 맨 아래에 한 줄로
        let pairsLast = isEditing && (rows.last.map { $0.count == 1 && $0[0].size == .small } ?? false)
        return ScrollView {
            VStack(spacing: 12) {
                if model.loadFailed {
                    SpaceBanner(text: "맥에 연결되지 않아 앞서 받은 화면을 보여 드려요.")
                }
                if let notice = model.notice {
                    SpaceBanner(text: notice)
                }
                // 카드는 모두 한 틀의 바로 아래에 둔다 (D104): 크기가 바뀌어 줄의 짜임이 달라져도 같은 카드가 그대로 남아
                // 자리와 크기가 이어서 바뀐다 — 핸들을 끄는 손동작도 끊기지 않는다
                SpaceGrid(spacing: arranging ? 18 : 12) {
                    ForEach(model.space.cards) { item in
                        card(for: item, tile: halves.contains(item.id))
                            .layoutValue(key: SpaceGrid.Half.self, value: halves.contains(item.id))
                    }
                    if pairsLast {
                        addTile.layoutValue(key: SpaceGrid.Half.self, value: true)
                    }
                }
                if isEditing, !pairsLast { addBar }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await model.reload() }
        // 빈 곳을 누르면 키보드를 내린다
        .simultaneousGesture(TapGesture().onEnded { typing = false })
    }

    /// 편집 중이고 맥이 손으로 고치기를 받을 때: 카드를 길게 눌러 옮기고, 모서리 핸들로 크기를 바꾸고, 메뉴로 뺀다 (D100)
    private var arranging: Bool { isEditing && model.canArrange }

    @ViewBuilder
    private func card(for card: SpaceCard, tile: Bool) -> some View {
        let view = SpaceCardView(
            card: card, model: model, weather: weather, calendar: calendar, onOpenTasks: onOpenTasks, onSay: onSay, fillsHeight: tile,
            highlighted: isEditing && model.change(card) != nil, onOpenRun: onOpenRun
        )
        if arranging {
            view
                // 편집 중에는 카드 안의 단추가 눌리지 않는다 (길게 눌러 옮기는 것과 섞이지 않게)
                .allowsHitTesting(false)
                // 길게 눌러 끄는 면: 카드 위에 따로 얹는다. 메뉴와 핸들은 이 면의 밖(위)에 있어야
                // 핸들을 천천히 끌 때 카드가 통째로 들리지 않는다 (D101)
                .overlay {
                    Color.clear
                        .contentShape(tile ? SpaceBrand.leaf : SpaceBrand.plain)
                        .onDrag {
                            dragging = card.id
                            return NSItemProvider(object: card.id as NSString)
                        } preview: {
                            view.frame(width: tile ? 172 : 340)
                        }
                        .onDrop(of: [.text], delegate: SpaceCardDrop(target: card.id, model: model, dragging: $dragging))
                }
                // 메뉴와 핸들은 카드의 모서리에 걸쳐 놓는다 (카드 안의 글을 가리지 않게)
                .overlay(alignment: .topTrailing) { cardMenu(card).offset(x: 13, y: -13) }
                .overlay(alignment: .bottomTrailing) { resizeHandle(card).offset(x: 13, y: 13) }
                // 핸들을 끄는 동안: 지금 크기의 이름을 가운데에 보인다 (카드 자체가 그 크기로 바뀌어 있다)
                .overlay { resizeBadge(card) }
                .zIndex(resizing?.id == card.id ? 1 : 0)
                .opacity(dragging == card.id ? 0.55 : 1)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
        } else {
            view.transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    /// 카드 메뉴 (편집 중, 오른쪽 위): 크기 · 위아래로 · 새로 받기 · 빼기
    private func cardMenu(_ card: SpaceCard) -> some View {
        let index = model.space.cards.firstIndex { $0.id == card.id } ?? 0
        return Menu {
            Picker("크기", selection: Binding(get: { card.size }, set: { size in Task { await model.resize(card.id, to: size) } })) {
                Text("작게").tag(SpaceCard.Size.small)
                Text("보통").tag(SpaceCard.Size.medium)
                Text("크게").tag(SpaceCard.Size.large)
            }
            Divider()
            Button {
                Task { await model.move(card.id, by: -1) }
            } label: {
                Label("위로", systemImage: "arrow.up")
            }
            .disabled(index == 0)
            Button {
                Task { await model.move(card.id, by: 1) }
            } label: {
                Label("아래로", systemImage: "arrow.down")
            }
            .disabled(index >= model.space.cards.count - 1)
            if !card.kind.filledByApp, card.state != .unavailable {
                Button {
                    Task { await model.refresh(card: card.id) }
                } label: {
                    Label("새로 받기", systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                Task { await model.remove(card.id) }
            } label: {
                Label("빼기", systemImage: "minus.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.55), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(card.title) 카드 메뉴")
    }

    /// 크기 핸들 (편집 중, 오른쪽 아래 모서리): 바깥으로 끌면 커지고 안으로 끌면 작아진다. 누르면 다음 크기로
    private func resizeHandle(_ card: SpaceCard) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(SpaceBrand.onMint)
            .frame(width: 28, height: 28)
            .background(SpaceBrand.mint, in: Circle())
            .overlay(Circle().strokeBorder(DS.Chat.background, lineWidth: 2))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .highPriorityGesture(
                // 화면 기준으로 잰다: 카드가 따라 커지며 핸들이 움직여도 끈 거리가 흔들리지 않게
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        // 끌기 시작할 때의 크기에서 센다 (끄는 동안 카드의 크기가 바뀌어도 기준이 흔들리지 않게)
                        let from = resizing?.id == card.id ? resizing?.from ?? card.size : card.size
                        if resizing?.id != card.id { resizing = (card.id, from) }
                        let target = SpaceResize.size(from: from, dragged: value.translation)
                        // 한 단계를 넘을 때마다 카드를 실제로 그 크기로 바꾼다: 내용과 옆 카드의 자리가 함께 바뀐다
                        if target != card.size {
                            withAnimation(.snappy(duration: 0.35)) { model.previewResize(card.id, to: target) }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.snappy(duration: 0.25)) { resizing = nil }
                        // 놓으면 지금 보이는 크기를 맥에 보낸다
                        Task { await model.commitArrange() }
                    }
            )
            .sensoryFeedback(.selection, trigger: card.size)
            .onTapGesture {
                Task { await model.resize(card.id, to: SpaceResize.next(card.size)) }
            }
            .accessibilityLabel("\(card.title) 카드 크기 바꾸기")
            .accessibilityHint("누르면 다음 크기로 바뀝니다")
            .accessibilityAddTraits(.isButton)
    }

    /// 핸들을 끄는 동안 카드 가운데에 놓으면 될 크기를 보인다 ("크게"). 지금 크기와 같으면 흐리게
    @ViewBuilder
    private func resizeBadge(_ card: SpaceCard) -> some View {
        if let resizing, resizing.id == card.id {
            let target = card.size
            Text(target.label)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(SpaceBrand.onMint)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(SpaceBrand.mint, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .transition(.scale.combined(with: .opacity))
                .accessibilityHidden(true)
        }
    }

    /// "카드 추가하기" 타일 (반 칸): 편집 중에만 보인다
    private var addTile: some View {
        Button { startEditing(focus: true) } label: {
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundStyle(SpaceBrand.accent)
                    .frame(width: 40, height: 40)
                    .background(SpaceBrand.accent.opacity(0.14), in: Circle())
                Text("카드 추가하기")
                    .font(SpaceType.body)
                    .foregroundStyle(DS.Chat.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: SpaceType.tileHeight, maxHeight: .infinity)
            .background(DS.Chat.card.opacity(0.5), in: SpaceBrand.leaf)
            .overlay(SpaceBrand.leaf.strokeBorder(DS.Chat.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(SpaceBrand.leaf)
        }
        .buttonStyle(.plain)
    }

    /// "카드 추가하기" 한 줄 (맨 아래)
    private var addBar: some View {
        Button { startEditing(focus: true) } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SpaceBrand.accent)
                Text("카드 추가하기")
                    .font(SpaceType.body)
                    .foregroundStyle(DS.Chat.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(DS.Chat.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 비어 있는 내 공간: 처음 화면(온보딩)과 같은 짜임 — 앱 아이콘의 네 조각, 제목, 설명, 아래의 단추
    private var empty: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 아래에 예시 화면이 들어가 로고는 작게 (D121)
                SpaceEmptyMark(width: 76)
                    .padding(.top, 20)
                    .padding(.bottom, 26)
                VStack(spacing: 10) {
                    Text("보고 싶은 것을 말하면\n이 화면이 만들어져요")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(DS.Chat.textPrimary)
                    Text("일정, 메일, 회의에서 나온 할 일처럼\n매일 확인하는 것을 한곳에 모아 둘 수 있어요.")
                        .font(.subheadline)
                        .lineSpacing(4)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(DS.Chat.textSecondary)
                }
                if let notice = model.notice {
                    SpaceBanner(text: notice)
                        .padding(.top, 20)
                }
                // 이렇게 말하면 (말풍선, 누르면 그 말을 보낸다) → 이런 화면이 된다 (실제 카드로 그린 예시, D121)
                Button { send(Self.exampleSay) } label: {
                    SpaceExampleBubble(text: "“\(Self.exampleSay)”")
                }
                .buttonStyle(.plain)
                .disabled(model.isEditing)
                .accessibilityLabel("예시: \(Self.exampleSay)")
                .accessibilityHint("이 말로 내 공간을 만들어요")
                .padding(.top, 32)
                SpaceExamplePreview(model: model, calendar: calendar)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(TapGesture().onEnded { typing = false })
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if !isEditing {
                Button { startEditing(focus: true) } label: {
                    Text("내 공간 만들기")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(SpaceBrand.onMint)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(SpaceBrand.mint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
    }

    /// 빈 화면 말풍선의 예시 말. 아래 예시 화면이 이 말로 만들어진 모습이다 (D121)
    static let exampleSay = "오늘 날씨랑 중요 메일, 일정만 모아줘"

    // MARK: - 편집

    /// 편집 중에만 보이는 아래 줄: 방금 바꾼 것의 한 줄 알림과 입력창
    private var editBar: some View {
        VStack(spacing: 8) {
            toast
            // 맥이 권하는 카드 (D108): 입력칸 위에 칩으로. 누르면 그 말로 바로 고친다. 되묻는 중에는 감춘다
            // 빈 화면에서도 보인다 (D121: 빈 화면의 예시 목록이 말풍선 하나와 예시 화면으로 바뀌었다)
            if !model.space.suggestions.isEmpty, !model.isAsked {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.space.suggestions) { suggestion in
                            Button { send(suggestion.say) } label: {
                                Label(suggestion.label, systemImage: "plus")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(DS.Chat.textPrimary)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 36)
                                    .background(DS.Chat.card, in: Capsule())
                                    .overlay(Capsule().strokeBorder(DS.Chat.hairline))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isEditing)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollClipDisabled()
            }
            HStack(spacing: 6) {
                Menu {
                    Button {
                        Task { await model.undo() }
                    } label: {
                        Label("되돌리기", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!model.space.canUndo)
                    Button {
                        Task { await model.reload() }
                    } label: {
                        Label("새로 받기", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        confirmsClear = true
                    } label: {
                        Label("비우기", systemImage: "trash")
                    }
                    .disabled(model.space.cards.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(DS.Chat.textSecondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .accessibilityLabel("되돌리기, 새로 받기, 비우기")
                // 한 줄 입력: 키보드의 "보내기"로 보낸다 (줄바꿈이 아니다)
                TextField(model.isAsked ? "답해 주세요" : (model.space.cards.isEmpty ? "무엇을 모아 둘까요?" : "어떻게 바꿔볼까요?"), text: $draft)
                    .font(.body)
                    .foregroundStyle(DS.Chat.textPrimary)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit { send(draft) }
                    .onChange(of: draft) { _, new in
                        if new.count > SpaceModel.textLimit { draft = String(new.prefix(SpaceModel.textLimit)) }
                    }
                    .frame(minHeight: 40)
                Button { send(draft) } label: {
                    Group {
                        if model.isEditing {
                            ProgressView().controlSize(.small).tint(SpaceBrand.onMint)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.bold))
                                .foregroundStyle(canSend ? SpaceBrand.onMint : DS.Chat.textSecondary)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .background(canSend || model.isEditing ? SpaceBrand.mint : DS.Chat.elevated, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(model.isEditing ? "바꾸는 중" : "보내기")
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .frame(minHeight: 52)
            .background(DS.Chat.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(DS.Chat.hairline))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var canSend: Bool { !model.isEditing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 방금 바꾼 것의 한 줄 알림: "'날씨' 카드를 크게 했어요 · 되돌리기". 고치는 중에는 그 말을 보인다
    @ViewBuilder
    private var toast: some View {
        if model.isEditing, model.turns.last?.changes == nil {
            toastRow(text: "화면을 바꾸는 중이에요", busy: true, undo: false)
        } else if let summary = model.lastSummary {
            toastRow(text: summary, busy: false, undo: model.lastChanged && model.space.canUndo)
        }
    }

    private func toastRow(text: String, busy: Bool, undo: Bool) -> some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small).tint(SpaceBrand.onHero)
            } else {
                Image(systemName: undo ? "checkmark.circle.fill" : (model.isAsked ? "questionmark.bubble.fill" : "info.circle"))
                    .foregroundStyle(undo || model.isAsked ? SpaceBrand.mint : SpaceBrand.onHero.opacity(0.7))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(SpaceBrand.onHero)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if undo {
                Button {
                    Task { await model.undo() }
                } label: {
                    Text("되돌리기")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(SpaceBrand.onHero)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .overlay(Capsule().strokeBorder(SpaceBrand.onHero.opacity(0.3)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.isEditing)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, undo ? 8 : 14)
        .frame(minHeight: 48)
        .background(SpaceBrand.hero, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }

    private func startEditing(focus: Bool) {
        isEditing = true
        if focus { typing = true }
    }

    private func stopEditing() {
        resizing = nil
        typing = false
        isEditing = false
        draft = ""
        dragging = nil
        Task {
            // 끌다가 카드 밖에 놓아 아직 보내지 않은 차례가 있으면 마저 보낸다
            await model.commitArrange()
            model.finishEditing()
        }
    }

    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.isEditing else { return }
        draft = ""
        // 보낸 뒤에는 키보드를 내린다: 바뀐 카드와 알림이 가려지지 않게
        typing = false
        isEditing = true
        Task {
            await model.edit(text)
            // 맥이 되물었으면 바로 답할 수 있게 입력칸을 연다 (D105)
            if model.isAsked { typing = true }
        }
    }
}

// MARK: - 카드의 틀 (D104)

/// 내 공간의 카드를 놓는 틀: 반 칸 카드 둘이 이어지면 한 줄에 나란히(같은 키로), 나머지는 한 줄에 하나.
/// 짝이 없는 반 칸 카드도 반 칸만 쓴다.
/// 모든 카드가 이 틀의 바로 아래에 있어, 크기가 바뀌어 줄의 짜임이 달라져도 같은 카드가 그대로 남는다
struct SpaceGrid: Layout {
    var spacing: CGFloat = 12

    /// 반 칸에 놓는 카드인지 (둘이 이어질 때만 나란히 놓인다)
    struct Half: LayoutValueKey {
        static let defaultValue = false
    }

    /// 줄마다 들어가는 카드의 번호: 반 칸 둘이 이어지면 한 줄, 나머지는 하나씩
    static func rows(_ halves: [Bool]) -> [[Int]] {
        var rows: [[Int]] = []
        var index = 0
        while index < halves.count {
            if halves[index], index + 1 < halves.count, halves[index + 1] {
                rows.append([index, index + 1])
                index += 2
            } else {
                rows.append([index])
                index += 1
            }
        }
        return rows
    }

    private func measure(_ subviews: Subviews, width: CGFloat) -> [(row: [Int], width: CGFloat, height: CGFloat)] {
        let halves = subviews.map { $0[Half.self] }
        return Self.rows(halves).map { row in
            // 반 칸 카드는 짝이 없어도 반 칸만 쓴다 (왼쪽에 놓이고 오른쪽은 비운다)
            let each = row.count == 2 || halves[row[0]] ? max(0, (width - spacing) / 2) : width
            let height = row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: each, height: nil)).height }.max() ?? 0
            return (row, each, height)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let rows = measure(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (row, each, height) in measure(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row {
                // 나란한 둘은 같은 키로 놓는다 (낮은 쪽이 높은 쪽에 맞춘다)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: each, height: height))
                x += each + spacing
            }
            y += height + spacing
        }
    }
}

// MARK: - 손으로 고치기 (D100)

/// 끌어 옮기는 카드가 다른 카드 위에 왔을 때: 그 자리로 옮긴 모습을 바로 보이고, 놓으면 맥에 보낸다
private struct SpaceCardDrop: DropDelegate {
    let target: String
    let model: SpaceModel
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.snappy(duration: 0.3)) { model.previewMove(dragging, onto: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        Task { await model.commitArrange() }
        return true
    }
}

/// 크기 핸들을 끈 만큼의 크기
enum SpaceResize {
    private static let order: [SpaceCard.Size] = [.small, .medium, .large]
    /// 한 단계에 해당하는 끈 거리
    static let step: CGFloat = 56

    /// 오른쪽·아래로 끌면 커지고, 왼쪽·위로 끌면 작아진다 (한 단계에 `step`만큼)
    static func size(from size: SpaceCard.Size, dragged: CGSize) -> SpaceCard.Size {
        let steps = Int(((dragged.width + dragged.height) / step).rounded())
        let index = (order.firstIndex(of: size) ?? 1) + steps
        return order[min(max(0, index), order.count - 1)]
    }

    /// 다음 크기 (크게 다음은 작게)
    static func next(_ size: SpaceCard.Size) -> SpaceCard.Size {
        order[((order.firstIndex(of: size) ?? 1) + 1) % order.count]
    }
}

// MARK: - 공통 조각

/// 비어 있는 내 공간의 그림: 앱 아이콘의 네 조각이 모인다 (처음 화면과 같은 로고, D98)
private struct SpaceEmptyMark: View {
    var width: CGFloat = 132
    @State private var settled = false
    @State private var sparked = false
    @State private var ripple = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MoaLogoMarkV4(
            width: width, mintColor: SpaceBrand.mint, leafColor: colorScheme == .dark ? .white : Color(red: 0.086, green: 0.098, blue: 0.118),
            showGuide: false, step1: settled, step2: settled, step3: settled, step4: sparked, ripple: ripple
        )
        .accessibilityHidden(true)
        .onAppear {
            guard !settled else { return }
            if reduceMotion {
                settled = true
                sparked = true
                ripple = true
                return
            }
            withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.9).delay(0.1)) { settled = true }
            withAnimation(.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.9).delay(0.45)) { sparked = true }
            withAnimation(.easeOut(duration: 1.0).delay(0.9)) { ripple = true }
        }
    }
}

/// 빈 화면의 말풍선: 예시 말 한 줄과, 아래 예시 화면을 가리키는 꼬리 (D121)
private struct SpaceExampleBubble: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(DS.Chat.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(DS.Chat.card, in: Capsule())
            SpaceBubbleTail()
                .fill(DS.Chat.card)
                .frame(width: 16, height: 8)
        }
        .contentShape(Rectangle())
    }
}

private struct SpaceBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 빈 화면의 예시 화면 (D121): 말풍선의 말로 만들어질 모습을 실제 카드(`SpaceCardView`)로 그린다.
/// 값은 모두 지어낸 것이다 — 날씨는 이 기기의 날씨를 묻지 않고 정해 둔 "서울 14°"를, 메일·일정도 정해 둔 글을 쓴다.
/// 누를 수 없고(그림일 뿐), 아래쪽은 흐리게 사라진다
private struct SpaceExamplePreview: View {
    let model: SpaceModel
    let calendar: any DayEventsProviding

    static let cards: [SpaceCard] = [
        SpaceCard(id: "example-weather", kind: .weather, size: .small, title: "날씨", state: .ok),
        SpaceCard(id: "example-mail", kind: .mailToday, size: .small, title: "중요 메일", state: .ok, mailCount: 3, mailHeadline: "답장할 메일 1통"),
        SpaceCard(
            id: "example-today", kind: .custom, size: .medium, title: "오늘", state: .ok,
            blocks: [.pairs([.init(label: "오늘 일정", value: "21:15 운동"), .init(label: "할 일", value: "회의 요약 확인")])]
        ),
    ]

    var body: some View {
        // 실제 카드 크기 그대로는 한 화면에 다 들어가지 않아 줄여 그린다 (모양·글의 비율은 실제 카드와 같다)
        SpaceScaled(scale: 0.74) {
            SpaceGrid(spacing: 12) {
                ForEach(Self.cards) { card in
                    SpaceCardView(card: card, model: model, weather: SpaceExampleWeather(), calendar: calendar, fillsHeight: card.size == .small)
                        .layoutValue(key: SpaceGrid.Half.self, value: card.size == .small)
                }
            }
        }
        .padding(12)
        .padding(.bottom, 6)
        .background(DS.Chat.card.opacity(0.35), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(DS.Chat.hairline))
        // 아래로 갈수록 흐려진다 (화면이 이어진다는 느낌)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("예시 화면: 서울 날씨, 중요 메일 3통, 오늘 일정과 할 일")
    }
}

/// 안의 화면을 `scale`배로 줄여 그리고, 차지하는 자리도 그만큼 줄인다 (`scaleEffect`만으로는 자리가 줄지 않는다)
private struct SpaceScaled<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ScaledLayout(scale: scale) {
            content.scaleEffect(scale, anchor: .topLeading)
        }
    }

    private struct ScaledLayout: Layout {
        let scale: CGFloat

        private func inner(_ proposal: ProposedViewSize) -> ProposedViewSize {
            ProposedViewSize(width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            let size = child.sizeThatFits(inner(proposal))
            return CGSize(width: size.width * scale, height: size.height * scale)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard let child = subviews.first else { return }
            let size = child.sizeThatFits(inner(proposal))
            child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}

/// 예시 화면의 날씨: 묻지 않고 정해 둔 서울 날씨를 준다 (지어낸 값. 위치를 쓰지 않는다)
private struct SpaceExampleWeather: WeatherProviding {
    func weather(place: String?) async -> Result<WeatherSource, WeatherFailure> {
        let now = Date.now
        return .success(WeatherSource(
            place: "서울", timeZone: TimeZone(identifier: "Asia/Seoul") ?? .current,
            now: WeatherSource.Now(temperature: 14, feelsLike: 12, condition: "구름 조금", symbol: "cloud.sun.fill"),
            days: [WeatherSource.Day(date: now, condition: "구름 조금", symbol: "cloud.sun.fill", high: 17, low: 8, rainChance: 0.1, wind: 2.4, uvIndex: 4)]
        ))
    }
}

/// 화면 가운데의 안내 (맥이 없거나, 닿지 않거나, 내 공간을 모를 때)
private struct SpaceNotice<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(DS.Chat.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(DS.Chat.textPrimary)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(DS.Chat.textSecondary)
                .multilineTextAlignment(.center)
            action()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension SpaceNotice where Action == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// 카드 위의 한 줄 알림
private struct SpaceBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.footnote)
            .foregroundStyle(DS.Chat.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(DS.Chat.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
