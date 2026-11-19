import SwiftUI

/// 키보드가 오르내릴 때 대화가 입력창과 같이 움직이게 한다 (D54).
///
/// 맨 아래에 닿아 있을 때는 스크롤 뷰가 스스로 아래를 붙잡는다 (`defaultScrollAnchor(.bottom, for: .sizeChanges)`).
/// 하지만 조금이라도 올라가 있으면 스크롤 뷰는 위쪽 자리를 지키고, 키보드와 입력창만 올라와 마지막 말을 덮는다.
/// 그때는 보이는 높이가 줄어든 만큼 대화를 직접 올린다 (내릴 때는 그만큼 내린다).
/// 옮기는 일은 키보드와 같은 시간·같은 모양의 움직임에 태운다 (`scrollWithKeyboard`). 그래야 프레임마다 입력창과 같이 간다.
///
/// 보이는 높이는 입력칸이 여러 줄로 늘 때도 바뀐다. 키보드 때문에 바뀐 것만 따라가도록,
/// "높이가 바뀌었다"와 "키보드가 움직인다"가 거의 같은 때에 왔을 때만 옮긴다 (어느 쪽이 먼저 오는지는 정해져 있지 않다).
@MainActor
final class KeyboardFollow {
    /// 스크롤 뷰에서 읽은 값 가운데 여기에 쓰는 것
    struct Snapshot: Equatable {
        /// 스크롤된 자리 (맨 위에서 `-topInset`)
        var offset: CGFloat
        var contentHeight: CGFloat
        var topInset: CGFloat
        /// 위아래 막대와 키보드를 뺀, 대화가 보이는 높이
        var visibleHeight: CGFloat

        init(offset: CGFloat, contentHeight: CGFloat, topInset: CGFloat, visibleHeight: CGFloat) {
            self.offset = offset
            self.contentHeight = contentHeight
            self.topInset = topInset
            self.visibleHeight = visibleHeight
        }

        init(_ geometry: ScrollGeometry) {
            // `contentInsets.bottom`은 키보드가 내려간 뒤에도 옛 값으로 남을 때가 있어 쓰지 않는다
            self.init(
                offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                topInset: geometry.contentInsets.top, visibleHeight: geometry.containerSize.height
            )
        }

        /// 맨 아래까지 남은 거리. 대화가 화면보다 짧으면 0보다 작다
        var distanceToBottom: CGFloat { contentHeight - offset - topInset - visibleHeight }
    }

    /// 두 일이 이 시간 안에 이어서 왔으면 같은 일로 본다
    static let window: Duration = .milliseconds(200)
    /// 키보드의 움직임에 태울 수 없을 때 대신 쓰는, 키보드와 비슷하게 맞춘 움직임 (iOS 26 시뮬레이터에서 프레임을 재서 맞췄다)
    static let animation: Animation = .interpolatingSpring(mass: 1, stiffness: 576, damping: 48)

    /// 키보드가 움직이는 시간과 모양 (키보드 알림에 들어 있다)
    struct Timing: Equatable {
        var duration: TimeInterval
        var curve: UInt

        init(duration: TimeInterval, curve: UInt) {
            self.duration = duration
            self.curve = curve
        }

        init?(_ note: Notification) {
            guard let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
                  let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt else { return nil }
            self.init(duration: duration, curve: curve)
        }
    }

    private var pendingTarget: (at: ContinuousClock.Instant, y: CGFloat)?
    private var keyboardMovedAt: ContinuousClock.Instant?
    /// 가장 최근에 키보드가 움직인 시간과 모양
    private(set) var timing: Timing?
    /// 대화를 담은 스크롤 뷰. 대화 안에 넣어 둔 빈 뷰(`Probe`)가 찾아 준다
    fileprivate weak var scrollView: UIScrollView?

    /// 보이는 높이가 `old`에서 `new`로 바뀌었을 때 스크롤을 옮겨 갈 자리.
    /// 높이가 그대로거나, 맨 아래에 닿아 있거나(스크롤 뷰가 스스로 따라간다), 대화가 화면보다 짧으면 nil
    static func target(old: Snapshot, new: Snapshot) -> CGFloat? {
        let change = old.visibleHeight - new.visibleHeight
        guard change != 0, old.distanceToBottom > 0.5 else { return nil }
        // `ScrollPosition`의 세로 자리는 맨 위에 있을 때가 0이다 (`contentOffset`에 위 여백을 더한 값). 내려갈 때 맨 위를 지나치지 않는다
        return max(0, new.offset + new.topInset + change)
    }

    /// 보이는 높이가 바뀌었다. 지금 옮겨야 하면 그 자리를 돌려준다
    func visibleHeightChanged(old: Snapshot, new: Snapshot, now: ContinuousClock.Instant = .now) -> CGFloat? {
        guard old.visibleHeight != new.visibleHeight else { return nil }
        guard let y = Self.target(old: old, new: new) else {
            pendingTarget = nil
            return nil
        }
        if let moved = keyboardMovedAt, now - moved < Self.window {
            keyboardMovedAt = nil
            return y
        }
        pendingTarget = (now, y)
        return nil
    }

