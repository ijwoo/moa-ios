import Foundation
import Testing
@testable import MeetingSummary

// "지금 가져오기"가 카드를 채우지 못하고 대화로 넘어갔을 때 (D128). 모두 지어낸 값이다.

@Suite("내 공간: 지금 가져오기가 대화로 넘어감")
struct SpaceRunStopTests {
    private func run(_ status: String, task: String? = nil) -> RoutineRun {
        RoutineRun(id: "rr_1", routineID: "rt_1", title: "가상 지원 현황", status: status, ranAt: .now, conversationID: "c_1", taskStatus: task)
    }

    @Test func runsThatNeedMeStopTheWait() {
        #expect(SpaceModel.stopsForUser(run("needs_login")))
        #expect(SpaceModel.stopsForUser(run("needs_reply")))
        #expect(SpaceModel.stopsForUser(run("task", task: "needs_input")))
        #expect(SpaceModel.stopsForUser(run("failed")))
        // 답이 났거나 작업이 아직 도는 중이면 카드를 계속 기다린다
        #expect(!SpaceModel.stopsForUser(run("done")))
        #expect(!SpaceModel.stopsForUser(run("task")))
    }

    @Test func theCardSaysWhy() {
        #expect(SpaceModel.stopText(run("needs_login")) == "로그인이 필요해 대화에서 멈췄어요")
        #expect(SpaceModel.stopText(run("needs_reply")) == "물어볼 것이 있어 대화로 넘어갔어요")
        #expect(SpaceModel.stopText(run("task", task: "needs_input")) == "물어볼 것이 있어 대화로 넘어갔어요")
        #expect(SpaceModel.stopText(run("missed")) == "맥이 꺼져 있어 돌지 못했어요")
        #expect(SpaceModel.stopText(run("failed")) == "가져오지 못했어요")
    }

    @Test func aRunThatFinishedWellIsRefetchedNotSentToChat() {
        // 작업은 잘 끝났는데 카드가 비어 있으면 대화가 아니라 카드를 다시 받는다 (D129)
        #expect(SpaceModel.finishedWell(run("task", task: "completed")))
        #expect(SpaceModel.finishedWell(run("done")))
        #expect(!SpaceModel.finishedWell(run("needs_login")))
        #expect(!SpaceModel.stopsForUser(run("task", task: "completed")))
    }
}
