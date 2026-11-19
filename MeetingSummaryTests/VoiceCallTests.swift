import Foundation
import Testing
@testable import MeetingSummary

// 에이전트에게 거는 전화 (D134, 맥의 D116). 모두 지어낸 말이다.

@Suite("통화: 읽을 글")
struct VoiceTextTests {
    @Test func markdownLinksAndEmojiAreNotRead() {
        let text = """
        ## 이번 주 정리 🎉
        - **가상 회의** 2건 [1]
        - 자료는 [여기](https://example.com/a) 있어요 https://example.com/b
        """
        #expect(VoiceText.spoken(text) == "이번 주 정리. 가상 회의 2건. 자료는 여기 있어요.")
    }

    @Test func longTextIsCutAtASentence() {
        let sentence = "가상 팀의 이번 주 회의는 네 건이었고 할 일은 아홉 개를 끝냈어요. "
        let spoken = VoiceText.spoken(String(repeating: sentence, count: 8))
        #expect(spoken.hasSuffix(VoiceText.more))
        #expect(spoken.count <= VoiceText.limit + VoiceText.more.count + 2)
        #expect(spoken.contains("끝냈어요. " + VoiceText.more))
    }

    @Test func shortTextStaysAsItIs() {
        #expect(VoiceText.spoken("네, 지금 볼게요.") == "네, 지금 볼게요.")
        #expect(VoiceText.clean("  \n ") == nil)
    }
}

@Suite("통화: 말이 끝났는지")
struct VoiceEndpointTests {
    @Test func waitsForAPauseAfterSpeech() {
        var endpoint = VoiceEndpoint()
        let start = Date(timeIntervalSince1970: 1000)
        #expect(!endpoint.isDone(at: start.addingTimeInterval(5)))
        endpoint.hear("내일 일정", final: false, at: start)
        #expect(endpoint.text == "내일 일정")
        #expect(!endpoint.isDone(at: start.addingTimeInterval(0.5)))
        endpoint.hear("내일 일정 알려 줘", final: true, at: start.addingTimeInterval(0.8))
        endpoint.hear("그리고", final: false, at: start.addingTimeInterval(1.2))
        #expect(endpoint.text == "내일 일정 알려 줘 그리고")
        #expect(!endpoint.isDone(at: start.addingTimeInterval(2.0)))
        #expect(endpoint.isDone(at: start.addingTimeInterval(2.6)))
        endpoint.reset()
        #expect(endpoint.text.isEmpty && !endpoint.isDone(at: start.addingTimeInterval(10)))
    }
}

@Suite("통화: 맥과 주고받기")
@MainActor
struct VoiceCallSessionTests {
    @Test func repliesCarryWhatToRead() throws {
        let json = """
        {"conversation_id":"c_1","replies":[{"text":"네! 😊 **내일**은 맑아요","speak":" 네, 내일은 맑아요. "},{"text":"우산은 필요 없어요"}],
         "action":{"type":"none"}}
        """
        let reply = try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200)
        #expect(reply.speak(at: 0) == "네, 내일은 맑아요.")
        #expect(reply.speak(at: 1) == nil)
        let plain = try AgentHTTPClient.decodeReply(data: Data(#"{"conversation_id":"c","replies":[{"text":"네"}],"action":{"type":"none"}}"#.utf8), status: 200)
        #expect(plain.speaks.isEmpty)
    }

    @Test func aFinishedTaskCarriesWhatToRead() throws {
        let json = """
        {"id":"t_v1","status":"completed","task":"가상 주간 정리","title":"주간 정리",\
        "created_at":"2026-11-17T12:30:00+00:00","updated_at":"2026-11-17T12:30:28+00:00","steps":[],\
        "result":{"outcome":"completed","summary":"읽었어요","approved_drafts":[],\
        "report":{"done":["가상 결과"],"blocked":[],"sources":[],"speak":"이번 주 회의는 4건이에요."}}}
        """
        let state = try AgentHTTPClient.decodeTask(data: Data(json.utf8), status: 200)
        #expect(state.report?.speak == "이번 주 회의는 4건이에요.")
    }

    @Test func onlyCallMessagesSayTheyAreCalls() async throws {
        let agent = MockAgentClient(v2: true)
        await agent.script(AgentReply(conversationID: "", replies: ["**네**, 내일은 맑아요."], action: .none))
        await agent.script(AgentReply(conversationID: "", replies: ["네, 그럴게요."], action: .none))
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        #expect(await session.supportsVoiceCall())
        session.voiceCall = true
        await session.send("내일 날씨 어때?", meetings: [])
        #expect(session.messages.last?.speak == "네, 내일은 맑아요.")
        session.voiceCall = false
        await session.send("고마워", meetings: [])
        let sent = await agent.receivedExtras.map { $0.clientFeatures.contains(MessageExtras.voiceCallFeature) }
        #expect(sent == [true, false])
        #expect(session.messages.last?.speak == nil)
    }

    @Test func theRequestNamesTheCallOnlyForAMacThatKnowsIt() throws {
        var extras = MessageExtras.none
        extras.clientFeatures = [MessageExtras.voiceCallFeature]
        func features(_ known: Set<String>) throws -> [String]? {
            let body = AgentHTTPClient.MessageBody(
                text: "가상", conversationID: "c_1", context: nil, messageID: nil, replyTaskID: nil,
                tone: "friendly", features: known, extras: extras
            )
            let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
            return object["client_features"] as? [String]
        }
        #expect(try features([AgentFeature.voiceCall]) == ["voice_call"])
        #expect(try features([]) == nil)
    }
}

// 맥이 준 읽을 글에 이모지가 섞여 와도 읽지 않는다, 목소리는 좋은 음질부터 (D135)
@Suite("통화: 이모지와 목소리")
struct VoiceEmojiAndVoiceTests {
    @Test func emojiInTheMacsTextIsNotRead() {
        #expect(VoiceText.spoken("네, 좋아요 😊👍 내일 봐요 ❤️", limit: VoiceText.sayLimit) == "네, 좋아요 내일 봐요.")
        #expect(VoiceText.spoken("확인했어요 ✅ → 다음은 ⭐️ 예약", limit: VoiceText.sayLimit) == "확인했어요 다음은 예약.")
        #expect(VoiceText.spoken("👨‍👩‍👧 가족 일정 3건", limit: VoiceText.sayLimit) == "가족 일정 3건.")
        #expect(VoiceText.spoken("🎉", limit: VoiceText.sayLimit).isEmpty)
    }

