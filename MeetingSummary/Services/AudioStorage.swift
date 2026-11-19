import Foundation

/// 녹음 음성 파일 저장 위치. 음성은 이 기기에만 저장된다.
enum AudioStorage {
    static var directory: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newFileName(for meetingID: UUID) -> String {
        "\(meetingID.uuidString).m4a"
    }

    static func url(fileName: String) -> URL {
        directory.appending(path: fileName)
    }

    /// 재생할 수 있는 음성 파일이 있으면 그 경로
    static func existingURL(for meeting: Meeting) -> URL? {
        guard let name = meeting.audioFileName else { return nil }
        let url = url(fileName: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func deleteAudio(for meeting: Meeting) {
        guard let name = meeting.audioFileName else { return }
        try? FileManager.default.removeItem(at: url(fileName: name))
    }

    /// 저장된 녹음 파일 전체 용량(바이트)
    static func totalBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
