import Foundation

/// 프록시 /v1/ask 요청: 질문 + 이전 대화 + 고른 회의 자료
struct AskRequest: Encodable, Equatable, Sendable {
    struct Turn: Encodable, Equatable, Sendable {
        enum Role: String, Encodable, Sendable { case user, assistant }
        let role: Role
        let text: String
    }

    struct Utterance: Encodable, Equatable, Sendable {
        let ref: String
        let start: TimeInterval
        let text: String
    }

    struct Meeting: Encodable, Equatable, Sendable {
        let ref: String
        let title: String
        let date: String
        let summary: String?
        let utterances: [Utterance]
    }

    struct ListedMeeting: Encodable, Equatable, Sendable {
        let ref: String
        let title: String
        let date: String
        let topic: String?
    }

    /// 답장이면 인용한 말이 앞에 붙는다 (`AskSession.questionWithQuote`)
    var question: String
    let history: [Turn]
    let meetings: [Meeting]
    let otherMeetings: [ListedMeeting]
    /// 답변 말투 ("friendly"·"formal"). 모르는 프록시는 무시한다
    var tone: String?
    /// 오늘 날짜 (예: "11월 12일 (목)"). "오늘", "어제" 같은 말을 읽는 기준. 모르는 프록시는 무시한다
    var today: String?
    /// 질문이 "오늘 회의"처럼 회의한 날을 직접 가리킨 경우. 모르는 프록시는 무시한다
    var day: Day?

    /// 질문이 가리킨 날
    struct Day: Encodable, Equatable, Sendable {
        /// 예: "오늘(11월 12일)"
        let label: String
        /// 그 날 녹음한 회의가 있는지. 있으면 `meetings`에는 그 날 회의만 담는다
        let found: Bool
    }

    enum CodingKeys: String, CodingKey {
        case question, history, meetings, tone, today, day
        case otherMeetings = "other_meetings"
    }
}

/// 답변. citations는 요청에 담은 말풍선 번호(ref)
struct AskAnswerDTO: Decodable, Equatable, Sendable {
    let answer: String
    let found: Bool
    let citations: [String]
}

protocol AskProviding: Sendable {
    func ask(_ request: AskRequest) async throws -> AskAnswerDTO
}

extension SummaryAPI: AskProviding {
    func ask(_ request: AskRequest) async throws -> AskAnswerDTO {
        let (data, status) = try await post(path: "v1/ask", body: request, timeout: 90)
        return try Self.decodeAnswer(data: data, status: status)
    }

    static func decodeAnswer(data: Data, status: Int) throws -> AskAnswerDTO {
        struct Success: Decodable { let answer: AskAnswerDTO }
        if status == 200 {
            guard let success = try? JSONDecoder().decode(Success.self, from: data) else {
                throw SummaryAPIError.invalidResponse
            }
            return success.answer
        }
        throw decodeError(data: data, status: status)
    }
}
