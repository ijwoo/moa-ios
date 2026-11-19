import CoreGraphics
import Foundation
import Testing
@testable import MeetingSummary

@MainActor
@Suite("대화를 왼쪽으로 밀기")
struct ChatSwipeTests {
    private let bubble = UUID()
    /// 말풍선 하나가 (100, 200)에서 200×60을 차지한다
    private func model() -> ChatSwipeModel {
        let model = ChatSwipeModel()
        model.setFrame(CGRect(x: 100, y: 200, width: 200, height: 60), for: bubble)
        return model
    }

    private let onBubble = CGPoint(x: 150, y: 220)
    private let onEmpty = CGPoint(x: 50, y: 500)

    private func size(_ width: CGFloat, _ height: CGFloat = 0) -> CGSize {
        CGSize(width: width, height: height)
    }

    // MARK: - 보낸 시각

    @Test("빈 곳을 왼쪽으로 밀면 대화 전체가 밀리고, 시각이 다 나오면 멈춘다")
    func emptySpaceShowsTimes() {
        let model = model()
        #expect(model.dragChanged(translation: size(-16), start: onEmpty))
        #expect(model.mode == .times)
        #expect(model.timeShift == 0)
        model.dragChanged(translation: size(-56), start: onEmpty)
        #expect(model.timeShift == 40)
        #expect(model.replyShift(for: bubble) == 0)
        model.dragChanged(translation: size(-400), start: onEmpty)
        #expect(model.timeShift == ChatSwipeModel.maxTimeShift)
        // 되돌아가면 따라 돌아오고, 처음보다 오른쪽으로는 가지 않는다
        model.dragChanged(translation: size(-26), start: onEmpty)
        #expect(model.timeShift == 10)
        model.dragChanged(translation: size(30), start: onEmpty)
        #expect(model.timeShift == 0)
    }

    @Test("시각을 보다가 손을 떼면 제자리로 돌아가고 답장은 없다")
    func timesEndWithoutReply() {
        let model = model()
        model.dragChanged(translation: size(-16), start: onEmpty)
        model.dragChanged(translation: size(-200), start: onEmpty)
        #expect(!model.isArmed)
        #expect(model.dragEnded() == nil)
        #expect(model.mode == nil)
        #expect(model.timeShift == 0)
    }

    // MARK: - 답장

    @Test("말풍선 위에서 밀기 시작하면 그 말만 밀린다")
    func bubbleStartsReply() {
        let model = model()
        #expect(model.dragChanged(translation: size(-16), start: onBubble))
        #expect(model.mode == .reply(bubble))
        model.dragChanged(translation: size(-46), start: onBubble)
        #expect(model.replyShift(for: bubble) == 30)
        #expect(model.replyShift(for: UUID()) == 0)
        #expect(model.timeShift == 0)
        #expect(!model.isArmed)
    }

    @Test("조금만 밀고 놓으면 답장하지 않는다")
    func shortPullDoesNotReply() {
        let model = model()
        model.dragChanged(translation: size(-16), start: onBubble)
        model.dragChanged(translation: size(-16 - ChatSwipeModel.replyThreshold + 1), start: onBubble)
        #expect(!model.isArmed)
        #expect(model.dragEnded() == nil)
        #expect(model.replyShift(for: bubble) == 0)
    }

    @Test("충분히 밀고 놓으면 그 말에 답장한다")
    func longPullReplies() {
        let model = model()
        model.dragChanged(translation: size(-16), start: onBubble)
        model.dragChanged(translation: size(-16 - ChatSwipeModel.replyThreshold), start: onBubble)
        #expect(model.isArmed)
        #expect(model.dragEnded() == bubble)
        #expect(model.mode == nil)
        #expect(model.replyShift(for: bubble) == 0)
        #expect(!model.isArmed)
    }

