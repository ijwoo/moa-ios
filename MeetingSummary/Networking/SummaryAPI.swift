import Foundation
import UIKit

/// 프록시(`https://meeting-api.example.com`)로 보내는 요약 요청. Claude API 키는 앱에 없다.
struct SummaryRequest: Encodable, Equatable {
    struct Item: Encodable, Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    let title: String
    let utterances: [Item]
    /// 발화가 없는 예전 회의용 원본 텍스트
    let transcript: String?
    /// "여기 중요"를 누른 시각들
    let bookmarks: [TimeInterval]

    @MainActor
    init(meeting: Meeting) {
        title = meeting.title
        utterances = meeting.sortedUtterances.map { Item(start: $0.start, end: $0.end, text: $0.text) }
        transcript = utterances.isEmpty ? meeting.transcript : nil
        bookmarks = meeting.sortedBookmarks.map(\.time)
    }

    /// 요약할 가치가 있는 최소 분량 (공백 제외 글자 수). 프록시와 같은 기준.
    static let minContentCharacters = 30

    /// 공백을 뺀 받아쓴 글자 수
    var contentLength: Int {
        let text = utterances.isEmpty ? (transcript ?? "") : utterances.map(\.text).joined()
        return text.filter { !$0.isWhitespace }.count
    }

    /// 너무 짧은 녹음(잡음 한 마디 등)은 요약하지 않는다 (API 비용 보호)
    var isSummarizable: Bool { contentLength >= Self.minContentCharacters }
}

/// Claude가 돌려주는 요약 JSON (스펙의 응답 형식)
struct SummaryDTO: Decodable, Equatable, Sendable {
    struct ActionItemDTO: Decodable, Equatable, Sendable {
        let task: String
        let owner: String?
        let due: String?
    }

    let topic: String
    let summary: String
    let decisions: [String]
    let actionItems: [ActionItemDTO]
    let openQuestions: [String]

    enum CodingKeys: String, CodingKey {
        case topic, summary, decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }
}

enum SummaryAPIError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case network(String)
    /// 프록시가 돌려준 오류 (code는 프록시와 약속한 값)
    case server(code: String, message: String, retryable: Bool)
    /// 응답을 해석하지 못함 (형식 오류)
    case invalidResponse

    /// 형식 오류만 한 번 다시 요청한다 (스펙: 파싱 실패 시 1회 재요청)
    var isFormatError: Bool {
        switch self {
        case .invalidResponse: true
        case .server(let code, _, _): code == "invalid_output"
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured: "요약 서버 설정이 없습니다. (앱 빌드 설정 확인 필요)"
        case .offline: "인터넷에 연결되어 있지 않습니다. 연결을 확인한 뒤 다시 요약하세요."
        case .network(let message): "요약 서버와 통신하지 못했습니다. (\(message))"
        case .server(_, let message, _): message
        case .invalidResponse: "요약 결과를 해석하지 못했습니다."
        }
    }
}

/// 테스트에서 가짜로 바꿔 끼울 수 있게 프로토콜로 둔다.
protocol SummaryProviding: Sendable {
    func summarize(_ request: SummaryRequest) async throws -> SummaryDTO
}

struct SummaryAPI: SummaryProviding {
    let baseURL: URL
    let token: String
    let deviceID: String
    var session: URLSession = .shared

    /// Info.plist(MSProxyHost, MSProxyToken)에서 읽는다. 값이 없으면 nil.
    @MainActor
    static func fromBundle(_ bundle: Bundle = .main) -> SummaryAPI? {
        guard let host = bundle.object(forInfoDictionaryKey: "MSProxyHost") as? String, !host.isEmpty,
              let token = bundle.object(forInfoDictionaryKey: "MSProxyToken") as? String, !token.isEmpty,
              let url = URL(string: "https://\(host)")
        else { return nil }
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        return SummaryAPI(baseURL: url, token: token, deviceID: deviceID)
    }

    func summarize(_ request: SummaryRequest) async throws -> SummaryDTO {
        // 1시간 회의는 1~2분 걸릴 수 있다
        let (data, status) = try await post(path: "v1/summarize", body: request, timeout: 180)
        return try Self.decode(data: data, status: status)
    }

    /// 공통 전송: 인증 헤더, 기기 ID, 네트워크 오류 변환
    func post(path: String, body: some Encodable, timeout: TimeInterval) async throws -> (Data, Int) {
        var urlRequest = URLRequest(url: baseURL.appending(path: path))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: urlRequest)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw SummaryAPIError.offline
        } catch let error as URLError {
            throw SummaryAPIError.network(error.localizedDescription)
        }
    }

    /// 요약 응답 해석: 200이면 `{summary: {...}}`, 아니면 `{error: {code, message, retryable}}`
    static func decode(data: Data, status: Int) throws -> SummaryDTO {
        struct Success: Decodable { let summary: SummaryDTO }
        if status == 200 {
            guard let success = try? JSONDecoder().decode(Success.self, from: data) else {
                throw SummaryAPIError.invalidResponse
            }
            return success.summary
        }
        throw decodeError(data: data, status: status)
    }

    /// 프록시 오류 응답 → SummaryAPIError
    static func decodeError(data: Data, status: Int) -> SummaryAPIError {
        struct Failure: Decodable {
            struct Body: Decodable { let code: String; let message: String; let retryable: Bool? }
            let error: Body
        }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            return .server(code: failure.error.code, message: failure.error.message, retryable: failure.error.retryable ?? false)
        }
        return .server(code: "http_\(status)", message: "요약 서버 오류입니다. (HTTP \(status))", retryable: status >= 500)
    }
}
