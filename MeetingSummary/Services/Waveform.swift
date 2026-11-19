@preconcurrency import AVFoundation
import Foundation

/// 오디오 버퍼를 받아 일정 간격(bin)마다 최대 진폭을 모은다.
struct WaveformBuilder {
    /// 파형 한 칸의 길이(초)
    static let binDuration: TimeInterval = 0.1

    let samplesPerBin: Int
    private(set) var peaks: [Float] = []
    private var currentPeak: Float = 0
    private var currentCount = 0

    init(sampleRate: Double) {
        samplesPerBin = max(1, Int(sampleRate * Self.binDuration))
    }

    mutating func add(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        if let data = buffer.floatChannelData {
            for i in 0..<frames { add(sample: data[0][i]) }
        } else if let data = buffer.int16ChannelData {
            for i in 0..<frames { add(sample: Float(data[0][i]) / Float(Int16.max)) }
        } else if let data = buffer.int32ChannelData {
            for i in 0..<frames { add(sample: Float(data[0][i]) / Float(Int32.max)) }
        }
    }

    mutating func add(sample: Float) {
        currentPeak = max(currentPeak, abs(sample))
        currentCount += 1
        if currentCount >= samplesPerBin {
            peaks.append(min(currentPeak, 1))
            currentPeak = 0
            currentCount = 0
        }
    }
}

enum Waveform {
    static func encode(_ peaks: [Float]) -> Data {
        peaks.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// 화면 폭에 맞게 줄인다. 각 칸은 해당 구간의 최댓값.
    static func downsample(_ peaks: [Float], to count: Int) -> [Float] {
        guard count > 0, !peaks.isEmpty else { return [] }
        guard peaks.count > count else { return peaks }
        return (0..<count).map { i in
            let lower = i * peaks.count / count
            let upper = max(lower + 1, (i + 1) * peaks.count / count)
            return peaks[lower..<upper].max() ?? 0
        }
    }

    /// 화면 표시용 0...1 값. 말소리는 진폭이 작아서 제곱근으로 키우고, 가장 큰 값에 맞춘다.
    static func normalized(_ peaks: [Float]) -> [Float] {
        let maxPeak = max(peaks.max() ?? 0, 0.01)
        return peaks.map { ($0 / maxPeak).squareRoot() }
    }

    /// 저장된 음성 파일에서 파형을 뽑는다. (파형 없이 저장된 회의를 위한 보완)
    nonisolated static func extract(from url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        var builder = WaveformBuilder(sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { return nil }
        while file.framePosition < file.length {
            do { try file.read(into: buffer) } catch { break }
            if buffer.frameLength == 0 { break }
            builder.add(buffer)
        }
        return builder.peaks
    }
}
