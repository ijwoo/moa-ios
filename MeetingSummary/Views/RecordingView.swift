import SwiftData
import SwiftUI
import UIKit

/// 녹음 화면 (실시간 받아쓰기)
///
/// 화면에 들어오면 바로 녹음을 시작한다. 문장이 확정될 때마다 저장하므로
/// 앱이 중간에 종료되어도 마지막으로 확정된 문장까지 남는다.
///
/// 구성: 위 — 상태·시간·실시간 파형 카드 / 가운데 — 받아쓴 말풍선 / 아래 — ★ 중요 · ■ 종료
struct RecordingView: View {
    let onFinish: (Meeting) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var service = TranscriptionService()
    @State private var meeting: Meeting?
    @State private var startError: String?
    @State private var bookmarkCount = 0
    /// 잠깐 보여주는 "중요 표시됨" 알림
    @State private var bookmarkToast: TimeInterval?
    @State private var confirmingStop = false

    var body: some View {
        VStack(spacing: 0) {
            if let message = startError ?? failureMessage {
                ContentUnavailableView("녹음할 수 없습니다", systemImage: "exclamationmark.triangle", description: Text(message))
            } else if case .preparing(let message) = service.state {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text(message)
                }
            } else {
                heroCard
                    .padding(.horizontal)
                    .padding(.top, 8)
                transcriptList
                    .overlay(alignment: .top) { toast }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if startError == nil && failureMessage == nil {
                controls
            }
        }
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: bookmarkCount)
        // 녹음이 시작되고 끝날 때 (D114). 화면을 보지 않아도 알 수 있게
        .sensoryFeedback(trigger: service.state) { old, new in
            guard old != new else { return nil }
            switch new {
            case .recording: return .start
            case .stopping: return .stop
            default: return nil
            }
        }
        .navigationTitle(meeting?.title ?? "새 회의")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // 녹음을 시작하지 못했거나 중단된 경우에만 닫을 수 있다.
            if startError != nil || failureMessage != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .confirmationDialog("녹음을 종료할까요?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("종료하고 요약") { Task { await stop() } }
            Button("계속 녹음", role: .cancel) {}
        } message: {
            Text("종료하면 받아쓴 내용으로 요약을 만듭니다.")
        }
        .task { await start() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: - 위: 상태·시간·파형

    private var heroCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                RecordingDot(isActive: service.state == .recording)
                Text(statusText)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Label("기기 내 인식", systemImage: "lock.iphone")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }

            Text(MeetingText.timestamp(service.elapsed))
                .font(.system(size: 52, weight: .light, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity)

            LiveWaveform(levels: service.recentLevels, isActive: service.state == .recording)
                .frame(height: 56)
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
    }

