import SwiftUI

// MARK: - Moa 4모듈 온보딩 뷰 (v4: 원본 아이콘 1:1 픽셀 실측 매칭)
//
// 사용자가 만든 화면이다 (D97). 모양·글·움직임은 받은 그대로 두고, 앱에 넣으며 세 가지만 더했다:
// ① 다시 재생의 기다림을 Task로 (Swift 6 동시성 검사) ② "동작 줄이기"를 켠 기기에서는 움직임 없이 다 놓인 모습으로
// ③ 로고 그림을 VoiceOver가 읽지 않게 (뜻은 아래 글에 있다)
// 그리고 로고의 흰 조각 색을 바꿀 수 있게 열었다 (`leafColor`. 기본은 흰색 그대로 — 내 공간의 빈 화면이 밝은 바탕에서 쓴다, D98)

/// 처음 한 번 보이는 화면을 보일지 정한다
enum Onboarding {
    /// 본 적이 없을 때만 보인다. 개발용 실행(`-demo…`)에서는 `-demoOnboarding`을 줄 때만 보인다 (다른 화면의 확인을 가리지 않게)
    static func shouldShow(done: Bool, arguments: [String]) -> Bool {
        if arguments.contains("-demoOnboarding") { return true }
        if arguments.contains(where: { $0.hasPrefix("-demo") }) { return false }
        return !done
    }
}

struct MoaOnboardingView: View {
    var onStart: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showGuide = false
    @State private var step1 = false   // 좌상
    @State private var step2 = false   // 좌하
    @State private var step3 = false   // 우하
    @State private var step4 = false   // 우상 AI 스파크
    @State private var ripple = false  // 스파크 안착 파동
    @State private var showTitle = false
    @State private var showSub = false
    @State private var showButton = false

    private let bgColor = Color(red: 0.055, green: 0.067, blue: 0.086)      // #0E1116
    /// 포인트 색: 고른 강조색 (D144, 기본 민트)
    private var mintColor: Color { SpaceBrand.mint }

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                MoaLogoMarkV4(
                    width: 184,
                    mintColor: mintColor,
                    showGuide: showGuide,
                    step1: step1,
                    step2: step2,
                    step3: step3,
                    step4: step4,
                    ripple: ripple
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    replayAnimation()
                }
                .accessibilityHidden(true)

                Spacer().frame(height: 44)

                VStack(spacing: 12) {
                    Text("흩어진 하루를 한곳에, 모아")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .opacity(showTitle ? 1 : 0)
                        .offset(y: showTitle ? 0 : 12)

                    // 글을 한 줄로 줄였다 (사용자 요청, D101. 전: "일정, 메일, 할 일, 배송까지 / 지금 꼭 볼 것만 알아서 한 화면에 모아둘게요.")
                    Text("꼭 볼 것만 한 화면에 모아둘게요.")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .opacity(showSub ? 1 : 0)
                        .offset(y: showSub ? 0 : 10)
                }

                Spacer()

                Button(action: onStart) {
                    Text("내 공간 시작하기")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(bgColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(mintColor)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .opacity(showButton ? 1 : 0)
                .offset(y: showButton ? 0 : 14)
            }
        }
        .onAppear {
            playAnimation()
        }
    }

    private func playAnimation() {
        // 동작 줄이기: 움직임 없이 다 놓인 모습으로
        if reduceMotion {
            showGuide = true
            step1 = true
            step2 = true
            step3 = true
            step4 = true
            ripple = true
            showTitle = true
            showSub = true
            showButton = true
            return
        }
        withAnimation(.easeOut(duration: 0.6).delay(0.1)) {
            showGuide = true
        }
        let settle = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 1.05)
        withAnimation(settle.delay(0.25)) { step1 = true }
        withAnimation(settle.delay(0.42)) { step2 = true }
        withAnimation(settle.delay(0.58)) { step3 = true }

        withAnimation(.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 1.1).delay(0.85)) {
            step4 = true
        }
        withAnimation(.easeOut(duration: 1.15).delay(1.35)) {
            ripple = true
        }

        withAnimation(.easeOut(duration: 0.65).delay(1.50)) { showTitle = true }
        withAnimation(.easeOut(duration: 0.65).delay(1.68)) { showSub = true }
        withAnimation(.easeOut(duration: 0.65).delay(1.88)) { showButton = true }
    }

    private func replayAnimation() {
        showGuide = false
        step1 = false
        step2 = false
        step3 = false
        step4 = false
        ripple = false
        showTitle = false
        showSub = false
        showButton = false
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            playAnimation()
        }
    }
}

// MARK: - 4모듈 로고 마크 v4 (실측 fill 0.90 매칭: bigR 0.48, smallR 0.07)
struct MoaLogoMarkV4: View {
    let width: CGFloat
    let mintColor: Color
    /// 흰 조각의 색. 밝은 바탕에 놓을 때만 바꾼다 (내 공간의 빈 화면, D98)
    var leafColor: Color = .white
    let showGuide: Bool
    let step1: Bool
    let step2: Bool
    let step3: Bool
    let step4: Bool
    let ripple: Bool

    private var height: CGFloat { width * (597.0 / 576.0) }

