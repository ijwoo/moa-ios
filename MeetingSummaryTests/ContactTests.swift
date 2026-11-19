import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

// 연락처에서 받는 사람 찾기, 다른 사람에게 보내는 메일의 표시 (D89). 사람과 주소는 모두 지어낸 것이다.

@Suite("연락처: 말에 나온 사람 찾기")
struct ContactMatchTests {
    private let people = MockContacts.demo

    @Test func nameKeysFollowTheMacsRule() {
        // 전체, 띄어 쓴 마디, 한글 세 글자 이름의 뒤 두 글자
        #expect(ContactMatch.keys(for: "김하늘") == ["김하늘", "하늘"])
        #expect(ContactMatch.keys(for: "Jane Doe") == ["janedoe", "jane", "doe"])
        #expect(ContactMatch.keys(for: "이바다 (직장)") == ["이바다(직장)", "이바다", "직장", "바다"])
        // 두 글자보다 짧은 조각은 쓰지 않는다
        #expect(ContactMatch.keys(for: "김") == [])
        #expect(ContactMatch.keys(for: "") == [])
    }

    @Test func onlyPeopleNamedInTheMessageAreFound() {
        let found = ContactMatch.mentioned(in: "박노을한테 회의 정리 메일 보내줘", people: people)
        #expect(found == ["박노을": "noeul@mail.test"])
        // 이름만(성 없이) 불러도, 띄어 써도 찾는다
        #expect(ContactMatch.mentioned(in: "노을 씨에게 보내줘", people: people).keys.sorted() == ["박노을"])
        // 아무도 부르지 않았으면 아무도 나가지 않는다
        #expect(ContactMatch.mentioned(in: "내일 날씨 어때?", people: people).isEmpty)
        #expect(ContactMatch.mentioned(in: "", people: people).isEmpty)
    }

    @Test func peopleWithoutAnAddressAreFoundByNameOnly() {
        let people = MockContacts.demo + [ContactPerson(name: "박노을"), ContactPerson(name: "", nickname: "한별이")]
        #expect(ContactMatch.mentionedWithoutEmail(in: "최구름한테 메일 보내줘", people: people) == ["최구름"])
        // 말에 나오지 않은 사람은 이름도 나가지 않는다
        #expect(ContactMatch.mentionedWithoutEmail(in: "김팀장한테 메일 보내줘", people: people).isEmpty)
        // 같은 이름에 주소가 있는 사람이 있으면 그쪽만 쓴다
        #expect(ContactMatch.mentionedWithoutEmail(in: "박노을한테 메일 보내줘", people: people).isEmpty)
        #expect(ContactMatch.mentioned(in: "박노을한테 메일 보내줘", people: people) == ["박노을": "noeul@mail.test"])
        // 주소 없는 사람은 `{이름: 주소}`에 들어가지 않는다
        #expect(ContactMatch.mentioned(in: "최구름한테 메일 보내줘", people: people).isEmpty)
        #expect(ContactMatch.mentionedWithoutEmail(in: "한별이한테 메일 보내줘", people: people) == ["한별이"])
    }

    @Test func aNicknameIsSentAsTheNameISaid() {
        // 별명으로만 불렀으면 그 별명으로 알린다
        #expect(ContactMatch.mentioned(in: "김팀장한테 메일 보내줘", people: people) == ["김팀장": "haneul.kim@mail.test"])
        #expect(ContactMatch.mentioned(in: "김하늘한테 메일 보내줘", people: people) == ["김하늘": "haneul.kim@mail.test"])
    }

    @Test func severalAddressesAreAllListedWithTheirLabels() {
        // 어느 주소인지 앱이 고르지 않는다
        let found = ContactMatch.mentioned(in: "이바다에게 보내줘", people: people)
        #expect(found == ["이바다 (직장)": "bada@work.test", "이바다 (집)": "bada@home.test"])
    }

