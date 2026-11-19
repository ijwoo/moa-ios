import Foundation
import SwiftData

enum MeetingStatusError: Error, Equatable {
    case invalidTransition(from: MeetingStatus, to: MeetingStatus)
}

@Model
final class Meeting {
    @Attribute(.unique) var id: UUID
    var title: String
    var date: Date
    /// 녹음 길이(초)
    var duration: TimeInterval
    /// 받아쓴 원본 텍스트 전체. 문장이 확정될 때마다 이어 붙여 저장한다 (검색·요약용).
    var transcript: String
    /// SwiftData 술어(#Predicate)에서 쓰기 쉽도록 원시값으로 저장한다.
    private(set) var statusRaw: String
    /// 실패했을 때 사용자에게 보여줄 메시지
    var failureMessage: String?
    /// 음성 인식 기록 (시작·종료·오류 등). 인식 품질 확인용
    var recognitionLog: String = ""
    /// 녹음을 정상적으로 끝냈는지. false인데 녹음 중 상태라면 앱이 녹음 도중 종료된 것이다.
    var isRecordingComplete: Bool = false
    /// 기기에 저장된 음성 파일 이름 (`AudioStorage` 폴더 기준). 음성이 없는 회의는 nil
    var audioFileName: String?

    @Relationship(deleteRule: .cascade, inverse: \Summary.meeting)
    var summary: Summary?

    /// 말풍선 단위 발화. 순서는 `start`로 정렬해서 쓴다.
    @Relationship(deleteRule: .cascade, inverse: \Utterance.meeting)
    var utterances: [Utterance] = []

    /// 녹음 중 찍은 "중요" 표시
    @Relationship(deleteRule: .cascade, inverse: \Bookmark.meeting)
    var bookmarks: [Bookmark] = []

    /// 파형 데이터 (0.1초마다 최대 진폭, Float32). 1시간 약 140KB라 별도 파일로 저장한다.
    @Attribute(.externalStorage) var waveformData: Data?

    init(
        id: UUID = UUID(),
        title: String,
        date: Date = .now,
        duration: TimeInterval = 0,
        transcript: String = "",
        status: MeetingStatus = .recording
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.transcript = transcript
        self.statusRaw = status.rawValue
    }

    var sortedUtterances: [Utterance] {
        utterances.sorted { $0.start < $1.start }
    }

    var sortedBookmarks: [Bookmark] {
        bookmarks.sorted { $0.time < $1.time }
    }

    /// 확정된 문장을 발화 목록과 원본 텍스트에 함께 추가한다.
    func appendUtterance(_ utterance: Utterance) {
        utterances.append(utterance)
        transcript = transcript.isEmpty ? utterance.text : transcript + " " + utterance.text
    }

    var status: MeetingStatus {
        MeetingStatus(rawValue: statusRaw) ?? .failed
    }

    /// 허용된 전이만 수행한다. 잘못된 전이는 오류를 던져 상태가 꼬이지 않게 한다.
    func transition(to next: MeetingStatus, failureMessage: String? = nil) throws {
        guard status.canTransition(to: next) else {
            throw MeetingStatusError.invalidTransition(from: status, to: next)
        }
        statusRaw = next.rawValue
        self.failureMessage = next == .failed ? failureMessage : nil
    }
}
