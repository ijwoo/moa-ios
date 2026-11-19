import SwiftUI
import UIKit

// 대화를 왼쪽으로 미는 손길 (D68).
// 말풍선 위에서 밀기 시작하면 그 말에 답장하고, 빈 곳에서 시작하면 말마다 보낸 시각이 오른쪽에서 나온다.
// 오른쪽으로 미는 것은 사이드바의 몫이다 (`sidebarDrag`, D55). 세로로 시작한 손길은 스크롤이라 건드리지 않는다.

/// 왼쪽으로 미는 손길 하나가 무엇을 하는 중인지와 얼마나 밀었는지
@MainActor
@Observable
final class ChatSwipeModel {
    enum Mode: Equatable {
        /// 대화 전체가 밀리고 보낸 시각이 나온다
        case times
        /// 이 말만 밀린다. 충분히 밀고 놓으면 이 말에 답장한다
        case reply(AskSession.Message.ID)
    }

    /// 시각 글자의 폭
    static let timeWidth: CGFloat = 68
    /// 말이 끝나는 곳과 시각 사이. 대화 양옆 여백(16)보다 커야 평소에 시각이 화면 밖에 있다
    static let timeGap: CGFloat = 20
    /// 시각이 다 나오는 거리. 대화는 여기까지만 밀린다
    static var maxTimeShift: CGFloat { timeWidth + timeGap }
    /// 이만큼 밀고 놓으면 답장이다
    static let replyThreshold: CGFloat = 52
    /// 말풍선이 밀리는 끝
    static let maxReplyShift: CGFloat = 76

    private(set) var mode: Mode?
    /// 왼쪽으로 밀려 있는 거리 (0 이상)
    private(set) var shift: CGFloat = 0

    /// 답장할 수 있는 말풍선이 화면에서 차지한 자리 (화면 전체 기준). 손길이 어디서 시작했는지 가릴 때만 쓴다
    @ObservationIgnored private var frames: [AskSession.Message.ID: CGRect] = [:]
    /// 이번 손길을 따라갈지. 처음 움직인 방향으로 한 번 정하면 손을 뗄 때까지 바꾸지 않는다
    private enum Lock {
        /// `startX`: 따라가기 시작할 때까지 손가락이 가로로 움직인 거리
        case tracking(startX: CGFloat)
        case ignored
    }
    @ObservationIgnored private var lock: Lock?

    /// 대화 전체가 밀려 있는 거리
    var timeShift: CGFloat { mode == .times ? shift : 0 }

    /// 이 말이 밀려 있는 거리
    func replyShift(for id: AskSession.Message.ID) -> CGFloat {
        mode == .reply(id) ? shift : 0
    }

    /// 왼쪽으로 미는 손길을 따라가는 동안에는 대화의 위아래 스크롤을 잠근다 (D82).
    /// 손가락은 곧게 옆으로만 가지 않는다: 잠그지 않으면 시각을 보려고 미는 동안 대화가 위아래로 같이 흔들린다.
    /// 세로로 시작한 손길은 따라가지 않으므로(`ignored`) 스크롤은 그대로다
    var locksScroll: Bool { mode != nil }

    /// 지금 놓으면 답장이 되는지
    var isArmed: Bool {
        if case .reply = mode { shift >= Self.replyThreshold } else { false }
    }

    /// 말풍선의 자리를 알린다. 화면에서 사라지면 nil
    func setFrame(_ frame: CGRect?, for id: AskSession.Message.ID) {
        frames[id] = frame
    }

    /// 그 자리에 있는, 답장할 수 있는 말
    func target(at point: CGPoint) -> AskSession.Message.ID? {
        frames.first { $0.value.contains(point) }?.key
    }

