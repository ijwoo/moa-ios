@preconcurrency import AVFoundation
import Foundation
import Observation
import os
import Speech

/// 소리로 읽을 글 (D134). 맥이 준 `speak`가 없을 때(회의 답·오류·작업 결과의 줄글) 화면의 글에서 만든다
enum VoiceText {
    /// 한 번에 읽는 길이 (맥의 `report.speak`와 같은 160자)
    static let limit = 160
    static let more = "자세한 건 화면에 있어요."
    /// 맥이 준 읽을 글을 거를 때의 길이 (맥의 글은 자르지 않는다)
    static let sayLimit = 600
    /// 전화를 받을 때의 인사 (D139)
    static let greeting = "여보세요, 모아예요. 오늘은 뭐부터 할까요?"

    /// 소리로 읽으면 안 되는 그림 글자: 이모지, 이모지를 잇는 글자(ZWJ·이체 선택자·피부색), 화살표·도형·별 같은 기호
    nonisolated static func isPictograph(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if scalar.properties.isEmojiPresentation { return true }
        if scalar.properties.isEmoji, v > 0x238C { return true }
        if v == 0x200D || (0xFE00...0xFE0F).contains(v) || (0x1F3FB...0x1F3FF).contains(v) || v == 0x20E3 { return true }
        // 화살표, 도형, 별·체크 같은 기호
        return (0x2190...0x21FF).contains(v) || (0x25A0...0x25FF).contains(v) || (0x2600...0x27BF).contains(v) || (0x2B00...0x2BFF).contains(v)
    }

