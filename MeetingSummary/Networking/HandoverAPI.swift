import Foundation

// 손 넘기기 (D123, 맥의 D106): 에이전트 브라우저가 사람이 해야 하는 단계(사람 확인 퍼즐 등)를 만나면
// 작업이 질문(["다 했어요", "그만하기"])으로 멈추고, 그 화면을 폰에 띄워 사용자가 직접 누르고 쓴다. 에이전트는 그동안 누르지 않는다.
// 앱 쪽 명세: local-ai-agent docs/API.md "손 넘기기" 절.
//
// - 화면은 `GET /v1/handover/{id}/frame`으로 받아 메모리에서만 그린다 (저장하지 않는다)
// - 누른 곳·쓴 글은 `POST /v1/handover/{id}/input`으로 그대로 보낸다. 쓴 글은 기록하지 않는다
// - 끝은 질문에 "다 했어요"로 답하는 것이다 (작업의 답과 같은 길). 질문이 끝나면 맥은 404를 준다

/// 질문에 붙은 손 넘기기 (`question.handover`)
struct AgentHandover: Codable, Equatable, Sendable {
    /// 주소에 넣는 번호 (`AgentHTTPClient.isPathSafe`). 주소는 맥이 준 문자열이 아니라 이 번호로 앱이 만든다
    let id: String
    /// 왜 사람이 해야 하는지 (맥의 코드가 정한 짧은 말)
    var reason: String?
    /// 그 화면의 사이트 (소문자)
    var host: String?
    /// 입력이 없으면 닫히는 시간(초)
    var idleClose: Int?

    static let reasonLimit = 120
}

/// `handover`를 읽는다. 꼴이 틀리면 없는 것으로 둔다 (그것을 담은 질문·로그인 전체를 버리지 않게).
/// 작업 질문(`question.handover`)과 로그인(`login.handover`, D149)이 같은 꼴이다.
/// `frame`·`input` 주소는 읽지 않는다: 주소는 맥이 준 문자열이 아니라 번호로 앱이 만든다
struct LooseHandover: Decodable, Sendable {
    let value: AgentHandover?

    init(from decoder: Decoder) throws {
        struct Raw: Decodable {
            let id: String?
            let reason: String?
            let host: String?
            let idle_close_s: Double?
        }
        let raw = try? Raw(from: decoder)
        value = AgentHTTPClient.handover(id: raw?.id, reason: raw?.reason, host: raw?.host, idleClose: raw?.idle_close_s)
    }
}

/// 받은 화면 한 장 (CSS 픽셀 크기)
struct HandoverFrame: Equatable, Sendable {
    let image: Data
    let width: Int
    let height: Int

    /// 받는 그림의 크기 한도
    static let maxBytes = 4_000_000
}

/// 화면에 보내는 손짓 하나. 좌표는 화면(frame)의 width·height 기준
enum HandoverInput: Equatable, Sendable {
    case tap(x: Int, y: Int)
    case drag(x: Int, y: Int, x2: Int, y2: Int)
    case wheel(dy: Int, x: Int?, y: Int?)
    case text(String)
    case key(Key)

    enum Key: String, CaseIterable, Sendable {
        case enter = "Enter", backspace = "Backspace", tab = "Tab", escape = "Escape"
        case left = "ArrowLeft", right = "ArrowRight", up = "ArrowUp", down = "ArrowDown"
        case delete = "Delete", space = "Space"
    }

    static let textLimit = 500

    /// 맥에 보내는 본문
    var body: [String: AnyCodableValue] {
        switch self {
        case let .tap(x, y): ["kind": .string("tap"), "x": .int(x), "y": .int(y)]
        case let .drag(x, y, x2, y2): ["kind": .string("drag"), "x": .int(x), "y": .int(y), "x2": .int(x2), "y2": .int(y2)]
        case let .wheel(dy, x, y):
            ["kind": .string("wheel"), "dy": .int(dy)].merging(
                [x.map { ("x", AnyCodableValue.int($0)) }, y.map { ("y", AnyCodableValue.int($0)) }].compactMap { $0 }, uniquingKeysWith: { a, _ in a }
            )
        case let .text(text): ["kind": .string("text"), "text": .string(String(text.prefix(Self.textLimit)))]
        case let .key(key): ["kind": .string("key"), "key": .string(key.rawValue)]
        }
    }
}

/// 본문에 쓰는 작은 값 (글자 · 정수)
enum AnyCodableValue: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        }
    }
}

extension AgentHTTPClient {
    /// `question.handover`를 읽는다. 번호가 주소에 넣을 수 없는 꼴이면 받지 않는다
    static func handover(id: String?, reason: String?, host: String?, idleClose: Double?) -> AgentHandover? {
        guard let id, isPathSafe(id) else { return nil }
        return AgentHandover(
            id: id, reason: ActivityDecoding.clean(reason, limit: AgentHandover.reasonLimit),
            host: host.flatMap(cleanHost), idleClose: idleClose.map { Int(max(0, $0)) }
        )
    }

    static func decodeHandoverFrame(data: Data, status: Int) throws -> HandoverFrame {
        struct Wrapper: Decodable {
            let jpeg_b64: String
            let width: Double
            let height: Double
        }
        guard (200..<300).contains(status) else { throw decodeError(data: data, status: status) }
        guard let dto = try? JSONDecoder().decode(Wrapper.self, from: data),
              dto.width >= 1, dto.height >= 1, dto.width <= 10_000, dto.height <= 10_000,
              dto.jpeg_b64.utf8.count <= HandoverFrame.maxBytes * 4 / 3 + 4,
              let image = Data(base64Encoded: dto.jpeg_b64), !image.isEmpty, image.count <= HandoverFrame.maxBytes,
              AgentAttachment.isImage(image) else { throw AgentError.invalidResponse }
        return HandoverFrame(image: image, width: Int(dto.width), height: Int(dto.height))
    }
}