    @Test func sameNamesGetNumbersAndBadAddressesAreDropped() {
        let twins = [
            ContactPerson(name: "최구름", emails: [.init(address: "one@mail.test")]),
            ContactPerson(name: "최구름", emails: [.init(address: "two@mail.test")]),
            // 맥이 받지 않는 꼴의 주소: 하나라도 가면 요청 전체가 거절된다
            ContactPerson(name: "최구름", emails: [.init(address: "구름@메일.test"), .init(address: "no-at-sign")]),
        ]
        let found = ContactMatch.mentioned(in: "최구름에게 보내줘", people: twins)
        #expect(found == ["최구름": "one@mail.test", "최구름 2": "two@mail.test"])
        #expect(ContactMatch.isAddress("a.b+c@mail-1.test"))
        #expect(!ContactMatch.isAddress("a b@mail.test"))
        #expect(!ContactMatch.isAddress("a@mail"))
    }

    @Test func permissionIsFirstAskedOnlyOnAMailRequest() {
        #expect(ContactMatch.looksLikeMail("김팀장한테 메일 보내줘"))
        #expect(ContactMatch.looksLikeMail("이거 전달해줘"))
        #expect(!ContactMatch.looksLikeMail("내일 날씨 어때?"))
    }
}

@Suite("연락처: 요청에 싣기")
struct ContactRequestTests {
    private func body(_ contacts: [String: String]) throws -> [String: Any] {
        var extras = MessageExtras.none
        extras.contacts = contacts
        let body = AgentHTTPClient.MessageBody(
            text: "김팀장한테 메일 보내줘", conversationID: nil, context: nil, messageID: "m1", replyTaskID: nil, tone: "polite", features: [],
            extras: extras
        )
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    @Test func contactsGoAsNameToAddress() throws {
        let sent = try body(["김팀장": "haneul.kim@mail.test"])["contacts"] as? [String: String]
        #expect(sent == ["김팀장": "haneul.kim@mail.test"])
    }

    @Test func noKeyWhenThereIsNoOne() throws {
        // 없으면 맥은 그 대화의 앞선 값을 그대로 쓴다
        #expect(try body([:])["contacts"] == nil)
    }

    @Test func namesWithoutAnAddressGoAsAList() throws {
        var extras = MessageExtras.none
        extras.contacts = ["김팀장": "haneul.kim@mail.test"]
        extras.contactsNoEmail = ["최구름", "김팀장", "", String(repeating: "가", count: 51)]
        let body = AgentHTTPClient.MessageBody(
            text: "최구름한테 메일 보내줘", conversationID: nil, context: nil, messageID: "m1", replyTaskID: nil, tone: "polite", features: [],
            extras: extras
        )
        let sent = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        // 주소 있는 쪽과 겹치는 이름, 빈 이름, 너무 긴 이름은 가지 않는다
        #expect(sent["contacts_no_email"] as? [String] == ["최구름"])
        // 없으면 키도 없다 (맥은 앞선 값을 그대로 쓴다)
        #expect(try self.body(["김팀장": "haneul.kim@mail.test"])["contacts_no_email"] == nil)
    }

    @Test func entriesTheMacWouldRejectNeverGo() throws {
        let long = String(repeating: "가", count: 51)
        let sent = try body(["김팀장": "haneul.kim@mail.test", long: "long@mail.test", "박노을": "주소 아님"])["contacts"] as? [String: String]
        #expect(sent == ["김팀장": "haneul.kim@mail.test"])
    }
}

@MainActor
@Suite("연락처: 대화 흐름")
struct ContactChatTests {
    let context: ModelContext
    let meeting: Meeting

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        meeting = Meeting(title: "주간 회의")
        context.insert(meeting)
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
    }

