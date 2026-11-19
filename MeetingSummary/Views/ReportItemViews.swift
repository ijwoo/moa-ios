import SwiftUI

/// 찾은 상품 카드 (D72): 맥이 찾은 상품을 그림 · 이름 · 값 · 파는 곳으로 보여 준다. 대화 안에서만 쓴다.
///
/// - 값·이름·파는 곳은 맥이 받은 그대로 그린다. 앱은 더하거나 빼거나 고쳐 쓰지 않고, 없는 값은 그리지 않는다
/// - 상품을 누르면 앱 안의 사파리 화면으로 그 페이지를 연다. 누르기 전에는 불러오지 않는다 (찾은 페이지 카드와 같다, D64)
/// - 쇼핑 화면에서 찾아 온 상품(D75)은 그 쇼핑 화면으로 연다: 거기서 읽은 화면이고, 로그인도 거기에 있다
/// - "고르기"는 그 상품을 골랐다는 말을 보낸다. 고르기만 한다: 담거나 주문하는 것은 맥이 따로 승인을 받는 일이다
/// - 그림은 카드가 보일 때 `LinkThumbnailStore`가 받아 메모리에만 들고 있다
struct ReportItemCards: View {
    let items: [AgentItem]
    /// 지금 고를 수 있는지 (못 고르는 동안에는 버튼을 흐리게 둔다)
    var canPick = false
    /// nil이면 "고르기"를 두지 않는다 (상품 목록을 모르는 맥, 작업 상세)
    var onPick: ((AgentItem) -> Void)?
    /// 쇼핑 화면에서 찾아 온 상품이다 (D75): 누르면 쇼핑 화면으로 연다
    var opensInShop = false
    @Environment(LinkThumbnailStore.self) private var store: LinkThumbnailStore?
    @Environment(\.shopDesk) private var shopDesk
    @State private var opened: OpenedPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.url) { index, item in
                if index > 0 { ChatHairline().padding(.leading, 90) }
                HStack(spacing: 10) {
                    Button {
                        open(item)
                    } label: {
                        ItemRow(item: item, store: store)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Self.spoken(item))
                    .accessibilityHint("상품 페이지를 엽니다")
                    if let onPick {
                        Button {
                            onPick(item)
                        } label: {
                            Text("고르기")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(DS.Chat.accent)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .background(DS.Chat.accent.opacity(0.12), in: Capsule())
                                // 보이는 크기는 작아도 누르는 자리는 44를 채운다
                                .frame(minHeight: DS.minTouch)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPick)
                        .opacity(canPick ? 1 : 0.45)
                        .accessibilityLabel("\(item.title) 고르기")
                        .accessibilityHint("이 상품으로 하겠다고 보냅니다. 주문하지는 않습니다")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            ChatHairline()
            Text("값은 찾은 때의 값이에요. 실제 값과 배송비는 상품 페이지에서 확인해 주세요.")
                .font(.caption)
                .foregroundStyle(DS.Chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .chatCard(padding: 0)
        .sheet(item: $opened) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
    }

    /// 상품 페이지를 연다. 쇼핑 화면에서 찾아 온 상품이고 그 화면이 여는 상품 주소이면 쇼핑 화면으로, 아니면 사파리 화면으로
    private func open(_ item: AgentItem) {
        guard opensInShop, let browser = shopDesk?.browser, browser.site.page(for: item.url)?.kind == .product else {
            opened = OpenedPage(url: item.url)
            return
        }
        // 에이전트가 다른 것을 찾는 중이면 그 화면을 건드리지 않고 보여 주기만 한다
        if browser.drive == nil { browser.visit(item.url) }
        browser.isPresented = true
    }

    /// VoiceOver가 읽는 한 줄: 이름, 값, 파는 곳
    static func spoken(_ item: AgentItem) -> String {
        ([item.title, item.priceText, item.detail, item.caption.isEmpty ? item.host : item.caption] as [String?])
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// 상품 한 줄: 그림, 이름(두 줄까지), 값, 파는 곳 · 브랜드 · 배송비
private struct ItemRow: View {
    let item: AgentItem
    let store: LinkThumbnailStore?

    var body: some View {
        HStack(spacing: 12) {
            LinkThumbnail(url: item.image, store: store, side: 64, placeholder: "bag")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DS.Chat.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .lineLimit(1)
                }
                if let price = item.priceText {
                    Text(price)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Chat.textPrimary)
                        .monospacedDigit()
                }
                // 파는 곳 이름이 없으면 실제로 열리는 사이트 주소를 보여 준다
                Text(item.caption.isEmpty ? item.host : item.caption)
                    .font(.caption)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