    var body: some View {
        let tlW = width * 0.470, tlH = height * 0.481
        let trD = width * 0.500
        let blW = width * 0.467, blH = height * 0.469
        let brW = width * 0.472, brH = height * 0.469

        let tlBig = tlW * 0.48, tlSmall = tlW * 0.07
        let bBig  = blW * 0.48, bSmall  = blW * 0.07

        ZStack {
            // 배경 가이드 슬롯
            Group {
                RoundedRectangle(cornerRadius: tlW * 0.16, style: .continuous)
                    .stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: tlW, height: tlH)
                    .offset(x: -width * 0.265, y: -height * 0.258)

                Circle()
                    .stroke(mintColor.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: trD, height: trD)
                    .offset(x: width * 0.250, y: -height * 0.258)

                RoundedRectangle(cornerRadius: blW * 0.16, style: .continuous)
                    .stroke(mintColor.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: blW, height: blH)
                    .offset(x: -width * 0.266, y: height * 0.265)

                RoundedRectangle(cornerRadius: brW * 0.16, style: .continuous)
                    .stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: brW, height: brH)
                    .offset(x: width * 0.264, y: height * 0.265)
            }
            .opacity(showGuide ? (step4 ? 0 : 1) : 0)

            // 1. 좌상: 흰색 나뭇잎
            UnevenRoundedRectangle(
                topLeadingRadius: tlBig,
                bottomLeadingRadius: tlSmall,
                bottomTrailingRadius: tlBig,
                topTrailingRadius: tlSmall,
                style: .continuous
            )
            .fill(leafColor)
            .frame(width: tlW, height: tlH)
            .offset(
                x: -width * 0.265 + (step1 ? 0 : -52),
                y: -height * 0.258 + (step1 ? 0 : -42)
            )
            .rotationEffect(.degrees(step1 ? 0 : -14))
            .scaleEffect(step1 ? 1 : 0.86)
            .opacity(step1 ? 1 : 0)

            // 3. 좌하: 민트 나뭇잎
            UnevenRoundedRectangle(
                topLeadingRadius: bSmall,
                bottomLeadingRadius: bBig,
                bottomTrailingRadius: bSmall,
                topTrailingRadius: bBig,
                style: .continuous
            )
            .fill(mintColor)
            .frame(width: blW, height: blH)
            .offset(
                x: -width * 0.266 + (step2 ? 0 : -46),
                y: height * 0.265 + (step2 ? 0 : 50)
            )
            .rotationEffect(.degrees(step2 ? 0 : 12))
            .scaleEffect(step2 ? 1 : 0.86)
            .opacity(step2 ? 1 : 0)

            // 4. 우하: 흰색 나뭇잎
            UnevenRoundedRectangle(
                topLeadingRadius: bSmall,
                bottomLeadingRadius: bBig,
                bottomTrailingRadius: bSmall,
                topTrailingRadius: bBig,
                style: .continuous
            )
            .fill(leafColor)
            .frame(width: brW, height: brH)
            .offset(
                x: width * 0.264 + (step3 ? 0 : 48),
                y: height * 0.265 + (step3 ? 0 : 46)
            )
            .rotationEffect(.degrees(step3 ? 0 : 14))
            .scaleEffect(step3 ? 1 : 0.86)
            .opacity(step3 ? 1 : 0)

            // 2. 우상: 민트 원 + AI 스파크 + 안착 리플
            ZStack {
                Circle()
                    .stroke(mintColor.opacity(ripple ? 0 : 0.45), lineWidth: 2)
                    .scaleEffect(ripple ? 1.75 : 0.95)

                Circle()
                    .fill(mintColor)

                FourPointSpark()
                    .fill(.white)
                    .frame(width: trD * 0.505, height: trD * 0.520)
                    .scaleEffect(step4 ? 1.0 : 0.5)
                    .rotationEffect(.degrees(step4 ? 0 : -35))
            }
            .frame(width: trD, height: trD)
            .offset(
                x: width * 0.250 + (step4 ? 0 : 54),
                y: -height * 0.258 + (step4 ? 0 : -48)
            )
            .scaleEffect(step4 ? 1 : 0.80)
            .opacity(step4 ? 1 : 0)
        }
        .frame(width: width, height: height)
    }
}

struct FourPointSpark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let cy = rect.midY
        let insetX = w * 0.38
        let insetY = h * 0.38

        var path = Path()
        path.move(to: CGPoint(x: cx, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: w, y: cy),
            control: CGPoint(x: cx + (w * 0.5 - insetX), y: cy - (h * 0.5 - insetY))
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: h),
            control: CGPoint(x: cx + (w * 0.5 - insetX), y: cy + (h * 0.5 - insetY))
        )
        path.addQuadCurve(
            to: CGPoint(x: 0, y: cy),
            control: CGPoint(x: cx - (w * 0.5 - insetX), y: cy + (h * 0.5 - insetY))
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: 0),
            control: CGPoint(x: cx - (w * 0.5 - insetX), y: cy - (h * 0.5 - insetY))
        )
        path.closeSubpath()
        return path
    }
}

#Preview {
    MoaOnboardingView()
}