    @Test("충분히 밀었다가 되돌리고 놓으면 답장하지 않는다")
    func pullBackCancels() {
        let model = model()
        model.dragChanged(translation: size(-16), start: onBubble)
        model.dragChanged(translation: size(-120), start: onBubble)
        #expect(model.isArmed)
        model.dragChanged(translation: size(-30), start: onBubble)
        #expect(!model.isArmed)
        #expect(model.dragEnded() == nil)
    }

    @Test("답장이 되는 곳을 지나면 뻑뻑해지고 끝에서 멈춘다")
    func replyDamping() {
        let threshold = ChatSwipeModel.replyThreshold
        #expect(ChatSwipeModel.shift(pulled: 20, mode: .reply(bubble)) == 20)
        #expect(ChatSwipeModel.shift(pulled: threshold, mode: .reply(bubble)) == threshold)
        #expect(abs(ChatSwipeModel.shift(pulled: threshold + 20, mode: .reply(bubble)) - (threshold + 6)) < 0.001)
        #expect(ChatSwipeModel.shift(pulled: 1000, mode: .reply(bubble)) == ChatSwipeModel.maxReplyShift)
        #expect(ChatSwipeModel.shift(pulled: -30, mode: .reply(bubble)) == 0)
        #expect(ChatSwipeModel.shift(pulled: -30, mode: .times) == 0)
    }

    @Test("끊긴 손길은 충분히 밀었어도 답장하지 않는다")
    func cancelDoesNotReply() {
        let model = model()
        model.dragChanged(translation: size(-16), start: onBubble)
        model.dragChanged(translation: size(-200), start: onBubble)
        model.dragCancelled()
        #expect(model.mode == nil)
        #expect(model.replyShift(for: bubble) == 0)
        #expect(model.dragEnded() == nil)
    }

    // MARK: - 받지 않는 손길

    @Test("오른쪽으로 시작한 손길은 받지 않는다 (사이드바의 몫). 도중에 왼쪽으로 꺾어도 그대로다")
    func rightwardIgnored() {
        let model = model()
        #expect(!model.dragChanged(translation: size(16), start: onBubble))
        #expect(model.mode == nil)
        model.dragChanged(translation: size(-200), start: onBubble)
        #expect(model.mode == nil)
        #expect(model.dragEnded() == nil)
    }

    @Test("세로로 시작한 손길은 받지 않는다 (스크롤)")
    func verticalIgnored() {
        let model = model()
        #expect(!model.dragChanged(translation: size(-10, 14), start: onBubble))
        model.dragChanged(translation: size(-200, 14), start: onBubble)
        #expect(model.mode == nil)
        #expect(model.timeShift == 0)
    }

    @Test("사이드바가 열려 있으면 받지 않는다")
    func disabledIgnored() {
        let model = model()
        #expect(!model.dragChanged(translation: size(-16), start: onBubble, enabled: false))
        model.dragChanged(translation: size(-200), start: onBubble, enabled: true)
        #expect(model.mode == nil)
        #expect(model.dragEnded() == nil)
    }

    @Test("받지 않은 손길이 끝나면 다음 손길은 다시 가린다")
    func nextDragStartsFresh() {
        let model = model()
        model.dragChanged(translation: size(0, 20), start: onBubble)
        _ = model.dragEnded()
        #expect(model.dragChanged(translation: size(-16), start: onBubble))
        #expect(model.mode == .reply(bubble))
    }

    // MARK: - 말풍선의 자리

    @Test("자리를 지운 말풍선(화면에서 사라졌거나 지금 답장할 수 없는 말)에서는 시각이 나온다")
    func removedFrameShowsTimes() {
        let model = model()
        #expect(model.target(at: onBubble) == bubble)
        model.setFrame(nil, for: bubble)
        #expect(model.target(at: onBubble) == nil)
        model.dragChanged(translation: size(-16), start: onBubble)
        #expect(model.mode == .times)
    }

