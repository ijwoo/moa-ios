import SwiftData
import SwiftUI

/// 회의 상세: 상단 파형·재생 카드 + 대화창 형태의 발화 목록 + TXT 내보내기
///
/// - 말풍선을 누르면 그 구간만 재생한다. ★ 줄을 누르면 북마크 앞뒤 구간을 재생한다.
/// - 파형을 훑거나 재생하면 그 시점의 말풍선을 강조하고 따라 스크롤한다.
/// - 화자 구분은 아직 없다. `Utterance.speaker`가 채워지면 이름이 붙는다.
struct MeetingDetailView: View {
    let meeting: Meeting
    /// 질문 탭의 근거 카드로 들어온 경우: 이 말풍선으로 스크롤하고 강조한다
    var focusUtteranceID: UUID? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var playback = PlaybackController()
    @State private var peaks: [Float] = []
    @State private var isScrubbing = false
    /// 스크롤을 내리면 상단 카드를 얇게 줄인다 (요약·대화를 읽을 공간 확보)
    @State private var isCompact = false

    private enum TimelineItem: Identifiable {
        case utterance(Utterance)
        case bookmark(Bookmark)

        var id: UUID {
            switch self {
            case .utterance(let u): u.id
            case .bookmark(let b): b.id
            }
        }

        var time: TimeInterval {
            switch self {
            case .utterance(let u): u.start
            case .bookmark(let b): b.time
            }
        }
    }