    /// 손가락이 움직일 때마다 부른다 (`translation`: 처음 닿은 곳에서 움직인 거리, `start`: 처음 닿은 곳).
    /// 왼쪽으로 시작한 손길만 따라간다. `enabled`가 거짓이면(사이드바가 열려 있을 때) 따라가지 않는다.
    /// 따라가기 시작한 그 순간에만 true를 돌려준다
    @discardableResult
    func dragChanged(translation: CGSize, start: CGPoint, enabled: Bool = true) -> Bool {
        switch lock {
        case .ignored:
            return false
        case .tracking(let startX):
            guard let mode else { return false }
            shift = Self.shift(pulled: startX - translation.width, mode: mode)
            return false
        case nil:
            let isHorizontal = abs(translation.width) > abs(translation.height)
            guard enabled, isHorizontal, translation.width < 0 else {
                lock = .ignored
                return false
            }
            // 알아채기까지 움직인 만큼은 빼고 따라간다 (그래야 처음에 툭 튀지 않는다)
            lock = .tracking(startX: translation.width)
            mode = target(at: start).map(Mode.reply) ?? .times
            shift = 0
            return true
        }
    }

    /// 손을 뗐다. 답장할 말이 있으면 돌려준다
    func dragEnded() -> AskSession.Message.ID? {
        defer { reset() }
        guard case .reply(let id) = mode, shift >= Self.replyThreshold else { return nil }
        return id
    }

    /// 손길이 끝났다는 말 없이 끊겼다 (전화, 다른 손길). 답장하지 않고 제자리로 돌린다
    func dragCancelled() {
        reset()
    }

    private func reset() {
        lock = nil
        mode = nil
        shift = 0
    }

    /// 손가락이 왼쪽으로 간 거리(`pulled`)만큼 화면이 밀리는 거리.
    /// 시각은 다 나오면 멈춘다. 말풍선은 답장이 되는 곳을 지나면 뻑뻑해지고, 끝에서 멈춘다
    static func shift(pulled: CGFloat, mode: Mode) -> CGFloat {
        let pulled = max(0, pulled)
        switch mode {
        case .times:
            return min(pulled, maxTimeShift)
        case .reply:
            guard pulled > replyThreshold else { return pulled }
            return min(replyThreshold + (pulled - replyThreshold) * 0.3, maxReplyShift)
        }
    }