    @Test func numbersAndSignsStay() {
        #expect(VoiceText.spoken("방문 1,450회 · 좋아요 #3", limit: VoiceText.sayLimit) == "방문 1,450회 · 좋아요 #3.")
    }

    @Test func theFallbackIsTheBestPhoneVoice() {
        let plain = VoiceChoice.Option(id: "a", name: "유나", quality: 1)
        let premium = VoiceChoice.Option(id: "b", name: "유나", quality: 3)
        let enhanced = VoiceChoice.Option(id: "c", name: "민수", quality: 2)
        #expect(VoiceChoice.fallback(from: [plain, enhanced, premium])?.id == "b")
        #expect(VoiceChoice.fallback(from: [plain, enhanced])?.id == "c")
        #expect(VoiceChoice.fallback(from: []) == nil)
    }
}

// 통화 답을 내 목소리로 (D136, 맥의 D117). 소리는 모두 지어낸 조용한 조각이다
@Suite("통화: 맥이 만든 내 목소리")
@MainActor
struct MacVoiceTests {
    @Test func chunkStatusesMeanWhatTheMacSays() {
        #expect(AgentHTTPClient.decodeVoiceChunk(data: MockVoice.wav, status: 200) == .audio(MockVoice.wav))
        #expect(AgentHTTPClient.decodeVoiceChunk(data: Data(), status: 204) == .end)
        #expect(AgentHTTPClient.decodeVoiceChunk(data: Data(), status: 409) == .notReady)
        #expect(AgentHTTPClient.decodeVoiceChunk(data: Data(), status: 503) == .unavailable)
        #expect(AgentHTTPClient.decodeVoiceChunk(data: Data(), status: 404) == .gone)
        // wav라고 하기엔 너무 짧은 200은 쓰지 않는다
        #expect(AgentHTTPClient.decodeVoiceChunk(data: Data(count: 10), status: 200) == .unavailable)
    }

    @Test func wavChunksAreRead() throws {
        let audio = try #require(WavPCM.parse(MockVoice.wav))
        #expect(audio.sampleRate == 24_000 && audio.channels == 1 && audio.samples.count == 2400)
        #expect(WavPCM.parse(Data("not a wav file at all, just some text here....".utf8)) == nil)
        // fmt와 data 사이에 다른 덩어리가 있어도 읽는다
        var bytes = [UInt8](MockVoice.wav)
        let extra: [UInt8] = Array("LIST".utf8) + [4, 0, 0, 0] + Array("INFO".utf8)
        bytes.insert(contentsOf: extra, at: 36)
        #expect(WavPCM.parse(Data(bytes))?.samples.count == 2400)
    }

    @Test func repliesCarryTheirVoice() throws {
        let json = """
        {"conversation_id":"c_1","replies":[{"text":"네","speak":"네","voice_id":"v_abc"},{"text":"그리고","voice_id":"../x"}],"action":{"type":"none"}}
        """
        let reply = try AgentHTTPClient.decodeReply(data: Data(json.utf8), status: 200)
        #expect(reply.voiceID(at: 0) == "v_abc")
        // 주소에 넣을 수 없는 번호는 버린다
        #expect(reply.voiceID(at: 1) == nil)
    }

