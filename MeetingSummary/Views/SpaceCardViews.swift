import SwiftData
import SwiftUI
import UIKit

// 내 공간의 카드 (D98: 앱 아이콘의 흰색·민트·어두운 바탕 대비와, 대각선 두 곳만 크게 둥근 모서리를 카드에 가져왔다).
// 급한 것 하나만 밝은 면으로 띄우고(챙길 메일), 날씨는 민트 타일로, 나머지는 조용한 면으로 둔다.

/// 내 공간의 색 (D98). 포인트는 앱 아이콘의 색 하나다 — 시스템 파랑을 쓰지 않는다.
/// D144부터 그 색은 사용자가 고른 강조색이다 (기본 민트). 이름 `mint`는 "아이콘의 포인트 색"이라는 뜻으로 남겼다
enum SpaceBrand {
    /// 면에 칠하는 포인트 색 (아이콘의 색 그대로, 밝은·어두운 모드 같음)
    static var mint: Color { AppTheme.shared.accent.bright }
    /// 포인트 면 위의 글
    static let onMint = Color(red: 0.055, green: 0.067, blue: 0.086)
    /// 글·아이콘에 쓰는 포인트 색. 밝은 바탕에서는 읽히게 한 단계 짙다
    static var accent: Color { AppTheme.shared.accent.text }
    /// 가장 급한 카드의 면: 바탕과 반대로 (어두운 모드에서는 흰색, 밝은 모드에서는 먹색)
    static let hero = Color(light: 0x14171C, dark: UIColor(hex: 0xFFFFFF))
    static let onHero = Color(light: 0xFFFFFF, dark: UIColor(hex: 0x0E1116))
    /// "확인 필요" 표시 (면과 글)
    static let alertFill = Color(red: 1.0, green: 0.906, blue: 0.741)
    static let alertText = Color(red: 0.62, green: 0.36, blue: 0.0)
    /// 날씨 카드의 면: 아이폰 날씨 위젯의 흐린 하늘빛 (위에서 아래로. 밝은·어두운 모드 같음, D104)
    static let sky = LinearGradient(
        colors: [Color(red: 0.33, green: 0.38, blue: 0.50), Color(red: 0.22, green: 0.26, blue: 0.36)], startPoint: .top, endPoint: .bottom
    )
    /// 큰 모서리와 작은 모서리 (아이콘의 나뭇잎: 왼쪽 위와 오른쪽 아래만 크게)
    static let bigCorner: CGFloat = 34
    static let smallCorner: CGFloat = 12
    /// 보통 카드의 모서리
    static let corner: CGFloat = 22

    /// 보통 카드의 모양 (네 모서리가 같다)
    static var plain: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: corner, bottomLeadingRadius: corner, bottomTrailingRadius: corner, topTrailingRadius: corner, style: .continuous
        )
    }

    /// 나뭇잎 모양
    static var leaf: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: bigCorner, bottomLeadingRadius: smallCorner, bottomTrailingRadius: bigCorner, topTrailingRadius: smallCorner,
            style: .continuous
        )
    }
}

/// 카드가 놓인 면에 맞는 글의 색 (조용한 면 / 민트 타일 / 밝게 띄운 면)
struct SpaceInk: Equatable {
    var primary: Color
    var secondary: Color
    var accent: Color
    var hairline: Color
    var skeleton: Color

    /// 강조 글자가 고른 강조색을 따르도록 읽을 때마다 만든다 (D144)
    static var plain: SpaceInk { SpaceInk(
        primary: DS.Chat.textPrimary, secondary: DS.Chat.textSecondary, accent: SpaceBrand.accent, hairline: DS.Chat.hairline, skeleton: DS.Chat.elevated
    ) }
    static let mint = SpaceInk(
        primary: SpaceBrand.onMint, secondary: SpaceBrand.onMint.opacity(0.72), accent: SpaceBrand.onMint,
        hairline: SpaceBrand.onMint.opacity(0.18), skeleton: SpaceBrand.onMint.opacity(0.14)
    )
    /// 하늘빛 면 위 (날씨)
    static let sky = SpaceInk(
        primary: .white, secondary: .white.opacity(0.78), accent: .white, hairline: .white.opacity(0.2), skeleton: .white.opacity(0.16)
    )
    static let hero = SpaceInk(
        primary: SpaceBrand.onHero, secondary: SpaceBrand.onHero.opacity(0.66), accent: SpaceBrand.onHero,
        hairline: SpaceBrand.onHero.opacity(0.16), skeleton: SpaceBrand.onHero.opacity(0.12)
    )
}

private struct SpaceInkKey: EnvironmentKey {
    static let defaultValue = SpaceInk.plain
}

extension EnvironmentValues {
    var spaceInk: SpaceInk {
        get { self[SpaceInkKey.self] }
        set { self[SpaceInkKey.self] = newValue }
    }
}

/// 내 공간 카드의 글 단계: 이름 / 줄의 글 / 회색 보조 / 큰 값. 모든 카드가 같은 단계를 쓴다
enum SpaceType {
    static let title = Font.subheadline.bold()
    static let body = Font.subheadline.weight(.medium)
    static let note = Font.footnote
    static let caption = Font.caption
    /// 큰 값 (기온, 다음 일정의 시각, 숫자 하나): 가늘고 크게
    static let value = Font.system(size: 36, weight: .regular)
    static let hugeValue = Font.system(size: 48, weight: .regular)
    static let unit = Font.system(size: 17, weight: .regular)
    /// 띄운 카드의 제목, 타일의 큰 글
    static let headline = Font.title3.weight(.semibold)
    /// 나란히 놓인 타일의 키
    static let tileHeight: CGFloat = 132
}