    private func session(_ agent: MockAgentClient, contacts: MockContacts?) async -> AskSession {
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero, contacts: contacts)
        session.attach(context)
        await session.checkAgent()
        return session
    }

    @Test func onlyTheNamedPersonLeavesThePhone() async {
        let agent = MockAgentClient(v2: true, mail: MockMail())
        let session = await session(agent, contacts: MockContacts())
        await session.send("김팀장한테 지난 회의 정리 메일 보내줘", meetings: [meeting])
        let received = await agent.receivedExtras
        #expect(received.last?.contacts == ["김팀장": "haneul.kim@mail.test"])
    }

    @Test func nothingIsReadWithoutAName() async {
        let agent = MockAgentClient(v2: true)
        let session = await session(agent, contacts: MockContacts())
        await session.send("안녕", meetings: [])
        #expect(await agent.receivedExtras.last?.contacts.isEmpty == true)
    }

    @Test func peopleNamedEarlierStayForTheConversationAndGoWithANewChat() async {
        let agent = MockAgentClient(v2: true)
        let session = await session(agent, contacts: MockContacts())
        await session.send("김팀장 얘기 좀 하자", meetings: [])
        await session.send("박노을 얘기도 있어", meetings: [])
        let received = await agent.receivedExtras
        #expect(received.count == 2)
        #expect(received.last?.contacts.keys.sorted() == ["김팀장", "박노을"])
        session.reset()
        await session.send("안녕", meetings: [])
        #expect(await agent.receivedExtras.last?.contacts.isEmpty == true)
    }

    @Test func permissionIsAskedOnceOnAMailRequestOnly() async {
        let agent = MockAgentClient(v2: true)
        let book = MockContacts(access: .notAsked)
        let session = await session(agent, contacts: book)
        await session.send("김팀장 잘 지내나?", meetings: [])
        // 메일 부탁이 아니면 묻지 않고, 읽지도 않는다
        #expect(book.requests == 0)
        #expect(book.reads == 0)
        await session.send("김팀장한테 메일 보내줘", meetings: [])
        #expect(book.requests == 1)
        #expect(await agent.receivedExtras.last?.contacts == ["김팀장": "haneul.kim@mail.test"])
        await session.send("김팀장한테 메일 또 보내줘", meetings: [])
        #expect(book.requests == 1)
    }

    @Test func aRefusalMeansNothingIsReadOrSent() async {
        let agent = MockAgentClient(v2: true)
        let refused = MockContacts(access: .notAsked, grants: false)
        let session = await session(agent, contacts: refused)
        await session.send("김팀장한테 메일 보내줘", meetings: [])
        await session.send("김팀장한테 메일 보내줘", meetings: [])
        // 거절한 뒤에는 다시 묻지 않는다
        #expect(refused.requests == 1)
        #expect(refused.reads == 0)
        #expect(await agent.receivedExtras.allSatisfy(\.contacts.isEmpty))

        let off = MockContacts(access: .denied)
        let other = await self.session(MockAgentClient(v2: true), contacts: off)
        await other.send("김팀장한테 메일 보내줘", meetings: [])
        #expect(off.requests == 0)
        #expect(off.reads == 0)
    }

    @Test func aSessionWithAFakeMacNeverTouchesRealContacts() async {
        // 주소록을 따로 주지 않으면, 가짜 맥과 함께일 때는 연락처를 쓰지 않는다 (테스트·데모가 실제 연락처를 읽지 않는다)
        let agent = MockAgentClient(v2: true)
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        session.attach(context)
        await session.checkAgent()
        await session.send("김팀장한테 메일 보내줘", meetings: [])
        #expect(await agent.receivedExtras.last?.contacts.isEmpty == true)
    }

    @Test func aNamedPersonWithoutAnAddressGoesAsANameOnly() async {
        let agent = MockAgentClient(v2: true, mail: MockMail())
        let session = await session(agent, contacts: MockContacts())
        await session.send("최구름한테 지난 회의 정리 메일 보내줘", meetings: [meeting])
        let received = await agent.receivedExtras
        #expect(received.last?.contactsNoEmail == ["최구름"])
        #expect(received.last?.contacts.isEmpty == true)
        // 맥은 없다고 하지 않고 주소를 묻는다. 작업은 만들어지지 않는다
        #expect(session.messages.last?.text.contains("메일 주소가 없어요") == true)
        #expect(session.messages.last?.agent == nil)
    }

    @Test func namesWithoutAnAddressStayForTheConversationOnly() async {
        let agent = MockAgentClient(v2: true)
        let session = await session(agent, contacts: MockContacts())
        await session.send("최구름한테 메일 보내줘", meetings: [])
        await session.send("안녕", meetings: [])
        #expect(await agent.receivedExtras.last?.contactsNoEmail == ["최구름"])
        session.reset()
        await session.send("안녕", meetings: [])
        #expect(await agent.receivedExtras.last?.contactsNoEmail.isEmpty == true)
    }

    @Test func mailToSomeoneElseIsMarkedAndNeverCalledDelivered() async throws {
        let agent = MockAgentClient(v2: true, mail: MockMail())
        let session = await session(agent, contacts: MockContacts())
        await session.send("김팀장한테 지난 회의 정리 메일 보내줘", meetings: [meeting])

        let asking = try #require(session.messages.last?.agent)
        #expect(asking.phase == .awaitingApproval)
        let draft = try #require(asking.draft)
        #expect(draft.isExternal)
        #expect(draft.fields.first { $0.label == "보내는 사람" }?.value == "me@naver.test")
        #expect(draft.fields.first { $0.label == AgentDraft.recipientLabel }?.value == "haneul.kim@mail.test")

        await session.decide(asking.id, approve: true)
        let done = try #require(session.messages.last?.agent)
        #expect(done.phase == .done)
        #expect(done.sent.first?.external == true)
        // 받는 분의 받은편지함은 볼 수 없다: 확인했다고도, "아직"이라고도 하지 않는다
        #expect(done.sent.first?.verified == .acceptedOnly)
        #expect(done.currentStatus == "메일을 보냈어요. 받는 분의 도착은 확인할 수 없어요")
    }

    @Test func mailToMyselfIsNotMarked() async throws {
        let session = await session(MockAgentClient(v2: true, mail: MockMail()), contacts: MockContacts())
        await session.send("지난 회의 내용 나한테 메일로 보내줘", meetings: [meeting])
        let draft = try #require(session.messages.last?.agent?.draft)
        #expect(draft.isSend)
        #expect(!draft.isExternal)
    }
}

