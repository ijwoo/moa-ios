import Foundation
import Testing
@testable import MeetingSummary

/// 키보드가 오르내릴 때 대화를 같이 옮길 자리 (D54)
@MainActor
@Suite("키보드 따라가기")
struct KeyboardFollowTests {
    typealias Snapshot = KeyboardFollow.Snapshot

    /// 위 여백 116, 내용 2000. 키보드가 없으면 618, 있으면 393이 보인다
    private func snapshot(y: CGFloat, visible: CGFloat, content: CGFloat = 2000) -> Snapshot {
        Snapshot(offset: y - 116, contentHeight: content, topInset: 116, visibleHeight: visible)
    }

    @Test("맨 아래까지 남은 거리")
    func distance() {
        #expect(snapshot(y: 1382, visible: 618).distanceToBottom == 0)
        #expect(snapshot(y: 1332, visible: 618).distanceToBottom == 50)
        // 대화가 화면보다 짧으면 0보다 작다
        #expect(snapshot(y: 0, visible: 618, content: 300).distanceToBottom == -318)
    }

    @Test("맨 아래에 닿아 있으면 스크롤 뷰가 스스로 따라가므로 옮기지 않는다")
    func atBottom() {
        #expect(KeyboardFollow.target(old: snapshot(y: 1382, visible: 618), new: snapshot(y: 1382, visible: 393)) == nil)
    }

    @Test("대화가 화면보다 짧으면 옮기지 않는다")
    func shortConversation() {
        let old = snapshot(y: 0, visible: 618, content: 300)
        let new = snapshot(y: 0, visible: 393, content: 300)
        #expect(KeyboardFollow.target(old: old, new: new) == nil)
    }

    @Test("보이는 높이가 그대로면 옮기지 않는다")
    func sameHeight() {
        #expect(KeyboardFollow.target(old: snapshot(y: 500, visible: 618), new: snapshot(y: 520, visible: 618)) == nil)
    }

    @Test("키보드가 올라오면 줄어든 높이만큼 올리고, 내려가면 그만큼 내린다")
    func shift() {
        let up = KeyboardFollow.target(old: snapshot(y: 1332, visible: 618), new: snapshot(y: 1332, visible: 393))
        #expect(up == 1557)
        let down = KeyboardFollow.target(old: snapshot(y: 1557, visible: 393), new: snapshot(y: 1557, visible: 618))
        #expect(down == 1332)
    }

    @Test("내려갈 때 맨 위를 지나치지 않는다")
    func clampsAtTop() {
        let down = KeyboardFollow.target(old: snapshot(y: 100, visible: 393), new: snapshot(y: 100, visible: 618))
        #expect(down == 0)
    }

    @Test("높이가 먼저 바뀌고 곧 키보드 알림이 오면, 알림 때 옮긴다")
    func heightThenKeyboard() {
        let follow = KeyboardFollow()
        let start = ContinuousClock.now
        #expect(follow.visibleHeightChanged(old: snapshot(y: 1332, visible: 618), new: snapshot(y: 1332, visible: 393), now: start) == nil)
        #expect(follow.keyboardWillMove(now: start + .milliseconds(7)) == 1557)
        // 한 번만 옮긴다
        #expect(follow.keyboardWillMove(now: start + .milliseconds(20)) == nil)
    }

    @Test("키보드 알림이 먼저 오고 곧 높이가 바뀌면, 높이가 바뀔 때 옮긴다")
    func keyboardThenHeight() {
        let follow = KeyboardFollow()
        let start = ContinuousClock.now
        #expect(follow.keyboardWillMove(now: start) == nil)
        let y = follow.visibleHeightChanged(
            old: snapshot(y: 1332, visible: 618), new: snapshot(y: 1332, visible: 393), now: start + .milliseconds(4)
        )
        #expect(y == 1557)
    }

    @Test("키보드 없이 높이만 바뀌면 (입력칸이 여러 줄로 늘 때) 옮기지 않는다")
    func heightOnly() {
        let follow = KeyboardFollow()
        let start = ContinuousClock.now
        #expect(follow.visibleHeightChanged(old: snapshot(y: 1332, visible: 393), new: snapshot(y: 1332, visible: 371), now: start) == nil)
        // 한참 뒤에 온 키보드 알림은 그 일과 상관없다
        #expect(follow.keyboardWillMove(now: start + .milliseconds(900)) == nil)
    }