    @Test("말풍선이 스크롤로 옮겨 가면 새 자리에서 받는다")
    func movedFrame() {
        let model = model()
        model.setFrame(CGRect(x: 100, y: 600, width: 200, height: 60), for: bubble)
        #expect(model.target(at: onBubble) == nil)
        #expect(model.target(at: CGPoint(x: 150, y: 620)) == bubble)
    }

    // MARK: - 보낸 시각 글자

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("오늘 보낸 말은 시각만")
    func stampToday() {
        let now = date(2026, 11, 14, 15, 0)
        let morning = ChatSwipeModel.stamp(date(2026, 11, 14, 9, 52), now: now, calendar: calendar)
        #expect(morning.day == nil)
        #expect(morning.time == "오전 9:52")
        #expect(ChatSwipeModel.stamp(date(2026, 11, 14, 14, 5), now: now, calendar: calendar).time == "오후 2:05")
        #expect(ChatSwipeModel.stamp(date(2026, 11, 14, 0, 7), now: now, calendar: calendar).time == "오전 12:07")
    }

    @Test("다른 날 보낸 말은 날짜도, 다른 해면 해까지")
    func stampOtherDay() {
        let now = date(2026, 11, 14, 15, 0)
        let yesterday = ChatSwipeModel.stamp(date(2026, 11, 13, 23, 59), now: now, calendar: calendar)
        #expect(yesterday.day == "11월 13일")
        #expect(yesterday.time == "오후 11:59")
        let lastYear = ChatSwipeModel.stamp(date(2025, 12, 31, 8, 0), now: now, calendar: calendar)
        #expect(lastYear.day == "2025. 12. 31.")
        #expect(lastYear.time == "오전 8:00")
    }
}

@MainActor
@Suite("왼쪽으로 미는 동안 위아래 스크롤 잠금 (D82)")
struct ChatSwipeScrollLockTests {
    private let anywhere = CGPoint(x: 50, y: 500)

    @Test("왼쪽으로 밀기 시작하면 잠그고, 손을 떼면 푼다")
    func locksWhileFollowingTheFinger() {
        let model = ChatSwipeModel()
        #expect(!model.locksScroll)
        model.dragChanged(translation: CGSize(width: -16, height: 4), start: anywhere)
        #expect(model.locksScroll)
        // 밀면서 손가락이 위아래로 흔들려도 잠긴 채다
        model.dragChanged(translation: CGSize(width: -60, height: 80), start: anywhere)
        #expect(model.locksScroll)
        _ = model.dragEnded()
        #expect(!model.locksScroll)
    }

    @Test("말풍선을 밀어 답장할 때도 잠근다")
    func locksForReplyToo() {
        let model = ChatSwipeModel()
        let bubble = UUID()
        model.setFrame(CGRect(x: 100, y: 200, width: 200, height: 60), for: bubble)
        model.dragChanged(translation: CGSize(width: -16, height: 0), start: CGPoint(x: 150, y: 220))
        #expect(model.mode == .reply(bubble))
        #expect(model.locksScroll)
    }

    @Test("위아래로 시작한 손길은 잠그지 않는다 (보통의 스크롤)")
    func verticalStartStaysFree() {
        let model = ChatSwipeModel()
        model.dragChanged(translation: CGSize(width: -10, height: 14), start: anywhere)
        model.dragChanged(translation: CGSize(width: -200, height: 14), start: anywhere)
        #expect(!model.locksScroll)
    }

    @Test("손길이 끊겨도 풀린다")
    func cancelUnlocks() {
        let model = ChatSwipeModel()
        model.dragChanged(translation: CGSize(width: -16, height: 0), start: anywhere)
        #expect(model.locksScroll)
        model.dragCancelled()
        #expect(!model.locksScroll)
    }

    @Test("사이드바가 열려 있어 받지 않은 손길은 잠그지 않는다")
    func disabledStaysFree() {
        let model = ChatSwipeModel()
        model.dragChanged(translation: CGSize(width: -16, height: 0), start: anywhere, enabled: false)
        #expect(!model.locksScroll)
    }
}
