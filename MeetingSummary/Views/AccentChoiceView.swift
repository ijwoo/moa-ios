import SwiftUI

/// 강조색 고르기 (D144, 내 정보 › 환경 설정 › 강조색): 고르면 앱 전체와 앱 아이콘이 그 색으로 바뀐다
struct AccentChoiceView: View {
    @State private var theme = AppTheme.shared

    var body: some View {
        List {
            Section {
                AccentPreview(choice: theme.accent)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            Section {
                ForEach(AccentChoice.allCases) { choice in
                    Button {
                        Haptic.select()
                        withAnimation(.easeInOut(duration: 0.25)) { theme.select(choice) }
                    } label: {
                        HStack(spacing: 12) {
                            AccentSwatch(choice: choice, size: 26)
                            Text(choice == .mint ? "\(choice.name) (기본)" : choice.name)
                                .font(DS.Settings.titleFont)
                                .foregroundStyle(DS.Colors.textPrimary)
                            Spacer()
                            if choice == theme.accent {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(DS.Colors.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(choice == theme.accent ? .isSelected : [])
                }
            } footer: {
                Text("탭 막대, 내 말풍선, 단추와 강조 글자, 내 공간의 포인트, 앱 아이콘이 이 색으로 바뀌어요. 앱 아이콘을 바꿀 때는 아이폰이 알림을 한 번 띄워요.")
            }
        }
        .settingsListStyle()
        .navigationTitle("강조색")
        .navigationBarTitleDisplayMode(.inline)
        // 탭 막대는 숨기지 않는다: 고른 색이 탭 막대에 바로 보이게
    }
}

/// 고른 색의 견본: 앱 아이콘의 그 색 그대로
struct AccentSwatch: View {
    let choice: AccentChoice
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(choice.bright)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// 미리 보기: 그 색의 앱 아이콘과 내 말풍선
private struct AccentPreview: View {
    let choice: AccentChoice
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        HStack(spacing: 20) {
            // 앱 아이콘과 같은 모양 (D146: 밝은 모드는 흰 바탕·먹색 잎, 어두운 모드는 어두운 바탕·흰 잎)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(dark ? Color(red: 0.059, green: 0.059, blue: 0.071) : .white)
                .frame(width: 80, height: 80)
                .overlay {
                    MoaLogoMarkV4(
                        width: 48, mintColor: choice.bright,
                        leafColor: dark ? .white : Color(red: 0.086, green: 0.098, blue: 0.118),
                        showGuide: false, step1: true, step2: true, step3: true, step4: true, ripple: false
                    )
                }
                .shadow(color: .black.opacity(dark ? 0 : 0.08), radius: 6, y: 2)
                .accessibilityLabel("\(choice.name) 앱 아이콘")
            VStack(alignment: .trailing, spacing: 6) {
                Text("내일 회의 정리해 줘")
                    .font(.subheadline)
                    .foregroundStyle(DS.Chat.onUserBubble)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(choice.bubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("강조 글자")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(choice.text)
            }
            .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
    }
}

#if DEBUG
#Preview {
    NavigationStack { AccentChoiceView() }
}
#endif