    @Test func aCallMessageKeepsTheVoiceTheMacStarted() async throws {
        let agent = MockAgentClient(v2: true)
        await agent.setTakesVoice(true)
        await agent.script(AgentReply(conversationID: "", replies: ["네, 내일은 맑아요."], action: .none))
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        session.voiceCall = true
        await session.send("내일 날씨 어때?", meetings: [])
        #expect(session.messages.last?.voiceID == "v_1")
        #expect(await session.voiceSource() != nil)
    }

    @Test func noChunkMeansThePhoneReads() async {
        let agent = MockAgentClient(v2: true)
        let player = MacVoicePlayer()
        await agent.setVoice("v_down", chunks: [.unavailable])
        #expect(await player.play(id: "v_down", from: agent) == .failed)
        await agent.setVoice("v_slow", chunks: [.notReady, .notReady, .notReady])
        // 한 조각도 없이 두 번 "아직"이면 기다리지 않는다 (같은 조각을 다시 묻는다)
        #expect(await player.play(id: "v_slow", from: agent) == .failed)
        #expect(await player.play(id: "v_missing", from: agent) == .failed)
    }

    /// 맥이 보내는 것과 같은 꼴의 조각: 24kHz 모노 16bit, 0.96초 (46,124바이트), 지어낸 낮은 음
    static func macLikeChunk(seconds: Double = 0.96) -> Data {
        let samples = Int(24_000 * seconds)
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        var bytes = Array("RIFF".utf8) + le32(36 + samples * 2) + Array("WAVEfmt ".utf8)
        bytes += le32(16) + le16(1) + le16(1) + le32(24_000) + le32(48_000) + le16(2) + le16(16)
        bytes += Array("data".utf8) + le32(samples * 2)
        for i in 0..<samples {
            let value = Int16(sin(Double(i) * 2 * .pi * 220 / 24_000) * 3000)
            bytes += le16(Int(UInt16(bitPattern: value)))
        }
        return Data(bytes)
    }

    @Test func macLikeChunksPlayBackToBack() async {
        #expect(Self.macLikeChunk().count == 46_124)
        let agent = MockAgentClient(v2: true)
        let player = MacVoicePlayer()
        await agent.setVoice("v_two", chunks: [.audio(Self.macLikeChunk()), .audio(Self.macLikeChunk()), .end])
        let started = Date.now
        #expect(await player.play(id: "v_two", from: agent) == .played)
        // 두 조각을 이어 끝까지 기다렸다 (끝났다는 신호가 없어도 갇히지 않는다)
        let elapsed = Date.now.timeIntervalSince(started)
        #expect(elapsed > 1.7 && elapsed < 4.5)
        #expect(await agent.cancelledVoices.isEmpty)
        // 읽는 도중 다음 조각이 계속 "아직"이면 읽은 데까지로 끝낸다 (끝없이 묻지 않는다)
        await agent.setVoice("v_stuck", chunks: [.audio(Self.macLikeChunk(seconds: 0.2)), .notReady])
        #expect(await player.play(id: "v_stuck", from: agent) == .played)
    }

    @Test func interruptingStopsAtOnceAndCancelsTheMac() async {
        let agent = MockAgentClient(v2: true)
        let player = MacVoicePlayer()
        await agent.setVoice("v_long", chunks: Array(repeating: .audio(Self.macLikeChunk()), count: 5) + [.end])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            player.stop()
        }
        let started = Date.now
        #expect(await player.play(id: "v_long", from: agent) == .stopped)
        #expect(Date.now.timeIntervalSince(started) < 1.5)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await agent.cancelledVoices == ["v_long"])
    }

    @Test func joinedChunksMakeOneWav() throws {
        let a = try #require(WavPCM.parse(Self.macLikeChunk(seconds: 0.1)))
        let b = try #require(WavPCM.parse(Self.macLikeChunk(seconds: 0.2)))
        let joined = WavPCM.encode(samples: a.samples + b.samples, sampleRate: 24_000, channels: 1)
        let back = try #require(WavPCM.parse(joined))
        #expect(back.sampleRate == 24_000 && back.channels == 1)
        #expect(back.samples == a.samples + b.samples)
        #expect(joined.count == 44 + (2_400 + 4_800) * 2)
    }

    @Test func chunksPlayOneAfterAnotherNeverOnTopOfEachOther() async {
        // 조각이 한꺼번에 와도 (맥은 말보다 빨리 만든다) 겹쳐 틀지 않고 차례로 끝까지 튼다
        let agent = MockAgentClient(v2: true)
        let player = MacVoicePlayer()
        await agent.setVoice("v_fast", chunks: Array(repeating: .audio(Self.macLikeChunk(seconds: 0.5)), count: 4) + [.end])
        let started = Date.now
        #expect(await player.play(id: "v_fast", from: agent) == .played)
        let elapsed = Date.now.timeIntervalSince(started)
        #expect(elapsed > 1.9 && elapsed < 3.5)
    }

