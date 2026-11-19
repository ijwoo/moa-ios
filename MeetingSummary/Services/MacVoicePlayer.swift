@preconcurrency import AVFoundation
import Foundation
import os

/// wav 조각을 읽는다 (D136): 맥이 보내는 24kHz 모노 16bit PCM. 다른 꼴이면 nil
enum WavPCM {
    struct Audio: Equatable {
        let sampleRate: Double
        let channels: Int
        let samples: [Int16]
    }

    nonisolated static func parse(_ data: Data) -> Audio? {
        let bytes = [UInt8](data)
        guard bytes.count >= 44, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var offset = 12
        var format: (pcm: Bool, channels: Int, rate: Int, bits: Int)?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt ", body + 16 <= bytes.count {
                format = (u16(body) == 1, u16(body + 2), u32(body + 4), u16(body + 14))
            } else if id == "data", let format, format.pcm, format.bits == 16, format.channels >= 1, format.rate > 0 {
                let end = min(bytes.count, body + size)
                var samples: [Int16] = []
                samples.reserveCapacity((end - body) / 2)
                var i = body
                while i + 1 < end {
                    samples.append(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))
                    i += 2
                }
                return Audio(sampleRate: Double(format.rate), channels: format.channels, samples: samples)
            }
            offset = body + size + (size & 1)
        }
        return nil
    }

    /// 16bit PCM wav로 묶는다 (이어 붙인 조각을 한 번에 틀려고)
    nonisolated static func encode(samples: [Int16], sampleRate: Double, channels: Int) -> Data {
        let rate = Int(sampleRate)
        let size = samples.count * 2
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        var bytes = Array("RIFF".utf8) + le32(36 + size) + Array("WAVEfmt ".utf8)
        bytes += le32(16) + le16(1) + le16(channels) + le32(rate) + le32(rate * channels * 2) + le16(channels * 2) + le16(16)
        bytes += Array("data".utf8) + le32(size)
        var data = Data(bytes)
        samples.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: UInt8.self) { data.append($0) }
        }
        return data
    }
}

/// 맥이 만든 모아 목소리를 조각마다 받아 차례로 재생한다 (D136, 맥의 D117).
/// 맥이 조각을 10초까지 붙잡고 있으니 요청은 쉬지 않고 이어 보낸다.
///
/// 재생은 한 번에 플레이어 하나만 (D141). 받은 조각은 줄에 모아 두었다가, 앞 소리가 끝나면 그동안 모인 조각을 이어 붙여
/// `AVAudioPlayer` 하나로 튼다. 맥은 말보다 빨리 만드니 보통 첫 조각 뒤에 나머지가 한 덩어리로 이어진다.
/// - D136: 따로 돌린 `AVAudioEngine`은 실기기 통화 중에 소리가 나지 않았다.
/// - D138: 조각마다 `play(atTime:)`로 시각을 맞춰 걸었더니, 실기기에서 조각들이 겹쳐 찢어지는 소리가 났다
///   (새 플레이어의 `deviceCurrentTime`은 믿을 수 없었다). 이제 장치 시계는 쓰지 않는다
@MainActor
final class MacVoicePlayer {
    enum Outcome: Equatable {
        /// 끝까지 읽었다
        case played
        /// 한 조각도 받지 못했거나 하나도 틀지 못했다: 폰 목소리로 읽는다
        case failed
        /// 읽다가 멈췄다 (끼어듦, 또는 중간에 끊김): 다시 읽지 않는다
        case stopped
    }

    private let logger = Logger(subsystem: "com.example.meetingsummary", category: "voicecall")
    /// 받았지만 아직 틀지 않은 소리
    private var pending: [Int16] = []
    private var format: (rate: Double, channels: Int)?
    /// 지금 나는 소리 (끝날 때까지 붙잡아 둔다: 놓으면 소리가 끊긴다)
    private var playing: AVAudioPlayer?
    /// 지금 소리가 늦어도 이때는 끝난 것으로 본다 (끝났다는 신호가 없어도 갇히지 않게)
    private var playingDeadline = Date.distantPast
    /// 앞 소리가 끝나 가면 미리 준비해 둔 다음 소리
    private var next: AVAudioPlayer?
    private var fetchDone = false
    private var stopped = false
    private var current: (id: String, source: any AgentProviding)?