/// 내 공간의 카드 하나. 종류마다 미리 만들어 둔 모양으로 그린다 — 맥이 준 것은 종류·크기·이름과, 맥이 채우는 카드의 내용뿐이다
struct SpaceCardView: View {
    let card: SpaceCard
    let model: SpaceModel
    let weather: any WeatherProviding
    let calendar: any DayEventsProviding
    var onOpenTasks: () -> Void = {}
    var onSay: (String) -> Void = { _ in }
    /// 한 줄에 둘이 나란히 놓인 타일인지 (나뭇잎 모서리, 같은 키, 이름은 위에 내용은 아래에)
    var fillsHeight = false
    /// 방금 말로 바꾼 카드 (편집 중에 테두리로 가린다)
    var highlighted = false
    /// "지금 가져오기"가 대화로 넘어갔을 때 그 대화로 간다 (D128)
    var onOpenRun: (RoutineRun) -> Void = { _ in }

    private var isRefreshing: Bool { model.refreshing.contains(card.id) }
    private var tile: Bool { fillsHeight }

    /// 어느 면에 놓는지: 날씨는 민트 타일, 챙길 메일이 있는 메일 카드는 밝게 띄운다
    private var surface: (fill: AnyShapeStyle, ink: SpaceInk) {
        // 날씨는 아이폰의 날씨 위젯처럼 하늘빛 면에 흰 글 (D104)
        if card.kind == .weather { return (AnyShapeStyle(SpaceBrand.sky), .sky) }
        if card.kind == .mailToday, !card.mailPicks.isEmpty, card.size != .small, card.state != .unavailable {
            return (AnyShapeStyle(SpaceBrand.hero), .hero)
        }
        return (AnyShapeStyle(DS.Chat.card), .plain)
    }

    /// 한 줄로 접히는 카드인지 (보일 것이 없다): 모서리를 덜 둥글게, 여백을 낮게
    private var leafShaped: Bool { tile || surface.ink == .hero }

    var body: some View {
        let surface = surface
        let shape = leafShaped ? SpaceBrand.leaf : SpaceBrand.plain
        VStack(alignment: .leading, spacing: 12) {
            switch card.kind {
            case .meetingTodos: SpaceTodosBody(card: card, tile: tile, onOpenTasks: onOpenTasks)
            case .weather: SpaceWeatherBody(card: card, tile: tile, weather: weather)
            case .calendarToday: SpaceCalendarBody(card: card, tile: tile, calendar: calendar)
            case .mailToday, .routineResult, .custom: filled
            }
            // 돌린 예약이 카드를 채우지 못하고 대화로 넘어갔다 (D128): 까닭 한 줄과 그 대화로 가는 단추
            if let stop = model.runStops[card.id] {
                SpaceRunStopRow(text: SpaceModel.stopText(stop), canOpen: stop.canOpen || stop.conversationID != nil) {
                    onOpenRun(stop)
                    model.clearRunStop(card.id)
                }
            }
            // 타일: 이름 바로 아래부터 내용을 놓는다 (이름과 내용 사이가 벌어지지 않게). 남는 자리는 아래에 둔다
            if tile { Spacer(minLength: 0) }
        }
        .environment(\.spaceInk, surface.ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: tile ? SpaceType.tileHeight : nil, maxHeight: tile ? .infinity : nil, alignment: .topLeading)
        .background(surface.fill, in: shape)
        // 둘레 선은 고르고 있을 때(편집)만 (D117)
        .overlay(shape.strokeBorder(highlighted ? SpaceBrand.accent : .clear, lineWidth: 2))
    }

    /// 머리 오른쪽: 오래된 내용이면 "40분 전"(누르면 새로 받는다)을 보인다.
    /// 새로 받는 동안에는 아무 말도 붙이지 않는다 — 앞서 받은 내용을 그대로 보이다 조용히 바꾼다 (D101)
    private func header(trailing: String? = nil) -> SpaceCardHeader {
        if card.state == .stale, !isRefreshing, let at = card.dataAt {
            let id = card.id
            return SpaceCardHeader(card: card, tile: tile, trailing: SpaceTime.ago(at), onRefresh: { Task { await model.refresh(card: id) } })
        }
        return SpaceCardHeader(card: card, tile: tile, trailing: trailing)
    }

    private var isRunning: Bool { model.running.contains(card.id) }

    /// 카드에서 바로 하는 일 (D103): 대화로 보내거나, 그 예약을 지금 돌린다
    private func perform(_ quick: SpaceCard.Quick) {
        switch quick.kind {
        case .say(let text): onSay(text)
        case .run(let routine):
            let id = card.id
            Task { await model.runNow(card: id, routine: routine) }
        }
    }

    /// 카드 아래의 단추 줄 (2개까지). 타일에는 자리가 없어 그리지 않는다
    @ViewBuilder
    private var quickRow: some View {
        if !tile, !card.quicks.isEmpty {
            SpaceQuickRow(quicks: card.quicks, isRunning: isRunning, perform: perform)
        }
    }