@Suite("연락처: 받은 형식과 알리는 글")
struct ContactFormatTests {
    @Test func externalMarkIsOnlyForMailBeingSent() {
        let fields = [AgentDraft.Field(label: "받는 사람", value: "haneul.kim@mail.test")]
        #expect(AgentDraft(approvalID: "a", action: "보내기", fields: fields, kind: "send", external: true).isExternal)
        #expect(!AgentDraft(approvalID: "a", action: "보내기", fields: fields, kind: "send").isExternal)
        // 저장만 하는 초안은 표시하지 않는다
        #expect(!AgentDraft(approvalID: "a", action: "임시 저장", fields: fields, kind: "draft", external: true).isExternal)
    }

    @Test func oldRecordsWithoutTheMarkStillOpen() throws {
        let old = #"{"to":["me@naver.test"],"verified":"delivered"}"#
        let sent = try JSONDecoder().decode(AgentSent.self, from: Data(old.utf8))
        #expect(sent.external == nil)
        #expect(sent.verified == .delivered)
    }

    @Test func contactsRowAppearsOnlyAfterBeingAsked() {
        #expect(PermissionItem.contacts(.notDetermined) == nil)
        #expect(PermissionItem.contacts(.granted)?.title == "연락처")
        #expect(PermissionItem.contacts(.denied)?.state == .denied)
    }
}

