import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 회의 검색과 TXT 내보내기에 쓰는 텍스트 처리
enum MeetingText {
    /// 제목·요약·원본 텍스트에서 검색어를 찾는다. 대소문자는 구분하지 않는다.
    static func matches(_ meeting: Meeting, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let fields = [meeting.title, meeting.summary?.topic, meeting.summary?.body, meeting.transcript]
        return fields.contains { field in
            guard let field else { return false }
            return field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// "MM:SS" 또는 한 시간이 넘으면 "H:MM:SS"
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// TXT 내보내기 본문
    static func exportText(for meeting: Meeting) -> String {
        var lines: [String] = [
            meeting.title,
            "일시: " + meeting.date.formatted(.dateTime.year().month().day().hour().minute()),
            "녹음 길이: " + timestamp(meeting.duration),
            "",
        ]

        if let summary = meeting.summary {
            lines.append("[요약]")
            if !summary.topic.isEmpty { lines.append("주제: \(summary.topic)") }
            lines.append(summary.body)
            appendList("결정 사항", summary.decisions, to: &lines)
            appendList("할 일", summary.sortedActionItems.map { item in
                let detail = [item.owner, item.dueText].compactMap { $0 }.joined(separator: ", ")
                return detail.isEmpty ? item.task : "\(item.task) (\(detail))"
            }, to: &lines)
            appendList("미해결 질문", summary.openQuestions, to: &lines)
            lines.append("")
        }

        lines.append("[대화]")
        let utterances = meeting.sortedUtterances
        if utterances.isEmpty {
            lines.append(meeting.transcript)
        } else {
            for u in utterances {
                let speaker = u.speaker.map { "\($0): " } ?? ""
                lines.append("[\(timestamp(u.start))] \(speaker)\(u.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 파일 이름에 쓸 수 없는 문자를 바꾼다.
    static func exportFileName(for meeting: Meeting) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let base = meeting.title.components(separatedBy: invalid).joined(separator: "-")
        return (base.isEmpty ? "회의" : base) + ".txt"
    }

    private static func appendList(_ title: String, _ items: [String], to lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("")
        lines.append("\(title):")
        lines.append(contentsOf: items.map { "- \($0)" })
    }
}

/// 공유 시트로 내보내는 TXT 파일
struct TranscriptFile: Transferable {
    let fileName: String
    let text: String

    init(meeting: Meeting) {
        fileName = MeetingText.exportFileName(for: meeting)
        text = MeetingText.exportText(for: meeting)
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { file in
            Data(file.text.utf8)
        }
        .suggestedFileName { $0.fileName }
    }
}
