import SwiftData
import SwiftUI

/// 회의 탭 (보관함): 지난 회의 목록(날짜 최신순)과 검색
struct MeetingsView: View {
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Environment(\.modelContext) private var modelContext
    @State private var query = ""
    @State private var path: [Meeting] = []

    private var results: [Meeting] {
        meetings.filter { MeetingText.matches($0, query: query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !results.isEmpty {
                    Section(query.isEmpty ? "최근 회의" : "검색 결과 \(results.count)개") {
                        ForEach(results) { meeting in
                            NavigationLink(value: meeting) {
                                MeetingRow(meeting: meeting)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            // 할 일·내 정보 탭과 같은 바탕색
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "제목, 요약, 대화 내용 검색")
            .overlay {
                if !query.isEmpty && results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if meetings.isEmpty {
                    ContentUnavailableView(
                        "회의 기록이 없습니다",
                        systemImage: "archivebox",
                        description: Text("질문 탭의 녹음 버튼으로 첫 회의를 녹음하세요.")
                    )
                }
            }
            .navigationTitle("회의")
            .navigationDestination(for: Meeting.self) { meeting in
                MeetingDetailView(meeting: meeting)
            }
            #if DEBUG
            .onAppear {
                if let search = DemoData.value(after: "-demoSearch") { query = search }
                if DemoData.arguments.contains("-demoOpenDetail"), path.isEmpty, let first = meetings.first {
                    path = [first]
                }
            }
            #endif
        }
    }

    /// 회의를 지우면 저장된 음성 파일도 함께 지운다.
    private func delete(at offsets: IndexSet) {
        for meeting in offsets.map({ results[$0] }) {
            AudioStorage.deleteAudio(for: meeting)
            modelContext.delete(meeting)
        }
        try? modelContext.save()
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            // 아이콘 열 28 + 간격 12 (CardRow와 같은 기준)
            Image(systemName: isInterrupted ? "exclamationmark.bubble" : "text.bubble")
                .font(.body.weight(.medium))
                .foregroundStyle(isInterrupted ? DS.Colors.warning : DS.Colors.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    /// 녹음을 정상 종료하지 못한 회의 (앱이 녹음 도중 종료됨)
    private var isInterrupted: Bool {
        meeting.status == .recording && !meeting.isRecordingComplete
    }

    /// 한 줄 미리보기: 날짜 · 상태 · 요약(없으면 원본 텍스트 앞부분)
    private var subtitle: String {
        var parts: [String] = [meeting.date.formatted(.dateTime.month().day().weekday())]
        parts.append(MeetingText.timestamp(meeting.duration))
        if isInterrupted {
            parts.append("녹음 중단됨")
        } else if meeting.status == .processing {
            parts.append("요약 중")
        } else if meeting.status == .failed {
            parts.append("요약 실패")
        }
        let preview = meeting.summary?.body ?? meeting.transcript
        if !preview.isEmpty { parts.append(preview) }
        return parts.joined(separator: " · ")
    }
}

#if DEBUG
#Preview("회의") {
    MeetingsView()
        .modelContainer(PreviewData.container)
}

#Preview("회의 - 빈 상태") {
    MeetingsView()
        .modelContainer(for: Meeting.self, inMemory: true)
}
#endif
