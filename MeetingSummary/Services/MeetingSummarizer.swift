import Foundation
import Observation
import SwiftData

/// 회의 요약 흐름: 상태 전이(→ 요약 중 → 완료/실패), 형식 오류 시 1회 재요청, 결과 저장.
///
/// 앱 전체에서 하나만 쓴다. 화면을 벗어나도 요약이 끝까지 진행되도록 화면이 아니라 여기서 작업을 들고 있다.
@MainActor
@Observable
final class MeetingSummarizer {
    static let shared = MeetingSummarizer(provider: SummaryAPI.fromBundle())

    private let provider: (any SummaryProviding)?
    private var running: Set<UUID> = []

    init(provider: (any SummaryProviding)?) {
        self.provider = provider
    }

    func isRunning(_ meeting: Meeting) -> Bool {
        running.contains(meeting.id)
    }

    /// 요약을 시작하고 끝날 때까지 기다린다. 이미 진행 중이면 아무것도 하지 않는다.
    func summarize(_ meeting: Meeting, in context: ModelContext) async {
        guard !running.contains(meeting.id) else { return }
        running.insert(meeting.id)
        defer { running.remove(meeting.id) }

        let request = SummaryRequest(meeting: meeting)
        // 내용이 너무 짧으면 서버를 부르지 않는다. 상태도 바꾸지 않는다 (실패가 아니라 "요약할 것이 없음").
        guard request.isSummarizable else { return }
        guard let provider else {
            fail(meeting, SummaryAPIError.notConfigured.localizedDescription, in: context)
            return
        }

        do {
            try meeting.transition(to: .processing)
        } catch {
            return // 이미 요약 중인 상태 등
        }
        save(context)

        do {
            let dto = try await Self.requestWithRetry(provider, request)
            apply(dto, to: meeting, in: context)
            try meeting.transition(to: .ready)
            save(context)
        } catch {
            // 실패해도 원본 텍스트는 그대로 남는다.
            fail(meeting, error.localizedDescription, in: context)
        }
    }

    /// 형식 오류(파싱 실패)일 때만 한 번 더 요청한다.
    nonisolated static func requestWithRetry(
        _ provider: any SummaryProviding, _ request: SummaryRequest
    ) async throws -> SummaryDTO {
        do {
            return try await provider.summarize(request)
        } catch let error as SummaryAPIError where error.isFormatError {
            return try await provider.summarize(request)
        }
    }

    /// 앱이 요약 도중 종료되면 "요약 중"에 멈춘 회의가 남는다. 시작할 때 실패로 바꿔 다시 시도할 수 있게 한다.
    static func recoverInterrupted(in context: ModelContext) {
        let processing = MeetingStatus.processing.rawValue
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.statusRaw == processing })
        guard let stuck = try? context.fetch(descriptor), !stuck.isEmpty else { return }
        for meeting in stuck {
            try? meeting.transition(to: .failed, failureMessage: "요약이 중단되었습니다. 다시 요약하세요.")
        }
        try? context.save()
    }

    // MARK: -

    private func apply(_ dto: SummaryDTO, to meeting: Meeting, in context: ModelContext) {
        // 다시 요약하면 이전 요약을 바꾼다.
        if let old = meeting.summary {
            meeting.summary = nil
            context.delete(old)
        }
        meeting.summary = SummaryMapper.makeSummary(from: dto)
    }

    private func fail(_ meeting: Meeting, _ message: String, in context: ModelContext) {
        if meeting.status == .failed {
            meeting.failureMessage = message
        } else {
            try? meeting.transition(to: .failed, failureMessage: message)
        }
        save(context)
    }

    private func save(_ context: ModelContext) {
        do { try context.save() } catch { print("저장 실패: \(error)") }
    }
}

/// 요약 JSON → 저장 모델
enum SummaryMapper {
    static func makeSummary(from dto: SummaryDTO) -> Summary {
        Summary(
            topic: clean(dto.topic) ?? "",
            body: clean(dto.summary) ?? "",
            decisions: dto.decisions.compactMap(clean),
            actionItems: dto.actionItems.enumerated().compactMap { index, item in
                guard let task = clean(item.task) else { return nil }
                // 담당자·기한은 비어 있으면 nil (추측해서 채우지 않는다)
                return ActionItem(task: task, owner: clean(item.owner), dueText: clean(item.due), order: index)
            },
            openQuestions: dto.openQuestions.compactMap(clean)
        )
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
