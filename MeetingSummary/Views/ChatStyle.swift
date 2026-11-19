import SwiftUI

// 대화 화면(질문 탭)의 모양 규칙 (D47).
// 색·간격은 `DS.Chat`, 여기에는 그것으로 만든 면(말풍선·카드)과 글 표시를 둔다.
// 작업 상세 시트도 같은 조각(결과, 보고)을 쓰는데, 시트에서는 `inChat`이 거짓이라 예전 모양 그대로다.

extension EnvironmentValues {
    /// 대화 화면 안에서 그리는지. 시트로 띄운 화면에는 전해지지 않는다
    @Entry var inChat = false
    /// 글 일부만 고르는 화면을 연다 (길게 눌러 "선택")
    @Entry var selectText: ((String) -> Void)?
    /// 맥에 맡긴 일에 답장한다 (D59). 대화 속 작업 한 줄 안에서만 전해진다:
    /// 그 안의 말풍선·결과 카드를 길게 누르면 "답장"이 나온다. 작업 상세 시트에는 전해지지 않는다
    @Entry var replyToTask: (() -> Void)?
    /// 상품 목록에서 고르기 (D72). 맥이 상품 목록을 알 때만 전해진다. 작업 상세 시트에는 전해지지 않는다
    @Entry var itemPicker: ItemPicker?
}

/// 상품 목록의 "고르기"가 하는 일
struct ItemPicker {
    /// 지금 고를 수 있는지 (답을 기다리거나 승인·질문에 답해야 하는 동안에는 못 고른다)
    let isEnabled: Bool
    /// 고른 상품과 그 목록이 붙은 작업의 번호
    let pick: (AgentItem, String) -> Void
}

extension View {
    /// 말풍선 면. 내용 크기만큼만 차지한다
    func chatBubble(_ fill: Color) -> some View {
        padding(.horizontal, DS.Chat.bubblePaddingH)
            .padding(.vertical, DS.Chat.bubblePaddingV)
            .background(fill, in: RoundedRectangle(cornerRadius: DS.Chat.bubbleRadius, style: .continuous))
    }

    /// 에이전트 카드 면: 말풍선보다 한 단계 가라앉은 면. 실제로 한 일(작업·승인·결과)과 목록 화면의 카드에 쓴다.
    /// 둘레 선은 두지 않는다 (D117: 카드마다 가는 선이 둘러져 있으면 만들어 낸 화면처럼 보인다는 사용자 피드백). 면의 색만으로 나눈다.
    /// `bordered`는 예전에 부르던 곳을 위해 남겨 둔 이름이다 (값과 상관없이 선이 없다)
    func chatCard(padding: CGFloat = 16, bordered: Bool = true) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Chat.card, in: RoundedRectangle(cornerRadius: DS.Chat.cardRadius, style: .continuous))
    }
}

/// 카드 안 구분선
struct ChatHairline: View {
    var body: some View {
        Rectangle().fill(DS.Chat.hairline).frame(height: 1)
    }
}

/// 답변 글. 굵게(**…**)·코드(`…`)·링크([…](…))가 들어 있으면 그 모양으로 보여 준다.
/// 그런 표시가 없는 글은 그대로 둔다 (곱셈 기호 같은 별표 하나를 강조로 읽어 글자가 빠지는 일을 막는다)
struct ChatText: View {
    let text: String

    var body: some View {
        Text(Self.attributed(text))
    }

    static func attributed(_ text: String) -> AttributedString {
        guard hasMarkup(text),
              var parsed = try? AttributedString(
                  markdown: text,
                  options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
              )
        else { return AttributedString(text) }
        for run in parsed.runs where run.link != nil {
            parsed[run.range].underlineStyle = .single
        }
        return parsed
    }

    static func hasMarkup(_ text: String) -> Bool {
        text.contains("**") || text.contains("`") || text.contains("](")
    }
}

