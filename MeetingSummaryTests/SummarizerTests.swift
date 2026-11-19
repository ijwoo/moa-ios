import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

/// 정해 둔 결과를 차례로 돌려주는 가짜 요약 서버
final class FakeProvider: SummaryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<SummaryDTO, SummaryAPIError>]
    private(set) var requests: [SummaryRequest] = []

    init(_ results: [Result<SummaryDTO, SummaryAPIError>]) { self.results = results }

    var callCount: Int { lock.withLock { requests.count } }

    func summarize(_ request: SummaryRequest) async throws -> SummaryDTO {
        try lock.withLock {
            requests.append(request)
            return try results.removeFirst().get()
        }
    }
}

let sampleDTO = SummaryDTO(
    topic: "출시 일정",
    summary: "베타 출시 일정을 정했다.",
    decisions: ["12월 첫째 주 출시", "  "],
    actionItems: [
        .init(task: "시안 전달", owner: "지원 씨", due: "금요일"),
        .init(task: "부하 테스트", owner: nil, due: " "),
        .init(task: " ", owner: nil, due: nil),
    ],
    openQuestions: ["결제 방식 미정"]
)

@MainActor
struct SummarizerTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func recordedMeeting() -> Meeting {
        let meeting = Meeting(title: "면담")
        context.insert(meeting)
        meeting.appendUtterance(Utterance(start: 0, end: 5, text: "베타 출시는 12월 첫째 주로 확정했고 디자인 시안은 금요일까지 전달합니다."))
        meeting.bookmarks.append(Bookmark(time: 4))
        meeting.isRecordingComplete = true
        return meeting
    }

    @Test func successMovesToReadyWithSummary() async {
        let provider = FakeProvider([.success(sampleDTO)])
        let meeting = recordedMeeting()
        await MeetingSummarizer(provider: provider).summarize(meeting, in: context)

        #expect(meeting.status == .ready)
        let summary = try! #require(meeting.summary)
        #expect(summary.topic == "출시 일정")
        #expect(summary.decisions == ["12월 첫째 주 출시"]) // 빈 항목 제거
        #expect(summary.sortedActionItems.map(\.task) == ["시안 전달", "부하 테스트"])
        #expect(summary.sortedActionItems[1].owner == nil)
        #expect(summary.sortedActionItems[1].dueText == nil) // 공백 기한은 nil
        #expect(provider.requests.first?.bookmarks == [4])
        #expect(provider.requests.first?.utterances.first?.text.hasPrefix("베타 출시는") == true)
    }

    @Test func formatErrorIsRetriedOnce() async {
        let provider = FakeProvider([.failure(.invalidResponse), .success(sampleDTO)])
        let meeting = recordedMeeting()
        await MeetingSummarizer(provider: provider).summarize(meeting, in: context)
        #expect(provider.callCount == 2)
        #expect(meeting.status == .ready)
    }

    @Test func secondFormatErrorFailsAndKeepsTranscript() async {
        let provider = FakeProvider([
            .failure(.server(code: "invalid_output", message: "형식 오류", retryable: true)),
            .failure(.invalidResponse),
        ])
        let meeting = recordedMeeting()
        await MeetingSummarizer(provider: provider).summarize(meeting, in: context)
        #expect(provider.callCount == 2)
        #expect(meeting.status == .failed)
        #expect(meeting.failureMessage == SummaryAPIError.invalidResponse.localizedDescription)
        #expect(meeting.summary == nil)
        #expect(meeting.transcript.hasPrefix("베타 출시는"))
    }

    @Test func networkErrorIsNotRetried() async {
        let provider = FakeProvider([.failure(.offline)])
        let meeting = recordedMeeting()
        await MeetingSummarizer(provider: provider).summarize(meeting, in: context)
        #expect(provider.callCount == 1)
        #expect(meeting.status == .failed)
        #expect(meeting.failureMessage?.contains("인터넷") == true)
    }

    @Test func tooShortMeetingIsNotSent() async {
        let provider = FakeProvider([])
        let empty = Meeting(title: "빈 회의")
        let noise = Meeting(title: "잡음")
        context.insert(empty)
        context.insert(noise)
        noise.appendUtterance(Utterance(start: 0, end: 1, text: "네 음 그"))
        let summarizer = MeetingSummarizer(provider: provider)
        await summarizer.summarize(empty, in: context)
        await summarizer.summarize(noise, in: context)
        #expect(provider.callCount == 0)
        // 실패가 아니라 "요약할 것이 없음"이므로 상태를 바꾸지 않는다
        #expect(empty.status == .recording)
        #expect(noise.status == .recording)
        #expect(!SummaryRequest(meeting: noise).isSummarizable)
    }

    @Test func contentLengthIgnoresWhitespace() {
        let meeting = Meeting(title: "t")
        context.insert(meeting)
        meeting.appendUtterance(Utterance(start: 0, end: 1, text: String(repeating: "가 ", count: 29)))
        #expect(SummaryRequest(meeting: meeting).contentLength == 29)
        #expect(!SummaryRequest(meeting: meeting).isSummarizable)
        meeting.appendUtterance(Utterance(start: 1, end: 2, text: "나"))
        #expect(SummaryRequest(meeting: meeting).isSummarizable)
    }

    @Test func failedMeetingCanBeResummarized() async {
        let provider = FakeProvider([.failure(.offline), .success(sampleDTO)])
        let summarizer = MeetingSummarizer(provider: provider)
        let meeting = recordedMeeting()
        await summarizer.summarize(meeting, in: context)
        #expect(meeting.status == .failed)
        await summarizer.summarize(meeting, in: context)
        #expect(meeting.status == .ready)
        #expect(meeting.failureMessage == nil)
    }

    @Test func resummarizeReplacesOldSummary() async throws {
        var second = sampleDTO
        second = SummaryDTO(topic: "새 주제", summary: "새 요약", decisions: [], actionItems: [], openQuestions: [])
        let provider = FakeProvider([.success(sampleDTO), .success(second)])
        let summarizer = MeetingSummarizer(provider: provider)
        let meeting = recordedMeeting()
        await summarizer.summarize(meeting, in: context)
        await summarizer.summarize(meeting, in: context)
        #expect(meeting.summary?.topic == "새 주제")
        #expect(try context.fetchCount(FetchDescriptor<Summary>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ActionItem>()) == 0)
    }

    @Test func oldMeetingSendsTranscript() async {
        let provider = FakeProvider([.success(sampleDTO)])
        let meeting = Meeting(title: "예전 회의", transcript: "구간 방식으로 받아쓴 예전 회의 텍스트입니다. 출시 일정과 담당자를 논의했습니다.")
        context.insert(meeting)
        await MeetingSummarizer(provider: provider).summarize(meeting, in: context)
        #expect(provider.requests.first?.transcript?.hasPrefix("구간 방식") == true)
        #expect(provider.requests.first?.utterances.isEmpty == true)
    }

    @Test func interruptedProcessingIsRecoveredAsFailed() throws {
        let meeting = recordedMeeting()
        try meeting.transition(to: .processing)
        try context.save()
        MeetingSummarizer.recoverInterrupted(in: context)
        #expect(meeting.status == .failed)
        #expect(meeting.failureMessage?.contains("중단") == true)
    }
}

