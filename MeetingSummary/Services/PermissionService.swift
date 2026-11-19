import AVFoundation
import Speech

struct PermissionResult: Equatable, Sendable {
    var microphone: Bool
    var speech: Bool

    var allGranted: Bool { microphone && speech }
}

enum PermissionService {
    /// 마이크와 음성 인식 권한을 차례로 요청한다. 이미 결정된 권한은 다시 묻지 않는다.
    static func requestAll() async -> PermissionResult {
        let microphone = await AVAudioApplication.requestRecordPermission()
        let speech = await requestSpeech()
        return PermissionResult(microphone: microphone, speech: speech)
    }

    private static func requestSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: break
        @unknown default: return false
        }
        let status = await withCheckedContinuation { continuation in
            requestSpeechAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    /// 콜백이 임의의 스레드에서 불리므로 MainActor 격리가 붙지 않는 곳에서 클로저를 만든다.
    /// (Swift 6에서 MainActor 클로저가 다른 스레드에서 불리면 앱이 종료된다)
    private nonisolated static func requestSpeechAuthorization(
        _ completion: @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization { completion($0) }
    }
}
