import SwiftData
import SwiftUI

// 대화 탭의 사이드바 (D53, 미는 방식은 D55).
//
// 하단 탭은 쌓인 것을 종류별로 보는 곳(회의·할 일·내 정보)이고, 사이드바는 대화 탭에만 딸린 서랍이다:
// 대화를 오가고(새 대화, 최근 대화), 맥에 맡길 일을 고르고(맡길 수 있는 일), 맡긴 일을 다시 찾는다(에이전트 작업).
// 설정은 내 정보 탭에 있으므로 여기에 두지 않는다.
//
// 서랍은 화면 위에 덮이지 않는다. 화면 왼쪽 바깥에 붙어 있다가, 열면 화면 전체(탭 막대까지)를 오른쪽으로 밀며 들어온다.
// 그래서 최상위 화면(`RootView`)을 `ChatSidebarHost`로 감싼다. 고른 화면은 대화 탭(`AskView`)이 띄운다.
// 여는 길은 둘이다: 왼쪽 위 단추, 그리고 대화 화면을 오른쪽으로 밀기 (`sidebarDrag`).

/// 사이드바가 열려 있는지와, 사이드바에서 고른 화면
@MainActor
@Observable
final class ChatSidebarModel {
    /// 대화 탭 안에서 밀어 넣는 화면
    enum Screen: Hashable { case skills, agentTasks, routines }

    var isOpen = false
    var screen: Screen?
    /// 대화 기록 전체 (지우기는 여기서 한다)
    var showingHistory = false

    // MARK: - 옆으로 밀기

    static let maxWidth: CGFloat = 320
    /// 손을 뗐을 때 이만큼 더 갈 기세면(튕기듯 밀었으면) 민 쪽으로 보낸다. 시스템이 어림하는 거리는 속도의 1/4쯤이라, 초당 320pt쯤이다
    static let flick: CGFloat = 80
    /// 끌다 손을 뗀 직후 이 동안은 줄을 누른 것으로 치지 않는다
    static let tapGuard: Duration = .milliseconds(150)

    /// 서랍의 너비: 화면의 84%, 넓은 화면에서는 320까지
    static func panelWidth(screenWidth: CGFloat) -> CGFloat {
        max(0, min(maxWidth, screenWidth * 0.84))
    }

    /// 손을 뗐을 때 열어 둘지. 튕기듯 밀었으면 그 방향으로, 천천히 놓았으면 절반을 넘었는지로 정한다
    static func settlesOpen(shift: CGFloat, predictedShift: CGFloat, panelWidth: CGFloat) -> Bool {
        if predictedShift - shift > flick { return true }
        if predictedShift - shift < -flick { return false }
        return shift > panelWidth / 2
    }

    /// 화면 너비 (`ChatSidebarHost`가 알려 준다)
    var screenWidth: CGFloat = 0
    var panelWidth: CGFloat { Self.panelWidth(screenWidth: screenWidth) }

    /// 손가락으로 끄는 동안 화면이 밀려 있는 거리 (끄는 중이 아니면 nil)
    private(set) var dragShift: CGFloat?
    /// 이번 손길을 따라갈지. 처음 움직인 방향으로 한 번 정하면 손을 뗄 때까지 바꾸지 않는다
    private enum DragLock {
        /// 따라간다. `startShift`: 시작할 때 밀려 있던 거리, `startX`: 그때까지 손가락이 가로로 움직인 거리
        case tracking(startShift: CGFloat, startX: CGFloat)
        /// 세로로 시작했거나(스크롤) 갈 곳이 없는 쪽으로 밀었다
        case ignored
    }
    private var dragLock: DragLock?
    /// 이번 손길이 옆으로 움직였다 (따라가지 않는 쪽이었어도). 그렇게 끝난 손길은 줄을 누른 것이 아니다
    private var movedSideways = false
    private var lastDragEnd: ContinuousClock.Instant?

