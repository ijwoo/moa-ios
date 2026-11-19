import Observation
import SwiftUI
import UIKit

/// 앱의 강조색 (D144): 사용자가 고른다. 기본은 앱 아이콘의 민트.
///
/// 강조색이 들어가는 곳은 모두 이 한 곳에서 색을 받는다 — 탭 막대, 내 말풍선, 강조 글자·아이콘, 내 공간의 포인트,
/// 모아 표시, 앱 아이콘(아이콘의 민트 부분). 색 하나마다 쓰임에 맞춘 다섯 값을 둔다:
/// - `bright`: 앱 아이콘의 그 색 그대로 (면에 칠한다. 위의 글은 `onBright` 먹색)
/// - `bubble`: 흰 글자를 얹는 진한 면 (내 말풍선, 캡슐 단추). 흰 글자 대비 4.5:1 이상
/// - `text`: 글자·아이콘 (밝은 바탕 대비 4.5:1, 어두운 바탕 대비 4.5:1 이상)
/// - `calm`: 모아 상태 표시처럼 차분하게 쓰는 색
/// 색을 더하려면 `AccentChoice`에 한 줄과, 그 색의 앱 아이콘(`AppIcon-<이름>`)을 더한다.
enum AccentChoice: String, CaseIterable, Identifiable {
    case mint, blue, violet, coral, orange, pink

    var id: String { rawValue }

    var name: String {
        switch self {
        case .mint: "민트"
        case .blue: "블루"
        case .violet: "바이올렛"
        case .coral: "코랄"
        case .orange: "오렌지"
        case .pink: "핑크"
        }
    }

    /// (bright, bubble 밝은, bubble 어두운, text 밝은, text 어두운, calm 밝은, calm 어두운)
    private var hex: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) {
        switch self {
        case .mint: (0x45D9AD, 0x1C7F62, 0x1F8063, 0x0A7A57, 0x43D9A3, 0x3E9C8A, 0x6CC4B0)
        case .blue: (0x5AA9FF, 0x1F66C8, 0x2468D0, 0x1F66C8, 0x6AA5FF, 0x4A7FC4, 0x7FAEE8)
        case .violet: (0xA98BFF, 0x6A48D6, 0x6A48D6, 0x6A48D6, 0xB7A2FF, 0x7D66C4, 0xA898E0)
        case .coral: (0xFF8A7A, 0xC23A2B, 0xC23A2B, 0xB8382A, 0xFF9A8C, 0xC4675B, 0xE89A90)
        case .orange: (0xFFB35C, 0xA85400, 0xA85400, 0x9A4E00, 0xFFB866, 0xB87A33, 0xE0AA6A)
        case .pink: (0xFF7EB6, 0xC0306E, 0xC0306E, 0xB52D67, 0xFF8FC2, 0xC2618C, 0xE895B9)
        }
    }

    var bright: Color { Color(uiColor: UIColor(hex: hex.0)) }
    var bubble: Color { Color(light: hex.1, dark: UIColor(hex: hex.2)) }
    var text: Color { Color(light: hex.3, dark: UIColor(hex: hex.4)) }
    var calm: Color { Color(light: hex.5, dark: UIColor(hex: hex.6)) }
    /// 강조 글자색을 옅게 깐 면 (선택된 줄, 강조 면)
    var soft: Color { Color(light: UIColor(hex: hex.3).withAlphaComponent(0.10), dark: UIColor(hex: hex.4).withAlphaComponent(0.15)) }
    /// 지금 재생 중인 말풍선처럼 한 단계 진한 면
    var highlight: Color { Color(light: UIColor(hex: hex.3).withAlphaComponent(0.22), dark: UIColor(hex: hex.4).withAlphaComponent(0.25)) }

    /// 앱 아이콘 이름. 민트는 기본 아이콘(nil)
    var iconName: String? { self == .mint ? nil : "AppIcon-\(rawValue.capitalized)" }

    /// 대비 확인용 원래 값 (테스트)
    var hexValues: (bright: UInt32, bubbleLight: UInt32, bubbleDark: UInt32, textLight: UInt32, textDark: UInt32) {
        (hex.0, hex.1, hex.2, hex.3, hex.4)
    }
}

/// 지금 고른 강조색. 색을 읽는 화면은 이 값을 지켜보므로, 바꾸면 앱 전체가 바로 다시 그려진다.
/// 색 토큰(`DS`)은 어느 곳에서나 읽으므로 이 값도 어디서나 읽을 수 있게 둔다. 바꾸는 것은 화면(메인)에서만 한다
@Observable
final class AppTheme: @unchecked Sendable {
    nonisolated static let shared = AppTheme()
    nonisolated static let key = "appAccent"

    private(set) var accent: AccentChoice

    nonisolated init(defaults: UserDefaults = .standard) {
        accent = defaults.string(forKey: Self.key).flatMap(AccentChoice.init(rawValue:)) ?? .mint
        #if DEBUG
        // 화면 확인용 (`-demoAccent violet`): 이 실행에서만 그 색으로 (저장하지 않는다)
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demoAccent"), i + 1 < args.count, let choice = AccentChoice(rawValue: args[i + 1]) {
            accent = choice
        }
        #endif
    }

    /// 강조색을 바꾸고, 앱 아이콘도 그 색으로 바꾼다 (시스템이 "아이콘을 바꿨다"는 알림을 띄운다)
    @MainActor
    func select(_ choice: AccentChoice, changeIcon: Bool = true) {
        guard choice != accent else { return }
        accent = choice
        UserDefaults.standard.set(choice.rawValue, forKey: Self.key)
        guard changeIcon, UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != choice.iconName else { return }
        UIApplication.shared.setAlternateIconName(choice.iconName) { error in
            if let error { print("앱 아이콘을 바꾸지 못했다: \(error.localizedDescription)") }
        }
    }
}