    /// 맥이 채우는 카드
    @ViewBuilder
    private var filled: some View {
        let hasContent = !card.blocks.isEmpty || !card.mails.isEmpty || card.mailCount != nil || card.mailHeadline != nil
        if card.state == .unavailable {
            // 채울 수 없는 카드: 긴 설명 없이 한 줄로 (D98)
            // 맥이 할 일을 주었으면 단추 하나 (D99): 누르면 그 말을 대화로 보낸다 — 비서가 그 말로 예약을 만든다
            if let action = card.action {
                SpaceQuietCard(card: card, note: SpaceQuiet.short(card.why) ?? "연동 필요", tile: tile, button: action.label) { onSay(action.say) }
            } else if let quick = card.quicks.first {
                // 카드에서 바로 하는 일이 있으면 그 첫째를 단추로 (D103. 한 줄 카드라 하나만)
                SpaceQuietCard(
                    card: card, note: isRunning ? "가져오는 중이에요" : SpaceQuiet.short(card.why) ?? "연동 필요", tile: tile,
                    button: isRunning ? nil : quick.label
                ) { perform(quick) }
            } else {
                SpaceQuietCard(card: card, note: SpaceQuiet.short(card.why) ?? "연동 필요", tile: tile)
            }
        } else if hasContent {
            if card.kind == .mailToday {
                if card.mailPicks.isEmpty || card.size == .small {
                    // 작은 카드·타일에서는 머리에 이름만 (챙길 것은 아래에 한 번만 쓴다. 이름이 잘리지 않게)
                    header(trailing: tile || card.size == .small ? nil : card.mailHeadline ?? card.mailSummary)
                    SpaceMailBody(card: card, tile: tile)
                } else {
                    SpaceMailHero(card: card, isRefreshing: isRefreshing, onSay: onSay)
                    quickRow
                }
            } else {
                // 넓은 카드의 머리 오른쪽: 새 줄이 있으면 "새 2건", 큰 값이 있으면 언제의 값인지. 타일에는 이름만 (자리가 좁다)
                header(trailing: tile ? nil : card.newCount > 0 ? "새 \(card.newCount)건" : card.dataAt.flatMap { at in
                    card.blocks.contains(where: \.isStat) ? "\(SpaceTime.clock(at)) 기준" : nil
                })
                // 타일에는 첫 덩어리 하나만 (큰 값 아래에 긴 글을 늘어놓지 않는다)
                ForEach(Array(card.blocks.prefix(tile ? 1 : SpaceBlock.limit).enumerated()), id: \.offset) { index, block in
                    SpaceBlockView(block: block, card: card, tile: tile, first: index == 0)
                }
                // 값이 쌓인 흐름 (D103): 작은 추세선
                if card.trend.count >= 2 {
                    SpaceTrendLine(points: card.trend)
                        .frame(height: tile ? 24 : 34)
                }
                quickRow
            }
        } else if isRefreshing {
            // 채우는 중: 글 없이 내용이 놓일 자리를 흐린 막대로만
            SpaceCardHeader(card: card, tile: tile)
            SpaceSkeleton()
        } else {
            SpaceQuietCard(
                card: card, note: model.refreshFailed.contains(card.id) ? "가져오지 못했어요" : "아직 내용이 없어요", tile: tile,
                button: "다시 가져오기"
            ) { Task { await model.refresh(card: card.id) } }
        }
    }
}

/// 카드 아래 한 줄 (D128): "로그인이 필요해 대화에서 멈췄어요 · 대화에서 보기"
struct SpaceRunStopRow: View {
    let text: String
    let canOpen: Bool
    let open: () -> Void
    @Environment(\.spaceInk) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "exclamationmark.bubble")
                .font(SpaceType.note.weight(.medium))
                .foregroundStyle(ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            if canOpen {
                Button(action: open) {
                    Label("대화에서 보기", systemImage: "arrow.up.right")
                        .font(SpaceType.caption.weight(.semibold))
                        .foregroundStyle(SpaceBrand.onMint)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(SpaceBrand.mint, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("이 카드의 예약이 이어진 대화를 엽니다")
            }
        }
        .padding(.top, 2)
    }
}

extension SpaceBlock {
    var isStat: Bool {
        if case .stat = self { return true }
        return false
    }
}

extension SpaceCard {
    /// 카드 머리의 아이콘. 말로 만든 카드는 내용의 꼴에 맞춘다 (모든 카드에 같은 반짝이를 붙이지 않는다, D98)
    var symbol: String {
        guard kind == .custom else { return kind.symbol }
        switch blocks.first {
        case .stat?: return "number"
        case .list?: return "list.bullet"
        case .progress?: return "chart.bar"
        case .pairs?: return "square.split.2x1"
        case .date?: return "calendar.badge.clock"
        case .text?: return "text.alignleft"
        case nil: return "square.dashed"
        }
    }
}

/// 보일 것이 없는 카드에 쓰는 짧은 말
enum SpaceQuiet {
    /// 맥이 준 까닭을 한 구절로: 첫 문장만, 길면 자른다. 긴 설명을 카드에 늘어놓지 않는다 (D98)
    static func short(_ why: String?, limit: Int = 24) -> String? {
        guard let why = why?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty else { return nil }
        var first = why
        if let end = why.firstIndex(where: { ".!?\n".contains($0) }) { first = String(why[..<end]) }
        first = first.trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty else { return nil }
        return first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
    }
}