    /// 앞뒤 빈칸을 떼고, 빈 글이면 nil
    nonisolated static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// 화면의 글을 귀로 듣는 말로: 마크다운·링크·주소·이모지·근거 번호를 빼고, 줄은 문장으로 잇고, 길면 문장 경계에서 끊는다
    nonisolated static func spoken(_ text: String, limit: Int = VoiceText.limit) -> String {
        var t = text
        // [글](주소) → 글
        t = t.replacing(#/\[([^\]]+)\]\([^)]*\)/#) { String($0.output.1) }
        // 맨 주소
        t = t.replacing(#/https?://\S+/#, with: "")
        // 이모지 (줄 끝에 마침표를 붙이기 전에 뺀다)
        t = String(t.unicodeScalars.filter { !isPictograph($0) }.map(Character.init))
        // 근거 번호 [1], [2, 3]
        t = t.replacing(#/\[\d+(?:\s*,\s*\d+)*\]/#, with: "")
        // 줄 앞의 머리표·번호·제목 표시
        t = t.split(separator: "\n", omittingEmptySubsequences: true).map { line -> String in
            var l = String(line).trimmingCharacters(in: .whitespaces)
            l = l.replacing(#/^(#{1,6}\s+|[-*•·]\s+|\d+[.)]\s+|>\s*)/#, with: "")
            if let last = l.last, !".!?…".contains(last), !l.isEmpty { l += "." }
            return l
        }.joined(separator: " ")
        // 굵게·기울임·코드 표시, 표의 칸 나눔
        t = t.replacing(#/[*_`|]+/#, with: "")
        t = t.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
        guard t.count > limit else { return t }
        // 문장 경계에서 끊는다. 한 문장도 들어가지 않으면 글자로 끊는다
        let head = String(t.prefix(limit))
        if let end = head.lastIndex(where: { ".!?…".contains($0) }), head.distance(from: head.startIndex, to: end) > 10 {
            return String(head[...end]) + " " + more
        }
        return head.trimmingCharacters(in: .whitespaces) + "… " + more
    }
}

/// 말이 끝났는지 (D134): 인식된 글이 있고, 그 뒤로 정해 둔 동안 새 결과가 오지 않으면 끝났다고 본다
struct VoiceEndpoint: Equatable {
    /// 말이 끝났다고 보는 쉼
    static let pause: TimeInterval = 1.3

    private(set) var finals: [String] = []
    private(set) var volatile = ""
    private(set) var lastChange: Date?

    var text: String {
        (finals + [volatile]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func hear(_ text: String, final: Bool, at now: Date) {
        if final {
            volatile = ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { finals.append(trimmed) }
        } else {
            volatile = text
        }
        lastChange = now
    }

    func isDone(at now: Date, pause: TimeInterval = VoiceEndpoint.pause) -> Bool {
        guard !text.isEmpty, let lastChange else { return false }
        return now.timeIntervalSince(lastChange) >= pause
    }

    mutating func reset() { self = VoiceEndpoint() }
}

/// 에이전트에게 거는 전화 (D134, 맥의 D116).
///
/// - 폰이 듣는다: 마이크 소리를 이 기기 안에서 글로 바꾼다 (`SpeechAnalyzer`). 소리는 맥에도 서버에도 가지 않는다
/// - 글은 채팅과 같은 길로 맥에 간다 (지금 대화의 `conversation_id`·회의 자료·연락처 그대로, 통화 표시 "voice_call"만 더해서)
/// - 맥의 답은 폰이 읽는다 (`AVSpeechSynthesizer`). 맥이 준 읽을 글(`speak`)이 있으면 그것을, 없으면 화면의 글을 짧게 다듬어
/// - 승인은 목소리로 받지 않는다: 화면의 승인 카드를 눌러야 한다 (통화 화면에서 카드로 갈 수 있다)
/// - 통화 소리·받아쓴 글을 따로 저장하지 않는다. 주고받은 말은 채팅과 같이 그 대화에 남는다
@MainActor
@Observable
final class VoiceCall {
    enum Phase: Equatable {
        case starting
        case listening
        case thinking
        case speaking
        case ended
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    /// 지금 듣고 있는 내 말 (확정 + 확정 전)
    private(set) var heard = ""
    /// 방금 내가 한 말 (보낸 뒤 화면에 남긴다)
    private(set) var lastSaid = ""
    /// 모아가 방금 한 말 (읽은 글)
    private(set) var lastReply = ""
    private(set) var isMuted = false
    /// 마이크 소리 크기 (0...1, 듣는 동안만)
    private(set) var level: Float = 0
    private(set) var startedAt = Date.now
    /// 화면을 접고 대화를 보는 중
    var isMinimized = false

    let session: AskSession
    private let meetings: () -> [Meeting]
    private let logger = Logger(subsystem: "com.example.meetingsummary", category: "voicecall")

    private var endpoint = VoiceEndpoint()
    private var listener: VoiceListener?
    private let speaker = VoiceSpeaker()
    /// 내 목소리를 만들어 주는 맥 (`voice_tts`, D136). 없으면 폰 목소리로만 읽는다
    private(set) var macVoice: (any AgentProviding)?
    private let macPlayer = MacVoicePlayer()
    /// 연결음 (D139): 걸자마자 모아가 받을 때까지
    private let ringer = RingBack()
    /// 이번 말을 맥이 만든 모아 목소리로 읽는지 (맥이 되면 늘, D140)
    private var usesMacVoice: Bool { macVoice != nil }
    /// 말하는 중에 가운데를 눌렀다: 남은 말은 읽지 않는다
    private var interrupted = false
    /// 보낸 말의 처리가 끝났다 (작업을 맡기면 그 일이 끝날 때까지 늦어진다)
    private var sendFinished = false
    private var loop: Task<Void, Never>?
    /// 지켜보는 작업 (번호 → 마지막으로 본 상태)
    private var watched: [String: AgentTaskState.Phase] = [:]
    private var isDemo = false
    /// 목소리를 고르는 동안은 듣지 않는다 (미리 듣기 소리를 내 말로 받아쓰지 않게)
    var isChoosingVoice = false {
        didSet { if phase == .listening { listener?.accepting = !isMuted && !isChoosingVoice } }
    }

    init(session: AskSession, meetings: @escaping () -> [Meeting]) {
        self.session = session
        self.meetings = meetings
    }

    /// 승인·질문처럼 화면에서 내가 해야 할 일이 있는지
    var needsScreen: Bool { session.hasPendingApproval || demoApproval }
    /// 화면 확인용: 승인 줄을 보인다
    private var demoApproval = false

    // MARK: - 시작·끝

    func start() async {
        guard phase == .starting else { return }
        startedAt = .now
        session.voiceCall = true
        session.callID = UUID()
        // 이 대화에서 이미 돌고 있는 일도 끝나면 알려 준다
        for message in session.messages {
            if let state = message.agent, !state.phase.isFinished { watched[state.id] = state.phase }
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            fail("마이크를 쓸 수 없어요. 설정에서 마이크를 켜 주세요.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // 블루투스 이어폰은 음악용 길(A2DP)로만 소리를 낸다 (D145). 전화용 길(HFP)은 이어폰 마이크를 쓰는 대신
            // 소리를 좁은 대역으로 깎아 모아 목소리가 깨져 들렸다. 듣기는 아이폰 마이크(유선 이어폰이면 그 마이크)로 한다
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let listener = VoiceListener { [weak self] text, final in self?.hear(text, final: final) }
            try await listener.start()
            self.listener = listener
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? "통화를 시작하지 못했어요.")
            return
        }
        Haptic.select()
        // 맥 목소리: 처음 모델을 올리는 데 7~8초 걸리니 걸자마자 데워 둔다
        macVoice = await session.voiceSource()
        if let macVoice { Task { _ = try? await macVoice.voiceWarm() } }
        await greet()
        listen()
        loop = Task { [weak self] in await self?.run() }
    }

    /// 전화를 건 것처럼 (D139): 연결음이 울리다가 모아가 받아 인사한다.
    /// 내 목소리면 맥이 인사의 첫 조각을 보낼 때까지 연결음이 이어진다 (첫 소리까지 4초쯤). 못 받으면 폰 목소리로 인사한다
    private func greet() async {
        guard phase == .starting else { return }
        ringer.start()
        defer { ringer.stop() }
        let text = VoiceText.greeting
        if usesMacVoice, let macVoice {
            // 맥이 만드는 동안 연결음이 적어도 한 번은 울리게 한다
            async let created = try? macVoice.voiceCreate(text: text)
            try? await Task.sleep(for: RingBack.minimum)
            let id = await created
            guard phase == .starting else { return }
            if let id {
                let outcome = await macPlayer.play(id: id, from: macVoice) { [weak self] in
                    guard let self, self.phase == .starting else { return }
                    self.ringer.stop()
                    self.interrupted = false
                    self.phase = .speaking
                    self.lastReply = text
                    // 연결음 플레이어가 출력에서 완전히 빠진 뒤에 첫 조각을 건다 (D140)
                    try? await Task.sleep(for: RingBack.release)
                }
                if outcome != .failed { return }
                logger.info("인사를 맥 목소리로 받지 못해 폰 목소리로 한다")
            }
        } else {
            try? await Task.sleep(for: RingBack.minimum)
        }
        guard phase == .starting else { return }
        ringer.stop()
        await say(text, phoneOnly: true)
    }

    func end() {
        guard phase != .ended else { return }
        loop?.cancel()
        ringer.stop()
        speaker.stop()
        macPlayer.stop()
        listener?.stop()
        listener = nil
        session.voiceCall = false
        session.callID = nil
        phase = .ended
        if !isDemo { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    func toggleMute() {
        isMuted.toggle()
        Haptic.tap()
        if phase == .listening { listener?.accepting = !isMuted }
        if isMuted { endpoint.reset(); heard = ""; level = 0 }
    }

    /// 가운데를 누르면: 말하는 중이면 멈추고 듣는다, 듣는 중이면 지금까지 한 말을 바로 보낸다
    func tapCenter() {
        switch phase {
        case .speaking:
            interrupted = true
            speaker.stop()
            macPlayer.stop()
        case .listening where !endpoint.text.isEmpty:
            submit()
        default: break
        }
    }

    private func fail(_ text: String) {
        logger.error("통화 실패: \(text, privacy: .public)")
        listener?.stop()
        listener = nil
        session.voiceCall = false
        session.callID = nil
        phase = .failed(text)
    }

    // MARK: - 듣기

    private func listen() {
        guard phase != .ended else { return }
        endpoint.reset()
        heard = ""
        phase = .listening
        listener?.accepting = !isMuted && !isChoosingVoice
    }

    private func hear(_ text: String, final: Bool) {
        // 듣는 동안의 결과만 받는다 (보낸 뒤 늦게 확정된 말은 버린다)
        guard phase == .listening, !isMuted, !isChoosingVoice else { return }
        endpoint.hear(text, final: final, at: .now)
        heard = endpoint.text
    }

    /// 0.1초마다: 말이 끝났는지 보고, 소리 크기를 옮기고, 지켜보는 작업이 바뀌었는지 본다
    private func run() async {
        while !Task.isCancelled, phase != .ended {
            try? await Task.sleep(for: .milliseconds(100))
            level = phase == .listening && !isMuted ? (listener?.level ?? 0) : 0
            if phase == .listening, endpoint.isDone(at: .now) { submit() }
            if phase == .listening, endpoint.text.isEmpty { await checkTasks() }
        }
    }

    // MARK: - 보내기와 답 읽기

    private func submit() {
        let text = endpoint.text
        guard !text.isEmpty, phase == .listening else { return }
        listener?.accepting = false
        endpoint.reset()
        heard = ""
        lastSaid = text
        phase = .thinking
        Haptic.tap()
        Task { await send(text) }
    }

    private func send(_ text: String) async {
        // 승인을 기다리는 동안 보낸 말은 채팅에서도 받지 않는다: 카드를 누르도록 알린다
        if session.hasPendingApproval {
            await say("먼저 화면의 승인 카드를 눌러 주세요.")
            listen()
            return
        }
        let before = session.messages.count
        sendFinished = false
        Task { [weak self, session, meetings] in
            await session.send(text, meetings: meetings())
            self?.sendFinished = true
        }
        // 답이 오기를 기다린다. 작업을 맡기면 send는 그 일이 끝날 때까지 돌아오지 않으니, 첫 답이 붙으면 멈춘다
        let deadline = Date.now.addingTimeInterval(90)
        while phase == .thinking, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
            if sendFinished { break }
            if !session.isLoading, newReplies(after: before).contains(where: { $0.role != .user }) { break }
        }
        guard phase == .thinking else { return }
        var lines: [(text: String, voice: String?)] = []
        for message in newReplies(after: before) {
            if let line = spokenLine(for: message) { lines.append(line) }
        }
        if lines.isEmpty { lines = [(sendFinished ? "답을 받지 못했어요. 다시 말씀해 주세요." : "아직 답이 오지 않았어요. 화면에서 확인해 주세요.", nil)] }
        interrupted = false
        for line in lines where !interrupted { await say(line.text, voice: line.voice) }
        listen()
    }

    private func newReplies(after index: Int) -> ArraySlice<AskSession.Message> {
        let messages = session.messages
        return index < messages.count ? messages[index...] : []
    }

    /// 한 말풍선을 읽을 글. 내 말·날씨 카드의 요약처럼 읽을 필요가 없는 것은 nil
    /// 맥이 그 말의 목소리를 만들기 시작했으면 그 번호도 (`voice_id`)
    private func spokenLine(for message: AskSession.Message) -> (text: String, voice: String?)? {
        switch message.role {
        case .user: return nil
        case .agent:
            guard let state = message.agent else { return nil }
            watched[state.id] = state.phase
            if let speak = session.voiceAcks[state.id] { return (speak, session.voiceAckIDs[state.id]) }
            return (VoiceText.spoken(state.ack ?? "네, 해 볼게요."), nil)
        case .error:
            return (VoiceText.spoken(message.text), nil)
        default:
            if let speak = message.speak { return (speak, message.voiceID) }
            return (VoiceText.spoken(message.text), nil)
        }
    }

    /// 지켜보는 작업이 승인·질문을 기다리거나 끝났으면 알린다
    private func checkTasks() async {
        for message in session.messages {
            guard let state = message.agent, let seen = watched[state.id], seen != state.phase else { continue }
            watched[state.id] = state.phase
            let line: String?
            switch state.phase {
            case .awaitingApproval:
                line = lastReply.contains("승인") ? nil : "승인할 일이 있어요. 화면의 승인 카드를 눌러 주세요."
            case .awaitingInput:
                line = state.question.map { VoiceText.spoken($0) }
            case .done:
                line = state.report?.speak ?? VoiceText.spoken(state.result ?? "\(state.title) 일을 마쳤어요.")
            case .failed, .needsInput:
                line = state.report?.speak ?? "\(state.title) 일을 끝내지 못했어요. 화면의 카드를 봐 주세요."
            default:
                line = nil
            }
            if state.phase.isFinished { watched[state.id] = nil }
            if let line {
                listener?.accepting = false
                await say(line)
                listen()
                return
            }
        }
    }

    /// `voice`: 맥이 이 말의 내 목소리를 이미 만들기 시작했으면 그 번호. 없으면 맥에 새로 맡긴다
    /// `phoneOnly`: 맥 목소리를 이미 시도했다 (인사)
    private func say(_ text: String, voice: String? = nil, phoneOnly: Bool = false) async {
        guard phase != .ended else { return }
        // 맥이 준 읽을 글에도 이모지·기호가 섞여 올 수 있다: 무엇을 읽든 한 번 더 거른다 (길이는 맥이 정한 대로 둔다)
        let text = VoiceText.spoken(text, limit: VoiceText.sayLimit)
        guard !text.isEmpty else { return }
        interrupted = false
        phase = .speaking
        lastReply = text
        if isDemo { return }
        // 내 목소리 (D136): 맥이 만든 조각을 받는 대로 재생한다. 한 조각도 못 받으면 폰 목소리로 읽는다
        if usesMacVoice, !phoneOnly, let macVoice {
            var id = voice
            if id == nil { id = try? await macVoice.voiceCreate(text: text) }
            if let id {
                let outcome = await macPlayer.play(id: id, from: macVoice)
                if outcome != .failed { return }
                logger.info("맥 목소리를 받지 못해 폰 목소리로 읽는다")
            }
            guard phase == .speaking, !interrupted else { return }
        }
        await speaker.speak(text)
    }

    #if DEBUG
    /// 화면 확인용 (`-demoCall` [`approval`]): 마이크 없이 통화 화면의 한 장면을 그린다 (지어낸 말)
    func startDemo(approval: Bool) {
        isDemo = true
        demoApproval = approval
        session.voiceCall = true
        startedAt = .now.addingTimeInterval(-74)
        lastSaid = "이번 주 일정 어때?"
        lastReply = approval
            ? "메일 초안을 만들었어요. 보내기 전에 화면의 승인 카드를 눌러 주세요."
            : "이번 주에는 회의가 4개 있고, 목요일 오후가 비어 있어요. 자세한 건 화면의 카드에 있어요."
        phase = approval ? .listening : .speaking
        heard = approval ? "그럼 내일 오전에" : ""
        level = 0.4
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                tick += 1
                guard let self, self.phase == .listening else { continue }
                self.level = Float.random(in: 0.15...0.8) * (tick % 17 < 3 ? 0.2 : 1)
            }
        }
    }
    #endif
}

// MARK: - 듣기 (기기 안 음성 인식)

/// 마이크 → 기기 안 인식. 녹음 파일은 만들지 않는다. `accepting`이 꺼져 있으면 소리를 인식기에 넣지 않는다 (모아가 말하는 동안)
@MainActor
private final class VoiceListener {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var feed: VoiceFeed?
    private var results: Task<Void, Never>?
    private let onText: (String, Bool) -> Void

    init(onText: @escaping (String, Bool) -> Void) { self.onText = onText }

    var accepting: Bool {
        get { feed?.accepting ?? false }
        set { feed?.accepting = newValue }
    }

    var level: Float { feed?.level ?? 0 }

    func start() async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionService.StartError.unsupportedDevice }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ko-KR")) else {
            throw TranscriptionService.StartError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionService.StartError.noAudioFormat
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = VoiceFeed(outputFormat: format, continuation: continuation)
        self.feed = feed
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)
        let onText = self.onText
        results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    onText(text, result.isFinal)
                }
            } catch {}
        }
        try startEngine(feed)
        // 통화 중에 이어폰을 꽂거나 빼면 엔진이 멈춘다: 새 마이크 형식으로 다시 건다 (D145)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    private var configObserver: NSObjectProtocol?

    private func startEngine(_ feed: VoiceFeed) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw TranscriptionService.StartError.noMicrophoneInput }
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat, block: Self.tap(feed))
        engine.prepare()
        try engine.start()
    }

    /// 듣는 장치가 바뀌었다: 탭을 새 형식으로 다시 단다 (인식기는 그대로. 형식 바꾸기는 `VoiceFeed`가 한다)
    private func restart() {
        guard let feed, analyzer != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try startEngine(feed)
        } catch {
            logger.error("이어폰을 바꾼 뒤 마이크를 다시 걸지 못했다: \(error.localizedDescription, privacy: .public)")
        }
    }

    private let logger = Logger(subsystem: "com.example.meetingsummary", category: "voicecall")

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        feed?.finish()
        results?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }

    /// 탭 블록은 오디오 스레드에서 불린다 (MainActor 밖에서 만든다)
    private nonisolated static func tap(_ feed: VoiceFeed) -> AVAudioNodeTapBlock {
        { buffer, _ in feed.process(buffer) }
    }
}

