import Foundation
import SwiftData

/// 말풍선 하나에 해당하는 발화. 녹음 음성 파일의 시간 구간과 연결된다.
@Model
final class Utterance {
    @Attribute(.unique) var id: UUID
    /// 녹음 시작 기준 시작 시각(초)
    var start: TimeInterval
    /// 녹음 시작 기준 끝 시각(초)
    var end: TimeInterval
    var text: String
    /// 화자 이름. 화자 구분 기능을 붙이기 전까지는 nil
    var speaker: String?

    var meeting: Meeting?

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}