struct SummaryAPIDecodeTests {
    @Test func decodesSnakeCaseSuccess() throws {
        let json = """
        {"summary":{"topic":"t","summary":"s","decisions":["d"],
        "action_items":[{"task":"a","owner":null,"due":"금요일"}],"open_questions":[]}}
        """
        let dto = try SummaryAPI.decode(data: Data(json.utf8), status: 200)
        #expect(dto.actionItems == [.init(task: "a", owner: nil, due: "금요일")])
    }

    @Test func decodesServerError() {
        let json = #"{"error":{"code":"upstream_busy","message":"바쁩니다","retryable":true}}"#
        #expect(throws: SummaryAPIError.server(code: "upstream_busy", message: "바쁩니다", retryable: true)) {
            try SummaryAPI.decode(data: Data(json.utf8), status: 503)
        }
    }

    @Test func malformedSuccessIsFormatError() {
        #expect(throws: SummaryAPIError.invalidResponse) {
            try SummaryAPI.decode(data: Data("{\"summary\":{}}".utf8), status: 200)
        }
        #expect(SummaryAPIError.invalidResponse.isFormatError)
        #expect(SummaryAPIError.server(code: "invalid_output", message: "", retryable: true).isFormatError)
        #expect(!SummaryAPIError.offline.isFormatError)
    }

    @Test func unknownErrorBodyFallsBackToHTTPStatus() {
        #expect(throws: SummaryAPIError.server(code: "http_502", message: "요약 서버 오류입니다. (HTTP 502)", retryable: true)) {
            try SummaryAPI.decode(data: Data("<html>".utf8), status: 502)
        }
    }
}