/// 카드의 머리. 넓은 카드: 민트 선 아이콘과 이름, 오른쪽의 작은 글. 타일: 회색 이름만 (아이콘 없이)
struct SpaceCardHeader: View {
    let card: SpaceCard
    var tile = false
    var title: String?
    var symbol: String?
    var trailing: String?
    /// 있으면 오른쪽 글이 새로 받는 단추가 된다 (오래된 내용의 "40분 전")
    var onRefresh: (() -> Void)?
    @Environment(\.spaceInk) private var ink

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !tile {
                Image(systemName: symbol ?? card.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ink.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            Text(title ?? card.title)
                .font(tile ? SpaceType.note.weight(.medium) : SpaceType.title)
                .foregroundStyle(tile ? ink.secondary : ink.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if let trailing {
                if let onRefresh {
                    Button(action: onRefresh) {
                        Label(trailing, systemImage: "arrow.clockwise")
                            .font(SpaceType.caption)
                            .foregroundStyle(ink.primary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 28)
                            .overlay(Capsule().strokeBorder(ink.hairline))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(trailing) 내용, 새로 받기")
                } else {
                    Text(trailing)
                        .font(SpaceType.caption)
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
        }
    }
}

/// 보일 것이 없는 카드 (남은 일 없음, 채울 수 없음, 권한 필요): 슬림한 한 줄로 접는다 —
/// 왼쪽에 아이콘 칸과 이름·한 구절, 오른쪽에 (있으면) 단추 하나. 타일이면 이름은 위에, 그 말은 아래에 크게
struct SpaceQuietCard: View {
    let card: SpaceCard
    let note: String
    var tile = false
    /// 타일에서 큰 글 아래의 한 줄
    var detail: String?
    var button: String?
    var action: (() -> Void)?
    @Environment(\.spaceInk) private var ink

    var body: some View {
        if tile {
            SpaceCardHeader(card: card, tile: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(note)
                    .font(note.count <= 9 ? SpaceType.headline : SpaceType.note)
                    .foregroundStyle(note.count <= 9 ? ink.primary : ink.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(SpaceType.note)
                        .foregroundStyle(ink.secondary)
                        .lineLimit(2)
                }
                if let button, let action {
                    Button(action: action) {
                        Text(button)
                            .font(SpaceType.note.weight(.semibold))
                            .foregroundStyle(ink.accent)
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: card.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ink.accent)
                    .frame(width: 36, height: 36)
                    .background(ink.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(SpaceType.title)
                        .foregroundStyle(ink.primary)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text(note)
                        .font(SpaceType.note)
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let button, let action {
                    Button(action: action) {
                        Text(button)
                            .font(SpaceType.note.weight(.semibold))
                            .foregroundStyle(SpaceBrand.onMint)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(SpaceBrand.mint, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// 내용이 놓일 자리 (채우는 중): 큰 값 자리 하나와 글 자리 하나
struct SpaceSkeleton: View {
    @Environment(\.spaceInk) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ink.skeleton)
                .frame(width: 96, height: 28)
            Capsule()
                .fill(ink.skeleton.opacity(0.7))
                .frame(height: 10)
                .frame(maxWidth: 200)
        }
        .accessibilityLabel("가져오는 중")
    }
}

/// 큰 값과 작은 단위 ("1,336.0" + "원", "8" + "통")
struct SpaceValueText: View {
    let value: String
    /// 타일에서는 더 크게 (옆의 날씨 타일의 기온과 같은 크기)
    var large = false
    @Environment(\.spaceInk) private var ink

    var body: some View {
        let parts = SpaceTime.split(value)
        (Text(parts.number).font(large ? SpaceType.hugeValue : SpaceType.value) + Text(parts.unit.isEmpty ? "" : " \(parts.unit)").font(SpaceType.unit))
            .foregroundStyle(ink.primary)
            .monospacedDigit()
            // 긴 값("20만 5,500원")도 잘리지 않게 넉넉히 줄인다 (D106. 반 칸 타일에서 "20만 5,5…"로 잘렸다)
            .minimumScaleFactor(0.35)
            .lineLimit(1)
    }
}

/// 가장 급한 카드 (D98): 챙길 메일이 있는 메일 카드를 밝은 면으로 띄운다.
/// "확인 필요"와 어느 메일인지 → 제목 크게 → 할 일 → 가는 선 → 나머지 한 줄
struct SpaceMailHero: View {
    let card: SpaceCard
    var isRefreshing = false
    /// 챙길 메일을 눌렀을 때 대화로 보내는 말 (맥이 준 것, D103)
    var onSay: (String) -> Void = { _ in }
    @Environment(\.spaceInk) private var ink

    var body: some View {
        let picks = Array(card.mailPicks.prefix(card.size == .large ? SpaceCard.pickLimit : 1))
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(picks.enumerated()), id: \.offset) { index, pick in
                // 누르면 그 메일에 대해 묻는 말이 대화로 간다 (말이 있을 때만 눌린다)
                Button {
                    if let say = pick.say { onSay(say) }
                } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("확인 필요")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SpaceBrand.alertText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(SpaceBrand.alertFill, in: Capsule())
                            .fixedSize()
                        Spacer(minLength: 4)
                        Text([pick.service, index == 0 ? card.dataAt.map { SpaceTime.ago($0) } : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(SpaceType.caption)
                            .foregroundStyle(ink.secondary)
                            .lineLimit(1)
                    }
                    Text(pick.title)
                        .font(SpaceType.headline)
                        .foregroundStyle(ink.primary)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if let note = pick.note {
                        Text(note)
                            .font(SpaceType.body.weight(.regular))
                            .foregroundStyle(ink.secondary)
                            .lineSpacing(3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(pick.say == nil)
                .accessibilityElement(children: .combine)
            }
            Rectangle()
                .fill(ink.hairline)
                .frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Self.restLine(card, shown: picks.count))
                    .font(SpaceType.note)
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(card.title)
                    .font(SpaceType.caption.weight(.medium))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "외 7통 · 배포 안내 6통, 영수증 1통" — 맥이 묶어 준 한 줄이 없으면 수만.
    /// 괄호로 감싸지 않는다: 줄이 잘릴 때 괄호가 열린 채 끝나거나 괄호 안에 괄호가 들어가지 않게 (D101)
    static func restLine(_ card: SpaceCard, shown: Int) -> String {
        let others = card.mailCount.map { max(0, $0 - shown) }
        let rest = plain(card.mailRest)
        switch (others, rest) {
        case let (count?, rest?) where count > 0: return "외 \(count)통 · \(rest)"
        case let (count?, nil) where count > 0: return "외 \(count)통"
        case let (_, rest?): return rest
        default: return card.mailServices.joined(separator: "·")
        }
    }

    /// 한 줄에 쓸 글에서 괄호 안의 덧말을 뗀다 ("배포 안내 8통 (54~61)" → "배포 안내 8통"). 닫히지 않은 괄호는 그 뒤를 모두 뗀다
    static func plain(_ text: String?) -> String? {
        guard var text else { return nil }
        while let open = text.firstIndex(where: { "([（".contains($0) }) {
            if let close = text[open...].firstIndex(where: { ")]）".contains($0) }) {
                text.removeSubrange(open...close)
            } else {
                text.removeSubrange(open...)
            }
        }
        // 괄호를 뗀 자리에 남은 빈칸을 정리한다 ("8통 , 영수증" → "8통, 영수증")
        text = text.replacingOccurrences(of: "  ", with: " ").replacingOccurrences(of: " ,", with: ",")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,·"))
        return text.isEmpty ? nil : text
    }
}

/// 오늘 온 메일 (챙길 것이 없을 때와 작은 카드): 목록이나 수, 그 아래 나머지 한 줄
struct SpaceMailBody: View {
    let card: SpaceCard
    var tile = false
    @Environment(\.spaceInk) private var ink

    /// 맥이 챙길 메일을 골라 주는지 (예전 맥은 목록과 글만 준다)
    private var picksOffered: Bool { card.mailHeadline != nil }

    var body: some View {
        if card.size == .small {
            VStack(alignment: .leading, spacing: 2) {
                if let count = card.mailCount {
                    SpaceValueText(value: "\(count)통", large: tile)
                }
                if let line = card.mailHeadline ?? (card.mailServices.isEmpty ? nil : card.mailServices.joined(separator: "·")) {
                    Text(line)
                        .font(SpaceType.note.weight(card.mailPicks.isEmpty ? .regular : .semibold))
                        .foregroundStyle(card.mailPicks.isEmpty ? ink.secondary : ink.accent)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
        } else if card.mails.isEmpty {
            // 목록이 없다: 나머지 한 줄이나 맥이 쓴 글이 있으면 그것을, 없으면 없다고
            if picksOffered {
                rest(divided: false)
            } else if card.blocks.isEmpty {
                Text("오늘 온 메일이 없어요")
                    .font(SpaceType.note)
                    .foregroundStyle(ink.secondary)
            } else {
                blocks
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(card.mails.prefix(card.size == .large ? 5 : 3).enumerated()), id: \.offset) { _, mail in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(mail.service ?? mail.time ?? "")
                            .font(SpaceType.caption)
                            .foregroundStyle(ink.secondary)
                            .frame(width: 44, alignment: .leading)
                            .lineLimit(1)
                        Text(mail.subject)
                            .font(SpaceType.body)
                            .foregroundStyle(ink.primary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            // 챙길 메일을 골라 주는 맥이면 나머지 한 줄만, 예전 맥이면 맥이 준 글을 그린다
            if picksOffered { rest(divided: true) } else { blocks }
        }
    }

    /// 나머지를 묶은 한 줄 (왼쪽)과 어느 메일인지·몇 통인지 (오른쪽)
    @ViewBuilder
    private func rest(divided: Bool) -> some View {
        let summary = card.mailSummary
        if card.mailRest != nil || summary != nil {
            VStack(alignment: .leading, spacing: 10) {
                if divided {
                    Rectangle()
                        .fill(ink.hairline)
                        .frame(height: 1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(card.mailRest ?? "")
                        .font(SpaceType.note)
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let summary {
                        Text(summary)
                            .font(SpaceType.caption)
                            .foregroundStyle(ink.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var blocks: some View {
        ForEach(Array(card.blocks.enumerated()), id: \.offset) { _, block in
            SpaceBlockView(block: block, card: card)
        }
    }
}

/// 맥이 준 덩어리 하나
struct SpaceBlockView: View {
    let block: SpaceBlock
    let card: SpaceCard
    var tile = false
    /// 카드의 첫 덩어리인지 (지난번과의 차이는 첫 큰 값에만 붙인다)
    var first = false
    /// 대화의 답변 카드 (D133): 읽으라고 준 답이라 자르지 않는다. 내 공간 카드는 칸에 맞춰 자른다
    var full = false
    @Environment(\.spaceInk) private var ink

    /// 글 덩어리의 줄 수. nil이면 다 보인다
    nonisolated static func textLines(size: SpaceCard.Size, full: Bool) -> Int? {
        if full { return nil }
        return size == .large ? 6 : (size == .small ? 2 : 3)
    }

    /// 이름·값 짝을 한 줄에 몇 개 둘지. 좁은 자리(반 칸 타일, 대화 카드)에서 셋 넘으면 둘씩
    nonisolated static func pairColumns(count: Int, tile: Bool, full: Bool) -> Int {
        max(1, (tile || full) && count > 2 ? 2 : count)
    }

    var body: some View {
        switch block {
        case .text(let text):
            Text(text)
                .font(SpaceType.note)
                .foregroundStyle(ink.secondary)
                .lineSpacing(3)
                .lineLimit(Self.textLines(size: card.size, full: full))
                .fixedSize(horizontal: false, vertical: true)
        case .stat(let label, let value, let note):
            VStack(alignment: .leading, spacing: 4) {
                // 카드 이름과 같은 말이면 한 번만 보인다
                if let label, label != card.title, !tile {
                    Text(label)
                        .font(SpaceType.caption)
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                }
                // 넓은 카드: 값 오른쪽에 덧붙인 말. 들어가지 않으면(또는 반 칸 카드면) 값 아래에
                ViewThatFits(in: .horizontal) {
                    if card.size != .small {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            SpaceValueText(value: value).fixedSize()
                            if first { deltaBadge }
                            Spacer(minLength: 0)
                            if let note {
                                Text(note)
                                    .font(SpaceType.note.weight(.medium))
                                    .foregroundStyle(ink.accent)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        SpaceValueText(value: value, large: tile)
                        if first { deltaBadge }
                        if let note {
                            Text(note)
                                .font(SpaceType.note.weight(.medium))
                                .foregroundStyle(ink.accent)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
        case .list(let items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.prefix(card.lineLimit).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // 지난번에 없던 줄: 앞에 민트 점 (D103)
                        if item.isNew {
                            Circle()
                                .fill(ink.accent)
                                .frame(width: 7, height: 7)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                                .accessibilityLabel("새로 생김")
                        } else if items.contains(where: \.isNew) {
                            // 새 줄이 섞여 있으면 나머지 줄도 점의 자리만큼 들여 쓴다 (글의 왼쪽이 가지런하게)
                            Color.clear.frame(width: 7, height: 7)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(SpaceType.body.weight(item.isNew ? .semibold : .medium))
                                .foregroundStyle(ink.primary)
                                .lineLimit(full ? 2 : 1)
                            if let subtitle = item.subtitle {
                                Text(subtitle)
                                    .font(SpaceType.caption)
                                    .foregroundStyle(ink.secondary)
                                    .lineLimit(full ? 3 : 1)
                                    .fixedSize(horizontal: false, vertical: full)
                            }
                        }
                        Spacer(minLength: 4)
                        if let trailing = item.trailing {
                            Text(trailing)
                                .font(SpaceType.caption.weight(.medium))
                                .foregroundStyle(ink.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        case .progress(let label, let ratio):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: ratio)
                    .tint(ink.accent)
                HStack {
                    if let label {
                        Text(label)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Text("\(Int((ratio * 100).rounded()))%")
                        .monospacedDigit()
                }
                .font(SpaceType.caption)
                .foregroundStyle(ink.secondary)
            }
            .accessibilityElement(children: .combine)
        case .pairs(let pairs):
            // 이름·값 짝 (D108): 작은 회색 이름 아래에 값을 크게, 한 줄에 나란히. 반 칸 타일에서 넷이면 둘씩 두 줄
            let columns = Self.pairColumns(count: pairs.count, tile: tile, full: full)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .leading), count: columns), alignment: .leading, spacing: 10) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.label)
                            .font(SpaceType.caption)
                            .foregroundStyle(ink.secondary)
                            .lineLimit(1)
                        Text(pair.value)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(ink.primary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        case .date(let label, let day, let note):
            // 다가오는 날 (D108): 남은 날을 크게("D-39", 오늘이면 "오늘"), 그 옆에 이름과 날짜
            let left = SpaceDay.left(until: day)
            // 반 칸 타일에서는 위아래로 (옆에 두면 날짜가 잘린다)
            let layout = tile || card.size == .small ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
            layout {
                Text(SpaceDay.badge(left))
                    .font(SpaceType.value)
                    .foregroundStyle(ink.accent)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(SpaceType.body)
                        .foregroundStyle(ink.primary)
                        .lineLimit(1)
                    Text([SpaceDay.text(day), note].compactMap { $0 }.joined(separator: " · "))
                        .font(SpaceType.caption)
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// 다가오는 날의 셈 (D108)
enum SpaceDay {
    /// 오늘부터 그날까지 며칠 남았는지 (이 기기의 달력으로). 날짜가 어긋나면 nil
    nonisolated static func left(until day: DateComponents, now: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let date = calendar.date(from: day) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day
    }

    /// "D-39" · "오늘" · "D+1" (지난 날은 맥이 보내지 않지만, 하루가 넘어가 지났을 수 있다)
    nonisolated static func badge(_ left: Int?) -> String {
        guard let left else { return "D-?" }
        if left == 0 { return "오늘" }
        return left > 0 ? "D-\(left)" : "D+\(-left)"
    }

    /// "12월 25일"
    nonisolated static func text(_ day: DateComponents) -> String {
        "\(day.month ?? 0)월 \(day.day ?? 0)일"
    }
}

extension SpaceBlockView {
    /// 지난번과의 차이 ("+4.5"): 오르내림의 화살표와 맥이 쓴 글
    @ViewBuilder
    var deltaBadge: some View {
        if let delta = card.delta {
            HStack(spacing: 3) {
                Image(systemName: card.deltaUp ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.bold))
                Text(delta)
                    .font(SpaceType.caption.weight(.bold))
                    .monospacedDigit()
            }
            .foregroundStyle(ink.accent)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(ink.accent.opacity(0.14), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("지난번보다 \(delta)")
        }
    }
}

/// 값이 쌓인 흐름의 작은 선 (D103. 오래된 것부터). 마지막 값에 점을 찍는다
struct SpaceTrendLine: View {
    let points: [Double]
    @Environment(\.spaceInk) private var ink

    var body: some View {
        GeometryReader { proxy in
            let spots = Self.spots(points, in: proxy.size)
            ZStack {
                Path { path in
                    guard let first = spots.first else { return }
                    path.move(to: first)
                    for spot in spots.dropFirst() { path.addLine(to: spot) }
                }
                .stroke(ink.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = spots.last {
                    Circle()
                        .fill(ink.accent)
                        .frame(width: 7, height: 7)
                        .position(last)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Self.summary(points))
    }

    /// 값을 그릴 자리로 옮긴다: 가로는 고르게, 세로는 가장 작은 값이 아래·가장 큰 값이 위 (위아래 4씩 띄운다). 값이 모두 같으면 가운데 줄
    nonisolated static func spots(_ points: [Double], in size: CGSize) -> [CGPoint] {
        guard points.count >= 2, let low = points.min(), let high = points.max() else { return [] }
        let inset: CGFloat = 4
        let height = max(0, size.height - inset * 2)
        let width = max(0, size.width - inset * 2)
        return points.enumerated().map { index, value in
            let x = inset + width * CGFloat(index) / CGFloat(points.count - 1)
            let ratio = high > low ? (value - low) / (high - low) : 0.5
            return CGPoint(x: x, y: inset + height * (1 - CGFloat(ratio)))
        }
    }

    /// 화면 읽기용 한마디: "지난 7번의 흐름, 내림"
    nonisolated static func summary(_ points: [Double]) -> String {
        guard let first = points.first, let last = points.last else { return "흐름" }
        return "지난 \(points.count)번의 흐름, \(last > first ? "오름" : (last < first ? "내림" : "그대로"))"
    }
}

/// 카드 아래의 단추 줄 (D103): "자세히 묻기" · "지금 가져오기". 예약을 돌려 놓고 기다리는 동안에는 그 단추가 "가져오는 중…"으로 바뀐다
struct SpaceQuickRow: View {
    let quicks: [SpaceCard.Quick]
    var isRunning = false
    let perform: (SpaceCard.Quick) -> Void
    @Environment(\.spaceInk) private var ink

    var body: some View {
        HStack(spacing: 8) {
            ForEach(quicks) { quick in
                let waiting = isRunning && quick.runs
                Button { perform(quick) } label: {
                    HStack(spacing: 6) {
                        if waiting {
                            ProgressView().controlSize(.mini).tint(ink.secondary)
                        } else {
                            Image(systemName: quick.runs ? "arrow.clockwise" : "bubble.left")
                                .font(.caption.weight(.semibold))
                        }
                        Text(waiting ? "가져오는 중…" : quick.label)
                            .font(SpaceType.note.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(waiting ? ink.secondary : ink.primary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .overlay(Capsule().strokeBorder(ink.hairline, lineWidth: 1.2))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(waiting)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}

extension SpaceCard.Quick {
    /// 예약을 돌리는 단추인지
    var runs: Bool {
        if case .run = kind { return true }
        return false
    }
}

// MARK: - 앱이 채우는 카드

/// 회의에서 나온 할 일 (이 기기의 회의 기록에서). 아직 하지 않은 것만, 최근 회의부터
struct SpaceTodosBody: View {
    let card: SpaceCard
    var tile = false
    var onOpenTasks: () -> Void
    @Query private var items: [ActionItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.spaceInk) private var ink

    var body: some View {
        let open = SpaceTodos.open(items)
        let shown = Array(open.prefix(card.lineLimit))
        if open.isEmpty {
            SpaceQuietCard(card: card, note: items.isEmpty ? "회의를 요약하면 보여요" : "남은 일 없음", tile: tile)
        } else if tile {
            // 타일: 남은 수와 맨 위의 일 하나
            SpaceCardHeader(card: card, tile: true)
            Button(action: onOpenTasks) {
                VStack(alignment: .leading, spacing: 2) {
                    SpaceValueText(value: "\(open.count)건", large: true)
                    Text(open[0].task)
                        .font(SpaceType.note)
                        .foregroundStyle(ink.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
        } else {
            SpaceCardHeader(card: card, trailing: "\(open.count)건")
            VStack(spacing: 0) {
                ForEach(shown) { item in
                    row(item)
                    if item.id != shown.last?.id {
                        Rectangle().fill(ink.hairline).frame(height: 1)
                    }
                }
            }
            if open.count > shown.count {
                Button(action: onOpenTasks) {
                    Text("\(open.count - shown.count)건 더 보기")
                        .font(SpaceType.note.weight(.semibold))
                        .foregroundStyle(ink.accent)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ item: ActionItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                // 할 일 탭과 같은 길로 완료한다 (미리알림에 넣은 것은 그쪽도 맞춘다)
                withAnimation { ReminderService.shared.setCompleted(item, true) }
                try? modelContext.save()
            } label: {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(ink.secondary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.task) 완료로 표시")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.task)
                    .font(SpaceType.body)
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                if let detail = SpaceTodos.detail(item) {
                    Text(detail)
                        .font(SpaceType.caption)
                        .foregroundStyle(TaskOverview.isOverdue(item) ? DS.Chat.warning : ink.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 48)
    }
}

/// 할 일 카드에 보일 것을 고른다 (화면 표시용 계산만, 데이터는 바꾸지 않는다)
enum SpaceTodos {
    /// 아직 하지 않은 할 일: 최근 회의부터, 회의 안에서는 원래 차례대로. 요약이 지워진 할 일은 뺀다
    static func open(_ items: [ActionItem]) -> [ActionItem] {
        items
            .filter { !$0.isCompleted && $0.summary?.meeting != nil }
            .sorted { a, b in
                let (dateA, dateB) = (a.summary?.meeting?.date ?? .distantPast, b.summary?.meeting?.date ?? .distantPast)
                return dateA == dateB ? a.order < b.order : dateA > dateB
            }
    }

    /// 줄 아래의 작은 글: 담당자와 기한 (본문에 있던 그대로. 없으면 넣지 않는다)
    static func detail(_ item: ActionItem) -> String? {
        let parts = [item.owner.map { "\($0) 님" }, item.dueText].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 오늘 일정 (D95. 이 아이폰의 캘린더에서 읽는다. 일정은 이 기기 밖으로 나가지 않는다).
/// 타일에는 다음 일정 하나를 크게 (시각 · 이름 · 얼마 뒤 · 남은 수만큼의 점), 넓은 카드에는 남은 일정을 줄로
struct SpaceCalendarBody: View {
    let card: SpaceCard
    var tile = false
    let calendar: any DayEventsProviding
    @State private var access = DayEvents.Access.notAsked
    @State private var events: [DayEvent] = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.spaceInk) private var ink

    var body: some View {
        let remaining = DayEvents.remaining(events)
        Group {
            switch access {
            case .notAsked:
                SpaceQuietCard(card: card, note: tile ? "허용하면 오늘 일정이 보여요" : "허용하면 여기에 보여요", tile: tile, button: tile ? "캘린더 허용하기" : "허용하기") {
                    Task {
                        _ = await calendar.request()
                        load()
                    }
                }
            case .denied:
                SpaceQuietCard(card: card, note: "캘린더 권한이 꺼져 있어요", tile: tile, button: "설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            case .allowed:
                if let next = remaining.first {
                    if tile || card.size == .small {
                        SpaceCardHeader(card: card, tile: true, title: "다음 일정", trailing: remaining.count > 1 ? "\(remaining.count - 1)개 더" : nil)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.timeText())
                                .font(tile ? SpaceType.hugeValue : SpaceType.value)
                                .foregroundStyle(ink.primary)
                                .monospacedDigit()
                            Text(next.title)
                                .font(SpaceType.headline)
                                .foregroundStyle(ink.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(next.isAllDay ? "하루 종일" : SpaceTime.until(next.start))
                                .font(SpaceType.note)
                                .foregroundStyle(ink.secondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        // 남은 일정의 수만큼 점 (셋까지). 맨 앞이 지금 보이는 일정이다
                        HStack(spacing: 5) {
                            ForEach(0..<min(3, remaining.count), id: \.self) { index in
                                Capsule()
                                    .fill(index == 0 ? ink.accent : ink.skeleton)
                                    .frame(width: 16, height: 5)
                            }
                        }
                        .accessibilityHidden(true)
                    } else {
                        let shown = Array(remaining.prefix(card.lineLimit))
                        SpaceCardHeader(card: card, trailing: "\(remaining.count)개")
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(shown) { event in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(event.timeText())
                                        .font(SpaceType.body)
                                        .foregroundStyle(ink.accent)
                                        .monospacedDigit()
                                        .frame(width: 48, alignment: .leading)
                                    Text(event.title)
                                        .font(SpaceType.body)
                                        .foregroundStyle(ink.primary)
                                        .lineLimit(1)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if remaining.count > shown.count {
                                Text("일정 \(remaining.count - shown.count)개 더")
                                    .font(SpaceType.caption)
                                    .foregroundStyle(ink.secondary)
                            }
                        }
                    }
                } else {
                    SpaceQuietCard(
                        card: card, note: events.isEmpty ? "일정 없음" : "남은 일정 없음", tile: tile,
                        detail: events.isEmpty ? "오늘은 일정이 없어요" : "오늘 \(events.count)개를 마쳤어요"
                    )
                }
            }
        }
        .task { load() }
        .onChange(of: scenePhase) { _, phase in
            // 설정에서 권한을 바꿨거나 캘린더에 일정을 넣고 왔을 수 있다
            if phase == .active { load() }
        }
    }

    private func load() {
        access = calendar.access()
        events = access == .allowed ? calendar.today(now: .now) : []
    }
}

/// 날씨 (이 기기가 Apple 날씨에서 받는다. 위치는 맥으로도 Claude로도 가지 않는다).
/// 아이폰의 날씨 위젯과 같은 짜임이다 (D104): 왼쪽 위에 곳과 큰 기온, 오른쪽 위에 하늘 그림·상태·최고와 최저,
/// 그 아래에 시간별 줄. 반 칸 타일은 작은 위젯처럼 세로로, 큰 카드는 그 아래에 며칠치를 더한다
struct SpaceWeatherBody: View {
    let card: SpaceCard
    var tile = false
    let weather: any WeatherProviding
    @State private var result: Result<WeatherSource, WeatherFailure>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.spaceInk) private var ink

    var body: some View {
        Group {
            switch result {
            case .success(let source):
                let today = source.days.first
                if tile || card.size == .small {
                    // 작은 위젯: 곳 → 기온 → 그림 → 상태 → 최고·최저
                    VStack(alignment: .leading, spacing: 2) {
                        place(source)
                        temperature(source, today: today)
                        symbol(source.now?.symbol ?? today?.symbol, size: 18)
                            .padding(.top, 4)
                        condition(source, today: today)
                        range(today)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            place(source)
                            temperature(source, today: today)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 3) {
                            symbol(source.now?.symbol ?? today?.symbol, size: 20)
                            condition(source, today: today)
                            range(today)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if !source.hours.isEmpty {
                        hours(source)
                    }
                    if card.size == .large, source.days.count > 1 {
                        Rectangle().fill(ink.hairline).frame(height: 1)
                        days(source)
                    }
                }
            case .failure(let failure):
                SpaceQuietCard(card: card, note: Self.message(failure), tile: tile)
            case nil:
                SpaceCardHeader(card: card, tile: true)
                SpaceSkeleton()
            }
        }
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
    }

    /// 곳의 이름: 말한 지역, 없으면 지금 위치의 동네 이름(화면에만 쓴다), 그것도 없으면 "나의 위치". 지금 위치면 화살표를 붙인다
    private func place(_ source: WeatherSource) -> some View {
        HStack(spacing: 4) {
            Text(source.place ?? source.locality ?? "나의 위치")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if source.place == nil {
                Image(systemName: "location.fill")
                    .font(.caption2)
                    .accessibilityLabel("지금 위치")
            }
        }
        .foregroundStyle(ink.primary)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func temperature(_ source: WeatherSource, today: WeatherSource.Day?) -> some View {
        if let temperature = source.now?.temperature ?? today?.high {
            Text("\(temperature)°")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(ink.primary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func symbol(_ name: String?, size: CGFloat) -> some View {
        if let name, !name.isEmpty {
            Image(systemName: name)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: size))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func condition(_ source: WeatherSource, today: WeatherSource.Day?) -> some View {
        if let condition = source.now?.condition ?? today?.condition {
            Text(condition)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ink.primary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func range(_ today: WeatherSource.Day?) -> some View {
        if let today {
            Text("최고:\(today.high)° 최저:\(today.low)°")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ink.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    /// 시간별 줄: 때 · 그림 · 기온 (여섯 칸까지)
    private func hours(_ source: WeatherSource) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(source.hours.prefix(6).enumerated()), id: \.offset) { index, hour in
                VStack(spacing: 7) {
                    Text(index == 0 ? "지금" : Self.hourText(hour.date, timeZone: source.timeZone))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    symbol(hour.symbol, size: 18)
                        .frame(height: 22)
                    Text("\(hour.temperature)°")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ink.primary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 2)
    }

    /// 며칠치 (큰 카드): 요일 · 그림 · 최저와 최고
    private func days(_ source: WeatherSource) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(source.days.dropFirst().prefix(4).enumerated()), id: \.offset) { _, day in
                HStack(spacing: 10) {
                    Text(Self.dayText(day.date, timeZone: source.timeZone))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ink.primary)
                        .frame(width: 44, alignment: .leading)
                    symbol(day.symbol, size: 17)
                        .frame(width: 28)
                    Spacer(minLength: 0)
                    Text("\(day.low)°")
                        .foregroundStyle(ink.secondary)
                    Text("\(day.high)°")
                        .foregroundStyle(ink.primary)
                        .frame(width: 40, alignment: .trailing)
                }
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func load() async {
        result = await weather.weather(place: nil)
    }

    /// "오후 7시" (그곳의 시각으로)
    nonisolated static func hourText(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: date)
        return "\(hour < 12 ? "오전" : "오후") \(hour % 12 == 0 ? 12 : hour % 12)시"
    }

    /// "화요일" (그곳의 달력으로)
    nonisolated static func dayText(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return ["일", "월", "화", "수", "목", "금", "토"][calendar.component(.weekday, from: date) - 1] + "요일"
    }

    nonisolated static func message(_ failure: WeatherFailure) -> String {
        switch failure {
        case .locationDenied: "위치 권한이 없어요"
        case .locationUnavailable: "위치를 찾지 못했어요"
        default: "받아오지 못했어요"
        }
    }
}
