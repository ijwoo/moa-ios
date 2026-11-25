import SwiftUI
import UIKit

/// 손 넘기기 화면 (D123, 맥의 D106): 맥의 에이전트 브라우저 화면을 폰에 띄워, 사람 확인 퍼즐 같은 것을 사용자가 직접 푼다.
///
/// - 화면은 0.6초마다 맥에서 받아 이 화면의 메모리에만 둔다 (저장하지 않는다. 닫으면 버린다)
/// - 누르기 · 한 손가락으로 쓸어 스크롤 · "끌기"로 바꾸면 끌기. 글자와 Enter 같은 키는 아래 키보드 줄에서
/// - 끝은 "다 했어요": 질문에 그 말로 답한다 (에이전트가 화면을 다시 읽고 이어 간다). "그만하기"도 같은 질문의 답이다
struct HandoverView: View {
    let agent: any AgentProviding
    let handover: AgentHandover
    let choices: [String]
    let onAnswer: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var frame: HandoverFrame?
    @State private var image: UIImage?
    @State private var closed = false
    /// 답("다 했어요"·"그만하기")을 보냈다. 맥이 화면을 닫으므로, 닫히는 동안 "닫혔어요"를 띄우지 않고 마지막 화면을 둔다
    @State private var answered = false
    @State private var problem: String?
    @State private var mode = Mode.touch
    @State private var typing = false
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case touch = "누르기·스크롤"
        case drag = "끌기"
        var id: String { rawValue }
    }

    /// 화면을 다시 받는 간격 (맥은 0.3~1초를 권한다)
    static let interval = Duration.milliseconds(600)

    private var doneChoice: String { choices.first ?? "다 했어요" }
    private var stopChoice: String? { choices.count > 1 ? choices[1] : nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let reason = handover.reason {
                    Text(DemoText.t(reason))
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                screen
                controls
            }
            .background(DS.Chat.background.ignoresSafeArea())
            .navigationTitle(handover.host ?? DemoText.t("맥의 브라우저"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(DemoText.t("닫기")) { dismiss() }
                }
            }
        }
        .task {
            while !Task.isCancelled, !closed, !answered {
                await load()
                try? await Task.sleep(for: Self.interval)
            }
        }
        #if DEBUG
        // 데모 영상 (-demoReel): 퍼즐 칸 셋을 누르고 "다 했어요" (칸의 자리는 가짜 맥이 그린 화면 기준)
        .task {
            guard DemoData.arguments.contains("-demoReel") else { return }
            try? await Task.sleep(for: .seconds(1.6))
            for (x, y) in [(92, 248), (300, 332), (196, 416)] {
                send(.tap(x: x, y: y))
                try? await Task.sleep(for: .milliseconds(900))
            }
            try? await Task.sleep(for: .seconds(1.2))
            finish(doneChoice)
        }
        #endif
        // 화면을 떠나면 받은 그림을 버린다
        .onDisappear {
            frame = nil
            image = nil
        }
    }

    // MARK: - 화면

    private var screen: some View {
        GeometryReader { proxy in
            ZStack {
                if let image, let frame {
                    let scale = min(proxy.size.width / CGFloat(frame.width), proxy.size.height / CGFloat(frame.height))
                    let shown = CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: shown.width, height: shown.height)
                        .contentShape(Rectangle())
                        .gesture(gesture(scale: scale, frame: frame))
                        .accessibilityLabel("맥의 브라우저 화면")
                        .accessibilityHint("누르면 맥의 브라우저의 같은 자리를 누릅니다")
                } else if !closed {
                    ProgressView("화면을 받는 중")
                }
                if closed {
                    ContentUnavailableView {
                        Label("브라우저 화면이 닫혔어요", systemImage: "rectangle.slash")
                    } description: {
                        Text("질문이 끝났거나 5분 동안 입력이 없어 맥이 닫았어요.")
                    } actions: {
                        Button(DemoText.t("닫기")) { dismiss() }.buttonStyle(.bordered)
                    }
                    .background(DS.Chat.background.opacity(0.92))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(.horizontal, 8)
    }

    /// 손가락을 떼었을 때 무엇을 보낼지: 거의 움직이지 않았으면 누르기, 아니면 "끌기"에서는 끌기, 그 밖에는 스크롤
    private func gesture(scale: CGFloat, frame: HandoverFrame) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                let start = HandoverGeometry.point(value.startLocation, scale: scale, width: frame.width, height: frame.height)
                let end = HandoverGeometry.point(value.location, scale: scale, width: frame.width, height: frame.height)
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 8 {
                    send(.tap(x: start.x, y: start.y))
                } else if mode == .drag {
                    send(.drag(x: start.x, y: start.y, x2: end.x, y2: end.y))
                } else {
                    send(.wheel(dy: HandoverGeometry.wheel(value.translation.height, scale: scale), x: start.x, y: start.y))
                }
            }
    }

    // MARK: - 아래 줄

    private var controls: some View {
        VStack(spacing: 10) {
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(DS.Chat.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Picker("손짓", selection: $mode) {
                    ForEach(Mode.allCases) { Text(DemoText.t($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                Button {
                    typing.toggle()
                    focused = typing
                } label: {
                    Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard")
                        .frame(width: 40, height: 32)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(typing ? "키보드 닫기" : "키보드 열기")
            }
            if typing {
                HStack(spacing: 6) {
                    TextField("맥의 화면에 쓸 글", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(sendText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(DS.Chat.bubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    key(.backspace, symbol: "delete.left", label: "지우기")
                    key(.enter, symbol: "return", label: "Enter")
                    key(.tab, symbol: "arrow.right.to.line", label: "Tab")
                }
            }
            Button { finish(doneChoice) } label: {
                Text(doneChoice).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Chat.userBubble)
            .controlSize(.large)
            .disabled(closed)
            if let stopChoice {
                Button(stopChoice, role: .destructive) { finish(stopChoice) }
                    .font(.subheadline)
                    .disabled(closed)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func key(_ key: HandoverInput.Key, symbol: String, label: String) -> some View {
        Button { send(.key(key)) } label: {
            Image(systemName: symbol).frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    // MARK: - 맥과 주고받기

    private func load() async {
        guard !answered else { return }
        do {
            let fresh = try await agent.handoverFrame(id: handover.id)
            guard !answered else { return }
            frame = fresh
            image = UIImage(data: fresh.image)
            problem = nil
        } catch AgentError.handoverClosed {
            if !answered { closed = true }
        } catch {
            problem = "화면을 받지 못하고 있어요. 맥과 연결을 확인해 주세요."
        }
    }

    private func send(_ input: HandoverInput) {
        guard !closed else { return }
        Haptic.select()
        Task {
            do {
                try await agent.handoverInput(id: handover.id, input)
                problem = nil
            } catch AgentError.handoverClosed {
                closed = true
            } catch {
                problem = "맥에 전하지 못했어요. 다시 해 주세요."
            }
            // 누른 결과를 바로 본다
            await load()
        }
    }

    private func sendText() {
        let value = text
        guard !value.isEmpty else { return }
        text = ""
        send(.text(value))
    }

    private func finish(_ choice: String) {
        answered = true
        onAnswer(choice)
        dismiss()
    }
}

/// 폰의 화면 좌표 → 맥 화면(frame)의 좌표
enum HandoverGeometry {
    struct Point: Equatable {
        let x: Int
        let y: Int
    }

    static func point(_ location: CGPoint, scale: CGFloat, width: Int, height: Int) -> Point {
        guard scale > 0 else { return Point(x: 0, y: 0) }
        let x = Int((location.x / scale).rounded())
        let y = Int((location.y / scale).rounded())
        return Point(x: min(max(0, x), max(0, width - 1)), y: min(max(0, y), max(0, height - 1)))
    }

    /// 손가락을 위로 쓸면 아래로 스크롤한다 (폰에서 쓰는 방향 그대로)
    static func wheel(_ translationHeight: CGFloat, scale: CGFloat) -> Int {
        guard scale > 0 else { return 0 }
        return Int((-translationHeight / scale).rounded())
    }
}
