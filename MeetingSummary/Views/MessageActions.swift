import SwiftUI
import UIKit

// 말풍선을 길게 눌렀을 때: 반응(이모지) · 답장 · 복사 · 선택 (D47).
// 반응은 기기에만 남는다. 답장의 인용은 말풍선에 붙고, 어디로 가는지는 `AskSession.send`가 정한다.

enum MessageReaction {
    /// 메뉴의 반응 줄은 칸 폭이 정해져 있어 여섯 개까지 한 번에 보이고, 일곱째는 옆으로 밀면 나온다
    static let all = ["👍", "❤️", "😂", "😮", "😢", "👏", "🔥"]

    /// 메뉴는 그림을 한 가지 색으로 칠하므로, 이모지를 원래 색 그림으로 만들어 넣는다
    @MainActor
    static func image(_ emoji: String, selected: Bool) -> UIImage {
        let side: CGFloat = 30
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in
            if selected {
                UIColor.tintColor.withAlphaComponent(0.25).setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            }
            let text = emoji as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 21)]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
        }
        .withRenderingMode(.alwaysOriginal)
    }
}

struct MessageActions: ViewModifier {
    let text: String
    var radius: CGFloat = DS.Chat.bubbleRadius
    /// 지금 붙어 있는 반응
    var reaction: String?
    /// nil이면 반응 줄을 두지 않는다 (작업 안내 말처럼 저장 단위가 아닌 말)
    var onReact: ((String) -> Void)?
    var onReply: (() -> Void)?

    @Environment(\.selectText) private var selectText
    @Environment(\.replyToTask) private var replyToTask

    func body(content: Content) -> some View {
        // 작업 안의 말풍선·카드는 그 작업에 답장한다
        let reply = onReply ?? replyToTask
        content
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contextMenu {
                if let onReact {
                    ControlGroup {
                        ForEach(MessageReaction.all, id: \.self) { emoji in
                            Button {
                                onReact(emoji)
                            } label: {
                                Label {
                                    Text(emoji)
                                } icon: {
                                    Image(uiImage: MessageReaction.image(emoji, selected: reaction == emoji))
                                }
                            }
                            .accessibilityLabel(reaction == emoji ? "\(emoji) 반응 지우기" : "\(emoji) 반응")
                        }
                    }
                    .controlGroupStyle(.palette)
                    // 반응을 고르면 메뉴를 닫는다 (팔레트는 그대로 두면 고른 뒤에도 열려 있다)
                    .menuActionDismissBehavior(.enabled)
                }
                if let reply {
                    Button(action: reply) { Label("답장", systemImage: "arrowshape.turn.up.left") }
                }
                Button {
                    UIPasteboard.general.string = text
                    Haptic.success()
                } label: {
                    Label("복사", systemImage: "doc.on.doc")
                }
                if let selectText {
                    Button {
                        selectText(text)
                    } label: {
                        Label("선택", systemImage: "character.cursor.ibeam")
                    }
                }
            }
    }
}

extension View {
    /// 길게 누르면 반응·답장·복사·선택이 나온다
    func messageActions(
        text: String, radius: CGFloat = DS.Chat.bubbleRadius, reaction: String? = nil,
        onReact: ((String) -> Void)? = nil, onReply: (() -> Void)? = nil
    ) -> some View {
        modifier(MessageActions(text: text, radius: radius, reaction: reaction, onReact: onReact, onReply: onReply))
    }
}

/// 말풍선 아래에 붙는 반응. 누르면 지운다
struct ReactionBadge: View {
    let emoji: String
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            Text(emoji)
                .font(.footnote)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(DS.Chat.card, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Chat.hairline, lineWidth: 1))
                // 누르는 곳은 44pt
                .frame(minWidth: DS.minTouch, minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(emoji) 반응")
        .accessibilityHint("누르면 반응을 지웁니다")
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

/// 대화 담당이 내 말에 단 반응 (D70). 내가 붙인 것이 아니라 누르는 곳이 아니다 (지우지 못한다)
struct AgentReactionBadge: View {
    let emoji: String

    var body: some View {
        Text(emoji)
            .font(.footnote)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(DS.Chat.card, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.Chat.hairline, lineWidth: 1))
            // 내가 붙인 반응과 같은 줄에 같은 높이로 선다
            .frame(minHeight: 34)
            .accessibilityLabel("받은 반응 \(emoji)")
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

/// 답장한 말풍선의 윗부분: 무엇에 답했는지와 그 말의 첫 줄. 누르면 원래 말로 간다
struct QuoteInset: View {
    let quote: AskSession.Quote
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(quote.label)에 답장")
                    .font(.caption.weight(.semibold))
                Text(quote.text)
                    .font(.footnote)
                    .lineLimit(1)
                    .opacity(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(quote.label)에 답장: \(quote.text)")
        .accessibilityHint("원래 말로 이동합니다")
    }
}

/// 인용과 내가 쓴 말 사이의 선. 말풍선 안쪽 폭을 다 쓴다
struct QuoteDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.Chat.onUserBubble.opacity(0.3))
            .frame(height: 1)
            .layoutValue(key: QuoteStack.FillsWidth.self, value: true)
            .accessibilityHidden(true)
    }
}

/// 답장한 말풍선의 안쪽: 인용 · 선 · 내가 쓴 말을 세로로 쌓는다.
/// 폭은 글 가운데 넓은 쪽에 맞추고 선은 그 폭을 다 쓴다 (VStack에 폭을 다 쓰는 선을 넣으면 짧은 답장도 말풍선이 끝까지 넓어진다)
struct QuoteStack: Layout {
    /// 폭을 정하는 데는 끼지 않고, 정해진 폭을 다 쓰는 것 (선)
    struct FillsWidth: LayoutValueKey {
        static let defaultValue = false
    }

    var spacing: CGFloat = 9

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = subviews
            .filter { !$0[FillsWidth.self] }
            .map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)).width }
            .max() ?? 0
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = ProposedViewSize(width: bounds.width, height: nil)
        var y = bounds.minY
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: size)
            y += subview.sizeThatFits(size).height + spacing
        }
    }
}

/// 입력창 위의 "답장 중" 줄: 무엇에 답하는지와 그 말의 첫 줄, 오른쪽에 그만두기
struct ReplyBar: View {
    let quote: AskSession.Quote
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(quote.label)에 답장")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.Chat.textPrimary)
                Text(quote.text)
                    .font(.footnote)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DS.Chat.textPrimary)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(DS.Chat.textSecondary.opacity(0.6), lineWidth: 1))
                    // 누르는 곳은 44pt
                    .frame(width: DS.minTouch, height: DS.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("답장 취소")
        }
        .accessibilityElement(children: .contain)
    }
}

/// 글 일부만 골라 복사하는 화면 (길게 눌러 "선택")
struct TextSelectSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .padding(.horizontal, 16)
                .navigationTitle("텍스트 선택")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("전체 복사") {
                            UIPasteboard.general.string = text
                            Haptic.success()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
