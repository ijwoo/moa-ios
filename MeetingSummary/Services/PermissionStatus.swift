import AVFoundation
import EventKit
import Speech

/// 권한 상태 (화면 표시용). 요청은 하지 않고 현재 상태만 읽는다.
/// 권한 요청은 기존 흐름(녹음 시작 시 `PermissionService`, 미리알림 추가 시 `ReminderService`)이 그대로 맡는다.
enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined

    var label: String {
        switch self {
        case .granted: "허용됨"
        case .denied: "꺼짐"
        case .notDetermined: "아직 묻지 않음"
        }
    }
}

enum PermissionStatus {
    static var microphone: PermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }

    static var speechRecognition: PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    /// 카메라 (D87). 질문에 붙일 사진을 찍을 때만 쓴다
    static var camera: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// 연락처 (D89). 메일을 받을 사람을 이름으로 찾을 때만 쓴다
    static var contacts: PermissionState {
        switch SystemContacts().access() {
        case .allowed: .granted
        case .notAsked: .notDetermined
        case .denied: .denied
        }
    }

    /// 캘린더 (D95). 내 공간의 오늘 일정 카드에만 쓴다 (읽기만)
    static var calendar: PermissionState {
        switch SystemDayEvents().access() {
        case .allowed: .granted
        case .notAsked: .notDetermined
        case .denied: .denied
        }
    }

    /// 미리알림은 읽기·완료 동기화까지 하므로 전체 접근만 "허용됨"으로 본다.
    static var reminders: PermissionState {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