    /// 키보드가 올라오거나 내려가기 시작했다. 지금 옮겨야 하면 그 자리를 돌려준다
    func keyboardWillMove(timing: Timing? = nil, now: ContinuousClock.Instant = .now) -> CGFloat? {
        // 내려갈 때는 시간이 0으로 올 때가 있다 (그래도 키보드는 올라올 때처럼 움직인다). 그때는 앞서 받은 값을 그대로 쓴다
        if let timing, timing.duration > 0 { self.timing = timing }
        if let pending = pendingTarget, now - pending.at < Self.window {
            pendingTarget = nil
            return pending.y
        }
        pendingTarget = nil
        keyboardMovedAt = now
        return nil
    }

    // MARK: 쉬는 자리 바로잡기 (D69)
    //
    // 스크롤 뷰가 "키보드가 있던 때의 맨 아래"에 멈춰 있을 때가 있다. 그러면 키보드는 내려갔는데 대화는 키보드 높이만큼 떠 있고,
    // 마지막 말 아래가 비어 보인다 (필요할 때 만드는 목록을 쓰던 때에 iOS 26 시뮬레이터에서 8번에 3번. 지금은 말을 한꺼번에 놓아 원인을 없앴다).
    // 그래도 손을 대지 않았는데 맨 아래를 지난 자리에 멈춰 있으면 돌려놓는다. 그 자리는 언제나 잘못된 자리라 고쳐서 나빠질 일이 없다.

    /// 자리가 바뀐 뒤 이만큼 조용하면 쉬는 자리로 본다 (움직이는 동안에는 기다린다)
    static let settleDelay: Duration = .milliseconds(80)
    /// 이 시간 안에 이만큼 고쳤으면 더 고치지 않는다 (서로 밀고 당기지 않게)
    static let correctionWindow: Duration = .seconds(2)
    static let correctionLimit = 4

    /// 손으로 밀거나 미는 힘으로 움직이는 중이 아닌지 (스크롤 뷰가 알려 준다)
    var isIdle = true
    private var latest: Snapshot?
    private var corrections: [ContinuousClock.Instant] = []
    private var settleTask: Task<Void, Never>?

    /// 쉬고 있는 자리가 잘못되어 있으면 가야 할 자리, 괜찮으면 nil.
    /// - 맨 아래를 지나 있다 (마지막 말 아래가 빈다): 맨 아래로
    /// - 화면보다 짧은 대화가 위로 밀려 있다: 맨 위로
    static func restingTarget(for snapshot: Snapshot) -> CGFloat? {
        guard snapshot.contentHeight > snapshot.visibleHeight else {
            return snapshot.offset + snapshot.topInset > 0.5 ? 0 : nil
        }
        guard snapshot.distanceToBottom < -0.5 else { return nil }
        return snapshot.contentHeight - snapshot.visibleHeight
    }

    /// 스크롤 뷰가 알려 준 지금 자리를 적어 둔다
    func note(_ snapshot: Snapshot) {
        latest = snapshot
    }

    /// 지금 쉬고 있는 자리가 잘못되어 있으면 가야 할 자리. 손을 대고 있거나, 짧은 사이에 이미 여러 번 고쳤으면 nil
    func restingCorrection(now: ContinuousClock.Instant = .now) -> CGFloat? {
        guard isIdle, let latest, let y = Self.restingTarget(for: latest) else { return nil }
        corrections.removeAll { now - $0 > Self.correctionWindow }
        guard corrections.count < Self.correctionLimit else { return nil }
        corrections.append(now)
        return y
    }

    /// 자리가 조용해진 뒤에 쉬는 자리를 살펴, 고칠 곳이 있으면 `move`에 넘긴다. 그 사이 또 부르면 처음부터 다시 기다린다
    func correctAfterSettling(_ move: @escaping @MainActor (CGFloat) -> Void) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let y = self?.restingCorrection() else { return }
            move(y)
        }
    }

    /// 대화를 `y` 자리로 옮기는 일을 키보드와 똑같은 움직임에 태운다 (같은 시간, 같은 모양이라 프레임마다 입력창과 같이 간다).
    /// 스크롤 뷰를 찾지 못했거나 키보드가 움직이는 시간을 모르면 아무것도 하지 않고 false
    func scrollWithKeyboard(to y: CGFloat) -> Bool {
        guard let timing, timing.duration > 0, let scrollView else { return false }
        // `y`는 맨 위에 있을 때가 0인 자리다. 스크롤 뷰의 자리는 거기서 위 여백을 뺀 값
        let offset = CGPoint(x: scrollView.contentOffset.x, y: y - scrollView.adjustedContentInset.top)
        UIView.animate(
            withDuration: timing.duration, delay: 0,
            options: [UIView.AnimationOptions(rawValue: timing.curve << 16), .beginFromCurrentState, .allowUserInteraction]
        ) {
            scrollView.contentOffset = offset
        }
        return true
    }

    /// 대화 내용 뒤에 깔아 두는 빈 뷰. 보이지 않고 누를 수도 없다. 화면에 붙을 때 자기를 담은 스크롤 뷰를 알려 준다
    struct Probe: UIViewRepresentable {
        let follow: KeyboardFollow

        func makeUIView(context: Context) -> ProbeView {
            let view = ProbeView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            view.follow = follow
            return view
        }

        func updateUIView(_ view: ProbeView, context: Context) {
            view.follow = follow
        }
    }

    final class ProbeView: UIView {
        weak var follow: KeyboardFollow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    follow?.scrollView = scrollView
                    return
                }
                view = current.superview
            }
        }
    }
}
