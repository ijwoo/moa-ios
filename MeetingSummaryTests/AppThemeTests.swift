import Foundation
import Testing
@testable import MeetingSummary

// 강조색 (D144): 사용자가 고르는 색. 기본은 민트. 어떤 색을 골라도 글자가 읽혀야 한다
@Suite("강조색")
struct AppThemeTests {
    private static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16 & 0xFF) + 0.7152 * channel(hex >> 8 & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test(arguments: AccentChoice.allCases)
    func everyChoiceStaysReadable(_ choice: AccentChoice) {
        let v = choice.hexValues
        // 내 말풍선의 흰 글자
        #expect(Self.contrast(v.bubbleLight, 0xFFFFFF) >= 4.5)
        #expect(Self.contrast(v.bubbleDark, 0xFFFFFF) >= 4.5)
        // 강조 글자: 밝은 화면의 흰 면·회색 바탕, 어두운 화면의 면
        #expect(Self.contrast(v.textLight, 0xFFFFFF) >= 4.5)
        #expect(Self.contrast(v.textLight, 0xF2F2F7) >= 4.5)
        #expect(Self.contrast(v.textDark, 0x1C1C1E) >= 4.5)
        // 아이콘 색 면 위의 먹색 글자
        #expect(Self.contrast(v.bright, 0x0E1116) >= 4.5)
    }

    @Test func mintIsTheDefaultAndKeepsTheMainIcon() {
        let defaults = UserDefaults(suiteName: "AppThemeTests")!
        defaults.removePersistentDomain(forName: "AppThemeTests")
        #expect(AppTheme(defaults: defaults).accent == .mint)
        #expect(AccentChoice.mint.iconName == nil)
        defaults.set("violet", forKey: AppTheme.key)
        #expect(AppTheme(defaults: defaults).accent == .violet)
        // 모르는 값이면 기본으로
        defaults.set("plaid", forKey: AppTheme.key)
        #expect(AppTheme(defaults: defaults).accent == .mint)
    }

    @Test func everyOtherChoiceHasItsOwnIcon() {
        let names = AccentChoice.allCases.compactMap(\.iconName)
        #expect(names == ["AppIcon-Blue", "AppIcon-Violet", "AppIcon-Coral", "AppIcon-Orange", "AppIcon-Pink"])
        // 앱 번들에 그 아이콘이 들어 있다 (빌드 설정의 대체 아이콘 이름과 같은지)
        let icons = Bundle(for: AppTheme.self).object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let alternates = (icons?["CFBundleAlternateIcons"] as? [String: Any]).map { Set($0.keys) } ?? []
        #expect(Set(names).isSubset(of: alternates))
    }
}
