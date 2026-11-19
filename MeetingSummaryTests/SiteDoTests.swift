import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 로그인한 사이트 안에서 해 주기 (맥의 `site_do`, D80). 사이트·할 일·값은 모두 지어낸 것이다

private enum SiteDoFixture {
    static let fields = ["할 일": "주간 보고 쓰기", "기한": "금요일"]
    static let url = "https://www.todo.test/list?tab=mine"

    static func approval(kind: String = "action", action: String = "추가", fields: String = #"{"할 일":"주간 보고 쓰기","기한":"금요일"}"#,
                         url: String? = SiteDoFixture.url, sha: String?) -> String {
        let address = url.map { #","url":"\#($0)""# } ?? ""
        let hash = sha.map { #","sha256":"\#($0)""# } ?? ""
        return """
        {"id":"t1","status":"awaiting_approval","task":"할 일 추가","skill":"site_do","title":"todo.test에서 하기","steps":[],\
        "approval":{"approval_id":"ap1","kind":"\(kind)","action":"\(action)","fields":\(fields)\(address)\(hash)}}
        """
    }

    static func completed(_ actions: String?) -> String {
        let pressed = actions.map { #""approved_actions":\#($0),"# } ?? ""
        return """
        {"id":"t1","status":"completed","task":"할 일 추가","skill":"site_do","title":"todo.test에서 하기","steps":[],\
        "result":{"outcome":"completed","summary":"할 일을 추가했어요","approved_drafts":[],\(pressed)\
        "report":{"done":["할 일 목록에 '주간 보고 쓰기'를 추가했어요"],"blocked":[],"sources":[],"by":"claude","private":true}}}
        """
    }

    static func question(skill: String? = "site_do", choices: String = #"["이 사이트는 허락","이번만","하지 않기"]"#) -> String {
        let name = skill.map { #""skill":"\#($0)","# } ?? ""
        return """
        {"id":"t1","status":"awaiting_input","task":"할 일 추가",\(name)"steps":[],\
        "question":{"question_id":"q1","text":"가상할일의 로그인한 화면을 Claude가 보고 조작해도 될까요? 그 화면의 글이 Claude로 갑니다(비밀번호는 가지 않아요).",\
        "choices":\(choices)}}
        """
    }

    static func decode(_ json: String) throws -> AgentTaskState {
        try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
    }
}

@Suite("사이트 안에서 하기: 응답 해석")
struct SiteDoDecodeTests {
    @Test func actionApprovalIsReadAsButtonPress() throws {
        let sha = AgentDraftHash.sha256(action: "추가", fields: SiteDoFixture.fields, kind: "action", url: SiteDoFixture.url)
        let state = try SiteDoFixture.decode(SiteDoFixture.approval(sha: sha))
        let draft = try #require(state.draft)

        #expect(state.phase == .awaitingApproval)
        #expect(state.skill == "site_do")
        #expect(draft.isAction && !draft.isSend)
        #expect(draft.action == "추가")
        #expect(Set(draft.fields.map(\.label)) == ["할 일", "기한"])
        // 앱이 받은 내용으로 계산한 확인 번호가 맥의 것과 같다 (초안과 같은 네 값)
        #expect(draft.shownSHA256 == sha)
        #expect(draft.approvalHash == sha)
        #expect(state.currentStatus == "누를 단추를 확인해 주세요")
    }

    @Test func emptyFieldsStillHashTheSame() throws {
        let sha = AgentDraftHash.sha256(action: "삭제", fields: [:], kind: "action", url: SiteDoFixture.url)
        let draft = try #require(try SiteDoFixture.decode(SiteDoFixture.approval(action: "삭제", fields: "{}", sha: sha)).draft)
        #expect(draft.fields.isEmpty)
        #expect(draft.shownSHA256 == sha)
    }

    @Test func onlyTheHostOfThePageIsKept() throws {
        let sha = AgentDraftHash.sha256(action: "추가", fields: SiteDoFixture.fields, kind: "action", url: SiteDoFixture.url)
        // 로그인한 화면의 주소 전체(경로·쿼리)는 남기지 않는다
        #expect(try SiteDoFixture.decode(SiteDoFixture.approval(sha: sha)).draft?.site == "todo.test")
        #expect(AgentDraft.siteHost("http://Shop.Test:8080/cart?id=1#top") == "shop.test")
        #expect(AgentDraft.siteHost("https://m.todo.test") == "m.todo.test")
        for bad in [nil, "", "todo.test/list", "javascript:alert(1)", "ftp://todo.test/a", "mailto:me@mail.test", "https://"] {
            #expect(AgentDraft.siteHost(bad) == nil)
        }
        // 주소가 없으면 사이트도 없다 (지어내지 않는다)
        #expect(try SiteDoFixture.decode(SiteDoFixture.approval(url: nil, sha: nil)).draft?.site == nil)
    }

    @Test func mailDraftsAreUnchanged() throws {
        // 초안·보내기에는 사이트를 적지 않는다: 저장되는 기록이 전과 같다
        let fields = ["제목": "공유"]
        let sha = AgentDraftHash.sha256(action: "임시 저장", fields: fields, kind: "draft", url: "http://mail.test/compose")
        let json = SiteDoFixture.approval(kind: "draft", action: "임시 저장", fields: #"{"제목":"공유"}"#, url: "http://mail.test/compose", sha: sha)
        let state = try SiteDoFixture.decode(json)
        let draft = try #require(state.draft)
        #expect(!draft.isAction && !draft.isSend)
        #expect(draft.site == nil)
        #expect(state.currentStatus == "초안을 확인해 주세요")
        #expect(state.approvedActions == nil && state.approvedActionsLine == nil)
        #expect(String(data: try JSONEncoder().encode(draft), encoding: .utf8)?.contains("site") == false)
    }

    @Test func approvedActionsAreRead() throws {
        let state = try SiteDoFixture.decode(SiteDoFixture.completed(#"["추가"]"#))
        #expect(state.phase == .done)
        #expect(state.approvedActions == ["추가"])
        #expect(state.approvedActionsLine == "승인한 단추: '추가'")
        // 초안이 아니라서 승인한 초안 목록에는 들지 않는다
        #expect(state.approvedDrafts.isEmpty)
        #expect(state.report?.by == "claude")

        let two = try SiteDoFixture.decode(SiteDoFixture.completed(#"["추가","저장"]"#))
        #expect(two.approvedActionsLine == "승인한 단추: '추가', '저장'")
    }

    @Test func oddApprovedActionsDoNotBreakTheResult() throws {
        let long = String(repeating: "가", count: 60)
        let odd = try SiteDoFixture.decode(SiteDoFixture.completed(#"["추가",3,null,"","  ",{"a":1},"줄\n바꿈","\#(long)"]"#))
        #expect(odd.approvedActions == ["추가", "줄 바꿈", String(repeating: "가", count: AgentTaskState.actionNameLimit)])
        #expect(odd.report?.done.count == 1)

        // 목록이 아니거나 없으면 없는 것으로 본다. 보고는 그대로 읽는다
        for shape in [#""추가""#, "null", "{}", "[]", "7"] {
            let state = try SiteDoFixture.decode(SiteDoFixture.completed(shape))
            #expect(state.approvedActions == nil)
            #expect(state.approvedActionsLine == nil)
            #expect(state.report?.done.count == 1)
        }
        #expect(try SiteDoFixture.decode(SiteDoFixture.completed(nil)).approvedActions == nil)

        let many = "[" + (1...15).map { #""단추\#($0)""# }.joined(separator: ",") + "]"
        #expect(try SiteDoFixture.decode(SiteDoFixture.completed(many)).approvedActions?.count == AgentTaskState.actionLimit)
    }

    @Test func permissionQuestionIsRecognizedOnlyByItsExactChoices() throws {
        #expect(try SiteDoFixture.decode(SiteDoFixture.question()).asksSitePermission)
        // 같은 작업이 하는 다른 질문, 다른 작업의 질문은 아니다 (입력창으로 답해도 된다)
        #expect(try !SiteDoFixture.decode(SiteDoFixture.question(choices: #"["오늘","내일"]"#)).asksSitePermission)
        #expect(try !SiteDoFixture.decode(SiteDoFixture.question(choices: "[]")).asksSitePermission)
        #expect(try !SiteDoFixture.decode(SiteDoFixture.question(choices: #"["이번만","이 사이트는 허락","하지 않기"]"#)).asksSitePermission)
        #expect(try !SiteDoFixture.decode(SiteDoFixture.question(skill: nil)).asksSitePermission)
        #expect(try !SiteDoFixture.decode(SiteDoFixture.question(skill: "web_find")).asksSitePermission)
    }

    @Test func savedRecordsSurviveBothWays() throws {
        // 새 값이 있는 상태는 그대로 돌아온다
        let sha = AgentDraftHash.sha256(action: "추가", fields: SiteDoFixture.fields, kind: "action", url: SiteDoFixture.url)
        for json in [SiteDoFixture.approval(sha: sha), SiteDoFixture.completed(#"["추가"]"#)] {
            let state = try SiteDoFixture.decode(json)
            #expect(try JSONDecoder().decode(AgentTaskState.self, from: JSONEncoder().encode(state)) == state)
        }
        // 전에 저장한 기록(새 키가 없다)도 읽힌다
        var old = try SiteDoFixture.decode(SiteDoFixture.approval(kind: "draft", sha: nil))
        old.skill = nil
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["approvedActions"] = nil
        if var draft = object["draft"] as? [String: Any] {
            draft["site"] = nil
            draft["kind"] = nil
            object["draft"] = draft
        }
        let restored = try JSONDecoder().decode(AgentTaskState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.approvedActions == nil)
        #expect(restored.draft?.site == nil && restored.draft?.isAction == false)
    }
}

@MainActor
@Suite("사이트 안에서 하기: 대화에서")
struct SiteDoFlowTests {
    let context: ModelContext
    static let ask = "todo.test에 '주간 보고 쓰기' 할 일 추가해줘"

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func session(_ agent: MockAgentClient) -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        session.attach(context)
        return session
    }

    private func task(_ session: AskSession) throws -> AgentTaskState {
        try #require(session.messages.last(where: { $0.role == .agent })?.agent)
    }

    @Test func asksPermissionThenApprovalThenPresses() async throws {
        let agent = MockAgentClient(v2: true, siteDo: MockSiteDo())
        let session = session(agent)
        await session.send(Self.ask, meetings: [])

        // 처음에는 그 사이트의 화면을 Claude가 봐도 되는지 묻는다
        var state = try task(session)
        #expect(state.phase == .awaitingInput)
        #expect(state.skill == "site_do")
        #expect(state.asksSitePermission)
        #expect(state.steps.isEmpty)

        // "이번만": 이어서 하고, 바꾸는 단추 앞에서 승인을 받는다
        await session.answer(state.id, with: "이번만")
        state = try task(session)
        #expect(state.phase == .awaitingApproval)
        let draft = try #require(state.draft)
        #expect(draft.isAction)
        #expect(draft.action == "추가")
        #expect(draft.site == "todo.test")
        #expect(draft.approvalHash != nil)
        #expect(state.currentStatus == "누를 단추를 확인해 주세요")
        #expect(state.approvedActions == nil)

        await session.decide(state.id, approve: true)
        state = try task(session)
        #expect(state.phase == .done)
        #expect(state.approvedActions == ["추가"])
        #expect(state.approvedActionsLine == "승인한 단추: '추가'")
        #expect(state.approvedDrafts.isEmpty)
        #expect(state.report?.done.first == MockSiteDo.done)
        #expect(!session.messages.contains { $0.role == .error })
    }

    @Test func allowingTheSiteIsRememberedByTheMac() async throws {
        let agent = MockAgentClient(v2: true, siteDo: MockSiteDo())
        let session = session(agent)
        await session.send(Self.ask, meetings: [])
        await session.answer(try task(session).id, with: "이 사이트는 허락")
        #expect(try task(session).phase == .awaitingApproval)
        await session.decide(try task(session).id, approve: true)
        #expect(try task(session).phase == .done)

        // 다음 부탁에는 묻지 않고 승인 카드까지 간다
        await session.send(Self.ask, meetings: [])
        let next = try task(session)
        #expect(next.phase == .awaitingApproval)
        #expect((next.answered ?? []).isEmpty)
    }

    @Test func alreadyAllowedSiteGoesStraightToApproval() async throws {
        let session = session(MockAgentClient(v2: true, siteDo: MockSiteDo(allowed: true)))
        await session.send(Self.ask, meetings: [])
        let state = try task(session)
        #expect(state.phase == .awaitingApproval)
        #expect(state.draft?.isAction == true)
    }

    @Test func refusingOrTypingSomethingElseDoesNothing() async throws {
        // 고른 "하지 않기"
        var session = session(MockAgentClient(v2: true, siteDo: MockSiteDo()))
        await session.send(Self.ask, meetings: [])
        await session.answer(try task(session).id, with: "하지 않기")
        var state = try task(session)
        #expect(state.phase == .done)
        #expect(state.report?.done == [MockSiteDo.refused])
        #expect(state.steps.isEmpty && state.approvedActions == nil)

        // 입력창에 쓴 글은 허락이 아니다 (맥이 선택지의 글만 허락으로 받는다)
        session = self.session(MockAgentClient(v2: true, siteDo: MockSiteDo()))
        await session.send(Self.ask, meetings: [])
        await session.send("응 해도 돼", meetings: [])
        state = try task(session)
        #expect(state.phase == .done)
        #expect(state.report?.done == [MockSiteDo.unanswered])
        #expect(state.steps.isEmpty && state.approvedActions == nil)
    }

    @Test func rejectingWithAReasonAsksAgainWithTheChange() async throws {
        let session = session(MockAgentClient(v2: true, siteDo: MockSiteDo(allowed: true)))
        await session.send(Self.ask, meetings: [])
        let first = try #require(try task(session).draft)

        await session.decide(try task(session).id, approve: false, reason: "기한을 월요일로")
        let state = try task(session)
        #expect(state.phase == .awaitingApproval)
        let second = try #require(state.draft)
        #expect(second.isAction)
        #expect(second.approvalID != first.approvalID)
        #expect(second.fields.first { $0.label == "기한" }?.value == "월요일")
        #expect(second.approvalHash != first.approvalHash)
        #expect(state.approvedActions == nil)

        // 사유 없이 거부하면 누르지 않고 끝난다
        await session.decide(state.id, approve: false)
        let ended = try task(session)
        #expect(ended.phase == .canceled)
        #expect(ended.approvedActions == nil)
    }

    @Test func changedContentIsNotApprovedAndSaysSoInButtonWords() async throws {
        let agent = MockAgentClient(v2: true, siteDo: MockSiteDo(allowed: true))
        let session = session(agent)
        await session.send(Self.ask, meetings: [])
        let state = try task(session)
        let draft = try #require(state.draft)

        // 화면에 보인 것과 다른 내용으로는 승인되지 않는다
        await #expect(throws: AgentError.hashMismatch) {
            try await agent.decide(state.id, approvalID: draft.approvalID ?? "", approve: true, reason: nil, sha256: String(repeating: "0", count: 64))
        }
        #expect(try await agent.state(of: state.id).phase == .awaitingApproval)

        // 카드를 보는 사이에 화면의 값이 달라졌다: 승인을 눌러도 누르지 않고, 달라진 내용을 다시 보여 준다
        await agent.changeScreen(state.id)
        await session.decide(state.id, approve: true)
        let now = try task(session)
        #expect(now.phase == .awaitingApproval)
        #expect(now.approvedActions == nil)
        #expect(now.draft?.fields.first { $0.label == "기한" }?.value == "월요일")
        // 그때의 말은 초안의 말이 아니다
        #expect(session.messages.last?.role == .error)
        #expect(session.messages.last?.text == AgentDraft.actionMismatchText)
        #expect(!AgentDraft.actionMismatchText.contains("초안"))
        #expect(AgentError.hashMismatch.localizedDescription.contains("초안"))

        // 다시 보여 준 내용으로는 승인된다
        await session.decide(state.id, approve: true)
        #expect(try task(session).phase == .done)
        #expect(try task(session).approvedActions == ["추가"])
    }
}
