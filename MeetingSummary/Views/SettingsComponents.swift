import SwiftUI
import UIKit

// 설정형 화면(내 정보와 그 아래 화면)의 공통 값과 부품 (D51).
// 면과 모서리는 시스템의 묶음 목록(`List`, inset grouped)을 그대로 쓰고, 여기서는 그 위에 얹는 값만 정한다.
// 다른 탭과 바텀시트는 `CardSection`·`CardRow`(DesignSystem.swift)를 그대로 쓴다.

extension DS {
    /// 설정형 화면 공통 값
    enum Settings {
        /// 줄 앞 아이콘 한 변 (본문 글자 크기를 따라 커진다)
        static let iconSize: CGFloat = 22
        /// 제목과 보조 문구 사이
        static let textSpacing: CGFloat = 2
        /// 묶음과 묶음 사이
        static let sectionSpacing: CGFloat = 28

        /// 줄 제목
        static let titleFont = Font.body
        /// 줄 아래 보조 문구, 묶음 아래 설명
        static let captionFont = Font.footnote
        /// 긴 글을 읽는 줄 (데이터 처리 방식)
        static let readingFont = Font.subheadline
        /// 줄 안의 주요 동작 글자 (로그인, 계정 연결)
        static let actionFont = Font.body
    }
}

/// 설정형 화면에 쓰는 선 아이콘 (Lucide, ISC 라이선스). 그림은 `Assets.xcassets/Lucide`에 있다.
///
/// 시스템이 그리는 것(뒤로 가기, 줄 끝 화살표, 고른 항목 표시, 더 보기 메뉴)은 SF Symbols를 그대로 쓴다.
/// 아이콘을 더할 때: lucide-static의 SVG를 같은 방식(선 굵기 1.75, 템플릿)으로 넣고 여기에 이름을 더한다.
enum Lucide: String, CaseIterable {
    case alignLeft = "align-left"
    case audioLines = "audio-lines"
    case bell
    case camera
    case circleUserRound = "circle-user-round"
    case clipboardList = "clipboard-list"
    case cloud
    case cpu
    case fileSearch = "file-search"
    case fileText = "file-text"
    case globe
    case hardDrive = "hard-drive"
    case history
    case inbox
    case info
    case keyRound = "key-round"
    case link
    case listChecks = "list-checks"
    case logIn = "log-in"
    case mail
    case messageCircle = "message-circle"
    case messageCircleQuestion = "message-circle-question"
    case messagesSquare = "messages-square"
    case mic
    case monitor
    case plus
    case shieldCheck = "shield-check"
    case sparkles
    case squareX = "square-x"
    case sunMoon = "sun-moon"
    case trash = "trash-2"

    var assetName: String { "Lucide/\(rawValue)" }
}

/// 선 아이콘 하나. 색은 바깥의 `foregroundStyle`을 따른다. 뜻은 옆 글자가 전하므로 VoiceOver는 읽지 않는다
struct LucideIcon: View {
    let icon: Lucide
    @ScaledMetric(relativeTo: .body) private var size = DS.Settings.iconSize

    init(_ icon: Lucide) { self.icon = icon }

    var body: some View {
        Image(icon.assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 설정 한 줄: 아이콘 + 제목(+ 짧은 보조 문구) + 오른쪽 값.
///
/// `NavigationLink`나 `Button` 안에 넣어 쓴다 (줄 끝 화살표는 시스템이 그린다).
/// 글자가 커지면 값이 아랫줄로 내려간다 (`LabeledContent`의 기본 동작).
struct SettingsRow<Value: View>: View {
    let icon: Lucide
    var tint: Color = DS.Colors.accent
    let title: String
    /// 아직 쓸 수 없는 줄은 제목도 흐리게 한다
    var titleColor: Color = DS.Colors.textPrimary
    var subtitle: String?
    @ViewBuilder var value: () -> Value

    var body: some View {
        LabeledContent {
            value()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: DS.Settings.textSpacing) {
                    Text(title)
                        .font(DS.Settings.titleFont)
                        .foregroundStyle(titleColor)
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.Settings.captionFont)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            } icon: {
                LucideIcon(icon).foregroundStyle(tint)
            }
        }
    }
}

extension SettingsRow where Value == EmptyView {
    init(icon: Lucide, tint: Color = DS.Colors.accent, title: String, titleColor: Color = DS.Colors.textPrimary, subtitle: String? = nil) {
        self.init(icon: icon, tint: tint, title: title, titleColor: titleColor, subtitle: subtitle) { EmptyView() }
    }
}

extension SettingsRow where Value == Text {
    /// 오른쪽에 현재 값을 글자로 보인다
    init(icon: Lucide, tint: Color = DS.Colors.accent, title: String, titleColor: Color = DS.Colors.textPrimary, subtitle: String? = nil, value: String) {
        self.init(icon: icon, tint: tint, title: title, titleColor: titleColor, subtitle: subtitle) {
            Text(value).foregroundStyle(DS.Colors.textSecondary)
        }
    }
}

/// 줄 안의 주요 동작 ("로그인", "계정 연결"). 강조색 글자, 제목과 같은 자리에서 시작한다
struct SettingsActionLabel: View {
    let title: String
    var icon: Lucide?
    var color: Color = DS.Colors.accent

    var body: some View {
        Label {
            Text(title).font(DS.Settings.actionFont)
        } icon: {
            if let icon { LucideIcon(icon) }
        }
        .foregroundStyle(color)
    }
}

extension View {
    /// 설정형 화면의 바탕: 시스템 묶음 목록 + 앱 배경색 (다른 탭과 같은 바탕)
    func settingsListStyle() -> some View {
        listStyle(.insetGrouped)
            .listSectionSpacing(DS.Settings.sectionSpacing)
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
    }
}

/// 여러 값 가운데 하나를 고르는 상세 화면 (화면 모드, 답변 말투). 고른 값에 시스템 체크 표시가 붙는다
struct SettingChoiceList<Option: Identifiable & Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var detail: (Option) -> String? = { _ in nil }
    var footer: String?

    var body: some View {
        List {
            Section {
                ForEach(options) { option in
                    Button {
                        selection = option
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: DS.Settings.textSpacing) {
                                Text(label(option))
                                    .font(DS.Settings.titleFont)
                                    .foregroundStyle(DS.Colors.textPrimary)
                                if let text = detail(option) {
                                    Text(text)
                                        .font(DS.Settings.captionFont)
                                        .foregroundStyle(DS.Colors.textSecondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if option == selection {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(DS.Colors.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(option == selection ? .isSelected : [])
                }
            } footer: {
                if let footer { Text(footer) }
            }
        }
        .settingsListStyle()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
