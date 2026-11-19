import SafariServices
import SwiftUI

/// 누른 링크 하나 (시트로 띄울 때 쓴다)
struct OpenedPage: Identifiable {
    let url: URL
    var id: URL { url }
}

/// 앱 안에서 여는 사파리 화면 (D64). 답에 붙은 링크를 사용자가 눌렀을 때만 띄운다.
/// 주소 표시줄이 보이고, 앱은 그 페이지의 내용이나 쿠키를 보지 못한다. 이 아이폰이 그 사이트에 직접 접속한다
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