@Suite("연락처: 누구에게 보내는지 알리는 글")
struct SendOthersFactsTests {
    @Test func footerSaysOthersOnlyWhenTheMacSendsToOthers() {
        let only = MacAgentFacts(setup: DialogSetup(place: .cloud)).footer
        #expect(only.contains("내 주소로만 보내요"))
        let others = MacAgentFacts(setup: DialogSetup(place: .cloud, sendsOthers: true)).footer
        #expect(!others.contains("내 주소로만"))
        #expect(others.contains("연락처에 있는 사람·내가 직접 쓴 주소"))
        // 로컬 판단인 맥도 같다
        #expect(MacAgentFacts(setup: DialogSetup(place: .local, sendsOthers: true)).footer.contains("연락처에 있는 사람"))
    }

    @Test func theMarkSurvivesBeingStored() {
        let setup = DialogSetup(place: .cloud, sendsOthers: true)
        #expect(DialogSetup(stored: setup.stored)?.sendsOthers == true)
        #expect(DialogSetup(stored: DialogSetup(place: .cloud).stored)?.sendsOthers == false)
    }

    @Test func contactsRowTellsWhatLeavesThePhone() {
        for place in [DialogPlace.local, .cloud] {
            let row = MacAgentFacts(setup: DialogSetup(place: place)).rows.first { $0.text.contains("연락처에서 그 사람만") }
            #expect(row?.note?.contains("주소록 전체는 보내지 않아요") == true)
            #expect(row?.note?.contains("메일 주소가 없으면 이름만 가요") == true)
        }
    }
}

@Suite("연락처: 맥이 주는 표시 읽기")
struct ExternalDecodingTests {
    private static let fields = #"{"보내는 사람":"me@naver.test","받는 사람":"haneul.kim@mail.test","제목":"정리","본문":"안녕하세요."}"#
    private static let head = #""id":"S7gk2Lw0","task":"회의 정리 메일 보내기","title":"회의 정리 메일 보내기""#

    private func decode(_ json: String) throws -> AgentTaskState {
        try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
    }

    @Test func approvalAndWaitingCardsCarryTheMark() throws {
        let approval = try decode("""
        {\(Self.head),"status":"awaiting_approval","approval":{"approval_id":"ap_1","action":"보내기","kind":"send",\
        "url":"mailto:haneul.kim@mail.test","sha256":"ab","external":true,"fields":\(Self.fields)}}
        """)
        #expect(approval.draft?.isExternal == true)
        // 보내기 전 기다리는 카드에도 같은 표시가 온다
        let waiting = try decode("""
        {\(Self.head),"status":"send_pending","send":{"sha256":"ab","external":true,"fields":\(Self.fields),\
        "cancel_until":"2020-01-01T00:00:10+00:00","now":"2020-01-01T00:00:00+00:00"}}
        """)
        #expect(waiting.outgoing?.isExternal == true)
    }

    @Test func noMarkMeansMailToMyself() throws {
        let approval = try decode("""
        {\(Self.head),"status":"awaiting_approval","approval":{"approval_id":"ap_1","action":"보내기","kind":"send",\
        "url":"mailto:me@naver.test","sha256":"ab","fields":\(Self.fields)}}
        """)
        #expect(approval.draft?.isExternal == false)
    }

    @Test func sentResultSaysTheInboxCannotBeChecked() throws {
        let done = try decode("""
        {\(Self.head),"status":"completed","result":{"outcome":"completed","summary":"메일을 보냈습니다","approved_drafts":[],\
        "report":{"done":[],"blocked":[],"sources":[],"sent":[{"to":"haneul.kim@mail.test","sent_at":"2026-11-16T01:00:12+00:00",\
        "verified":"accepted_only","detail":"받는 분의 도착은 확인할 수 없음","external":true}]}}}
        """)
        #expect(done.sent.first?.external == true)
        #expect(done.currentStatus == "메일을 보냈어요. 받는 분의 도착은 확인할 수 없어요")
    }
}
