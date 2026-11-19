import Foundation
import Testing
@testable import MeetingSummary

// 활동 탭과 전역 검색 (D120). 모두 지어낸 값이다.

@Suite("활동: 맥이 준 것 읽기")
struct ActivityDecodingTests {
    @Test func entriesAreReadAndSortedByTime() throws {
        let entries = try ActivityDecoding.entries(data: Data("""
        {"waiting":[{"kind":"task","id":"t_w","at":"2026-11-17T02:00:00Z","title":"보고서 메일 보내기","status":"awaiting_approval"}],
         "items":[
          {"kind":"task","id":"t_1","at":"2026-11-17T00:10:00Z","title":"결제내역 확인","status":"completed","card_kind":"answer","card_subtitle":"가상페이 · 이번 주","line":"최근 결제 3건이에요","conversation_id":"c_1"},
          {"kind":"routine","id":"rr_1","at":"2026-11-17T07:30:00+09:00","title":"아침 브리핑","status":"done","routine_id":"rt_1","line":"메일 5통\\n맑음"},
          {"kind":"task","id":"t_2","at":"2026-11-17T01:00:00.123Z","title":"비밀 작업","status":"failed","private":true,"line":"숨길 줄"},
          {"kind":"task","id":"../x","at":"2026-11-17T01:00:00Z","title":"경로"},
          {"kind":"task","id":"t_3","at":"어제","title":"시각 없음"},
          {"kind":"weird","id":"t_4","at":"2026-11-17T01:00:00Z"}, 7]}
        """.utf8), status: 200, key: "items")
        // 07:30+09:00 = 2026-11-16T22:30Z 라 가장 이르다
        #expect(entries.map(\.id) == ["t_2", "t_1", "rr_1"])
        #expect(entries[1].line == "가상페이 · 이번 주" && entries[1].conversationID == "c_1")
        #expect(entries[2].kind == .routine && entries[2].line == "메일 5통 맑음")
        // 맥이 숨긴 작업의 한 줄은 보이지 않는다
        #expect(entries[0].line == nil && entries[0].isFailed)
    }

    @Test func onlyApprovalsAndQuestionsAreWaiting() {
        func entry(_ status: String) -> ActivityEntry {
            ActivityEntry(id: "t", kind: .task, at: .now, title: "t", status: status)
        }
        #expect(entry("awaiting_approval").isWaiting && entry("awaiting_input").isWaiting)
        // 보내기 대기는 사람이 할 일이 아니다
        #expect(!entry("send_pending").isWaiting && !entry("running").isWaiting)
    }

    @Test func searchResultsKeepTheirSnippetAndRoutineDefinitions() throws {
        let entries = try ActivityDecoding.entries(data: Data("""
        {"q":"브리핑","items":[{"kind":"routine_def","id":"rt_1","title":"아침 브리핑","snippet":"오늘 온 메일이랑 날씨 요약해줘","at":"2026-11-16T22:30:00Z"}]}
        """.utf8), status: 200, key: "items")
        #expect(entries.first?.kind == .routineDefinition && entries.first?.snippet == "오늘 온 메일이랑 날씨 요약해줘")
    }
}

@MainActor
@Suite("활동: 맥 쪽 목록")
struct ActivityModelTests {
    @Test func onlyAMacThatKnowsActivityIsAsked() async throws {
        let without = ActivityModel(agent: MockAgentClient(v2: true))
        await without.load()
        #expect(!without.isOffered && without.entries.isEmpty)

        let agent = MockAgentClient(v2: true, routines: .demo(), offersActivity: true)
        let model = ActivityModel(agent: agent)
        await model.load()
        #expect(model.isOffered)
        #expect(model.entries.contains { $0.kind == .routine && $0.title == "아침 브리핑" })
        let found = await model.search("브리핑")
        #expect(found.contains { $0.kind == .routineDefinition })
    }
}