/// 맥이 쓴 답 글 (D82). 맥은 답을 "결론 한 문장 + 줄바꿈 뒤 '- '로 시작하는 짧은 줄들"로 보낸다.
/// 그 짧은 줄들을 목록 꼴로 그린다: 점은 왼쪽에, 글은 접혀도 점 아래로 들어가지 않게.
/// 글자는 맥이 쓴 그대로다 (줄 앞의 표시만 점으로 바꿔 그린다). 그런 줄이 없는 글은 그대로 보여 준다.
/// 맥이 `**…**`로 감싼 낱말은 굵게 그린다 (D84. 링크·코드 같은 다른 표시는 읽지 않는다: 사이트에서 읽은 글이 섞일 수 있다)
struct AnswerText: View {
    enum Line: Equatable {
        case text(String)
        case bullet(String)
        /// 소제목 (D119): "## 잘 들어간 부분"처럼 #으로 시작하는 줄. 굵게 한 줄로 그린다
        case heading(String)
    }

    let text: String

    var body: some View {
        if let lines = Self.lines(text) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    switch line {
                    case .text(let text):
                        Text(Self.emphasized(text))
                            .fixedSize(horizontal: false, vertical: true)
                    case .heading(let text):
                        Text(Self.emphasized(text))
                            .font(.body.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                            .accessibilityAddTraits(.isHeader)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                                .foregroundStyle(DS.Chat.textSecondary)
                                .accessibilityHidden(true)
                            Text(Self.emphasized(text))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } else {
            Text(Self.emphasized(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `**…**`로 감싼 곳만 굵게 한 글. 표시는 그리지 않는다.
    /// 짝이 맞지 않거나, 감싼 곳이 비었거나 빈칸으로 시작·끝나거나 줄을 넘으면 손대지 않고 글 그대로 둔다
    /// ("2 ** 3" 같은 글에서 글자가 빠지지 않게). 굵게 말고는 아무것도 바꾸지 않는다 (링크를 만들지 않는다)
    nonisolated static func emphasized(_ text: String) -> AttributedString {
        let parts = text.components(separatedBy: "**")
        guard parts.count >= 3, parts.count % 2 == 1 else { return AttributedString(text) }
        let strong = stride(from: 1, to: parts.count, by: 2).map { parts[$0] }
        let isClean = strong.allSatisfy { part in
            guard let first = part.first, let last = part.last else { return false }
            return !first.isWhitespace && !last.isWhitespace && !part.contains(where: \.isNewline) && !part.contains("*")
        }
        guard isClean else { return AttributedString(text) }
        var result = AttributedString()
        for (index, part) in parts.enumerated() where !part.isEmpty {
            var piece = AttributedString(part)
            if index % 2 == 1 { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
        }
        return result
    }

    /// 말풍선으로 나눌 덩어리 (D84): 빈 줄로 갈린 문단마다 하나. 문단이 하나면 그 글 하나다.
    /// 목록 줄만 있는 문단은 바로 앞 문단에 붙인다 (목록만 든 말풍선을 만들지 않는다).
    /// 너무 잘게 나뉘지 않게 `limit`개까지만 나누고, 남은 문단은 마지막 덩어리에 붙인다. 글자는 바꾸지 않는다
    nonisolated static func bubbles(_ text: String, limit: Int = 5) -> [String] {
        var paragraphs: [[String]] = []
        var current: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        var result: [String] = []
        for lines in paragraphs {
            let joined = lines.joined(separator: "\n")
            let onlyBullets = lines.allSatisfy { bullet($0) != nil }
            if let last = result.last, onlyBullets {
                result[result.count - 1] = last + "\n" + joined
            } else if let last = result.last, result.count >= limit {
                result[result.count - 1] = last + "\n\n" + joined
            } else {
                result.append(joined)
            }
        }
        return result.isEmpty ? [text] : result
    }

    /// 목록 줄이 하나라도 있으면 줄 단위로 나눈 것, 없으면 nil (글 그대로 그린다).
    /// 목록 줄: 줄 맨 앞이 "- " · "• " · "· " (표시 뒤에 빈칸이 있어야 한다. "-3도"는 목록이 아니다).
    /// 이어지는 보통 줄은 한 덩어리로 묶고, 빈 줄은 덩어리를 가르기만 한다
    static func lines(_ text: String) -> [Line]? {
        var result: [Line] = []
        var paragraph: [String] = []
        var hasBullet = false
        var hasHeading = false
        func flush() {
            if !paragraph.isEmpty { result.append(.text(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if let title = heading(line) {
                flush()
                result.append(.heading(title))
                hasHeading = true
            } else if let item = bullet(line) {
                flush()
                result.append(.bullet(item))
                hasBullet = true
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return hasBullet || hasHeading ? result : nil
    }

    /// "# 제목"·"## 제목"·"### 제목" (#은 셋까지, 뒤에 빈칸). 감싼 굵게(**…**)는 벗긴다
    nonisolated static func heading(_ line: String) -> String? {
        let marks = line.prefix { $0 == "#" }.count
        guard (1...3).contains(marks), line.dropFirst(marks).first == " " else { return nil }
        var title = line.dropFirst(marks).trimmingCharacters(in: .whitespaces)
        if title.hasPrefix("**"), title.hasSuffix("**"), title.count > 4 { title = String(title.dropFirst(2).dropLast(2)) }
        return title.isEmpty ? nil : title
    }

    private nonisolated static func bullet(_ line: String) -> String? {
        for mark in ["- ", "• ", "· "] where line.hasPrefix(mark) {
            let item = line.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }
        return nil
    }
}

/// 대화 맨 위의 "이전 대화 보기" (D69). 긴 대화는 최근 것만 그려 두고, 누르면 그 앞의 말을 더 그린다
struct EarlierMessagesButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("이전 대화 보기", systemImage: "chevron.up")
                .font(.footnote.weight(.medium))
                .foregroundStyle(DS.Chat.textSecondary)
                .padding(.horizontal, 14)
                .frame(minHeight: DS.minTouch)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityHint("앞의 말 \(count)개 가운데 일부를 더 보여 줍니다")
    }
}

/// 입력창과 탭 막대 뒤의 엷은 막 (D88. D83의 "막는다"를 되돌렸다). 대화는 입력창과 탭 막대 뒤로 흐리게 비치며 지나간다.
/// 막지 않고 바탕색을 아래로 갈수록 조금씩 더 입혀, 비친 글이 입력창 글자·탭 그림보다 옅게 보이게만 한다.
/// 어디에도 끊기는 자리(선)가 없다: 위에서는 투명하게 시작해 화면 아래 끝까지 한 번에 이어진다
struct ChatBarBackdrop: View {
    /// 입력창 위로 올라와 투명하게 시작하는 길이
    static let fade: CGFloat = 44
    /// 가장 짙은 곳(화면 아래 끝)에서 바탕색을 입히는 정도. 1이면 막는 것이다
    static let depth: Double = 0.78

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: DS.Chat.background.opacity(0), location: 0),
                .init(color: DS.Chat.background.opacity(Self.depth * 0.6), location: 0.3),
                .init(color: DS.Chat.background.opacity(Self.depth), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .padding(.top, -Self.fade)
        // 탭 막대·홈 표시 줄(키보드가 올라오면 키보드) 뒤까지
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 대화 화면의 바탕. 키보드 뒤까지 깐다: iOS 26의 키보드는 위쪽 모서리가 둥글어서,
/// 바탕이 키보드 위에서 끝나면 그 모서리 뒤로 창의 검은 바탕이 비친다
struct ChatBackdrop: View {
    var body: some View {
        DS.Chat.background.ignoresSafeArea()
    }
}

/// 새 말이 나타날 때: 살짝 올라오며 나타난다. "동작 줄이기"에서는 투명도만 바뀐다
struct ChatAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
    }
}

extension View {
    func chatAppear() -> some View { modifier(ChatAppear()) }
}
