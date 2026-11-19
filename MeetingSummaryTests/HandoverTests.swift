import Foundation
import Testing
@testable import MeetingSummary

// 손 넘기기 (D123, 맥의 D106). 모두 지어낸 값이다.

@Suite("손 넘기기: 맥이 준 것 읽기")
struct HandoverDecodingTests {
    private func task(_ handover: String) throws -> AgentTaskState {
        try AgentHTTPClient.decodeTask(data: Data("""
        {"id":"t1","status":"awaiting_input","task":"가상몰에서 찾기","steps":[],
         "question":{"question_id":"q1","text":"사람 확인 화면이 나왔어요","choices":["다 했어요","그만하기"],"handover":\(handover)}}
        """.utf8), status: 200)
    }

    @Test func theQuestionCarriesTheHandover() throws {
        let state = try task(#"{"id":"h_1","reason":"사람 확인\n퍼즐","host":"Shop.TEST","frame":"/v1/handover/h_1/frame","input":"/v1/handover/h_1/input","idle_close_s":300}"#)
        #expect(state.phase == .awaitingInput)
        #expect(state.pendingQuestion?.choices == ["다 했어요", "그만하기"])
        #expect(state.pendingQuestion?.handover == AgentHandover(id: "h_1", reason: "사람 확인 퍼즐", host: "shop.test", idleClose: 300))
    }

    @Test func aBadHandoverLeavesTheQuestionAlone() throws {
        // 주소에 넣을 수 없는 번호, 꼴이 틀린 값: 손 넘기기만 없고 질문은 그대로다
        for bad in [#"{"id":"../x"}"#, #"{"reason":"번호 없음"}"#, #""글""#, "7"] {
            let state = try task(bad)
            #expect(state.pendingQuestion?.text == "사람 확인 화면이 나왔어요")
            #expect(state.pendingQuestion?.handover == nil)
        }
    }

    @Test func framesAreReadOnlyWhenTheyAreImages() throws {
        let jpeg = MockHandoverScreen.frame(inputs: []).image
        let frame = try AgentHTTPClient.decodeHandoverFrame(
            data: Data(#"{"jpeg_b64":"\#(jpeg.base64EncodedString())","width":390,"height":640}"#.utf8), status: 200
        )
        #expect(frame.width == 390 && frame.height == 640 && frame.image == jpeg)
        // 그림이 아닌 것, 크기가 없는 것은 받지 않는다
        #expect(throws: AgentError.self) {
            try AgentHTTPClient.decodeHandoverFrame(data: Data(#"{"jpeg_b64":"\#(Data("글자".utf8).base64EncodedString())","width":390,"height":640}"#.utf8), status: 200)
        }
        #expect(throws: AgentError.self) {
            try AgentHTTPClient.decodeHandoverFrame(data: Data(#"{"jpeg_b64":"\#(jpeg.base64EncodedString())","width":0,"height":640}"#.utf8), status: 200)
        }
    }

    @Test func inputsAreSentInTheMacsShape() throws {
        func json(_ input: HandoverInput) throws -> [String: AnyHashable] {
            let data = try JSONEncoder().encode(input.body)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
        }
        #expect(try json(.tap(x: 10, y: 20)) == ["kind": "tap", "x": 10, "y": 20])
        #expect(try json(.drag(x: 1, y: 2, x2: 3, y2: 4)) == ["kind": "drag", "x": 1, "y": 2, "x2": 3, "y2": 4])
        #expect(try json(.wheel(dy: -120, x: 5, y: 6)) == ["kind": "wheel", "dy": -120, "x": 5, "y": 6])
        #expect(try json(.wheel(dy: 80, x: nil, y: nil)) == ["kind": "wheel", "dy": 80])
        #expect(try json(.key(.enter)) == ["kind": "key", "key": "Enter"])
        // 글은 500자까지
        #expect((try json(.text(String(repeating: "가", count: 600))))["text"] == AnyHashable(String(repeating: "가", count: 500)))
        #expect(HandoverInput.Key.allCases.map(\.rawValue) == ["Enter", "Backspace", "Tab", "Escape", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Delete", "Space"])
    }

    @Test func phonePointsBecomeScreenPoints() {
        // 390×640 화면을 절반 크기로 그렸다
        #expect(HandoverGeometry.point(CGPoint(x: 100, y: 50), scale: 0.5, width: 390, height: 640) == .init(x: 200, y: 100))
        // 그림 밖은 가장자리로
        #expect(HandoverGeometry.point(CGPoint(x: -5, y: 900), scale: 0.5, width: 390, height: 640) == .init(x: 0, y: 639))
        // 손가락을 위로 쓸면 아래로 스크롤
        #expect(HandoverGeometry.wheel(-60, scale: 0.5) == 120)
    }
}

@Suite("손 넘기기: 가짜 맥과 끝까지")
struct HandoverFlowTests {
    @Test func theUserSolvesItAndTheTaskGoesOn() async throws {
        let agent = MockAgentClient(v2: true)
        await agent.enableHandover()
        let reply = try await agent.message("가상몰에서 사람 확인 나오는 물건 찾아줘", conversationID: nil, context: nil)
        guard case .task(let started) = reply.action else {
            Issue.record("작업이 되어야 한다")
            return
        }
        var state = started
        for _ in 0..<6 where state.phase != .awaitingInput { state = try await agent.state(of: started.id) }
        let question = try #require(state.pendingQuestion)
        let handover = try #require(question.handover)
        #expect(question.choices == ["다 했어요", "그만하기"])
        let frame = try await agent.handoverFrame(id: handover.id)
        #expect(frame.width > 0 && AgentAttachment.isImage(frame.image))
        try await agent.handoverInput(id: handover.id, .tap(x: 90, y: 250))
        try await agent.handoverInput(id: handover.id, .text("가상"))
        #expect(await agent.handoverInputs == [.tap(x: 90, y: 250), .text("가상")])
        // 다 했다고 답하면 손 넘기기가 닫히고 작업이 이어진다
        _ = try await agent.answer(started.id, questionID: question.id, answer: "다 했어요")
        await #expect(throws: AgentError.handoverClosed) { try await agent.handoverFrame(id: handover.id) }
        await #expect(throws: AgentError.handoverClosed) { try await agent.handoverInput(id: handover.id, .key(.enter)) }
        for _ in 0..<8 where state.phase != .done { state = try await agent.state(of: started.id) }
        #expect(state.phase == .done)
    }

    @Test func stoppingEndsWithoutGoingOn() async throws {
        let agent = MockAgentClient(v2: true)
        await agent.enableHandover()
        let reply = try await agent.message("사람 확인 화면 테스트", conversationID: nil, context: nil)
        guard case .task(let started) = reply.action else {
            Issue.record("작업이 되어야 한다")
            return
        }
        var state = started
        for _ in 0..<6 where state.phase != .awaitingInput { state = try await agent.state(of: started.id) }
        let question = try #require(state.pendingQuestion)
        _ = try await agent.answer(started.id, questionID: question.id, answer: "그만하기")
        state = try await agent.state(of: started.id)
        #expect(state.phase == .done)
        #expect(state.report?.done == ["사람 확인을 하지 않아 멈췄어요."])
    }

    @Test func aMacWithoutHandoverHasNoScreen() async {
        let agent = MockAgentClient(v2: true)
        await #expect(throws: AgentError.handoverClosed) { try await agent.handoverFrame(id: "h_1") }
    }
}
