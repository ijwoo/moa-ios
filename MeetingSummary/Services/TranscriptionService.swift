@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Observation
import os
import Speech

/// 확정된 발화 하나 (녹음 시작 기준 시간 구간 포함)
struct LiveUtterance: Identifiable, Equatable, Sendable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// 마이크 입력을 iOS 26 `SpeechAnalyzer`로 받아쓰고, 같은 음성을 파일로 저장한다.
///
/// - 인식은 기기 안에서만 이뤄진다 (음성이 서버로 나가지 않음).
/// - 문장이 확정될 때마다 `onUtterance`로 넘겨 바로 저장하게 한다 (앱 강제 종료 대비).
/// - 인식기에 넣는 오디오와 파일에 쓰는 오디오가 같은 버퍼라서, 발화의 시간 구간이
///   음성 파일의 재생 위치와 정확히 맞는다.
@MainActor
@Observable
final class TranscriptionService {
    enum State: Equatable {
        case idle
        case preparing(String)
        case recording
        case stopping
        case finished
        case failed(String)
    }

    enum StartError: LocalizedError {
        case unsupportedDevice
        case unsupportedLocale
        case noAudioFormat
        case noMicrophoneInput

        var errorDescription: String? {
            switch self {
            case .unsupportedDevice: "이 기기에서는 음성 인식을 사용할 수 없습니다."
            case .unsupportedLocale: "이 기기에서는 한국어 음성 인식을 지원하지 않습니다."
            case .noAudioFormat: "음성 인식에 맞는 오디오 형식을 찾지 못했습니다."
            case .noMicrophoneInput: "마이크 입력을 찾을 수 없습니다."
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var utterances: [LiveUtterance] = []
    /// 아직 확정되지 않은(바뀔 수 있는) 인식 결과
    private(set) var volatileText = ""
    private(set) var elapsed: TimeInterval = 0
    private(set) var diagnostics: [String] = []
    /// 녹음 화면의 실시간 파형용 (최근 6초, 0...1)
    private(set) var recentLevels: [Float] = []

    /// 문장이 확정되면 호출된다.
    var onUtterance: ((LiveUtterance) -> Void)?

    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.example.meetingsummary", category: "transcription")
    private var analyzer: SpeechAnalyzer?
    private var pipeline: AudioPipeline?
    private var resultsTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var startedAt: Date?
    private var observers: [NSObjectProtocol] = []

    var diagnosticsText: String { diagnostics.joined(separator: "\n") }

    /// 지금까지 녹음된 음성 길이(초). 북마크 시각은 이 값을 쓴다 (음성 파일 재생 위치와 일치).
    var currentAudioTime: TimeInterval { pipeline?.audioTime ?? 0 }

    /// 지금까지의 파형
    func waveformSnapshot() -> [Float] { pipeline?.waveformPeaks ?? [] }

    // MARK: - 시작 / 종료

    func start(audioURL: URL) async throws {
        guard state == .idle else { return }
        guard SpeechTranscriber.isAvailable else { throw StartError.unsupportedDevice }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ko-KR")) else {
            throw StartError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        // 한국어 인식 모델이 기기에 없으면 처음 한 번 내려받는다.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            state = .preparing("한국어 음성 인식 모델을 내려받는 중…")
            log("인식 모델 내려받기 시작")
            try await request.downloadAndInstall()
            log("인식 모델 내려받기 완료")
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw StartError.noAudioFormat
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pipeline = try AudioPipeline(outputFormat: format, fileURL: audioURL, continuation: continuation)
        self.pipeline = pipeline

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result)
                }
            } catch {
                self?.log("인식 결과 오류: \(error.localizedDescription)")
            }
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        try startAudioEngine()
        observeAudioSession()

        state = .recording
        startedAt = .now
        log("녹음 시작 · 기기 내 인식 (\(locale.identifier), \(Int(format.sampleRate))Hz)")
        startClock()
    }

