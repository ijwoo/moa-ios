import AppIntents
import SwiftUI
import WidgetKit

// 홈 화면 위젯 (D109): 내 공간의 카드 가운데 맥이 채우는 것(메일·값·예약 결과·날짜)을 보인다.
// 누르면 앱의 내 공간 탭이 열린다. 맥에 닿지 못하면 지난 모습을 보인다.

@main
struct MoaWidgets: WidgetBundle {
    var body: some Widget {
        SpaceWidget()
    }
}

struct SpaceWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "내 공간"
    static let description = IntentDescription("내 공간의 카드를 홈 화면에 보여 줘요.")
}

struct SpaceWidgetEntry: TimelineEntry {
    enum State: Equatable {
        case shown(SpaceWidgetSnapshot, stale: Bool)
        case empty
        case unsupported
    }

    let date: Date
    let state: State
}

struct SpaceWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SpaceWidgetEntry {
        SpaceWidgetEntry(date: .now, state: .shown(Self.sample, stale: false))
    }

    func snapshot(for configuration: SpaceWidgetIntent, in context: Context) async -> SpaceWidgetEntry {
        if context.isPreview { return placeholder(in: context) }
        return await entry()
    }

    func timeline(for configuration: SpaceWidgetIntent, in context: Context) async -> Timeline<SpaceWidgetEntry> {
        // 30분마다 다시 묻는다 (실제로 언제 다시 부를지는 아이폰이 정한다)
        Timeline(entries: [await entry()], policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func entry() async -> SpaceWidgetEntry {
        switch await SpaceWidgetFetch.fetch() {
        case .fresh(let snapshot):
            SpaceWidgetCache.save(snapshot)
            return SpaceWidgetEntry(date: .now, state: snapshot.items.isEmpty ? .empty : .shown(snapshot, stale: false))
        case .unreachable:
            if let last = SpaceWidgetCache.load(), !last.items.isEmpty {
                return SpaceWidgetEntry(date: .now, state: .shown(last, stale: true))
            }
            return SpaceWidgetEntry(date: .now, state: .empty)
        case .unsupported:
            return SpaceWidgetEntry(date: .now, state: .unsupported)
        }
    }

    /// 위젯을 고를 때 보이는 모습 (지어낸 값)
    static let sample = SpaceWidgetSnapshot(
        items: [
            SpaceWidgetItem(id: "s1", title: "오늘 온 메일", value: "8통", line: "챙길 메일 1통", unavailable: false),
            SpaceWidgetItem(id: "s2", title: "원달러 환율", value: "1,382.0원", line: "개장가 기준", unavailable: false),
            SpaceWidgetItem(id: "s3", title: "다음 공휴일", value: "2026-12-25", line: "성탄절", date: "2026-12-25", unavailable: false),
            SpaceWidgetItem(id: "s4", title: "아침 브리핑", value: nil, line: "메일 5통, 맑고 낮 최고 15도", unavailable: false),
        ],
        fetchedAt: .now
    )
}

struct SpaceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "SpaceWidget", intent: SpaceWidgetIntent.self, provider: SpaceWidgetProvider()) { entry in
            SpaceWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetColors.background }
                .widgetURL(URL(string: "moa://space"))
        }
        .configurationDisplayName("내 공간")
        .description("내 공간의 카드를 홈 화면에 보여 줘요.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

enum WidgetColors {
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.055, green: 0.067, blue: 0.086, alpha: 1) : .white })
    static let tile = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.07) : UIColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1) })
    /// 앱 아이콘의 민트 (밝은 바탕에서는 한 단계 짙게)
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.263, green: 0.851, blue: 0.639, alpha: 1) : UIColor(red: 0.04, green: 0.48, blue: 0.34, alpha: 1) })
}

struct SpaceWidgetView: View {
    let entry: SpaceWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.state {
        case .shown(let snapshot, let stale):
            let items = Array(snapshot.items.prefix(SpaceWidgetSnapshot.limit(small: family == .systemSmall, large: family == .systemLarge)))
            VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 8) {
                header(stale: stale, at: snapshot.fetchedAt)
                if family == .systemSmall, let item = items.first {
                    Spacer(minLength: 0)
                    SpaceWidgetTile(item: item, prominent: true)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(items) { item in
                            SpaceWidgetTile(item: item, prominent: false)
                                .padding(10)
                                .frame(maxWidth: .infinity, minHeight: family == .systemLarge ? 92 : 56, alignment: .topLeading)
                                .background(WidgetColors.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        case .empty:
            message("내 공간에 카드가 없어요", "앱에서 보고 싶은 것을 말해 보세요")
        case .unsupported:
            message("맥을 최신으로 올려 주세요", "위젯은 맥의 에이전트가 있어야 보여요")
        }
    }

    private func header(stale: Bool, at date: Date) -> some View {
        HStack(spacing: 4) {
            Text("내 공간")
                .font(.caption.weight(.bold))
                .foregroundStyle(WidgetColors.accent)
            Spacer(minLength: 0)
            // 맥에 닿지 못해 지난 모습이면 언제 받은 것인지
            if stale {
                Text(date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("내 공간")
                .font(.caption.weight(.bold))
                .foregroundStyle(WidgetColors.accent)
            Spacer(minLength: 0)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 카드 하나: 이름(작게) → 값(크게) → 한 줄
struct SpaceWidgetTile: View {
    let item: SpaceWidgetItem
    let prominent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(item.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let new = item.newCount {
                    Text("새 \(new)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(WidgetColors.accent)
                }
            }
            if let value = shownValue {
                Text(value)
                    .font(.system(size: prominent ? 30 : 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(item.date != nil ? WidgetColors.accent : .primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            if let line = item.line {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(item.unavailable ? .secondary : .primary)
                    .lineLimit(item.value == nil ? 3 : 2)
            }
        }
    }

    /// 날짜 카드는 남은 날로 ("D-39")
    private var shownValue: String? {
        if let date = item.date { return SpaceWidgetDays.badge(date) ?? item.value }
        return item.value
    }
}
