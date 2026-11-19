import SwiftUI
import UIKit

/// 모아의 상태 그림 (D130): 사용자가 준 v3 아이콘(24×24 SVG)의 모양을 그대로 옮겼다.
/// 선은 사용자와 정한 대로 가늘게(24 기준 1.2), 안쪽 면은 옅게(8%), 색은 채도를 낮춘 C안.
/// 색의 뜻: 주황 = 내가 할 일(승인·답·로그인), 민트 = 끝남·진행, 빨강 = 못 끝냄, 회색 = 예약.
/// 밝은·어두운 화면에서 색이 따로 있다 (밝은 화면은 한 단계 진하게)
struct MoaStatusIcon: View {
    enum Kind: Sendable {
        case done, running, failed, approval, reply, login, scheduled
    }

    let kind: Kind
    var size: CGFloat = 22

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 24
            let line = StrokeStyle(lineWidth: 1.2 * s, lineCap: .round, lineJoin: .round)
            let tint = MoaStatusIcon.tint(kind)
            func fillAndStroke(_ path: Path) {
                context.fill(path, with: .color(tint.opacity(0.08)))
                context.stroke(path, with: .color(tint), style: line)
            }
            func stroke(_ path: Path, color: Color? = nil) { context.stroke(path, with: .color(color ?? tint), style: line) }
            func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
                context.fill(Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)), with: .color(tint))
            }
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let circle = Path(ellipseIn: CGRect(x: 3.25 * s, y: 3.25 * s, width: 17.5 * s, height: 17.5 * s))

            switch kind {
            case .done:
                fillAndStroke(circle)
                var check = Path()
                check.move(to: p(8.75, 12.1)); check.addLine(to: p(11.0, 14.35)); check.addLine(to: p(15.5, 9.6))
                stroke(check)
            case .running:
                // 옅은 고리 위에 4분의 1 호
                context.stroke(Path(ellipseIn: CGRect(x: 3.5 * s, y: 3.5 * s, width: 17 * s, height: 17 * s)), with: .color(tint.opacity(0.18)), style: line)
                var arc = Path()
                arc.addArc(center: p(12, 12), radius: 8.5 * s, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
                stroke(arc)
            case .failed:
                fillAndStroke(circle)
                var bar = Path()
                bar.move(to: p(12, 8.2)); bar.addLine(to: p(12, 12.6))
                stroke(bar)
                dot(12, 15.5, 0.85)
            case .approval:
                var shield = Path()
                shield.move(to: p(12, 3.25))
                shield.addLine(to: p(5.25, 6.1))
                shield.addLine(to: p(5.25, 11.4))
                shield.addCurve(to: p(12, 20.85), control1: p(5.25, 15.8), control2: p(8.1, 19.6))
                shield.addCurve(to: p(18.75, 11.4), control1: p(15.9, 19.6), control2: p(18.75, 15.8))
                shield.addLine(to: p(18.75, 6.1))
                shield.closeSubpath()
                fillAndStroke(shield)
                var check = Path()
                check.move(to: p(9.35, 12.1)); check.addLine(to: p(11.15, 13.9)); check.addLine(to: p(14.95, 10.1))
                stroke(check)
            case .reply:
                var bubble = Path()
                bubble.move(to: p(4.5, 11.6))
                bubble.addCurve(to: p(12, 4.25), control1: p(4.5, 7.5), control2: p(7.85, 4.25))
                bubble.addCurve(to: p(19.5, 11.6), control1: p(16.15, 4.25), control2: p(19.5, 7.5))
                bubble.addCurve(to: p(12, 18.95), control1: p(19.5, 15.7), control2: p(16.15, 18.95))
                bubble.addCurve(to: p(8.15, 17.92), control1: p(10.6, 18.95), control2: p(9.3, 18.58))
                bubble.addLine(to: p(4.7, 18.95))
                bubble.addLine(to: p(5.68, 15.55))
                bubble.addCurve(to: p(4.5, 11.6), control1: p(4.92, 14.4), control2: p(4.5, 13.05))
                bubble.closeSubpath()
                fillAndStroke(bubble)
                dot(9.2, 11.6, 0.85); dot(12, 11.6, 0.85); dot(14.8, 11.6, 0.85)
            case .login:
                var shackle = Path()
                shackle.move(to: p(8.5, 10.4)); shackle.addLine(to: p(8.5, 8.1))
                shackle.addArc(center: p(12, 8.1), radius: 3.5 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                shackle.addLine(to: p(15.5, 10.4))
                stroke(shackle)
                fillAndStroke(Path(roundedRect: CGRect(x: 5.75 * s, y: 10.4 * s, width: 12.5 * s, height: 9.2 * s), cornerRadius: 3 * s))
                var hole = Path()
                hole.move(to: p(12, 13.8)); hole.addLine(to: p(12, 16.1))
                stroke(hole)
            case .scheduled:
                fillAndStroke(circle)
                var hands = Path()
                hands.move(to: p(12, 7.8)); hands.addLine(to: p(12, 12)); hands.addLine(to: p(14.9, 13.7))
                stroke(hands, color: MoaStatusIcon.clockHands)
            }
        }
        .frame(width: size, height: size)
        .modifier(Spinning(active: kind == .running))
        .accessibilityHidden(true)
    }

    // MARK: 색 (C안)

    /// 차분한 포인트 색: 고른 강조색을 따른다 (D144, 기본 민트 #3E9C8A·#6CC4B0)
    static var mint: Color { AppTheme.shared.accent.calm }
    static let red = Color(light: 0xC26464, dark: UIColor(hex: 0xE08A8A))
    static let orange = Color(light: 0xC2843A, dark: UIColor(hex: 0xE0A458))
    static let gray = Color(light: 0x6B7385, dark: UIColor(hex: 0x8A94A6))
    static let clockHands = Color(light: 0x6B7385, dark: UIColor(hex: 0xB8C0CC))

    static func tint(_ kind: Kind) -> Color {
        switch kind {
        case .done, .running: mint
        case .failed: red
        case .approval, .reply, .login: orange
        case .scheduled: gray
        }
    }

    /// 진행 중이면 호가 천천히 돈다 (움직임 줄이기를 켠 사람에게는 돌지 않는다)
    private struct Spinning: ViewModifier {
        let active: Bool
        @State private var turned = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func body(content: Content) -> some View {
            if active, !reduceMotion {
                content
                    .rotationEffect(.degrees(turned ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: turned)
                    .onAppear { turned = true }
            } else {
                content
            }
        }
    }
}
