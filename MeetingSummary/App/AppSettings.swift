import SwiftUI

/// 사용자가 바꿀 수 있는 화면 설정. 값은 `@AppStorage`(UserDefaults)에 저장한다.
///
/// 새 설정을 추가할 때: ① 아래 `Key`에 키를 추가 ② 값 타입(열거형)을 이 파일에 정의
/// ③ `AppSettingsModifier`에서 적용 ④ 내 정보 화면의 "화면" 카드에 항목 추가.
/// 화면이 아닌 설정(대화 말투)은 쓰는 곳에서 `ReplyTone.current()`로 읽는다.
enum AppSettings {
    enum Key {
        static let appearance = "settings.appearance"
        static let replyTone = "settings.replyTone"
        /// 내 공간 탭을 쓸지 (D94). 켠 사람에게만 탭이 보인다. 처음에는 꺼져 있다
        static let space = "settings.space"
        /// 처음 한 번 보이는 화면을 보았는지 (D97)
        static let onboarded = "onboarding.done"
    }
}

/// 화면 모드
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "시스템"
        case .light: "라이트"
        case .dark: "다크"
        }
    }

    /// nil이면 시스템 설정을 따른다.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 대화 답변의 말투. 답하는 쪽(맥·Claude)에 `rawValue`를 그대로 보낸다.
///
/// 말투만 바꾼다. 무엇을 할지 판단하는 것, 작업 내용, 메일 초안, 승인 요청은 말투와 상관없이 같다.
enum ReplyTone: String, CaseIterable, Identifiable, Sendable {
    case friendly
    case formal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friendly: "친근하게"
        case .formal: "딱딱하게"
        }
    }

    /// 지금 고른 말투 (고른 적이 없으면 친근하게)
    static func current(_ defaults: UserDefaults = .standard) -> ReplyTone {
        defaults.string(forKey: AppSettings.Key.replyTone).flatMap(ReplyTone.init) ?? .friendly
    }
}

/// 앱 전체에 화면 설정을 적용한다 (루트 화면에 한 번).
struct AppSettingsModifier: ViewModifier {
    @AppStorage(AppSettings.Key.appearance) private var appearance: AppearanceMode = .system

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}

extension View {
    func applyingAppSettings() -> some View {
        modifier(AppSettingsModifier())
    }
}
