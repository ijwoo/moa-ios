import SwiftUI

/// 녹음 전 안내와 동의 확인. 녹음할 때마다 반드시 거친다.
///
/// 안내 문구는 실제 데이터 흐름과 같아야 한다. 데이터 처리 방식이 바뀌면 여기도 함께 고친다.
struct ConsentView: View {
    let onAgree: () -> Void

    @State private var confirmed = false

    var body: some View {
        List {
            Section {
                Label {
                    Text("이 앱은 **대화 내용을 녹음하고 텍스트로 받아씁니다.** 녹음을 시작하기 전에 대화에 참여하는 모든 사람에게 녹음 사실을 알리고 동의를 받아 주세요.")
                } icon: {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                }
            }

            Section("데이터가 처리되는 곳") {
                Label("음성은 이 기기 안에서 텍스트로 변환됩니다.", systemImage: "iphone")
                Label("녹음한 음성과 받아쓴 텍스트는 이 기기에 저장됩니다. 회의를 삭제하면 함께 삭제됩니다.", systemImage: "internaldrive")
                Label("질문 탭에서 질문하면 관련 회의의 받아쓴 텍스트가 같은 방식으로 Claude로 전송됩니다.", systemImage: "bubble.left.and.text.bubble.right")
                Label("녹음이 끝나면 요약을 위해 받아쓴 텍스트가 중계 서버를 거쳐 외부 AI 서비스(Anthropic Claude)로 전송됩니다. 중계 서버는 내용을 저장하지 않으며, 음성은 전송되지 않습니다.", systemImage: "text.bubble")
            }

            Section {
                Toggle("대화 참여자에게 녹음 사실을 알리고 동의를 받았습니다", isOn: $confirmed)
            }

            Section {
                Button {
                    onAgree()
                } label: {
                    Text("동의하고 녹음 시작")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .disabled(!confirmed)
            }
        }
        .navigationTitle("녹음 안내")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { ConsentView {} }
}