    /// 남은 음성까지 모두 확정한 뒤 종료한다.
    func stop() async {
        guard state == .recording else { return }
        state = .stopping
        clockTask?.cancel()
        updateElapsed()

        stopAudioEngine()
        removeObservers()
        pipeline?.finishInput()

        if let analyzer {
            // 마지막 문장 확정이 오래 걸리면 끊고 넘어간다.
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await analyzer.cancelAndFinishNow()
            }
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                log("마무리 중 오류: \(error.localizedDescription)")
            }
            watchdog.cancel()
        }
        await resultsTask?.value

        pipeline?.closeFile()
        if let error = pipeline?.writeError {
            log("음성 파일 저장 오류: \(error.localizedDescription)")
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log("녹음 종료 · 총 \(Int(elapsed))초, 문장 \(utterances.count)개")
        state = .finished
    }

    #if DEBUG
    /// 개발용: 마이크 없이 녹음 화면을 확인하기 위한 가짜 진행 (실행 인자 -demoRecording)
    func startDemo() {
        state = .recording
        startedAt = .now.addingTimeInterval(-83)
        let lines = [
            "오늘은 다음 달 출시 준비 상황을 점검하겠습니다.",
            "출시일은 12월 3일로 확정했습니다.",
            "디자인 최종본은 김지원 님이 이번 주 금요일까지 전달하기로 했습니다.",
        ]
        clockTask = Task { [weak self] in
            var tick = 0
            var levels: [Float] = []
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                tick += 1
                levels.append(Float.random(in: 0.15...0.9) * (tick % 23 < 4 ? 0.2 : 1))
                self.recentLevels = Array(levels.suffix(60))
                self.updateElapsed()
                if tick % 15 == 0, tick / 15 <= lines.count {
                    let text = lines[tick / 15 - 1]
                    self.utterances.append(LiveUtterance(start: Double(tick) / 10 + 60, end: Double(tick) / 10 + 64, text: text))
                }
                self.volatileText = tick > 50 ? "서버 부하 테스트는 다음 주 안에" : ""
            }
        }
    }
    #endif

    // MARK: - 인식 결과

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.isFinal else {
            volatileText = text
            return
        }
        volatileText = ""
        guard !text.isEmpty else { return }
        let utterance = LiveUtterance(
            start: result.range.start.seconds,
            end: result.range.end.seconds,
            text: text
        )
        utterances.append(utterance)
        updateElapsed()
        onUtterance?(utterance)
    }

    // MARK: - 오디오 엔진

    private func startAudioEngine() throws {
        guard let pipeline else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw StartError.noMicrophoneInput }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.makeTapBlock(pipeline))
        engine.prepare()
        try engine.start()
    }

    private func stopAudioEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// 이어폰 연결 등으로 입력 장치가 바뀌거나 전화 등으로 중단됐다가 돌아왔을 때 다시 연결한다.
    private func restartAudioEngine(reason: String) {
        guard state == .recording else { return }
        log("오디오 다시 연결: \(reason)")
        stopAudioEngine()
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            try startAudioEngine()
        } catch {
            log("마이크 재연결 실패: \(error.localizedDescription)")
            state = .failed("마이크를 다시 연결하지 못했습니다. 녹음을 종료하고 다시 시작하세요.")
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.log("오디오 중단됨 (전화 등)")
                case .ended: self?.restartAudioEngine(reason: "중단 종료")
                default: break
                }
            }
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartAudioEngine(reason: "입력 장치 변경")
            }
        })
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    // MARK: - 시간 / 기록

    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.updateElapsed()
                self?.updateLevels()
            }
        }
    }

    private func updateLevels() {
        let recent = pipeline?.recentPeaks(60) ?? []
        recentLevels = recent.map { min(1, ($0 * 4).squareRoot()) }
    }

    private func updateElapsed() {
        if let startedAt { elapsed = Date.now.timeIntervalSince(startedAt) }
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        diagnostics.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(message)")
    }

    /// 탭 블록은 오디오 스레드에서 불린다. MainActor 안에서 만들면 Swift 6가 MainActor로
    /// 격리해 실행 중 앱이 종료되므로 nonisolated 함수에서 만든다.
    private nonisolated static func makeTapBlock(_ pipeline: AudioPipeline) -> AVAudioNodeTapBlock {
        { buffer, _ in pipeline.process(buffer) }
    }
}

/// 오디오 스레드 쪽 처리: 마이크 버퍼를 인식기 형식으로 변환해 인식기에 넘기고, 같은 버퍼를 파일에 쓴다.
private final class AudioPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var _writeError: (any Error)?
    private var waveform: WaveformBuilder
    private var framesProcessed: AVAudioFramePosition = 0

    var writeError: (any Error)? { lock.withLock { _writeError } }

    /// 인식기와 파일에 넘긴 음성 길이(초)
    var audioTime: TimeInterval {
        lock.withLock { Double(framesProcessed) / outputFormat.sampleRate }
    }

    var waveformPeaks: [Float] { lock.withLock { waveform.peaks } }

    func recentPeaks(_ count: Int) -> [Float] {
        lock.withLock { Array(waveform.peaks.suffix(count)) }
    }

    init(outputFormat: AVAudioFormat, fileURL: URL, continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        self.outputFormat = outputFormat
        self.continuation = continuation
        self.waveform = WaveformBuilder(sampleRate: outputFormat.sampleRate)
        self.file = try Self.makeFile(url: fileURL, format: outputFormat)
    }

    /// 음성 파일: AAC(m4a), 인식기와 같은 샘플레이트·채널
    private static func makeFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            return try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            // 비트레이트를 지원하지 않는 조합이면 기본값으로 다시 시도
            settings.removeValue(forKey: AVEncoderBitRateKey)
            return try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let converted = convert(buffer) else { return }
            framesProcessed += AVAudioFramePosition(converted.frameLength)
            waveform.add(converted)
            if let file {
                do { try file.write(from: converted) } catch { _writeError = error }
            }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finishInput() {
        continuation.finish()
    }

    func closeFile() {
        lock.withLock {
            file?.close()
            file = nil
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converterInputFormat != buffer.format {
            // 입력 장치가 바뀌면 형식도 바뀔 수 있다 (예: 블루투스 이어폰)
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        // 변환기에 이 버퍼를 한 번만 넘긴다. (.noDataNow로 답해야 샘플레이트 변환 상태가 다음 버퍼로 이어진다)
        let once = PendingBuffer(buffer)
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

/// 변환기 입력 블록에 버퍼를 한 번만 건네기 위한 상자. 변환은 `convert` 호출 안에서 동기적으로 끝난다.
private final class PendingBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
