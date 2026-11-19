import Testing
import UIKit
@testable import MeetingSummary

/// 내 정보(설정형 화면)의 부품: 아이콘 그림, 라이선스 고지, 권한 한마디 (D51)
@MainActor
struct SettingsScreenTests {
    @Test func everyLucideIconHasAnAsset() {
        for icon in Lucide.allCases {
            #expect(UIImage(named: icon.assetName) != nil, "그림이 없다: \(icon.rawValue)")
        }
    }

    /// 아이콘을 쓰는 동안 라이선스 고지가 앱에 들어 있어야 한다 (ISC: 저작권 표시와 허가 문구를 함께 둔다)
    @Test func lucideLicenseNoticeShipsWithTheApp() {
        let text = OpenSourceLicenses.lucide
        #expect(text.contains("ISC License"))
        #expect(text.contains("Lucide Contributors"))
        #expect(text.contains("Permission to use, copy, modify, and/or distribute this software"))
        #expect(text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
    }

    @Test func permissionSummaryNamesWhatIsOffFirst() {
        func items(_ mic: PermissionState, _ speech: PermissionState, _ reminders: PermissionState) -> [PermissionItem] {
            [
                PermissionItem(id: "microphone", title: "마이크", reason: "", icon: .mic, state: mic),
                PermissionItem(id: "speech", title: "음성 인식", reason: "", icon: .audioLines, state: speech),
                PermissionItem(id: "reminders", title: "미리알림", reason: "", icon: .listChecks, state: reminders)
            ]
        }
        #expect(PermissionSummary.text(items(.granted, .granted, .granted)) == "모두 허용됨")
        #expect(PermissionSummary.text(items(.notDetermined, .notDetermined, .notDetermined)) == "아직 묻지 않음")
        #expect(PermissionSummary.text(items(.granted, .granted, .notDetermined)) == "2개 허용됨")
        // 꺼진 것이 있으면 허용된 것보다 먼저 말한다
        #expect(PermissionSummary.text(items(.granted, .denied, .granted)) == "음성 인식 꺼짐")
        #expect(PermissionSummary.text(items(.denied, .denied, .notDetermined)) == "2개 꺼짐")
    }

    /// 화면에 보이는 권한 줄은 앱이 실제로 읽는 세 가지다 (카메라는 한 번 물은 뒤에만 뒤에 붙는다, D87)
    @Test func permissionItemsCoverTheThreePermissions() {
        #expect(PermissionItem.current().prefix(3).map(\.title) == ["마이크", "음성 인식", "미리알림"])
    }

    /// 카메라 줄은 물어본 적이 있을 때만 보인다: 찍어 붙이지 않는 사람에게 "아직 묻지 않음"이 남지 않는다
    @Test func cameraRowAppearsOnlyAfterBeingAsked() {
        #expect(PermissionItem.camera(.notDetermined) == nil)
        #expect(PermissionItem.camera(.granted)?.title == "카메라")
        #expect(PermissionItem.camera(.denied)?.state == .denied)
    }
}
