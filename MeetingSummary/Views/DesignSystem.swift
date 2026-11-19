import SwiftUI
import UIKit

/// 공통 디자인 토큰과 기본 컴포넌트. 할 일·내 정보 화면이 같은 값을 쓴다.
///
/// - 색은 `DS.Colors` 토큰만 쓴다. 라이트는 정리된 팔레트, 다크는 시스템 의미 색 (거의 검은 배경 + 차콜 카드).
/// - 글자는 시스템 텍스트 스타일만 써서 Dynamic Type을 그대로 따른다.
/// - 장식용 그라데이션·과도한 유리 효과는 쓰지 않는다.
enum DS {
    /// 색 토큰. 화면에서는 이 값만 쓴다 (색을 직접 적지 않는다).
    ///
    /// - 라이트: 정리된 팔레트 (D29). 글자 대비는 모두 WCAG AA(4.5:1) 이상.
    /// - 다크: 기존 모습을 유지하도록 시스템 의미 색 그대로.
    enum Colors {
        /// 화면 배경
        static let background = Color(light: 0xF7F8FA, dark: .systemGroupedBackground)
        /// 카드·메일 미리보기 등 기본 면
        static let surface = Color(light: 0xFFFFFF, dark: .secondarySystemGroupedBackground)
        /// 답변 말풍선, 에이전트 진행·승인 카드 (다크는 기존 채움 색)
        static let secondarySurface = Color(light: 0xF0F2F5, dark: .tertiarySystemFill)
        /// 카드 안의 한 단계 낮은 면 (진행 막대 바탕, 입력칸)
        static let inset = Color(light: 0xF0F2F5, dark: .tertiarySystemGroupedBackground)
        static let border = Color(light: 0xE5E8ED, dark: .separator)

        static let textPrimary = Color(light: 0x17191D, dark: .label)
        static let textSecondary = Color(light: 0x626873, dark: .secondaryLabel)

        /// 강조색 하나로 통일 (선택 상태, 승인 버튼, 진행 표시, 강조 글자·아이콘). 사용자가 고른 색이다 (D144, `AppTheme`).
        /// 읽는 화면은 고른 색을 지켜보므로 색을 바꾸면 바로 다시 그려진다
        static var accent: Color { AppTheme.shared.accent.text }
        static var accentSoft: Color { AppTheme.shared.accent.soft }
        /// 지금 재생 중인 말풍선
        static var highlightSurface: Color { AppTheme.shared.accent.highlight }
        static let warning = Color(light: 0xA35E14, dark: .systemOrange)
        static let warningSoft = Color(light: 0xFFF5E9, dark: UIColor.systemOrange.withAlphaComponent(0.06))
        static let success = Color(light: 0x248A3D, dark: .systemGreen)
        static let danger = Color(light: 0xD12C2C, dark: .systemRed)
        /// 미리알림 연결 표시. 강조색과 같은 값이다 (인디고가 파랑 옆에서 따로 놀아 통일, D29 보완).
        /// 뜻이 달라 토큰은 따로 둔다
        static let reminder = accent

        /// 승인 카드: 라이트·다크 모두 중립 보조 면, 테두리 없음. 경고색은 제목·아이콘에만.
        static let approvalSurface = secondarySurface
        /// 테두리 카드의 면 (메일 미리보기, 근거 카드): 라이트는 흰 면, 다크는 기존(채움 없음 + 구분선)
        static let outlinedSurface = Color(light: 0xFFFFFF, dark: .clear)
        /// 카드 안 입력칸 (승인 카드의 거부 사유)
        static let field = Color(light: 0xFFFFFF, dark: .tertiarySystemGroupedBackground)
    }

    /// 대화 화면(질문 탭) 전용 색 (D47). 다른 탭과 작업 상세는 `Colors`를 그대로 쓴다.
    ///
    /// - 다크: 순수 검정 대신 차콜 바탕, 그 위에 한 단계씩 밝은 면. 글자 대비는 모두 WCAG AA(4.5:1) 이상.
    /// - 라이트: 기존 팔레트(D29)와 같은 계열.
    enum Chat {
        /// 대화 바탕 (D119: 파란 기 없는 중립 회색. 참고 앱처럼 차분하게)
        static let background = Color(light: 0xF7F7F8, dark: UIColor(hex: 0x121212))
        /// 답변 말풍선
        static let bubble = Color(light: 0xEFEFF1, dark: UIColor(hex: 0x262628))
        /// 에이전트 카드 (작업 카드, 승인·결과 카드). D119부터 말풍선과 같은 면이다 — 카드는 내용이 많은 말풍선이다
        static let card = bubble
        /// 카드·말풍선 위에 얹는 면 (아이콘 바탕, 입력칸, 인용)
        static let elevated = Color(light: 0xE6E6EA, dark: UIColor(hex: 0x323235))
        /// 말풍선 안에 한 단계 가라앉힌 줄 (고르기 후보, 카드의 누르는 줄. D119)
        static let inset = Color(light: 0xE4E4E8, dark: UIColor(hex: 0x1C1C1E))
        /// 카드 안 구분선
        static let hairline = Color(light: UIColor(hex: 0xDEDEE2), dark: UIColor.white.withAlphaComponent(0.08))

