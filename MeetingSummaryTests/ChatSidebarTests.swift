import CoreGraphics
import Testing
@testable import MeetingSummary

@MainActor
@Suite("사이드바 밀기")
struct ChatSidebarTests {
    /// 화면 너비 402 (서랍 320)
    private func model(open: Bool = false) -> ChatSidebarModel {
        let model = ChatSidebarModel()
        model.screenWidth = 402
        model.isOpen = open
        return model
    }

    private func size(_ width: CGFloat, _ height: CGFloat = 0) -> CGSize {
        CGSize(width: width, height: height)
    }

    // MARK: - 너비와 자리

    @Test("서랍 너비는 화면의 84%, 넓으면 320까지")
    func panelWidth() {
        #expect(ChatSidebarModel.panelWidth(screenWidth: 402) == 320)
        #expect(abs(ChatSidebarModel.panelWidth(screenWidth: 320) - 268.8) < 0.001)
        #expect(ChatSidebarModel.panelWidth(screenWidth: 0) == 0)
    }

    @Test("닫혀 있으면 화면은 제자리, 열려 있으면 서랍 너비만큼 밀려 있다")
    func shiftFollowsOpen() {
        let model = model()
        #expect(model.shift == 0)
        #expect(model.progress == 0)
        model.isOpen = true
        #expect(model.shift == 320)
        #expect(model.progress == 1)
    }

    @Test("화면 너비를 아직 모르면 밀지 않는다")
    func noWidth() {
        let model = ChatSidebarModel()
        model.isOpen = true
        #expect(model.shift == 0)
        #expect(model.progress == 0)
        model.isOpen = false
        #expect(!model.dragChanged(size(40)))
        #expect(!model.isDragging)
    }

    // MARK: - 손을 뗐을 때

    @Test("천천히 놓으면 절반을 넘었는지로 정한다")
    func settlesByHalf() {
        #expect(ChatSidebarModel.settlesOpen(shift: 170, predictedShift: 180, panelWidth: 320))
        #expect(!ChatSidebarModel.settlesOpen(shift: 150, predictedShift: 160, panelWidth: 320))
    }

    @Test("튕기듯 밀면 조금만 밀어도 그 방향으로 간다")
    func settlesByFlick() {
        #expect(ChatSidebarModel.settlesOpen(shift: 40, predictedShift: 300, panelWidth: 320))
        #expect(!ChatSidebarModel.settlesOpen(shift: 280, predictedShift: 20, panelWidth: 320))
    }

    @Test("서랍은 닫혀 있을 때 살짝 어둡고 열리면서 밝아진다 (D148)")
    func panelBrightensAsItOpens() {
        #expect(ChatSidebarModel.panelDim(progress: 0, dark: false) == 0.12)
        #expect(ChatSidebarModel.panelDim(progress: 0, dark: true) > ChatSidebarModel.panelDim(progress: 0, dark: false))
        #expect(ChatSidebarModel.panelDim(progress: 0.5, dark: false) < ChatSidebarModel.panelDim(progress: 0.2, dark: false))
        #expect(ChatSidebarModel.panelDim(progress: 1, dark: true) == 0)
        // 끝을 넘어 계산돼도(되튐) 밝아진 채로 둔다
        #expect(ChatSidebarModel.panelDim(progress: 1.1, dark: false) == 0)
    }

    @Test("서랍에 넣을 것은 여는 움직임이 끝난 뒤에 받는다 (D148)")
    func loadsAfterTheOpeningSettles() {
        #expect(ChatSidebarModel.settleDelay > .milliseconds(320))
    }

    // MARK: - 끌기

    @Test("닫힌 화면을 오른쪽으로 밀면 따라 나온다 (알아채기까지 움직인 만큼은 뺀다)")
    func opensByDraggingRight() {
        let model = model()
        #expect(model.dragChanged(size(18, 2)))
        #expect(model.isDragging)
        #expect(model.shift == 0)
        #expect(!model.dragChanged(size(118, 30)))
        #expect(model.shift == 100)
    }

    @Test("서랍 너비보다 더 밀리지 않고, 왼쪽으로 넘어가지도 않는다")
    func clampsShift() {
        let model = model()
        model.dragChanged(size(18))
        model.dragChanged(size(600))
        #expect(model.shift == 320)
        model.dragChanged(size(-200))
        #expect(model.shift == 0)
    }

    @Test("세로로 시작한 손길은 스크롤이다: 나중에 옆으로 가도 따라가지 않는다")
    func ignoresVerticalStart() {
        let model = model()
        #expect(!model.dragChanged(size(4, 18)))
        #expect(!model.dragChanged(size(200, 20)))
        #expect(!model.isDragging)
        #expect(model.shift == 0)
        model.dragEnded(predictedTranslation: size(400, 20))
        #expect(!model.isOpen)
    }