    /// 화면이 지금 오른쪽으로 밀려 있는 거리 (0 = 닫힘, 서랍 너비 = 다 열림)
    var shift: CGFloat { dragShift ?? (isOpen ? panelWidth : 0) }
    /// 얼마나 열렸는지 (0…1)
    var progress: CGFloat { panelWidth > 0 ? shift / panelWidth : 0 }
    var isDragging: Bool { dragShift != nil }

    /// 손가락이 움직일 때마다 부른다 (`translation`: 처음 닿은 곳에서 움직인 거리).
    /// 가로로 시작한 손길만 따라간다: 닫혀 있으면 오른쪽으로, 열려 있으면 왼쪽으로. 세로로 시작한 손길은 스크롤이라 건드리지 않는다.
    /// 따라가기 시작한 그 순간에만 true를 돌려준다
    @discardableResult
    func dragChanged(_ translation: CGSize) -> Bool {
        switch dragLock {
        case .ignored:
            return false
        case .tracking(let startShift, let startX):
            dragShift = min(panelWidth, max(0, startShift + translation.width - startX))
            return false
        case nil:
            let isHorizontal = abs(translation.width) > abs(translation.height)
            movedSideways = isHorizontal
            let hasRoom = isOpen ? translation.width < 0 : translation.width > 0
            guard isHorizontal, hasRoom, panelWidth > 0 else {
                dragLock = .ignored
                return false
            }
            let startShift = isOpen ? panelWidth : 0
            // 알아채기까지 움직인 만큼은 빼고 따라간다 (그래야 처음에 툭 튀지 않는다)
            dragLock = .tracking(startShift: startShift, startX: translation.width)
            dragShift = startShift
            return true
        }
    }

    /// 손을 뗐다. `predictedTranslation`: 그 기세로 더 갔을 때의 거리
    func dragEnded(predictedTranslation: CGSize, now: ContinuousClock.Instant = .now) {
        defer { finishDrag(now: now) }
        guard case .tracking(let startShift, let startX) = dragLock, let shift = dragShift else { return }
        let predicted = startShift + predictedTranslation.width - startX
        isOpen = Self.settlesOpen(shift: shift, predictedShift: predicted, panelWidth: panelWidth)
    }

    /// 손길이 끝났다는 말 없이 끊겼다 (전화, 다른 손길). 있던 자리에서 가까운 쪽으로 보낸다
    func dragCancelled(now: ContinuousClock.Instant = .now) {
        defer { finishDrag(now: now) }
        guard case .tracking = dragLock, let shift = dragShift else { return }
        isOpen = Self.settlesOpen(shift: shift, predictedShift: shift, panelWidth: panelWidth)
    }

    private func finishDrag(now: ContinuousClock.Instant) {
        if movedSideways { lastDragEnd = now }
        movedSideways = false
        dragLock = nil
        dragShift = nil
    }

    /// 옆으로 끄는 중이거나 방금 끌다 뗐다. 손을 뗀 자리에 있던 줄이 눌린 것으로 처리되지 않게 한다
    /// (줄 안에서 옆으로만 움직이다 떼면 단추는 눌린 것으로 안다)
    func swallowsTap(now: ContinuousClock.Instant = .now) -> Bool {
        if movedSideways { return true }
        guard let lastDragEnd else { return false }
        return now - lastDragEnd < Self.tapGuard
    }

    /// 여는 움직임(0.32초)이 끝나는 때. 서랍에 넣을 것은 이 뒤에 새로 받는다 (D148)
    static let settleDelay: Duration = .milliseconds(380)

    /// 닫혀 있을 때 서랍을 덮는 어둠 (D148). 열리면서 걷혀 다 열리면 밝다.
    /// 어두운 화면에서는 서랍 면이 이미 어두워 조금 더 짙어야 밝아지는 것이 보인다
    static func panelDim(progress: CGFloat, dark: Bool) -> Double {
        (dark ? 0.32 : 0.12) * Double(1 - min(1, max(0, progress)))
    }