    /// 한 조각도 오지 않은 채 "아직"을 몇 번까지 기다리는지 (한 번에 10초)
    static let firstChunkTries = 2
    /// 읽는 도중 다음 조각이 계속 "아직"이면 몇 번까지 기다리는지: 넘으면 읽은 데까지로 끝낸다
    static let laterChunkTries = 3
    /// 앞 소리가 이만큼 남으면 다음 소리를 미리 준비한다
    static let prepareAhead: TimeInterval = 0.15
    /// 재생이 끝났는지 보는 간격
    static let tick: Duration = .milliseconds(10)

    /// `beforeFirst`: 첫 조각을 받아 틀기 직전에 한 번 (인사 앞에서 연결음을 완전히 멈춘다, D139·D140)
    func play(id: String, from source: any AgentProviding, beforeFirst: (() async -> Void)? = nil) async -> Outcome {
        stopped = false
        fetchDone = false
        pending = []
        format = nil
        playing = nil
        next = nil
        current = (id, source)
        defer { current = nil }
        let playback = Task { await self.playLoop() }
        var index = 0
        var waits = 0
        var received = false
        loop: while !stopped {
            let chunk = (try? await source.voiceChunk(id: id, index: index)) ?? .unavailable
            guard !stopped else { break }
            switch chunk {
            case .audio(let data):
                guard let wav = WavPCM.parse(data), !wav.samples.isEmpty,
                      format == nil || (format?.rate == wav.sampleRate && format?.channels == wav.channels)
                else {
                    logger.error("맥 목소리 조각 \(index)을 읽지 못했다 (\(data.count) 바이트)")
                    break loop
                }
                if !received, let beforeFirst {
                    await beforeFirst()
                    guard !stopped else { break loop }
                }
                format = (wav.sampleRate, wav.channels)
                pending += wav.samples
                received = true
                index += 1
                waits = 0
            case .end:
                break loop
            case .notReady:
                waits += 1
                if waits >= (received ? Self.laterChunkTries : Self.firstChunkTries) { break loop }
            case .unavailable, .gone:
                break loop
            }
        }
        fetchDone = true
        let startedAny = await playback.value
        playing = nil
        next = nil
        pending = []
        if stopped { return .stopped }
        if !startedAny {
            // 맥이 만들던 것도 멈춘다 (폰 목소리로 넘어간다)
            await source.voiceCancel(id: id)
            return .failed
        }
        return .played
    }

    /// 끼어들었다: 소리를 멈추고 맥의 남은 생성도 멈춘다
    func stop() {
        guard !stopped else { return }
        stopped = true
        playing?.stop()
        playing = nil
        next = nil
        pending = []
        if let current { Task { [current] in await current.source.voiceCancel(id: current.id) } }
    }

    /// 한 번에 하나씩: 앞 소리가 끝나면 그동안 모인 조각을 이어 붙여 튼다. 하나라도 틀었으면 true
    private func playLoop() async -> Bool {
        var startedAny = false
        while !stopped {
            if let playing, playing.isPlaying, Date.now < playingDeadline {
                // 끝나 가면 다음 소리를 미리 준비해 둔다 (틈을 줄이려고)
                if next == nil, !pending.isEmpty, playing.duration - playing.currentTime < Self.prepareAhead {
                    next = takePending()
                }
            } else {
                playing = nil
                let upcoming = next ?? takePending()
                next = nil
                if let upcoming {
                    guard upcoming.play() else {
                        logger.error("맥 목소리를 틀지 못했다")
                        break
                    }
                    playing = upcoming
                    playingDeadline = Date.now.addingTimeInterval(upcoming.duration + 0.5)
                    startedAny = true
                } else if fetchDone, pending.isEmpty {
                    break
                }
            }
            try? await Task.sleep(for: Self.tick)
        }
        return startedAny
    }

    /// 모인 조각을 한 소리로 만든다 (준비까지). 없거나 만들 수 없으면 nil
    private func takePending() -> AVAudioPlayer? {
        guard !pending.isEmpty, let format else { return nil }
        let data = WavPCM.encode(samples: pending, sampleRate: format.rate, channels: format.channels)
        pending = []
        guard let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue),
              player.prepareToPlay() else { return nil }
        return player
    }
}