    // MARK: - 가운데: 받아쓴 말풍선

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if service.utterances.isEmpty && service.volatileText.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "text.bubble")
                                .font(.title2)
                            Text(service.state == .recording ? "말하면 여기에 받아쓴 내용이 나타납니다" : "")
                                .font(.subheadline)
                        }
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    }
                    ForEach(service.utterances) { utterance in
                        bubble(utterance.text, time: utterance.start, isFinal: true)
                    }
                    if !service.volatileText.isEmpty {
                        bubble(service.volatileText, time: nil, isFinal: false)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 16)
            }
            .scrollIndicators(.hidden)
            .onChange(of: service.utterances.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: service.volatileText) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func bubble(_ text: String, time: TimeInterval?, isFinal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(time.map(MeetingText.timestamp) ?? "받아쓰는 중")
                .font(.caption.monospacedDigit())
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.leading, 4)
            Text(text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(DS.Colors.secondarySurface, in: RoundedRectangle(cornerRadius: 18))
                .opacity(isFinal ? 1 : 0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)
    }

    @ViewBuilder
    private var toast: some View {
        if let time = bookmarkToast {
            Label("\(MeetingText.timestamp(time)) 중요 표시됨", systemImage: BookmarkStyle.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(BookmarkStyle.color, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - 아래: ★ 중요 · ■ 종료

    private var controls: some View {
        HStack(alignment: .top) {
            // 화면을 보지 않고도 누를 수 있도록 크게, 종료 버튼과 떨어뜨려 둔다.
            ControlButton(
                title: bookmarkCount > 0 ? "중요 \(bookmarkCount)" : "여기 중요",
                isEnabled: service.state == .recording,
                action: addBookmark
            ) {
                Circle().fill(BookmarkStyle.color)
                Image(systemName: BookmarkStyle.icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHint("지금 시점을 중요 구간으로 표시합니다")

            Spacer()

            ControlButton(
                title: service.state == .stopping ? "마무리 중…" : "종료",
                isEnabled: service.state == .recording,
                action: { confirmingStop = true }
            ) {
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 4)
                RoundedRectangle(cornerRadius: 8)
                    .fill(.red)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("녹음 종료")
        }
        .padding(.horizontal, 48)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36))
        .padding(.horizontal)
    }

    private var statusText: String {
        switch service.state {
        case .idle, .preparing: "준비 중"
        case .recording: "녹음 중"
        case .stopping: "마무리 중"
        case .finished: "녹음 완료"
        case .failed: "녹음 중단"
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = service.state { return message }
        return nil
    }

    // MARK: - 동작

    private func start() async {
        guard service.state == .idle, meeting == nil else { return }
        #if DEBUG
        if DemoData.arguments.contains("-demoRecording") {
            service.startDemo()
            if DemoData.arguments.contains("-demoBookmark") {
                try? await Task.sleep(for: .seconds(2.5))
                bookmarkCount = 2
                withAnimation { bookmarkToast = 82 }
            }
            return
        }
        #endif
        let meeting = Meeting(title: Self.defaultTitle())
        let fileName = AudioStorage.newFileName(for: meeting.id)
        meeting.audioFileName = fileName
        modelContext.insert(meeting)
        save()
        self.meeting = meeting

        service.onUtterance = { live in
            meeting.appendUtterance(Utterance(start: live.start, end: live.end, text: live.text))
            meeting.duration = service.elapsed
            meeting.waveformData = Waveform.encode(service.waveformSnapshot())
            save()
        }

        do {
            try await service.start(audioURL: AudioStorage.url(fileName: fileName))
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            startError = error.localizedDescription
            // 아무것도 녹음하지 못한 빈 회의는 남기지 않는다.
            AudioStorage.deleteAudio(for: meeting)
            modelContext.delete(meeting)
            save()
            self.meeting = nil
        }
    }

    private func stop() async {
        await service.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        guard let meeting else { return }
        meeting.duration = service.elapsed
        meeting.isRecordingComplete = true
        meeting.recognitionLog = service.diagnosticsText
        meeting.waveformData = Waveform.encode(service.waveformSnapshot())

        // 실수로 누른 녹음(5초 미만, 받아쓴 내용 없음)은 남기지 않는다.
        if meeting.duration < 5 && meeting.utterances.isEmpty {
            AudioStorage.deleteAudio(for: meeting)
            modelContext.delete(meeting)
            save()
            dismiss()
            return
        }
        save()
        onFinish(meeting)
        // 요약할 만큼 내용이 있을 때만 바로 요약한다. 화면을 닫아도 끝까지 진행된다.
        guard SummaryRequest(meeting: meeting).isSummarizable else { return }
        let context = modelContext
        Task { await MeetingSummarizer.shared.summarize(meeting, in: context) }
    }

    private func addBookmark() {
        guard service.state == .recording, let meeting else { return }
        let time = service.currentAudioTime
        meeting.bookmarks.append(Bookmark(time: time))
        save()
        bookmarkCount += 1
        withAnimation(.spring(duration: 0.3)) { bookmarkToast = time }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if bookmarkToast == time {
                withAnimation { bookmarkToast = nil }
            }
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            // 저장 실패는 화면 흐름을 막지 않되 기록은 남긴다.
            print("저장 실패: \(error)")
        }
    }

    static func defaultTitle(date: Date = .now) -> String {
        "회의 " + date.formatted(.dateTime.month().day().hour().minute())
    }
}

/// 원형 조작 버튼 + 아래 이름
private struct ControlButton<Face: View>: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
    @ViewBuilder let face: () -> Face

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack { face() }
                    .frame(width: 76, height: 76)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// 녹음 중 깜빡이는 빨간 점
private struct RecordingDot: View {
    let isActive: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(isActive ? .red : .gray)
            .frame(width: 10, height: 10)
            .opacity(isActive && dim ? 0.3 : 1)
            .animation(isActive ? .easeInOut(duration: 0.8).repeatForever() : .default, value: dim)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}

/// 실시간 파형: 최근 몇 초의 음량을 가운데 기준 막대로 흘려 보여준다.
private struct LiveWaveform: View {
    let levels: [Float]
    let isActive: Bool

    var body: some View {
        Canvas { context, size in
            let count = 60
            let gap: CGFloat = 2
            let barWidth = max(1, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let padded = Array(repeating: Float(0), count: max(0, count - levels.count)) + levels.suffix(count)
            for (i, level) in padded.enumerated() {
                let height = max(4, CGFloat(level) * size.height)
                let rect = CGRect(
                    x: CGFloat(i) * (barWidth + gap),
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                // 오래된 소리일수록 옅게
                let age = Double(i) / Double(count)
                let color: Color = isActive ? .red.opacity(0.35 + 0.65 * age) : .gray.opacity(0.4)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}
