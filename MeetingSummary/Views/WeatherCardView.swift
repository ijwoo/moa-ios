import SwiftUI
import UIKit

/// 대화 속 날씨 카드 (D66). 맥(Claude)이 "날씨를 물었다, 어디·언제"만 정하면 이 기기가 Apple 날씨에서 받아 그린다.
///
/// 저장된 카드는 받아온 그때의 날씨다. 그래서 아래에 언제 받은 것인지 적는다 (며칠 뒤에 다시 봐도 "오늘"을 오해하지 않게).
/// Apple 날씨 표시와 데이터 출처 링크는 Apple 날씨를 쓰는 조건이라 항상 붙인다
struct WeatherCardView: View {
    let card: WeatherCard

    @Environment(\.openURL) private var openURL
    @State private var opened: OpenedPage?

    /// Apple 날씨의 데이터 출처 (Apple이 정한 주소)
    static let legalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: card.isCurrentLocation ? "location.fill" : "mappin.and.ellipse")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Chat.accent)
                .accessibilityAddTraits(.isHeader)

            if let failure = card.failure {
                failed(failure)
            } else {
                switch card.kind {
                case .now: current
                case .day: day
                case .week: week
                }
                ChatHairline()
                footer
            }
        }
        .chatCard()
        .sheet(item: $opened) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
    }

    private var title: String {
        "\(card.place ?? "현재 위치") · \(card.period)"
    }

    // MARK: - 지금

    @ViewBuilder
    private var current: some View {
        if let now = card.now {
            HStack(spacing: 14) {
                WeatherSymbol(name: now.symbol, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(now.temperature)°")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Chat.textPrimary)
                    Text("\(now.condition) · 체감 \(now.feelsLike)°")
                        .font(.subheadline)
                        .foregroundStyle(DS.Chat.textSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("지금 \(now.condition), \(now.temperature)도, 체감 \(now.feelsLike)도")
        }
        if let today = card.days.first {
            HStack(spacing: 0) {
                Metric(title: "오늘 최저 · 최고", value: "\(today.low)° · \(today.high)°")
                Metric(title: "강수확률", value: "\(today.rainChance)%")
                Metric(title: "바람", value: "\(today.wind)m/s")
            }
        }
    }

    // MARK: - 하루

    @ViewBuilder
    private var day: some View {
        if let day = card.days.first {
            HStack(spacing: 14) {
                WeatherSymbol(name: day.symbol, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.condition)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(DS.Chat.textPrimary)
                    Text("최저 \(day.low)° · 최고 \(day.high)°")
                        .font(.subheadline)
                        .foregroundStyle(DS.Chat.textSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(day.condition), 최저 \(day.low)도, 최고 \(day.high)도")
            HStack(spacing: 0) {
                Metric(title: "강수확률", value: "\(day.rainChance)%")
                Metric(title: "바람", value: "\(day.wind)m/s")
                Metric(title: "자외선", value: "\(day.uvIndex) \(Self.uvLabel(day.uvIndex))")
            }
        }
    }

    // MARK: - 한 주

    private var week: some View {
        VStack(spacing: 0) {
            ForEach(Array(card.days.enumerated()), id: \.offset) { index, day in
                if index > 0 { ChatHairline() }
                HStack(spacing: 10) {
                    Text(day.label)
                        .font(.subheadline.weight(index == 0 ? .semibold : .regular))
                        .foregroundStyle(DS.Chat.textPrimary)
                        .frame(width: 74, alignment: .leading)
                    WeatherSymbol(name: day.symbol, size: 30)
                    Text(day.condition)
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if day.rainChance >= 20 {
                        Text("\(day.rainChance)%")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(DS.Chat.accent)
                    }
                    Text("\(day.low)° / \(day.high)°")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(DS.Chat.textPrimary)
                        .frame(minWidth: 72, alignment: .trailing)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.label) \(day.condition), 최저 \(day.low)도, 최고 \(day.high)도, 강수확률 \(day.rainChance)퍼센트")
            }
        }
    }

    // MARK: - 보여 주지 못했을 때

    @ViewBuilder
    private func failed(_ failure: WeatherFailure) -> some View {
        Text(Self.message(for: failure, asked: card.asked))
            .lineSpacing(4)
            .foregroundStyle(DS.Chat.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        if failure == .locationDenied || failure == .locationUnavailable {
            Text("\u{201C}부산 날씨\u{201D}처럼 지역을 말하면 위치 없이도 볼 수 있어요.")
                .font(.footnote)
                .foregroundStyle(DS.Chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if failure == .locationDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
            Button("설정 열기") { openURL(settings) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    static func message(for failure: WeatherFailure, asked: String?) -> String {
        switch failure {
        case .locationDenied: "위치 권한이 없어서 지금 있는 곳의 날씨를 볼 수 없어요."
        case .locationUnavailable: "지금 위치를 찾지 못했어요. 잠시 뒤에 다시 물어봐 주세요."
        case .placeNotFound: "\u{201C}\(asked ?? "그곳")\u{201D}을(를) 찾지 못했어요. 지역 이름을 다시 말해 주세요."
        case .noForecast: "그 날짜의 예보는 볼 수 없어요. 오늘부터 열흘 안의 날씨만 볼 수 있어요."
        case .unavailable: "날씨를 받아오지 못했어요. 잠시 뒤에 다시 물어봐 주세요."
        }
    }

    // MARK: - 출처

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\u{F8FF} Weather")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.Chat.textSecondary)
                .accessibilityLabel("Apple 날씨")
            Text("· \(Self.stamp(card.asOf)) 기준")
                .font(.footnote)
                .foregroundStyle(DS.Chat.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if let url = Self.legalURL {
                Button("데이터 출처") { opened = OpenedPage(url: url) }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(DS.Chat.accent)
                    .buttonStyle(.plain)
                    .accessibilityHint("Apple 날씨의 데이터 출처 페이지를 엽니다")
            }
        }
    }

    /// "11월 13일 오후 3:12"
    static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M월 d일 a h:mm"
        return formatter.string(from: date)
    }

    static func uvLabel(_ index: Int) -> String {
        switch index {
        case ..<3: "낮음"
        case 3..<6: "보통"
        case 6..<8: "높음"
        case 8..<11: "매우 높음"
        default: "위험"
        }
    }
}

/// 날씨 그림: 하늘색 바탕 위에 올린다 (밝은 화면에서 흰 구름이 보이게)
private struct WeatherSymbol: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.29, green: 0.56, blue: 0.89), Color(red: 0.16, green: 0.38, blue: 0.74)],
                    startPoint: .top, endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// 작은 제목 아래 값 하나 (세 칸으로 나눠 쓴다)
private struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(DS.Chat.textSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Chat.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