    @Test("한참 전에 온 키보드 알림은 지금 바뀐 높이와 상관없다")
    func staleKeyboard() {
        let follow = KeyboardFollow()
        let start = ContinuousClock.now
        #expect(follow.keyboardWillMove(now: start) == nil)
        let y = follow.visibleHeightChanged(
            old: snapshot(y: 1332, visible: 393), new: snapshot(y: 1332, visible: 371), now: start + .milliseconds(900)
        )
        #expect(y == nil)
    }

    @Test("맨 아래에서 높이가 바뀌면 기다리던 자리도 버린다")
    func bottomClearsPending() {
        let follow = KeyboardFollow()
        let start = ContinuousClock.now
        #expect(follow.visibleHeightChanged(old: snapshot(y: 1332, visible: 618), new: snapshot(y: 1332, visible: 393), now: start) == nil)
        #expect(follow.visibleHeightChanged(
            old: snapshot(y: 1607, visible: 393), new: snapshot(y: 1607, visible: 371), now: start + .milliseconds(5)
        ) == nil)
        #expect(follow.keyboardWillMove(now: start + .milliseconds(7)) == nil)
    }

    @Test("내려갈 때 시간이 0으로 오면 앞서 받은 시간을 그대로 쓴다")
    func keepsLastTiming() {
        let follow = KeyboardFollow()
        #expect(follow.timing == nil)
        _ = follow.keyboardWillMove(timing: .init(duration: 0.3833, curve: 7))
        #expect(follow.timing == .init(duration: 0.3833, curve: 7))
        _ = follow.keyboardWillMove(timing: .init(duration: 0, curve: 7))
        #expect(follow.timing == .init(duration: 0.3833, curve: 7))
        _ = follow.keyboardWillMove(timing: nil)
        #expect(follow.timing == .init(duration: 0.3833, curve: 7))
    }

    // MARK: 쉬는 자리 바로잡기 (D69)

    @Test("맨 아래를 지나 멈춰 있으면 맨 아래로 돌려놓는다 (키보드는 내려갔는데 대화가 떠 있는 것)")
    func restsPastBottom() {
        // 키보드가 있던 때의 맨 아래(1607)에 그대로 있다: 마지막 말 아래가 225만큼 빈다
        let floating = snapshot(y: 1607, visible: 618)
        #expect(floating.distanceToBottom == -225)
        #expect(KeyboardFollow.restingTarget(for: floating) == 1382)
    }

    @Test("맨 아래에 있거나 위로 올려 읽는 중이면 그대로 둔다")
    func restsFine() {
        #expect(KeyboardFollow.restingTarget(for: snapshot(y: 1382, visible: 618)) == nil)
        #expect(KeyboardFollow.restingTarget(for: snapshot(y: 700, visible: 618)) == nil)
        #expect(KeyboardFollow.restingTarget(for: snapshot(y: 0, visible: 618)) == nil)
    }

    @Test("화면보다 짧은 대화가 위로 밀려 있으면 맨 위로 돌려놓는다")
    func restsShortConversation() {
        #expect(KeyboardFollow.restingTarget(for: snapshot(y: 0, visible: 618, content: 300)) == nil)
        #expect(KeyboardFollow.restingTarget(for: snapshot(y: 225, visible: 618, content: 300)) == 0)
    }

    @Test("손을 대고 있는 동안에는 고치지 않는다")
    func noCorrectionWhileMoving() {
        let follow = KeyboardFollow()
        #expect(follow.restingCorrection() == nil)
        follow.note(snapshot(y: 1607, visible: 618))
        follow.isIdle = false
        #expect(follow.restingCorrection() == nil)
        follow.isIdle = true
        #expect(follow.restingCorrection() == 1382)
    }

    @Test("짧은 사이에 여러 번 고쳤으면 더 고치지 않고, 시간이 지나면 다시 고친다")
    func correctionLimit() {
        let follow = KeyboardFollow()
        follow.note(snapshot(y: 1607, visible: 618))
        let start = ContinuousClock.now
        for step in 0..<KeyboardFollow.correctionLimit {
            #expect(follow.restingCorrection(now: start + .milliseconds(100 * step)) == 1382)
        }
        #expect(follow.restingCorrection(now: start + .milliseconds(500)) == nil)
        #expect(follow.restingCorrection(now: start + .seconds(3)) == 1382)
    }

    @Test("스크롤 뷰를 모르면 키보드 움직임에 태우지 못한다")
    func noScrollView() {
        let follow = KeyboardFollow()
        _ = follow.keyboardWillMove(timing: .init(duration: 0.3833, curve: 7))
        #expect(follow.scrollWithKeyboard(to: 100) == false)
    }
}
