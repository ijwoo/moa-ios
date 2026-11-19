import SwiftUI
import UIKit

/// 찾은 페이지 카드 (D64): 맥의 브라우저가 실제로 연 공개 페이지를 그림 · 제목 · 사이트 주소로 보여 준다. 대화 안에서만 쓴다.
///
/// 누르면 앱 안의 사파리 화면으로 연다. 누르기 전에는 페이지를 불러오지 않는다.
/// 제목은 그 페이지가 적어 둔 글이라, 실제로 열리는 사이트 주소를 그 아래에 항상 함께 보여 준다.
/// 그림은 카드가 보일 때 `LinkThumbnailStore`가 받아 메모리에만 들고 있다. 받지 못하면 그림 없이 그린다
struct ReportLinkCards: View {
    let links: [AgentLink]
    @Environment(LinkThumbnailStore.self) private var store: LinkThumbnailStore?
    @State private var opened: OpenedPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(links.enumerated()), id: \.element.url) { index, link in
                if index > 0 { ChatHairline().padding(.leading, 82) }
                Button {
                    opened = OpenedPage(url: link.url)
                } label: {
                    HStack(spacing: 12) {
                        LinkThumbnail(url: link.image, store: store)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(link.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(DS.Chat.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(link.host)
                                .font(.caption)
                                .foregroundStyle(DS.Chat.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(link.title == link.host ? link.host : "\(link.title), \(link.host)")
                .accessibilityHint("웹 페이지를 엽니다")
            }
        }
        .chatCard(padding: 0)
        .sheet(item: $opened) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
    }
}

/// 카드의 그림 자리. 그림이 없거나 받지 못하면 지구본을 그린다 (꾸밈이라 VoiceOver는 읽지 않는다)
struct LinkThumbnail: View {
    let url: URL?
    let store: LinkThumbnailStore?
    /// 그림 자리의 한 변 (찾은 페이지 56, 상품 64)
    var side: CGFloat = 56
    /// 그림이 없을 때 그리는 기호
    var placeholder = "globe"

    /// 다시 받아야 하는 때: 주소가 바뀌거나, 앱이 뒤로 갔다 오거나, 그림을 모두 버렸을 때
    private struct LoadKey: Equatable {
        var url: URL?
        var wasSeen: Bool
        var isOnScreen: Bool
        var generation: Int
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    /// 이 자리가 화면에 한 번이라도 보였는지. 대화는 말을 한꺼번에 놓으므로(D69), 놓였다고 받지 않고 보였을 때 받는다 (D64)
    @State private var wasSeen = false

    var body: some View {
        ZStack {
            DS.Chat.hairline.opacity(0.6)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: placeholder)
                    .font(.title3)
                    .foregroundStyle(DS.Chat.textSecondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            if visible { wasSeen = true }
        }
        .task(id: LoadKey(url: url, wasSeen: wasSeen, isOnScreen: scenePhase != .background, generation: store?.generation ?? 0)) {
            // 앱이 뒤로 가 있는 동안에는 받지 않고, 들고 있던 것도 내려놓는다
            guard let url, let store, scenePhase != .background else {
                image = nil
                return
            }
            guard wasSeen else { return }
            image = await store.image(for: url)
        }
    }
}