    /// 열고 닫을 때의 움직임. 끝에서 넘치지 않는다 (넘치면 화면 가장자리에 틈이 보인다)
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0)
    }
}

// MARK: - 옆으로 끄는 손길

/// 화면을 옆으로 끌어 서랍을 여닫는다. 대화 화면(열기)과 서랍·가림막(닫기)이 같이 쓴다
private struct SidebarDrag: ViewModifier {
    let model: ChatSidebarModel
    let onBegan: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 손길이 살아 있는 동안만 참. 끝났다는 말 없이 끊겨도 거짓으로 돌아온다
    @GestureState private var isActive = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                // 끄는 동안 화면이 손가락을 따라 움직이므로, 거리는 움직이지 않는 화면 전체를 기준으로 잰다
                DragGesture(minimumDistance: 16, coordinateSpace: .global)
                    .updating($isActive) { _, state, _ in state = true }
                    .onChanged { value in
                        if model.dragChanged(value.translation) { onBegan() }
                    }
                    .onEnded { value in
                        withAnimation(ChatSidebarModel.animation(reduceMotion: reduceMotion)) {
                            model.dragEnded(predictedTranslation: value.predictedEndTranslation)
                        }
                    }
            )
            .onChange(of: isActive) { _, active in
                guard !active else { return }
                // 정상으로 끝났으면 위의 onEnded가 먼저 정리한다. 그 뒤에도 남아 있으면 끊긴 것이다
                Task { @MainActor in
                    withAnimation(ChatSidebarModel.animation(reduceMotion: reduceMotion)) { model.dragCancelled() }
                }
            }
    }
}

/// 사이드바를 끌어 열 때 손가락 밑의 단추가 눌리지 않게 한다.
/// 화면이 손가락을 따라 움직여서, 단추 위에서 끌기 시작하면 손을 뗄 때 그 단추가 눌렸다 (승인 단추도).
/// 위의 `DragGesture`는 나란히 가는 손길이라 단추의 누름을 취소하지 않는다. 그래서 오른쪽으로 시작한 손길을
/// UIKit 손길로도 한 번 받는다: 하는 일은 없고, 시작하는 순간 그 손가락의 누름이 취소된다 (`SidePan`).
/// 끄는 동안 `allowsHitTesting(false)`로는 이미 시작된 누름이 취소되지 않았고, `disabled`는 취소하지만 단추가 흐려진다
private struct SidebarDragShield: ViewModifier {
    let model: ChatSidebarModel

    func body(content: Content) -> some View {
        content.gesture(SidePan(toward: .right, isEnabled: { !model.isOpen }, onChanged: { _, _ in }, onEnded: { _ in }))
    }
}

/// 서랍의 열림에 따라 바뀌는 것만 읽는 자리 (D148).
/// 끄는 동안 매 순간 바뀌는 값이나 여닫힘을 큰 화면(대화, 서랍)의 body가 읽으면, 그 화면 전체가 그때마다 다시 그려져 움직임이 끊긴다.
/// 여기서 읽으면 이 수식어만 다시 계산되고 안의 화면은 그대로다
private struct SidebarPanelState: ViewModifier {
    let model: ChatSidebarModel
    let onOpenChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            // 닫혀 있으면 화면 밖에 있다. 손길도 VoiceOver도 받지 않는다
            .allowsHitTesting(model.isOpen)
            .accessibilityHidden(!model.isOpen)
            .onChange(of: model.isOpen) { _, open in onOpenChange(open) }
    }
}

/// 끄는 동안은 굴리지 않고 스크롤 선도 감춘다. 선은 서랍 안 목록이면 다 열려 있을 때만, 대화 화면이면 닫혀 있을 때만 보인다
/// (선이 밀려 움직이는 화면의 가장자리에 붙어 손가락을 따라다녔다)
private struct SidebarScrollLock: ViewModifier {
    let model: ChatSidebarModel
    let inPanel: Bool