        static let textPrimary = Color(light: 0x17171A, dark: UIColor(hex: 0xF2F2F4))
        static let textSecondary = Color(light: 0x66666D, dark: UIColor(hex: 0x9C9CA2))

        /// 내 말풍선 (D119): 강조색을 흰 글자가 읽히게(4.5:1 이상) 짙게 낮춘 색. 진한 색은 여기에만 쓴다 (D144: 고른 강조색)
        static var userBubble: Color { AppTheme.shared.accent.bubble }
        static let onUserBubble = Color.white

        /// 글자·아이콘에 쓰는 강조색 (면에는 `userBubble`). 다크에서는 한 단계 밝혀 어두운 면 위에서 읽힌다 (D144: 고른 강조색)
        static var accent: Color { AppTheme.shared.accent.text }
        /// 상태 글자로도 쓰므로 흰 면 위 대비 4.5:1을 넘긴다
        static let success = Color(light: 0x1E7B36, dark: UIColor(hex: 0x4CC38A))
        static let warning = Color(light: 0x9A5710, dark: UIColor(hex: 0xF0A857))
        static let danger = Color(light: 0xC9342B, dark: UIColor(hex: 0xFF6B61))

        /// 말풍선 모서리 (카드도 같다, D119)
        static let bubbleRadius: CGFloat = 22
        /// 카드 모서리
        static let cardRadius: CGFloat = 22
        /// 한 사람이 이어서 한 말 사이 (D119: 이어진 말이 한 덩어리로 읽히게 좁힌다. D150: 참고 앱처럼 2)
        static let groupSpacing: CGFloat = 2
        /// 말하는 사람이 바뀔 때 (D150: 참고 앱처럼 12)
        static let turnSpacing: CGFloat = 12
        /// 같은 쪽이어도 카드·덧말(근거, 반응)이 끼어 있을 때
        static let blockSpacing: CGFloat = 10
        /// 말풍선 안쪽 여백 (D150: 참고 앱을 재서 맞췄다. 줄 간격은 글꼴 그대로, 따로 벌리지 않는다)
        static let bubblePaddingH: CGFloat = 14
        static let bubblePaddingV: CGFloat = 11
    }

    enum Radius {
        static let card: CGFloat = 24
        static let inner: CGFloat = 14
    }

    enum Spacing {
        /// 카드와 카드 사이
        static let section: CGFloat = 24
        /// 카드 안쪽 여백
        static let card: CGFloat = 18
        /// 행(`CardRow`)으로만 된 카드의 위아래 여백. 행이 이미 44 높이라 카드 여백까지 18이면 한 줄 카드가 80이 된다
        static let cardRows: CGFloat = 6
        /// 카드 안 항목 사이
        static let item: CGFloat = 12
    }

    /// 손가락으로 누르는 요소의 최소 크기 (Apple HIG)
    static let minTouch: CGFloat = 44
}

extension Color {
    /// 라이트·다크에 따라 바뀌는 색
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    init(light hex: UInt32, dark: UIColor) {
        self.init(light: UIColor(hex: hex), dark: dark)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 제목(선택) + 둥근 카드 + 설명(선택)
struct CardSection<Content: View>: View {
    var title: String?
    var footer: String?
    /// 카드 안 항목 사이 간격. 구분선으로 나뉜 목록형 카드는 작게 준다.
    var spacing: CGFloat = DS.Spacing.item
    /// 카드 위아래 여백. 행으로만 된 카드는 `DS.Spacing.cardRows`를 준다.
    var verticalPadding: CGFloat = DS.Spacing.card
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.card)
            .padding(.vertical, verticalPadding)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// 상태 표시 작은 배지 ("허용됨", "준비 중" 등)
struct StatusBadge: View {
    enum Tone { case positive, warning, neutral, muted }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(foreground.opacity(0.15), in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .positive: DS.Colors.success
        case .warning: DS.Colors.warning
        case .neutral: DS.Colors.accent
        case .muted: DS.Colors.textSecondary
        }
    }
}

/// 아이콘 + 제목(+ 부제) + 오른쪽 내용. 카드 안 한 줄.
struct CardRow<Trailing: View>: View {
    let icon: String
    var iconColor: Color = DS.Colors.accent
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(iconColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: DS.minTouch)
        .contentShape(Rectangle())
    }
}

extension CardRow where Trailing == EmptyView {
    init(icon: String, iconColor: Color = DS.Colors.accent, title: String, subtitle: String? = nil) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// `CardRow` 사이의 구분선. 아이콘 열(28) + 간격(12)만큼 들여서 글자 시작점에 맞춘다.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 28 + 12)
    }
}