    @Test func theRingStopsOnceRightBeforeTheFirstChunk() async {
        let agent = MockAgentClient(v2: true)
        let player = MacVoicePlayer()
        var starts = 0
        await agent.setVoice("v_hi", chunks: [.audio(Self.macLikeChunk(seconds: 0.1)), .audio(Self.macLikeChunk(seconds: 0.1)), .end])
        #expect(await player.play(id: "v_hi", from: agent) { starts += 1 } == .played)
        #expect(starts == 1)
        // 한 조각도 못 받으면 부르지 않는다 (연결음은 폰 목소리 인사 앞에서 멈춘다)
        await agent.setVoice("v_none", chunks: [.unavailable])
        #expect(await player.play(id: "v_none", from: agent) { starts += 1 } == .failed)
        #expect(starts == 1)
        // 연결음을 멈추고 쉬는 틈에 끊으면 조각을 걸지 않고 멈춘다
        await agent.setVoice("v_cut", chunks: [.audio(Self.macLikeChunk()), .end])
        let started = Date.now
        #expect(await player.play(id: "v_cut", from: agent) { player.stop() } == .stopped)
        #expect(Date.now.timeIntervalSince(started) < 0.5)
    }

    @Test func theRingBackIsOneSecondOfToneThenRest() throws {
        let ring = try #require(WavPCM.parse(RingBack.wav))
        #expect(ring.sampleRate == 24_000 && ring.channels == 1 && ring.samples.count == 72_000)
        let peak = { (range: Range<Int>) in ring.samples[range].map { abs(Int($0)) }.max() ?? 0 }
        // 울리는 1초는 들릴 만큼, 쉬는 2초는 조용히. 시작은 부드럽게 (딸깍 소리 없게)
        #expect(peak(2_400..<21_600) > 8_000)
        #expect(peak(24_100..<72_000) == 0)
        #expect(abs(Int(ring.samples[0])) < 100)
        #expect(!VoiceText.spoken(VoiceText.greeting).isEmpty)
    }

}

// 통화는 대화에서 카드 하나로 접는다 (D137). 작업·승인 카드는 접지 않는다
@Suite("통화: 대화 속 통화 카드")
@MainActor
struct CallFoldTests {
    @Test func onlyCallBubblesAreFolded() async throws {
        let agent = MockAgentClient(v2: true)
        await agent.script(AgentReply(conversationID: "", replies: ["네, 내일은 맑아요."], action: .none))
        await agent.script(AgentReply(conversationID: "", replies: ["채팅으로 받은 답이에요."], action: .none))
        let session = AskSession(provider: FakeAskProvider([]), agent: agent, pollInterval: .zero)
        let call = UUID()
        session.voiceCall = true
        session.callID = call
        await session.send("내일 날씨 어때?", meetings: [])
        session.voiceCall = false
        session.callID = nil
        await session.send("고마워", meetings: [])
        #expect(session.messages.map(\.callID) == [call, call, nil, nil])
        let fold = CallFold(rows: session.messages)
        #expect(fold.hosts == [session.messages[0].id])
        #expect(fold.messages(of: call, in: session.messages).count == 2)
    }

    @Test func cardsThatNeedMeStayOpen() {
        var task = AskSession.Message(role: .agent, text: "", engine: .local)
        task.agent = AgentTaskState(id: "t_1", task: "가상 메일 보내기", steps: [], phase: .awaitingApproval)
        #expect(!AskSession.foldsIntoCall(task))
        var login = AskSession.Message(role: .assistant, text: "로그인이 필요해요", engine: .local)
        login.siteLogin = "naver"
        #expect(!AskSession.foldsIntoCall(login))
        #expect(AskSession.foldsIntoCall(AskSession.Message(role: .assistant, text: "네", engine: .local)))
        #expect(AskSession.foldsIntoCall(AskSession.Message(role: .user, text: "응", engine: .local)))
    }

    @Test func theCardSaysWhenHowLongAndHowMuch() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var first = AskSession.Message(role: .user, text: "가", engine: .local)
        first.date = start
        var last = AskSession.Message(role: .assistant, text: "나", engine: .local)
        last.date = start.addingTimeInterval(150)
        let line = CallFold.line([first, last], live: false)
        #expect(line.hasPrefix("통화 · ") && line.hasSuffix(" · 3분"))
        #expect(!line.contains("마디"))
        #expect(CallFold.line([first], live: true).hasPrefix("통화 중 · "))
        #expect(!CallFold.line([first], live: true).contains("분"))
    }
}