    var body: some View {
        let utterances = meeting.sortedUtterances
        let items = timeline(utterances)
        let active = activeUtterance(in: utterances)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    header
                    SummaryCard(meeting: meeting)
                        .padding(.bottom, 8)

                    if utterances.isEmpty {
                        legacyTranscript
                    }
                    ForEach(items) { item in
                        switch item {
                        case .utterance(let utterance):
                            UtteranceBubble(
                                utterance: utterance,
                                isActive: active?.id == utterance.id,
                                isFocused: focusUtteranceID == utterance.id,
                                isPlayable: playback.isAvailable
                            )
                            .id(utterance.id)
                            .onTapGesture {
                                guard playback.isAvailable else { return }
                                playback.play(from: utterance.start, until: utterance.end)
                            }
                        case .bookmark(let bookmark):
                            BookmarkRow(time: bookmark.time, isPlayable: playback.isAvailable) {
                                let range = Bookmark.range(for: bookmark.time, duration: playback.duration)
                                playback.play(from: range.lowerBound, until: range.upperBound)
                            }
                            .id(bookmark.id)
                        }
                    }

                }
                .padding()
            }
            .background(DS.Colors.background)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 60
            } action: { _, compact in
                withAnimation(.snappy(duration: 0.25)) { isCompact = compact }
            }
            .task {
                // 근거 카드로 들어오면 해당 말풍선으로 이동
                guard let focusUtteranceID else { return }
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeInOut) { proxy.scrollTo(focusUtteranceID, anchor: .center) }
            }
            .onChange(of: active?.id) { _, id in
                guard let id, playback.isPlaying || isScrubbing else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .safeAreaInset(edge: .top) {
            if playback.isAvailable {
                playerCard(activeRange: active.map { $0.start...$0.end })
            }
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: TranscriptFile(meeting: meeting),
                    preview: SharePreview(MeetingText.exportFileName(for: meeting))
                ) {
                    Label("TXT 내보내기", systemImage: "square.and.arrow.up")
                }
            }
        }
        .onAppear {
            playback.load(url: AudioStorage.existingURL(for: meeting))
            #if DEBUG
            if let seek = DemoData.value(after: "-demoSeek").flatMap(Double.init) { playback.seek(to: seek) }
            if DemoData.arguments.contains("-demoSummarize"), meeting.summary == nil {
                Task { await MeetingSummarizer.shared.summarize(meeting, in: modelContext) }
            }
            #endif
        }
        .task { await loadWaveform() }
        .onDisappear { playback.stop() }
    }

    // MARK: - 상단 파형·재생 카드

    @ViewBuilder
    private func playerCard(activeRange: ClosedRange<TimeInterval>?) -> some View {
        if isCompact {
            compactPlayer(activeRange: activeRange)
        } else {
            fullPlayer(activeRange: activeRange)
        }
    }

    /// 스크롤했을 때의 얇은 재생 막대
    private func compactPlayer(activeRange: ClosedRange<TimeInterval>?) -> some View {
        HStack(spacing: 10) {
            Button {
                playback.togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(playback.isPlaying ? "일시정지" : "재생")

            if peaks.isEmpty {
                Slider(
                    value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                    in: 0...max(playback.duration, 0.1)
                )
            } else {
                waveform(activeRange: activeRange)
                    .frame(height: 28)
            }

            Text(MeetingText.timestamp(playback.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func waveform(activeRange: ClosedRange<TimeInterval>?) -> WaveformTimeline {
        WaveformTimeline(
            peaks: peaks,
            duration: playback.duration,
            currentTime: playback.currentTime,
            bookmarkTimes: meeting.sortedBookmarks.map(\.time),
            activeRange: activeRange
        ) { time, ended in
            isScrubbing = !ended
            playback.seek(to: time)
        }
    }

    private func fullPlayer(activeRange: ClosedRange<TimeInterval>?) -> some View {
        VStack(spacing: 8) {
            if peaks.isEmpty {
                Slider(
                    value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                    in: 0...max(playback.duration, 0.1)
                )
            } else {
                waveform(activeRange: activeRange)
            }

            HStack(spacing: 12) {
                Button {
                    playback.togglePlay()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(playback.isPlaying ? "일시정지" : "재생")

                Text("\(MeetingText.timestamp(playback.currentTime)) / \(MeetingText.timestamp(playback.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.Colors.textSecondary)

                Spacer()

                if !meeting.bookmarks.isEmpty {
                    Button {
                        playback.play(ranges: Bookmark.mergedRanges(
                            times: meeting.bookmarks.map(\.time), duration: playback.duration
                        ))
                    } label: {
                        Label(
                            playback.isPlayingHighlights ? "중요 구간 재생 중" : "중요 구간 \(meeting.bookmarks.count)개 듣기",
                            systemImage: BookmarkStyle.icon
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(BookmarkStyle.color)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    // MARK: - 구성 요소

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.date.formatted(.dateTime.year().month().day().weekday().hour().minute()))
                .font(.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
            HStack(spacing: 8) {
                ChipLabel(text: MeetingText.timestamp(meeting.duration), systemImage: "clock")
                if !meeting.bookmarks.isEmpty {
                    ChipLabel(text: "중요 \(meeting.bookmarks.count)", systemImage: BookmarkStyle.icon)
                }
                if meeting.status == .recording && !meeting.isRecordingComplete {
                    ChipLabel(text: "녹음 중단됨", systemImage: "exclamationmark.triangle")
                }
            }
            if !playback.isAvailable {
                Text("이 회의는 저장된 음성이 없어 재생할 수 없습니다.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .padding(.bottom, 8)
    }

    /// 말풍선 기능 이전에 녹음한 회의: 원본 텍스트를 말풍선 하나로 보여준다.
    @ViewBuilder
    private var legacyTranscript: some View {
        if meeting.transcript.isEmpty {
            ContentUnavailableView("받아쓴 내용이 없습니다", systemImage: "text.bubble")
        } else {
            Text(meeting.transcript)
                .textSelection(.enabled)
                .padding(12)
                .background(DS.Colors.secondarySurface, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: - 계산

    private func timeline(_ utterances: [Utterance]) -> [TimelineItem] {
        let items = utterances.map(TimelineItem.utterance) + meeting.bookmarks.map(TimelineItem.bookmark)
        // 같은 시각이면 말풍선 다음에 북마크 (들은 뒤에 누르므로)
        return items.sorted { a, b in
            if a.time != b.time { return a.time < b.time }
            if case .utterance = a { return true }
            return false
        }
    }

    /// 재생 위치가 속한 발화
    private func activeUtterance(in utterances: [Utterance]) -> Utterance? {
        guard playback.isPlaying || isScrubbing || playback.currentTime > 0 else { return nil }
        let t = playback.currentTime
        return utterances.last { $0.start <= t + 0.05 && t < $0.end }
    }

    /// 저장된 파형을 읽는다. 없으면(녹음 도중 종료 등) 음성 파일에서 뽑아 저장한다.
    private func loadWaveform() async {
        if let data = meeting.waveformData {
            peaks = Waveform.decode(data)
            return
        }
        guard let url = AudioStorage.existingURL(for: meeting) else { return }
        let extracted = await Task.detached(priority: .userInitiated) {
            Waveform.extract(from: url)
        }.value
        guard let extracted, !extracted.isEmpty else { return }
        peaks = extracted
        meeting.waveformData = Waveform.encode(extracted)
        try? modelContext.save()
    }
}

private struct UtteranceBubble: View {
    let utterance: Utterance
    let isActive: Bool
    var isFocused = false
    let isPlayable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let speaker = utterance.speaker {
                    Text(speaker).font(.caption.weight(.semibold))
                }
                Text(MeetingText.timestamp(utterance.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.Colors.textSecondary)
                if isPlayable {
                    Image(systemName: isActive ? "speaker.wave.2.fill" : "play.fill")
                        .font(.caption2)
                        .foregroundStyle(isActive ? DS.Colors.accent : DS.Colors.textSecondary)
                }
            }
            .padding(.leading, 4)

            Text(utterance.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isActive ? AnyShapeStyle(DS.Colors.highlightSurface) : AnyShapeStyle(DS.Colors.secondarySurface),
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 18).strokeBorder(DS.Colors.accent, lineWidth: 2)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(isPlayable ? "두 번 탭하면 이 부분을 재생합니다" : "")
    }
}

/// 대화 중간에 끼워 보여주는 "중요" 표시 줄
private struct BookmarkRow: View {
    let time: TimeInterval
    let isPlayable: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 6) {
                Image(systemName: BookmarkStyle.icon).foregroundStyle(BookmarkStyle.color)
                Text("중요 표시 · \(MeetingText.timestamp(time))")
                if isPlayable {
                    Text("· \(Int(Bookmark.leadIn))초 전부터 듣기")
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(BookmarkStyle.color.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isPlayable)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview {
    let container = PreviewData.container
    let meeting = try! container.mainContext.fetch(FetchDescriptor<Meeting>()).first!
    NavigationStack {
        MeetingDetailView(meeting: meeting)
    }
    .modelContainer(container)
}
#endif
