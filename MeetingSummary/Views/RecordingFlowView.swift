import SwiftUI

/// 새 회의: 동의 → 권한 확인 → 녹음 → 결과
struct RecordingFlowView: View {
    private enum Phase {
        case consent
        case checkingPermissions
        case denied(PermissionResult)
        case recording
        case finished(Meeting)
    }

    @State private var phase: Phase = Self.initialPhase

    private static var initialPhase: Phase {
        #if DEBUG
        if DemoData.arguments.contains("-demoRecording") { return .recording }
        #endif
        return .consent
    }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch phase {
            case .consent:
                ConsentView { checkPermissions() }
            case .checkingPermissions:
                ProgressView("권한 확인 중…")
            case .denied(let result):
                PermissionDeniedView(result: result) { checkPermissions() }
            case .recording:
                RecordingView { meeting in phase = .finished(meeting) }
            case .finished(let meeting):
                MeetingDetailView(meeting: meeting)
            }
        }
        .toolbar {
            // 녹음 중에는 녹음 화면이 직접 닫기를 관리한다 (먼저 종료해야 함)
            if !isRecordingPhase {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isFinished ? "완료" : "취소") { dismiss() }
                }
            }
        }
        // 설정에서 권한을 바꾸고 돌아오면 자동으로 다시 확인한다.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active, case .denied = phase { checkPermissions() }
        }
    }

    private var isRecordingPhase: Bool {
        if case .recording = phase { return true }
        return false
    }

    private var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    private func checkPermissions() {
        phase = .checkingPermissions
        Task {
            let result = await PermissionService.requestAll()
            phase = result.allGranted ? .recording : .denied(result)
        }
    }
}
