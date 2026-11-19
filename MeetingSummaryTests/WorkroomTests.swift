import Foundation
import Testing
@testable import MeetingSummary

// 작업실 (D112): 긴 메시지, 만든 영상·그림 첨부, 단계의 한 줄 설명, 긴 단계 접기. 모두 지어낸 값이다.

@Suite("작업실")
struct WorkroomTests {
    static func task(attachments: String = "[]", steps: String = "[]") -> Data {
        Data("""
        {"id":"t_work1","status":"completed","task":"보고서 만들어줘","title":"보고서 만들기","skill":"workroom",\
        "created_at":"2026-11-17T01:00:00+00:00","updated_at":"2026-11-17T01:20:00+00:00","steps":\(steps),\
        "result":{"outcome":"completed","summary":"만들었어요","approved_drafts":[],\
        "report":{"done":["보고서를 만들었어요."],"blocked":[],"sources":[],"attachments":\(attachments)}}}
        """.utf8)
    }

    @Test func messageTextKeepsSixteenThousandCharacters() throws {
        let long = String(repeating: "가", count: 17000)
        let body = AgentHTTPClient.MessageBody(
            text: long, conversationID: nil, context: nil, messageID: nil, replyTaskID: nil, tone: "friendly", features: []
        )
        #expect(body.text.count == 16000)
    }

    @Test func videoAndMadePicturesAreRead() throws {
        let state = try AgentHTTPClient.decodeTask(data: Self.task(attachments: """
        [{"id":"v1","type":"video","mime":"video/mp4","width":1080,"height":1920,"bytes":8400000,"sensitive":false},
         {"id":"v2","type":"video","mime":"video/mp4","width":1080,"height":1920},
         {"id":"g1","type":"image","mime":"image/png","width":1024,"height":1024,"sensitive":false},
         {"id":"x1","type":"video","mime":"video/quicktime"},
         {"id":"x2","type":"audio","mime":"audio/mpeg"}]
        """), status: 200)
        let attachments = state.report?.attachments ?? []
        // 영상은 하나만, 모르는 종류·형식은 버린다
        #expect(attachments.map(\.id) == ["v1", "g1"])
        #expect(attachments[0].isVideo && attachments[0].bytes == 8_400_000 && !attachments[0].isSensitive)
        #expect(attachments[1].kind == .image)
    }

    @Test func approvalCardsTakeOnlyScreenshots() throws {
        let data = Data("""
        {"id":"t_work2","status":"awaiting_approval","task":"보고서 만들어줘","created_at":"2026-11-17T01:00:00+00:00",\
        "updated_at":"2026-11-17T01:00:00+00:00","steps":[],\
        "approval":{"approval_id":"ap1","action":"영상 생성","kind":"action","url":"https://video.example.org/app","fields":{"길이":"12초"},\
        "attachment":{"id":"v1","type":"video","mime":"video/mp4","width":1080,"height":1920}}}
        """.utf8)
        let state = try AgentHTTPClient.decodeTask(data: data, status: 200)
        #expect(state.draft != nil)
        #expect(state.draft?.attachment == nil)
    }

    @Test func unknownStepsUseTheirBrief() throws {
        let state = try AgentHTTPClient.decodeTask(data: Self.task(steps: """
        [{"tool":"run_command","args":{"brief":"ffmpeg -i clip_01.mp4\\n-vf subtitles"},"status":"ok"},
         {"tool":"write_file","args":{},"status":"ok"},
         {"tool":"navigate","args":{"url":"https://video.example.org/app"},"status":"ok"}]
        """), status: 200)
        #expect(state.steps[0] == "ffmpeg -i clip_01.mp4")
        #expect(state.steps[1] == "write_file")
        #expect(state.steps[2].hasPrefix("열기 · "))
    }

    @Test func longStepListsFoldTheEarlyOnes() {
        #expect(AgentTaskState.foldedStepCount(10) == 0)
        #expect(AgentTaskState.foldedStepCount(11) == 5)
        #expect(AgentTaskState.foldedStepCount(40) == 34)
    }

    @Test func onlyMP4DataCountsAsVideo() {
        var mp4 = Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8)
        mp4.append(Data(count: 20))
        #expect(AgentAttachment.isVideo(mp4))
        #expect(!AgentAttachment.isVideo(Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0, count: 20))))
    }

    @Test func savedCapturesWithoutKindStayScreenshots() throws {
        let old = #"{"id":"a1","width":1280,"height":720,"isSensitive":true}"#
        let attachment = try JSONDecoder().decode(AgentAttachment.self, from: Data(old.utf8))
        #expect(attachment.kind == nil && !attachment.isVideo)
    }
}
