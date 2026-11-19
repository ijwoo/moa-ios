import SwiftUI

/// 녹음 전체 파형 + 재생 위치 + 북마크 표시. 손가락으로 훑으면 그 시점으로 이동한다.
///
/// 화자 구분이 생기면 `activeRange` 대신 발화 구간마다 참여자 색을 칠하도록 확장한다.
struct WaveformTimeline: View {
    let peaks: [Float]
    let duration: TimeInterval
    let currentTime: TimeInterval
    let bookmarkTimes: [TimeInterval]
    /// 지금 재생 중인 말풍선 구간
    let activeRange: ClosedRange<TimeInterval>?
    /// (시각, 손을 뗐는지)
    let onScrub: (TimeInterval, Bool) -> Void

    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onScrub(time(at: $0.location.x, width: width), false) }
                    .onEnded { onScrub(time(at: $0.location.x, width: width), true) }
            )
        }
        .frame(minHeight: 24, idealHeight: 56, maxHeight: 56)
        .accessibilityElement()
        .accessibilityLabel("녹음 파형")
        .accessibilityValue("\(MeetingText.timestamp(currentTime)) / \(MeetingText.timestamp(duration))")
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = direction == .increment ? 10 : -10
            onScrub(min(max(0, currentTime + step), duration), true)
        }
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return min(max(0, Double(x / width)), 1) * duration
    }

    private func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(0, time / duration), 1)) * width
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let barCount = max(1, Int(size.width / (barWidth + barSpacing)))
        let bars = Waveform.normalized(Waveform.downsample(peaks, to: barCount))
        let playheadX = x(for: currentTime, width: size.width)

        // 지금 재생 중인 말풍선 구간
        if let activeRange {
            let startX = x(for: activeRange.lowerBound, width: size.width)
            let endX = x(for: activeRange.upperBound, width: size.width)
            context.fill(
                Path(roundedRect: CGRect(x: startX, y: 0, width: max(2, endX - startX), height: size.height), cornerRadius: 4),
                with: .color(DS.Colors.accent.opacity(0.15))
            )
        }

        // 파형 막대: 들은 부분은 강조색, 남은 부분은 회색
        let step = bars.isEmpty ? 0 : size.width / CGFloat(bars.count)
        for (index, value) in bars.enumerated() {
            let barX = CGFloat(index) * step
            let height = max(2, CGFloat(value) * (size.height - 12))
            let rect = CGRect(x: barX, y: (size.height - height) / 2, width: barWidth, height: height)
            let color: Color = barX <= playheadX ? DS.Colors.accent : .secondary.opacity(0.45)
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
        }

        // 북마크
        for time in bookmarkTimes {
            let markX = x(for: time, width: size.width)
            var marker = Path()
            marker.move(to: CGPoint(x: markX - 4, y: 0))
            marker.addLine(to: CGPoint(x: markX + 4, y: 0))
            marker.addLine(to: CGPoint(x: markX, y: 6))
            marker.closeSubpath()
            context.fill(marker, with: .color(BookmarkStyle.color))
            context.fill(Path(CGRect(x: markX - 0.5, y: 0, width: 1, height: size.height)), with: .color(BookmarkStyle.color.opacity(0.7)))
        }

        // 재생 위치
        context.fill(
            Path(roundedRect: CGRect(x: playheadX - 1, y: 0, width: 2, height: size.height), cornerRadius: 1),
            with: .color(.primary)
        )
    }
}

#Preview {
    WaveformTimeline(
        peaks: (0..<600).map { Float(abs(sin(Double($0) / 9))) * Float.random(in: 0.2...1) },
        duration: 60,
        currentTime: 22,
        bookmarkTimes: [15, 41],
        activeRange: 18...26,
        onScrub: { _, _ in }
    )
    .padding()
}