    @Test("닫힌 화면을 왼쪽으로 미는 것은 따라가지 않는다")
    func ignoresLeftWhenClosed() {
        let model = model()
        #expect(!model.dragChanged(size(-18)))
        #expect(!model.dragChanged(size(100)))
        #expect(!model.isDragging)
    }

    @Test("열린 화면을 왼쪽으로 밀면 따라 들어간다")
    func closesByDraggingLeft() {
        let model = model(open: true)
        #expect(model.dragChanged(size(-18)))
        #expect(model.shift == 320)
        model.dragChanged(size(-118))
        #expect(model.shift == 220)
    }

    @Test("열린 화면을 오른쪽으로 미는 것은 따라가지 않는다")
    func ignoresRightWhenOpen() {
        let model = model(open: true)
        #expect(!model.dragChanged(size(18)))
        #expect(!model.isDragging)
        #expect(model.shift == 320)
    }

    @Test("절반 넘게 밀고 놓으면 열린다")
    func endsOpen() {
        let model = model()
        model.dragChanged(size(18))
        model.dragChanged(size(218))
        model.dragEnded(predictedTranslation: size(230))
        #expect(model.isOpen)
        #expect(!model.isDragging)
        #expect(model.shift == 320)
    }

    @Test("조금 밀다 놓으면 도로 닫힌다")
    func endsClosed() {
        let model = model()
        model.dragChanged(size(18))
        model.dragChanged(size(98))
        model.dragEnded(predictedTranslation: size(110))
        #expect(!model.isOpen)
        #expect(model.shift == 0)
    }

    @Test("조금만 밀어도 튕기듯 놓으면 열린다")
    func flickOpens() {
        let model = model()
        model.dragChanged(size(18))
        model.dragChanged(size(68))
        model.dragEnded(predictedTranslation: size(400))
        #expect(model.isOpen)
    }

    @Test("열린 서랍을 왼쪽으로 튕기면 닫힌다")
    func flickCloses() {
        let model = model(open: true)
        model.dragChanged(size(-18))
        model.dragChanged(size(-58))
        model.dragEnded(predictedTranslation: size(-400))
        #expect(!model.isOpen)
    }

    @Test("한 손길이 끝나면 다음 손길은 새로 정한다")
    func nextGestureStartsFresh() {
        let model = model()
        model.dragChanged(size(2, 18))
        model.dragEnded(predictedTranslation: size(2, 40))
        #expect(model.dragChanged(size(18)))
    }

    @Test("손길이 끊기면 있던 자리에서 가까운 쪽으로 간다")
    func cancelSettlesNearest() {
        let opened = model()
        opened.dragChanged(size(18))
        opened.dragChanged(size(218))
        opened.dragCancelled()
        #expect(opened.isOpen)
        #expect(!opened.isDragging)

        let closed = model()
        closed.dragChanged(size(18))
        closed.dragChanged(size(58))
        closed.dragCancelled()
        #expect(!closed.isOpen)
        #expect(!closed.isDragging)
    }

    @Test("끝난 손길에 끊겼다는 말이 뒤따라와도 바뀌지 않는다")
    func cancelAfterEndDoesNothing() {
        let model = model()
        model.dragChanged(size(18))
        model.dragChanged(size(68))
        model.dragEnded(predictedTranslation: size(400))
        model.dragCancelled()
        #expect(model.isOpen)
    }

    // MARK: - 끌다 뗀 자리의 줄

    @Test("끄는 중과 뗀 직후에는 줄을 누른 것으로 치지 않는다")
    func swallowsTapAroundDrag() {
        let model = model(open: true)
        let start = ContinuousClock.now
        #expect(!model.swallowsTap(now: start))
        model.dragChanged(size(-18))
        #expect(model.swallowsTap(now: start))
        model.dragChanged(size(-40))
        model.dragEnded(predictedTranslation: size(-45), now: start)
        #expect(model.swallowsTap(now: start + .milliseconds(100)))
        #expect(!model.swallowsTap(now: start + .milliseconds(200)))
    }

    @Test("열린 서랍의 줄 위에서 오른쪽으로 밀다 떼도(따라가지 않는 쪽) 누른 것으로 치지 않는다")
    func sidewaysDragSwallowsTapEvenWhenIgnored() {
        let model = model(open: true)
        let start = ContinuousClock.now
        #expect(!model.dragChanged(size(18, 1)))
        #expect(model.swallowsTap(now: start))
        model.dragEnded(predictedTranslation: size(240, 5), now: start)
        #expect(model.isOpen)
        #expect(model.swallowsTap(now: start + .milliseconds(100)))
        #expect(!model.swallowsTap(now: start + .milliseconds(200)))
    }

    @Test("세로로 민 손길(목록 스크롤) 뒤에는 바로 누를 수 있다")
    func ignoredDragDoesNotSwallowTap() {
        let model = model(open: true)
        let start = ContinuousClock.now
        model.dragChanged(size(2, -18))
        model.dragEnded(predictedTranslation: size(2, -80), now: start)
        #expect(!model.swallowsTap(now: start))
    }
}
