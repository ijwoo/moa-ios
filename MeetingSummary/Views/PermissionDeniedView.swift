import SwiftUI
import UIKit

/// 마이크 또는 음성 인식 권한이 거부됐을 때 설정 화면으로 안내한다.
struct PermissionDeniedView: View {
    let result: PermissionResult
    let onRetry: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("권한이 필요합니다", systemImage: "mic.slash")
        } description: {
            VStack(spacing: 8) {
                Text("녹음하고 받아쓰려면 아래 권한을 허용해야 합니다.")
                if !result.microphone { Text("• 마이크").bold() }
                if !result.speech { Text("• 음성 인식").bold() }
                Text("설정 → 모아에서 허용한 뒤 돌아오세요.")
            }
        } actions: {
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("다시 확인", action: onRetry)
        }
    }
}

#Preview {
    PermissionDeniedView(result: PermissionResult(microphone: false, speech: true)) {}
}