/// 오디오 스레드 쪽: 받는 중일 때만 인식기 형식으로 바꿔 넘기고, 소리 크기를 잰다
private final class VoiceFeed: @unchecked Sendable {
    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var _accepting = false
    private var _level: Float = 0

    init(outputFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.outputFormat = outputFormat
        self.continuation = continuation
    }

    var accepting: Bool {
        get { lock.withLock { _accepting } }
        set { lock.withLock { _accepting = newValue } }
    }

    var level: Float { lock.withLock { _level } }

    func process(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard _accepting else { _level = 0; return }
            _level = Self.rms(buffer)
            guard let converted = convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() { continuation.finish() }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return min(1, (sum / Float(buffer.frameLength)).squareRoot() * 6)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converterInput = buffer.format
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        let once = OnceBuffer(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let pending = once.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return pending
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// 변환기에 버퍼를 한 번만 건네는 상자 (변환은 `convert` 안에서 동기적으로 끝난다)
private final class OnceBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

// MARK: - 연결음

/// 전화를 건 것처럼 울리는 연결음 (D139): 440Hz와 480Hz를 섞은 소리 1초, 쉼 2초를 되풀이한다.
/// 소리는 코드로 만든다 (파일을 넣지 않는다)
@MainActor
final class RingBack {
    /// 모아가 받기 전에 적어도 이만큼은 울린다 (한 번 울리고 조금 쉬는 데까지)
    nonisolated static let minimum: Duration = .milliseconds(1600)
    /// 연결음을 멈추고 인사의 첫 조각을 걸기까지 쉬는 틈 (D140): 실기기는 울리는 플레이어가 없어질 때 장치 시계를 0으로 되돌린다
    nonisolated static let release: Duration = .milliseconds(300)
    nonisolated static let sampleRate = 24_000
    nonisolated static let toneSeconds = 1.0
    nonisolated static let cycleSeconds = 3.0

    private var player: AVAudioPlayer?

    func start() {
        guard player == nil, let player = try? AVAudioPlayer(data: Self.wav, fileTypeHint: AVFileType.wav.rawValue) else { return }
        player.numberOfLoops = -1
        player.volume = 0.7
        player.prepareToPlay()
        player.play()
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
    }

    /// 한 주기 (울림 + 쉼)의 wav: 24kHz 모노 16bit. 울림 앞뒤는 20ms 동안 부드럽게 키우고 줄인다 (딸깍 소리 없게)
    nonisolated static let wav: Data = {
        let total = Int(Double(sampleRate) * cycleSeconds)
        let tone = Int(Double(sampleRate) * toneSeconds)
        let fade = sampleRate / 50
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        var bytes = Array("RIFF".utf8) + le32(36 + total * 2) + Array("WAVEfmt ".utf8)
        bytes += le32(16) + le16(1) + le16(1) + le32(sampleRate) + le32(sampleRate * 2) + le16(2) + le16(16)
        bytes += Array("data".utf8) + le32(total * 2)
        bytes.reserveCapacity(bytes.count + total * 2)
        for i in 0..<total {
            var value = 0.0
            if i < tone {
                let t = Double(i) / Double(sampleRate)
                let edge = min(1, Double(min(i, tone - 1 - i)) / Double(fade))
                value = (sin(2 * .pi * 440 * t) + sin(2 * .pi * 480 * t)) * 0.18 * edge
            }
            bytes += le16(Int(UInt16(bitPattern: Int16(value * Double(Int16.max)))))
        }
        return Data(bytes)
    }()
}

// MARK: - 읽기

/// 모아의 말을 소리로 읽는다 (이 기기의 한국어 목소리)
@MainActor
final class VoiceSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var waiting: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        let utterance = VoiceChoice.utterance(text)
        await withCheckedContinuation { continuation in
            waiting = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish()
    }

    private func finish() {
        waiting?.resume()
        waiting = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}

// MARK: - 목소리 고르기

/// 통화 목소리 (D140): 맥이 만드는 모아 목소리 하나만 쓴다. 고르는 목록은 없다 (D135의 아이폰 목소리 고르기는 뺐다).
/// 맥이 꺼져 있거나 늦을 때만 이 아이폰의 한국어 목소리 가운데 가장 좋은 음질의 것으로 읽는다 (예전에 고른 아이폰 목소리는 쓰지 않는다).
/// 친근하게 들리도록 높이를 조금 올리고, 빠르기는 보통으로
enum VoiceChoice {
    static let pitch: Float = 1.08
    static let sample = "안녕하세요, 모아예요. 이 목소리로 말할게요."

    struct Option: Equatable {
        let id: String
        let name: String
        let quality: Int
    }

    /// 대신 읽을 아이폰 목소리: 가장 좋은 음질, 같은 음질이면 이름 차례
    nonisolated static func fallback(from options: [Option]) -> Option? {
        options.min { $0.quality != $1.quality ? $0.quality > $1.quality : $0.name < $1.name }
    }

    static var options: [Option] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "ko-KR" }
            .map { Option(id: $0.identifier, name: $0.name, quality: $0.quality.rawValue) }
    }

    static var current: Option? { fallback(from: options) }

    static func utterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = current.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) } ?? AVSpeechSynthesisVoice(language: "ko-KR")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = pitch
        return utterance
    }
}