    func body(content: Content) -> some View {
        let showsLine = !model.isDragging && (inPanel ? model.isOpen : !model.isOpen)
        content
            .scrollDisabled(model.isDragging)
            .scrollIndicators(showsLine ? .automatic : .hidden)
    }
}

extension View {
    /// 사이드바를 끄는 동안과 열려 있는 동안의 스크롤 (`inPanel`: 서랍 안의 목록인지)
    func sidebarScrollLock(_ model: ChatSidebarModel, inPanel: Bool) -> some View {
        modifier(SidebarScrollLock(model: model, inPanel: inPanel))
    }

    /// 이 위에서 옆으로 끌면 사이드바가 따라 나온다(들어간다). `onBegan`: 따라가기 시작할 때 한 번
    func sidebarDrag(_ model: ChatSidebarModel, onBegan: @escaping () -> Void = {}) -> some View {
        modifier(SidebarDrag(model: model, onBegan: onBegan))
    }

    /// 사이드바를 끌어 열 때 이 안의 단추가 눌리지 않게 한다
    func sidebarDragShield(_ model: ChatSidebarModel) -> some View {
        modifier(SidebarDragShield(model: model))
    }
}

// MARK: - 놓는 자리

/// 서랍은 뒤에 붙박여 있고, 열면 화면이 그 위에서 오른쪽으로 밀려나며 서랍이 드러난다 (참고 앱처럼, D115).
/// 전에는 서랍도 화면 왼쪽 바깥에서 함께 밀려 들어왔다
struct ChatSidebarHost<Content: View>: View {
    let session: AskSession
    let model: ChatSidebarModel
    let skills: SkillsModel
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .leading) {
            // 맨 아래: 움직이지 않는 서랍 (닫혀 있으면 화면에 가려진다)
            ChatSidebar(session: session, model: model, skills: skills)
                .frame(width: model.panelWidth)
                // 열리기 전에는 살짝 어둡고, 열리면서 밝아진다 (D148)
                .overlay {
                    Color.black
                        .opacity(ChatSidebarModel.panelDim(progress: model.progress, dark: colorScheme == .dark))
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            content
                .offset(x: model.shift)
                // 열려 있는 동안 VoiceOver는 서랍 안만 읽는다
                .accessibilityHidden(model.isOpen)
            // 밀려난 화면을 덮는 가림막: 물러난 화면답게 어둡게 하고, 누르거나 왼쪽으로 밀면 닫힌다.
            // 어두운 화면에서는 글자가 밝아, 더 짙게 덮어야 물러나 보인다
            Color.black.opacity((colorScheme == .dark ? 0.4 : 0.14) * model.progress)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.isOpen = false }
                .sidebarDrag(model)
                .modifier(PushedScreenEdge(progress: model.progress))
                .offset(x: model.shift)
                .allowsHitTesting(model.isOpen || model.isDragging)
                .accessibilityLabel("닫기")
                .accessibilityAddTraits(.isButton)
                .accessibilityHidden(!model.isOpen)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.screenWidth = $0 }
        .animation(ChatSidebarModel.animation(reduceMotion: reduceMotion), value: model.isOpen)
        // 열고 닫을 때 가볍게 (끌다가 제자리로 돌아간 것은 바뀐 것이 아니라 울리지 않는다)
        .sensoryFeedback(.impact(weight: .light), trigger: model.isOpen)
    }
}

