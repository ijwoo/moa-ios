import Foundation

/// 회의 처리 상태.
///
/// 허용되는 전이:
/// - recording  → processing (녹음 종료 후 요약 요청), failed (음성 인식 실패)
/// - processing → ready (요약 성공), failed (네트워크/API/파싱 실패)
/// - failed     → processing (재시도)
/// - ready      → processing (요약 다시 생성)
enum MeetingStatus: String, Codable, CaseIterable, Sendable {
    case recording
    case processing
    case ready
    case failed

    func canTransition(to next: MeetingStatus) -> Bool {
        switch (self, next) {
        case (.recording, .processing), (.recording, .failed),
             (.processing, .ready), (.processing, .failed),
             (.failed, .processing),
             (.ready, .processing):
            return true
        default:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .recording: "녹음 중"
        case .processing: "요약 중"
        case .ready: "완료"
        case .failed: "실패"
        }
    }
}