    /// 놓았을 때 돌아가는 움직임
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.1)
    }

    // MARK: - 보낸 시각

    /// 말 옆에 보이는 시각. 오늘 보낸 말은 "오전 9:52"만, 다른 날의 말은 그 위에 날짜("11월 13일", 다른 해면 "2025. 11. 13.")를 둔다
    static func stamp(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> (day: String?, time: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "a h:mm"
        let time = formatter.string(from: date)
        guard !calendar.isDate(date, inSameDayAs: now) else { return (nil, time) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "M월 d일" : "yyyy. M. d."
        return (formatter.string(from: date), time)
    }

    #if DEBUG
    /// 개발용: 밀고 있는 도중의 화면을 만든다 (`-demoSwipe times|reply`)
    func demo(_ mode: Mode) {
        self.mode = mode
        shift = mode == .times ? Self.maxTimeShift : Self.replyThreshold + 8
    }
    #endif
}

// MARK: - 손길

/// 대화 영역을 왼쪽으로 미는 손길.
/// SwiftUI의 `DragGesture`를 나란히 붙이면(사이드바처럼) 카드나 단추 위에서 밀다 손을 뗄 때 그것이 눌린다.
/// 그래서 UIKit의 손길로 받는다: 왼쪽으로 민 것으로 알아챈 순간 그 손가락의 다른 누름(단추, 길게 누르기)은 취소된다. 스크롤이 단추를 취소하는 것과 같은 방식이다
private struct ChatSwipeGesture: ViewModifier {
    let model: ChatSwipeModel
    /// 지금 받아도 되는지 (사이드바가 닫혀 있을 때만)
    let isEnabled: () -> Bool
    let onReply: (AskSession.Message.ID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .gesture(SidePan(toward: .left, isEnabled: isEnabled) { translation, start in
                model.dragChanged(translation: translation, start: start)
            } onEnded: { finished in
                var replied: AskSession.Message.ID?
                withAnimation(ChatSwipeModel.animation(reduceMotion: reduceMotion)) {
                    // 끊긴 손길(전화, 다른 손길)은 답장하지 않고 제자리로 돌린다
                    if finished { replied = model.dragEnded() } else { model.dragCancelled() }
                }
                if let replied { onReply(replied) }
            })
            // 미는 동안에는 위아래로 움직이지 않는다. 이미 시작된 스크롤도 여기서 멈춘다 (손을 떼면 풀린다)
            .scrollDisabled(model.locksScroll)
            // 답장이 되는 곳을 지날 때 한 번 톡
            .sensoryFeedback(trigger: model.isArmed) { _, armed in armed ? .impact(weight: .light) : nil }
    }
}

/// 한쪽으로 시작한 가로 손길만 받는 UIKit 손길. 세로(스크롤)와 반대쪽으로 시작한 손길은 시작하지 않는다.
/// SwiftUI의 `DragGesture`를 나란히 붙이면 손가락 밑의 단추가 손을 뗄 때 눌려서 (승인 단추도) UIKit 손길로 받는다.
/// 왼쪽은 대화 밀기(시각·답장), 오른쪽은 사이드바를 끌 때 누름을 취소하는 데 쓴다 (`SidebarDragShield`)
struct SidePan: UIGestureRecognizerRepresentable {
    enum Side { case left, right }

    /// 이쪽으로 시작한 손길만 받는다
    let toward: Side
    let isEnabled: () -> Bool
    /// 처음 닿은 곳에서 움직인 거리와 처음 닿은 곳 (화면 전체 기준)
    let onChanged: (CGSize, CGPoint) -> Void
    /// 참: 손을 뗐다. 거짓: 끊겼다
    let onEnded: (Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        context.coordinator.toward = toward
        context.coordinator.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.toward = toward
        context.coordinator.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            let moved = context.coordinator.moved(recognizer)
            onChanged(CGSize(width: moved.x, height: moved.y), context.coordinator.start)
        case .ended:
            onEnded(true)
        case .cancelled, .failed:
            onEnded(false)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var toward = Side.left
        var isEnabled: () -> Bool = { true }
        /// 손가락이 처음 닿은 곳 (화면 전체 기준)
        private(set) var start: CGPoint = .zero

        /// 처음 닿은 곳에서 움직인 거리. 밀리는 말풍선이 아니라 움직이지 않는 화면 전체(창)를 기준으로 잰다.
        /// `translation(in:)`은 쓰지 않는다: 손길을 알아채기까지 움직인 만큼(10pt)을 빼고 알려 줘서,
        /// 시작할 때 (0, 0)이 나오기도 하고 방향을 가릴 수 없다
        func moved(_ recognizer: UIGestureRecognizer) -> CGPoint {
            let location = recognizer.location(in: nil)
            return CGPoint(x: location.x - start.x, y: location.y - start.y)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if recognizer.numberOfTouches == 0 { start = touch.location(in: nil) }
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled() else { return false }
            let moved = moved(recognizer)
            return (toward == .left ? moved.x < 0 : moved.x > 0) && abs(moved.x) > abs(moved.y)
        }

        /// 다른 손길과 나란히 간다. 그러지 않으면 빠르게 밀 때 사이드바 손길이 같은 순간에 먼저 알아채서 이 손길이 시작하지 못한다
        /// (손가락이 한 번에 16pt 넘게 움직인 때). 나란히 가도 손가락 밑 단추의 누름은 이 손길이 시작할 때 취소된다
        /// (스크롤이 시작될 때처럼). 대화가 손가락을 따라 움직여도 손을 뗄 때 단추가 눌리지 않는 것은 그래서다
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// 대화 전체를 시각이 나오는 만큼 옮긴다. 밀린 거리를 여기서만 읽어, 미는 동안 대화 화면 전체를 다시 그리지 않는다
private struct ChatTimeShift: ViewModifier {
    @Environment(ChatSwipeModel.self) private var swipe

    func body(content: Content) -> some View {
        content.offset(x: -swipe.timeShift)
    }
}

/// 말 한 줄: 답장으로 밀리는 만큼 옮기고, 빈 자리에 답장 표시를, 오른쪽 화면 바깥에 보낸 시각을 둔다
private struct ChatSwipeRow: ViewModifier {
    let id: AskSession.Message.ID
    let date: Date

    @Environment(ChatSwipeModel.self) private var swipe

    func body(content: Content) -> some View {
        let shift = swipe.replyShift(for: id)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: -shift)
            .overlay(alignment: .trailing) {
                if shift > 0 {
                    ReplyHint(shift: shift)
                }
            }
            // 시각은 줄의 오른쪽 끝 바깥(화면 밖)에 있다가, 대화 전체가 밀릴 때 따라 들어온다.
            // 이 줄만 밀릴 때(답장)는 제자리에 있어 보이지 않는다
            .overlay(alignment: .trailing) {
                MessageTimeLabel(date: date)
                    .offset(x: ChatSwipeModel.timeGap + ChatSwipeModel.timeWidth)
            }
    }
}

/// 말풍선이 밀려난 자리에 나타나는 답장 표시. 답장이 되는 곳을 지나면 색이 찬다
private struct ReplyHint: View {
    let shift: CGFloat

    private static let side: CGFloat = 32

    var body: some View {
        let progress = min(1, shift / ChatSwipeModel.replyThreshold)
        let armed = shift >= ChatSwipeModel.replyThreshold
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(armed ? DS.Chat.onUserBubble : DS.Chat.textSecondary)
            .frame(width: Self.side, height: Self.side)
            .background(armed ? DS.Chat.userBubble : DS.Chat.elevated, in: Circle())
            .scaleEffect(0.6 + 0.4 * progress)
            .opacity(progress)
            // 밀려난 자리의 가운데에 둔다 (조금 밀었을 때 말풍선과 겹치지 않게)
            .offset(x: max(0, (Self.side - shift) / 2))
            .animation(.snappy(duration: 0.15), value: armed)
            .accessibilityHidden(true)
    }
}

/// 말 옆의 보낸 시각
private struct MessageTimeLabel: View {
    let date: Date

    var body: some View {
        let stamp = ChatSwipeModel.stamp(date)
        VStack(alignment: .trailing, spacing: 1) {
            if let day = stamp.day {
                Text(day).font(.caption2)
            }
            Text(stamp.time).font(.footnote)
        }
        .monospacedDigit()
        .foregroundStyle(DS.Chat.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: ChatSwipeModel.timeWidth, alignment: .trailing)
        // 폭이 정해진 자리라 글자가 아주 커지면 잘린다
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        // 화면 밖에 있는 글자다. VoiceOver로는 읽지 않는다
        .accessibilityHidden(true)
    }
}

/// 답장할 수 있는 말풍선: 자리를 알려, 그 위에서 시작한 손길을 답장으로 받게 한다
private struct ChatSwipeTarget: ViewModifier {
    let id: AskSession.Message.ID
    let isEnabled: Bool

    @Environment(ChatSwipeModel.self) private var swipe: ChatSwipeModel?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                swipe?.setFrame(isEnabled ? frame : nil, for: id)
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { swipe?.setFrame(nil, for: id) }
            }
            .onDisappear { swipe?.setFrame(nil, for: id) }
    }
}

extension View {
    /// 이 위에서 왼쪽으로 밀면 답장하거나(말풍선 위) 보낸 시각을 본다(빈 곳)
    func chatSwipe(
        _ model: ChatSwipeModel, isEnabled: @escaping () -> Bool, onReply: @escaping (AskSession.Message.ID) -> Void
    ) -> some View {
        modifier(ChatSwipeGesture(model: model, isEnabled: isEnabled, onReply: onReply))
    }

    /// 대화 목록 전체에 붙인다
    func chatTimeShift() -> some View { modifier(ChatTimeShift()) }

    /// 말 한 줄에 붙인다
    func chatSwipeRow(id: AskSession.Message.ID, date: Date) -> some View {
        modifier(ChatSwipeRow(id: id, date: date))
    }

    /// 답장할 수 있는 말풍선에 붙인다
    func chatSwipeTarget(_ id: AskSession.Message.ID, isEnabled: Bool) -> some View {
        modifier(ChatSwipeTarget(id: id, isEnabled: isEnabled))
    }
}
