import Foundation
import Testing
@testable import MeetingSummary

/// 맥의 브라우저로 직접 해 보기 (`web_browse`, D76): 응답의 꼴은 찾기 작업과 같아서 앱이 새로 그리는 것은 없다.
/// 앱이 달리 하는 것은 데이터 처리 방식의 글(그 작업에서는 공개 페이지의 화면 글이 Claude로 간다)과 새 단계 이름의 글뿐이다.
/// 여기의 사이트·주소는 모두 가상이다
@MainActor
@Suite("맥의 브라우저로 직접 해 보기")
struct WebBrowseTests {
    private func mac(browses: Bool, finds: Bool = true) -> MockAgentClient {
        MockAgentClient(v2: true, dialogCloud: MockDialogCloud(marksWriter: true, findsPages: finds, browsesWeb: browses))
    }

    private func facts(_ setup: DialogSetup) -> [String] {
        MacAgentFacts(setup: setup).rows.map { $0.text + " " + ($0.note ?? "") }
    }

    @Test func thePrivacyScreenSaysThePageTextGoesToClaude() async throws {
        let setup = await DialogSetup(agent: mac(browses: true))
        #expect(setup.browsesWeb)
        #expect(setup.stored.split(separator: " ").contains("webbrowse"))
        #expect(DialogSetup(stored: setup.stored)?.browsesWeb == true)

        let all = facts(setup)
        let fact = try #require(all.first { $0.contains("공개 사이트를 직접 열어 찾아봐요") })
        // 가는 것과 가지 않는 것
        #expect(fact.contains("그 화면의 글을 Claude가 봐요"))
        #expect(fact.contains("공개 페이지의 화면 글(주소, 제목, 누르거나 입력할 수 있는 것의 이름, 보이는 글)이 Claude로 가요"))
        #expect(fact.contains("화면 캡처(그림)는 가지 않아요"))
        #expect(fact.contains("대화 기록, 연락처의 이름, 회의 발췌는 받지 않아요"))
        #expect(fact.contains("내가 말에 쓴 낱말(가게 이름, 날짜, 지역 등)이 그 사이트로 갈 수 있어요"))
        // 하지 않는 것: 맥이 막는 것과 지시인 것을 가려 쓴다
        #expect(fact.contains("신청·결제·제출·예약 같은 단추는 누르지 않고, 비밀번호 칸에는 넣지 못해요(둘 다 맥이 막아요)"))
        #expect(fact.contains("멈추도록 지시하고"))
        #expect(fact.contains("작업마다 새로 뜨고 닫을 때 지워져요"))
        #expect(fact.contains("화면 글은 맥에 저장하지 않아요"))
        // 모델 이름은 적지 않는다 (맥의 설정으로 바뀔 수 있다)
        #expect(!fact.contains("Haiku"))

        // 다른 줄의 "가지 않는다"·"맥이 한다"는 말도 이 작업은 다르다고 고쳐 쓴다
        let held = try #require(all.first { $0.contains("이런 것은 Claude로 가지 않아요") })
        #expect(held.contains("사이트를 직접 열어 찾아보는 작업은 달라요"))
        #expect(held.contains("공개 페이지의 화면 글과 진행 과정은 Claude로 가요"))
        let local = try #require(all.first { $0.contains("브라우저·메일·로그인도 맥이 해요") })
        #expect(local.contains("무엇을 누를지는 Claude가 정하고, 답도 Claude가 써요"))
        let writer = try #require(all.first { $0.contains("모두 맥에서 만들어요") })
        #expect(writer.contains("찾아 달라는 작업의 답, 사이트를 직접 열어 찾아보는 작업의 답·질문 말고는 모두 맥에서 만들어요"))
    }

    @Test func aMacWithoutItKeepsTheOldWords() async throws {
        let setup = await DialogSetup(agent: mac(browses: false))
        #expect(!setup.browsesWeb)
        #expect(!setup.stored.contains("webbrowse"))
        let all = facts(setup)
        #expect(!all.contains { $0.contains("직접 열어 찾아") })
        let held = try #require(all.first { $0.contains("이런 것은 Claude로 가지 않아요") })
        #expect(held.hasSuffix("맡긴 일의 진행 과정과 승인 내용"))
        #expect(all.contains { $0.contains("찾아 달라는 작업의 답 말고는 모두 맥에서 만들어요") })
        // 찾기는 하지 않고 직접 해 보기만 하는 맥
        let only = await DialogSetup(agent: mac(browses: true, finds: false))
        #expect(facts(only).contains { $0.contains("맡긴 일의 보고·초안·질문은 사이트를 직접 열어 찾아보는 작업의 답·질문 말고는 모두 맥에서 만들어요") })
        // 대화 판단을 맥 안에서 하는 맥에는 없는 기능이다
        #expect(!DialogSetup(place: .local, browsesWeb: true).browsesWeb)
        #expect(DialogSetup(place: .cloud, browsesWeb: true).browsesWeb)
    }

    @Test func theNewStepHasWords() throws {
        let json = """
        {"id":"t_browse1","status":"running","task":"가상박물관 홈페이지에서 수요일 관람 시간 봐줘","title":"웹에서 직접 해 보기",\
        "created_at":"2026-11-14T12:30:00+00:00","updated_at":"2026-11-14T12:30:08+00:00","steps":[\
        {"n":1,"tool":"search_web","args":{"query":"가상박물관 홈페이지"},"status":"ok"}]}
        """
        let state = try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
        #expect(state.phase == .running)
        #expect(state.serverTitle == "웹에서 직접 해 보기")
        #expect(state.activity == "갈 곳을 찾고 있어요")
        #expect(state.timeline.contains { $0.text == "갈 곳 찾기" })
        // 쇼핑 화면에 시킨 일이 아니다
        #expect(state.browse == nil && state.usedShop == nil)
    }
}
