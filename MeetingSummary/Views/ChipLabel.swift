import SwiftUI

/// 작은 정보 칩 (아이콘 + 글자). 시스템 Label은 목록 안에서 아이콘 칸을 넓게 잡아 간격이 벌어지므로 직접 배치한다.
struct ChipLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DS.Colors.accent.opacity(0.12), in: Capsule())
    }
}
