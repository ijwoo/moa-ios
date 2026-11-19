import Foundation
import SwiftData

/// 녹음 중 "여기 중요" 표시. 시각은 음성 파일 기준(초)이다.
@Model
final class Bookmark {
    @Attribute(.unique) var id: UUID
    /// 버튼을 누른 시각
    var time: TimeInterval
    var meeting: Meeting?

    init(id: UUID = UUID(), time: TimeInterval) {
        self.id = id
        self.time = time
    }

    /// 사람은 중요한 말을 들은 *뒤에* 누르므로, 누른 시점보다 앞부터 재생한다.
    static let leadIn: TimeInterval = 10
    /// 누른 시점 뒤로 조금 더 들려준다.
    static let tail: TimeInterval = 5

    /// 북마크 하나의 재생 구간
    static func range(for time: TimeInterval, duration: TimeInterval) -> ClosedRange<TimeInterval> {
        let start = max(0, time - leadIn)
        let end = duration > 0 ? min(duration, time + tail) : time + tail
        return start...max(start, end)
    }

    /// "중요 구간 모아 듣기"용: 겹치거나 맞닿은 구간은 하나로 합친다.
    static func mergedRanges(times: [TimeInterval], duration: TimeInterval) -> [ClosedRange<TimeInterval>] {
        var result: [ClosedRange<TimeInterval>] = []
        for range in times.sorted().map({ self.range(for: $0, duration: duration) }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