/// 밀려난 화면의 가장자리. 화면이 서랍 면 위에 놓인 둥근 카드로 보이게 한다:
/// 모서리 바깥을 서랍 면 색으로 칠하고, 둘레에 가는 선을 두른다.
///
/// 모서리 곡선은 기기 화면의 둥근 모서리와 같다 (`ConcentricRectangle`). 화면이 제자리에 있을 때는
/// 기기 모서리에 가려지는 자리라, 밀려 나오면서 화면 모서리가 그대로 따라 나온 것처럼 보인다.
/// 화면이 조금이라도 밀려 있는 동안만 그린다 (닫히는 움직임이 끝날 때까지 남아 있도록 값을 따라간다)
private struct PushedScreenEdge: ViewModifier, Animatable {
    var progress: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// 둘레 선. 어두운 화면에서는 덮인 화면과 서랍 면이 둘 다 어두워, 조금 더 밝아야 경계가 보인다
    private var line: Color { colorScheme == .dark ? Color.white.opacity(0.16) : DS.Chat.hairline }

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                // 선과 바깥 칠을 같은 모양에서 만든다: 1pt 안쪽 모양의 바깥을 선 색으로 칠하고,
                // 그 위에 제 모양의 바깥을 서랍 면 색으로 덮으면 사이에 1pt 띠가 남는다.
                // (`stroke`로 그은 선은 모서리 곡선이 칠한 모양과 달라 모서리에서 틈이 벌어졌다)
                line.mask { Self.outside(inset: 1) }
                DS.Chat.card.mask { Self.outside(inset: 0) }
            }
            .opacity(progress > 0.001 ? 1 : 0)
            // 화면 끝까지 덮어야 기기 모서리와 같은 곡선이 나온다 (안전 영역 안에만 그리면 그만큼 작아진다)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// 둥근 모양의 바깥쪽만 남긴 가림막. 위·아래·오른쪽은 화면 끝이라 왼쪽만 들인다
    private static func outside(inset: CGFloat) -> some View {
        ZStack {
            Rectangle()
            ConcentricRectangle()
                .padding(.leading, inset)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

/// 서랍. 화면 왼쪽 바깥에 붙어 있다가 화면을 밀며 들어온다. 바깥을 누르거나 왼쪽으로 밀면 닫힌다
struct ChatSidebar: View {
    let session: AskSession
    let model: ChatSidebarModel
    let skills: SkillsModel

    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    /// 대화 찾기에 쓴 글 (D116)
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var deleting: Conversation?

    var body: some View {
        panel
            // 가로로 민 것만 닫기로 본다 (세로로 미는 것은 최근 대화 목록의 스크롤이다)
            .sidebarDrag(model)
            // 열고 닫힌 것은 여기서만 읽는다 (D148): 이 화면의 body가 읽으면 여닫는 순간 서랍 전체를 다시 그려 움직임이 멈칫한다
            .modifier(SidebarPanelState(model: model) { open in
                if open {
                    loadAfterOpening()
                } else {
                    // 닫으면 찾던 글을 비운다
                    search = ""
                    searchFocused = false
                }
            })
    }

    /// 열 때마다 새로 받는다: 로그인·메일 연결을 마치고 돌아오면 준비 상태가 바뀌어 있다.
    /// 여는 움직임이 끝난 뒤에 받는다 (D148): 받은 것을 그리는 일이 움직임 중간에 끼면 서랍이 한 번 멈췄다가 다시 움직였다
    private func loadAfterOpening() {
        Task {
            try? await Task.sleep(for: ChatSidebarModel.settleDelay)
            guard model.isOpen else { return }
            Task { await skills.load() }
            Task { await session.routines.load() }
            // 대화 줄의 "승인 필요" 표시 (D116)
            Task { await session.checkWaitingTasks() }
            // 떠난 대화의 작업과 맥의 활동을 살펴 "진행 중"·안 읽음 점을 바꾼다 (D126)
            Task { await session.refreshConversationNews() }
        }
    }

    private func close() {
        model.isOpen = false
    }

    /// 줄을 눌렀을 때. 옆으로 밀다 뗀 것이면 누른 것으로 치지 않는다
    private func pick(_ action: () -> Void) {
        guard !model.swallowsTap() else { return }
        action()
        close()
    }

    // MARK: - 내용

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 위: 제목과 새 대화 단추 (D116: "새 대화"를 면을 깐 줄 대신 연필 단추로 — 고른 대화만 면이 깔리게)
            HStack {
                Text("대화")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(DS.Chat.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    pick {
                        // 이미 빈 대화면 그대로 둔다
                        if !session.messages.isEmpty { session.reset() }
                        model.screen = nil
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(DS.Chat.textPrimary)
                        .frame(width: DS.minTouch, height: DS.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!session.canSwitchConversation)
                .accessibilityLabel("새 대화")
            }
            // 닫는 단추는 두지 않는다: 밀려난 화면의 사이드바 단추가 바로 옆에 보여 같은 그림이 둘이 된다.
            // 닫는 것은 밀려난 화면을 누르거나 왼쪽으로 미는 것으로 한다
            .frame(minHeight: DS.minTouch)
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.top, 4)

            searchField
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

            // 서랍 전체가 한 번에 굴러간다 (D116): 메뉴가 늘어도 대화 목록 자리가 줄지 않는다
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if isSearching {
                        searchResults
                    } else {
                        menu
                        ChatHairline()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 12)
                        if session.workingElsewhere > 0 {
                            // 떠난 대화에서도 맥의 작업은 계속된다 (D126)
                            Label("다른 대화에서 작업 \(session.workingElsewhere)개가 맥에서 계속 돌고 있어요.", systemImage: "gearshape.2")
                                .font(.caption)
                                .foregroundStyle(DS.Chat.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                        }
                        if !session.canSwitchConversation, !conversations.isEmpty {
                            // 답을 받는 중에 옮기면 그 답이 옮겨 간 대화에 붙는다
                            Label("답을 받는 동안에는 다른 대화로 옮길 수 없어요. 답이 오면 옮길 수 있어요.", systemImage: "hourglass")
                                .font(.caption)
                                .foregroundStyle(DS.Chat.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                        }
                        if conversations.isEmpty {
                            Text("아직 대화 기록이 없어요.")
                                .font(.subheadline)
                                .foregroundStyle(DS.Chat.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                        ForEach(SidebarText.sections(conversations, now: .now), id: \.title) { section in
                            sectionHeader(section.title)
                            ForEach(section.items) { conversation in
                                row(conversation)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
            // 이 목록의 스크롤 선은 서랍의 오른쪽 끝(밀려난 화면과의 경계)에 붙어, 끄는 동안 손가락을 따라다녔다.
            // 끄는 동안은 굴리지 않고, 다 열려 멈춰 있을 때만 선을 보인다
            .sidebarScrollLock(model, inPanel: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 오른쪽 끝의 선은 밀려난 화면(둥근 카드)의 둘레 선이 대신한다
        .background(DS.Chat.card.ignoresSafeArea())
        // 열려 있는 동안 VoiceOver는 서랍 안만 읽는다. 두 손가락으로 문지르면(escape) 닫힌다
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
        .alert("대화 이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("이름", text: $renameText)
            Button("저장") {
                if let renaming { session.rename(renaming, to: renameText) }
                renaming = nil
            }
            Button("취소", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "이 대화를 지울까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("지우기", role: .destructive) {
                if let deleting { session.delete(deleting) }
                deleting = nil
            }
            Button("취소", role: .cancel) { deleting = nil }
        } message: {
            Text("이 아이폰에 남은 대화 기록이 지워져요. 되돌릴 수 없어요.")
        }
    }

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 대화 찾기 (D116. 예전의 "전체 보기" 대신): 이름과 마지막 말에서 찾는다
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(DS.Chat.textSecondary)
                .accessibilityHidden(true)
            TextField("대화 찾기", text: $search)
                .font(.subheadline)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Chat.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("찾는 글 지우기")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(DS.Chat.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var searchResults: some View {
        let found = SidebarText.matching(conversations, query: search)
        if found.isEmpty {
            Text("'\(search.trimmingCharacters(in: .whitespaces))'이(가) 들어간 대화가 없어요.")
                .font(.subheadline)
                .foregroundStyle(DS.Chat.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        } else {
            sectionHeader("찾은 대화 \(found.count)개")
            ForEach(found) { conversation in
                row(conversation)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if skills.isOffered {
            SidebarRow(icon: "square.grid.2x2", title: "맡길 수 있는 일") {
                pick { model.screen = .skills }
            }
        }
        if session.hasAgent {
            SidebarRow(icon: "desktopcomputer", title: "에이전트 작업") {
                pick { model.screen = .agentTasks }
            }
        }
        // 예약 (D91): 맥이 예약을 할 줄 알 때만
        if session.routines.isOffered {
            SidebarRow(icon: "clock.arrow.circlepath", title: "예약") {
                pick { model.screen = .routines }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(DS.Chat.textSecondary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// 대화 한 줄 (D116): 이름 · 시각 / 마지막 말 · 상태. 길게 누르면 이름 바꾸기·고정·지우기
    private func row(_ conversation: Conversation) -> some View {
        let isCurrent = session.conversation?.id == conversation.id
        let locked = !session.canSwitchConversation && !isCurrent
        return ConversationRow(
            title: conversation.title,
            preview: conversation.previewText,
            time: SidebarText.rowTime(conversation.updatedAt),
            isPinned: conversation.isPinned,
            badge: session.sidebarBadge(for: conversation),
            isUnread: !isCurrent && conversation.hasUnread,
            isSelected: isCurrent
        ) {
            pick {
                if !isCurrent { session.open(conversation) }
                model.screen = nil
            }
        }
        .disabled(locked)
        .contextMenu {
            Button("이름 바꾸기", systemImage: "pencil") {
                renameText = conversation.title
                renaming = conversation
            }
            Button(conversation.isPinned ? "고정 풀기" : "맨 위에 고정", systemImage: conversation.isPinned ? "pin.slash" : "pin") {
                session.setPinned(conversation, !conversation.isPinned)
                Haptic.select()
            }
            // 답을 받는 중인 대화는 지우지 않는다 (지우면 답이 새 대화로 남는다)
            if session.canSwitchConversation || !isCurrent {
                Button("지우기", systemImage: "trash", role: .destructive) { deleting = conversation }
            }
        }
    }
}

/// 대화 한 줄: 아이콘 없이 이름(+ 고정 표시)과 시각, 그 아래 마지막 말 또는 상태 (D116)
private struct ConversationRow: View {
    let title: String
    let preview: String?
    let time: String
    let isPinned: Bool
    let badge: AskSession.SidebarBadge?
    /// 마지막으로 본 뒤에 새 소식이 있다 (D126): 이름 앞에 점
    var isUnread = false
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isUnread {
                        Circle()
                            .fill(DS.Chat.userBubble)
                            .frame(width: 8, height: 8)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            .accessibilityLabel("새 소식")
                    }
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .accessibilityLabel("고정됨")
                    }
                    Text(title)
                        .font(.subheadline.weight(isSelected || isUnread ? .semibold : .medium))
                        .foregroundStyle(DS.Chat.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(time)
                        .font(.caption)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    if let badge {
                        badgeView(badge)
                    }
                    if let preview {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(filled: isSelected))
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("길게 누르면 이름 바꾸기·고정·지우기")
    }

    @ViewBuilder
    private func badgeView(_ badge: AskSession.SidebarBadge) -> some View {
        HStack(spacing: 4) {
            // 모아의 상태 그림 (D130)
            MoaStatusIcon(kind: badge == .working ? .running : (badge == .approval ? .approval : .reply), size: 14)
            Text(badge.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(badge == .working ? DS.Chat.textSecondary : MoaStatusIcon.orange)
        }
        .fixedSize()
    }
}

/// 사이드바 한 줄: 아이콘 + 제목(+ 아랫줄). 누르는 곳은 줄 전체다
private struct SidebarRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var trailingIcon: String?
    /// 맨 위 "새 대화"처럼 면을 깔아 두드러지게
    var isProminent = false
    /// 지금 보고 있는 대화
    var isSelected = false
    var showsChevron = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isProminent ? DS.Chat.textPrimary : DS.Chat.textSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(isProminent ? .body.weight(.semibold) : .body)
                        .foregroundStyle(DS.Chat.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DS.Chat.textSecondary)
                        .accessibilityHidden(true)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, subtitle == nil ? 0 : 7)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(filled: isProminent || isSelected))
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 누르는 동안과 고른 줄에 면을 깐다
private struct SidebarRowStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                (filled || configuration.isPressed) ? DS.Chat.elevated : .clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
    }
}

/// 사이드바와 에이전트 작업 목록에 쓰는 날짜 글
enum SidebarText {
    private static let locale = Locale(identifier: "ko_KR")

    /// "오늘", "어제", "11월 10일". 해가 다르면 "2025년 11월 10일"
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "오늘" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "어제"
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }

    /// 날짜와 시각: "오늘 오후 3:42", "11월 10일 오전 9:05". 같은 날 맡긴 일이 여럿일 때 가려 보게 한다
    static func dayTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()
        return "\(day(date, now: now, calendar: calendar)) \(date.formatted(time))"
    }

    /// 대화 줄 오른쪽의 시각 (D116): 오늘이면 "오전 9:27", 어제면 "어제", 이번 해면 "11월 10일", 그 전이면 "2025. 11. 10."
    static func rowTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        }
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).year().month(.defaultDigits).day())
        }
        return day(date, now: now, calendar: calendar)
    }

    /// 사이드바의 대화 묶음 (D116): 고정됨 → 오늘 → 어제 → 지난 7일 → 지난 30일 → 이전. 빈 묶음은 뺀다. 묶음 안은 최근 것부터
    static func sections<Item: SidebarDated>(_ items: [Item], now: Date, calendar: Calendar = .current) -> [(title: String, items: [Item])] {
        let order = ["고정됨", "오늘", "어제", "지난 7일", "지난 30일", "이전"]
        var buckets: [String: [Item]] = [:]
        let today = calendar.startOfDay(for: now)
        for item in items.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let key: String
            if item.isPinned {
                key = "고정됨"
            } else {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: item.updatedAt), to: today).day ?? 0
                key = days <= 0 ? "오늘" : days == 1 ? "어제" : days < 7 ? "지난 7일" : days < 30 ? "지난 30일" : "이전"
            }
            buckets[key, default: []].append(item)
        }
        return order.compactMap { key in buckets[key].map { (title: key, items: $0) } }
    }

    /// 이름이나 마지막 말에 찾는 글이 들어간 대화 (대소문자·앞뒤 빈칸 무시). 최근 것부터
    static func matching<Item: SidebarDated>(_ items: [Item], query: String) -> [Item] {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return [] }
        return items
            .filter { $0.title.localizedCaseInsensitiveContains(words) || ($0.previewText?.localizedCaseInsensitiveContains(words) ?? false) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 최근 대화의 아랫줄: 날짜, 그리고 맥 에이전트를 쓴 대화면 그 표시
    static func subtitle(for date: Date, usesAgent: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        let day = day(date, now: now, calendar: calendar)
        return usesAgent ? "\(day) · 맥 에이전트" : day
    }
}

/// 사이드바에 놓이는 대화 (테스트에서는 지어낸 값으로 바꿔 끼운다)
protocol SidebarDated {
    var title: String { get }
    var updatedAt: Date { get }
    var isPinned: Bool { get }
    var previewText: String? { get }
}

extension Conversation: SidebarDated {}
