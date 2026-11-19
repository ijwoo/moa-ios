import SwiftUI
import UIKit

// 내 정보에서 눌러 들어가는 작은 화면들: 권한, 오픈소스 라이선스 (D51).
// 고르는 화면(화면 모드, 답변 말투)은 `SettingChoiceList`를 쓴다.

// MARK: - 권한

/// 앱이 쓰는 권한 하나와 지금 상태 (표시용). 요청은 하지 않는다 (`PermissionStatus` 참고)
struct PermissionItem: Identifiable, Equatable {
    let id: String
    let title: String
    /// 어디에 쓰는지 한 줄
    let reason: String
    let icon: Lucide
    var state: PermissionState

    static func current() -> [PermissionItem] {
        [
            PermissionItem(id: "microphone", title: "마이크", reason: "회의를 녹음할 때 써요", icon: .mic, state: PermissionStatus.microphone),
            PermissionItem(id: "speech", title: "음성 인식", reason: "녹음을 텍스트로 바꿀 때 써요", icon: .audioLines, state: PermissionStatus.speechRecognition),
            PermissionItem(id: "reminders", title: "미리알림", reason: "할 일을 미리알림에 넣을 때 써요", icon: .listChecks, state: PermissionStatus.reminders)
        ] + [camera(PermissionStatus.camera), contacts(PermissionStatus.contacts), calendar(PermissionStatus.calendar)].compactMap { $0 }
    }

    /// 캘린더 줄 (D95). 한 번이라도 물은 뒤에만 보인다 (내 공간에 일정 카드를 두지 않는 사람에게는 보이지 않는다)
    static func calendar(_ state: PermissionState) -> PermissionItem? {
        guard state != .notDetermined else { return nil }
        return PermissionItem(id: "calendar", title: "캘린더", reason: "내 공간에 오늘 일정을 보일 때 써요", icon: .clipboardList, state: state)
    }

    /// 연락처 줄 (D89). 카메라처럼 한 번이라도 물은 뒤에만 보인다
    static func contacts(_ state: PermissionState) -> PermissionItem? {
        guard state != .notDetermined else { return nil }
        return PermissionItem(id: "contacts", title: "연락처", reason: "메일 받을 사람을 이름으로 찾을 때 써요", icon: .circleUserRound, state: state)
    }

    /// 카메라 줄 (D87). 한 번이라도 물은 뒤에만 보인다 — 카메라로 찍어 붙이지 않는 사람에게 "아직 묻지 않음"이 늘 남지 않게
    static func camera(_ state: PermissionState) -> PermissionItem? {
        guard state != .notDetermined else { return nil }
        return PermissionItem(id: "camera", title: "카메라", reason: "질문에 붙일 사진을 찍을 때 써요", icon: .camera, state: state)
    }
}

extension PermissionState {
    var tone: StatusBadge.Tone {
        switch self {
        case .granted: .positive
        case .denied: .warning
        case .notDetermined: .muted
        }
    }
}

/// 내 정보의 "권한" 줄에 보이는 한마디. 꺼진 것이 있으면 그것부터 말한다
enum PermissionSummary {
    static func text(_ items: [PermissionItem]) -> String {
        let denied = items.filter { $0.state == .denied }
        if denied.count == 1 { return "\(denied[0].title) 꺼짐" }
        if denied.count > 1 { return "\(denied.count)개 꺼짐" }
        let granted = items.filter { $0.state == .granted }.count
        if granted == items.count, !items.isEmpty { return "모두 허용됨" }
        return granted == 0 ? PermissionState.notDetermined.label : "\(granted)개 허용됨"
    }
}

/// 권한별 상태와 쓰는 곳. 꺼진 권한이 있으면 아이폰 설정으로 보낸다 (앱이 다시 물을 수 없다)
struct PermissionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var items = PermissionItem.current()
    /// 알림 권한 (D67). 맥이 알림을 보낼 수 있을 때만 줄이 생긴다
    private let push = PushCenter.shared

    var body: some View {
        let rows = items + [push.permissionItem].compactMap { $0 }
        List {
            Section {
                ForEach(rows) { item in
                    SettingsRow(icon: item.icon, title: item.title, subtitle: item.reason) {
                        StatusBadge(text: item.state.label, tone: item.state.tone)
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                Text("한국어 음성을 이 기기 안에서 텍스트로 바꿔요. 권한은 처음 녹음하거나 미리알림에 추가할 때 물어봐요.")
            }
            if push.canAsk {
                Section {
                    Button("알림 받기") { Task { await push.askPermission() } }
                        .accessibilityHint("알림을 받을지 아이폰이 물어봅니다")
                } footer: {
                    Text("처음 일을 맡길 때에도 물어봐요. 알림에는 정해진 문장만 보이고, 내용은 앱을 열어야 보여요.")
                }
            }
            if rows.contains(where: { $0.state == .denied }) {
                Section {
                    Button("설정 열기") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .accessibilityHint("꺼진 권한을 아이폰 설정에서 켭니다")
                } footer: {
                    Text("꺼진 권한은 아이폰 설정에서 다시 켤 수 있어요.")
                }
            }
        }
        .settingsListStyle()
        .navigationTitle("권한")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { items = PermissionItem.current() }
        .task { await push.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // 설정에서 켜고 돌아오면 바로 보이게 (알림은 맨 위 화면이 다시 확인한다)
            if phase == .active { items = PermissionItem.current() }
        }
    }
}

// MARK: - 오픈소스 라이선스

/// 앱에 들어 있는 오픈소스의 고지문. 글은 앱에 넣어 둔 라이선스 파일에서 읽는다
enum OpenSourceLicenses {
    /// Lucide 아이콘 (ISC). 줄바꿈으로 끊긴 문단을 이어 붙여 화면 너비에 맞게 흐르게 한다
    static let lucide: String = {
        guard let url = Bundle.main.url(forResource: "Lucide-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n").joined(separator: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }()
}

struct LicensesView: View {
    var body: some View {
        List {
            Section {
                Text(OpenSourceLicenses.lucide.isEmpty ? "ISC License" : OpenSourceLicenses.lucide)
                    .font(DS.Settings.captionFont)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .textSelection(.enabled)
            } header: {
                Text("Lucide")
            } footer: {
                Text("내 정보 화면의 선 아이콘에 써요. lucide.dev")
            }
        }
        .settingsListStyle()
        .navigationTitle("오픈소스 라이선스")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    NavigationStack { PermissionsView() }
}
#endif
