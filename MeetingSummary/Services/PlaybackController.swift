import AVFoundation
import Foundation
import Observation

/// 회의 음성 재생. 전체 재생과 "말풍선 구간만 재생"을 지원한다.
@MainActor
@Observable
final class PlaybackController {
    private(set) var isAvailable = false
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    /// 구간 재생일 때 멈출 시각
    private var stopAt: TimeInterval?
    /// 이어서 재생할 구간들 ("중요 구간 모아 듣기")
    private var queue: [ClosedRange<TimeInterval>] = []
    /// 중요 구간 모아 듣기 중인지
    private(set) var isPlayingHighlights = false
    private var ticker: Task<Void, Never>?
    /// 오디오 세션을 이 화면이 잡았는지 (잡은 경우에만 놓아 준다)
    private var didActivateSession = false

    /// 음성 파일을 연다. 오디오 장치는 잡지 않는다.
    /// (`prepareToPlay`는 오디오 세션을 활성화해 다른 앱의 음악을 멈추므로, 재생을 누를 때까지 부르지 않는다)
    func load(url: URL?) {
        guard player == nil, let url, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        duration = player.duration
        isAvailable = true
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    /// 지정한 위치부터 재생. `until`을 주면 그 시각에 멈춘다 (말풍선 구간 재생).
    func play(from start: TimeInterval? = nil, until end: TimeInterval? = nil) {
        queue = []
        isPlayingHighlights = false
        startPlaying(from: start, until: end)
    }

    /// 여러 구간을 차례로 재생한다.
    func play(ranges: [ClosedRange<TimeInterval>]) {
        guard let first = ranges.first else { return }
        queue = Array(ranges.dropFirst())
        isPlayingHighlights = true
        startPlaying(from: first.lowerBound, until: first.upperBound)
    }

    private func startPlaying(from start: TimeInterval?, until end: TimeInterval?) {
        guard let player else { return }
        if !didActivateSession {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            didActivateSession = true
        }
        if let start { player.currentTime = max(0, min(start, duration)) }
        stopAt = end
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopAt = nil
        queue = []
        isPlayingHighlights = false
        ticker?.cancel()
        currentTime = player?.currentTime ?? currentTime
    }

    /// 재생 위치 이동 (파형 훑기). 구간 재생 중이었다면 일반 재생으로 바뀐다.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        stopAt = nil
        queue = []
        isPlayingHighlights = false
        player.currentTime = max(0, min(time, duration))
        currentTime = player.currentTime
    }

    /// 화면을 떠날 때. 재생했던 경우에만 세션을 놓고, 멈췄던 다른 앱의 음악이 다시 나오도록 알린다.
    func stop() {
        pause()
        guard didActivateSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        didActivateSession = false
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if let stopAt, currentTime >= stopAt {
            if queue.isEmpty {
                pause()
            } else {
                let next = queue.removeFirst()
                player.currentTime = next.lowerBound
                currentTime = next.lowerBound
                self.stopAt = next.upperBound
            }
        } else if !player.isPlaying {
            // 끝까지 재생됨
            isPlaying = false
            stopAt = nil
            ticker?.cancel()
        }
    }
}
