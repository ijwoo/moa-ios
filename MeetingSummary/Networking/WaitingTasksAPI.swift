import Foundation

/// 내 답을 기다리는 작업 하나 (`GET /v1/tasks?status=…`, D113)
struct AgentWaitingTask: Equatable, Sendable, Identifiable {
    static let statuses = ["awaiting_approval", "awaiting_input"]

    var id: String
    var isApproval: Bool
    var title: String
    var conversationID: String?

    /// 거르기를 모르는 맥(서버를 다시 띄우기 전)은 모든 작업을 주므로 앱에서도 거른다
    static func decode(data: Data, status: Int) throws -> [AgentWaitingTask] {
        struct Row: Decodable {
            let id: String
            let status: String?
            let task: String?
            let title: String?
            let conversation_id: String?
        }
        struct Lossy: Decodable {
            let value: Row?
            init(from decoder: Decoder) throws { value = try? Row(from: decoder) }
        }
        struct Wrapper: Decodable { let tasks: [Lossy] }
        guard (200..<300).contains(status) else { throw AgentHTTPClient.decodeError(data: data, status: status) }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { throw AgentError.invalidResponse }
        return wrapper.tasks.compactMap(\.value).compactMap { row in
            guard let status = row.status, statuses.contains(status), AgentHTTPClient.isPathSafe(row.id) else { return nil }
            let title = [row.title, row.task].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "맥의 작업"
            let conversation = row.conversation_id.flatMap { AgentHTTPClient.isPathSafe($0) ? $0 : nil }
            return AgentWaitingTask(
                id: row.id, isApproval: status == "awaiting_approval",
                title: String(title.split(separator: "\n").first.map(String.init)?.prefix(60) ?? ""), conversationID: conversation
            )
        }
    }
}
