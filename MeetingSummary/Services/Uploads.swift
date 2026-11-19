import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

// 사진·PDF 붙여 묻기 (D85. 맥의 D73)
//
// 붙인 것은 아이폰 → 맥 → Claude로 간다 (앱의 중계 서버를 거치지 않는다).
// 이 기기에는 메모리에만 둔다: 대화 기록에는 "사진 2장" 같은 종류와 PDF의 파일 이름만 남는다.

/// 한 말에 붙인 사진·PDF 하나. 기록에 남는 것은 이것뿐이다 (그림·파일의 내용은 없다)
struct ChatUpload: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case image, pdf }
    var id = UUID()
    let kind: Kind
    /// PDF의 파일 이름 (사진에는 없다: 사진의 이름은 보내지도 남기지도 않는다)
    var name: String?
}

/// 내 말에 붙여 보낸 것들
struct SentUploads: Codable, Equatable, Sendable {
    var items: [ChatUpload]
    /// 글 없이 붙인 것만 보낸 말인지. 그때 말의 `text`에는 "사진 1장" 같은 한 줄이 들어 있고, 맥에는 빈 글이 간다
    var textless = false

    /// 글 없이 보낸 말을 대신하는 한 줄 (대화 제목, 답장의 인용, 기록에 쓴다)
    static func caption(_ items: [ChatUpload]) -> String {
        let images = items.filter { $0.kind == .image }.count
        let pdfs = items.count - images
        var parts: [String] = []
        if images > 0 { parts.append("사진 \(images)장") }
        if pdfs > 0 { parts.append("PDF \(pdfs)개") }
        return parts.isEmpty ? "붙인 것" : parts.joined(separator: " · ")
    }
}

/// 붙이기 전의 손질: 종류를 가리고, 사진은 JPEG로 다시 만든다.
/// 다시 만드는 까닭: 맥은 HEIC를 받지 않고, 사진에 든 정보(찍은 위치 등)는 보내지 않으며, 크기를 한도 안에 둔다
enum UploadPrep {
    /// 맥이 받는 크기 (맥과 맞춘 값)
    static let imageLimit = 7 * 1024 * 1024
    static let pdfLimit = 10 * 1024 * 1024
    /// 사진의 긴 변 (맥이 권한 값)
    static let longSide = 2000
    /// 대화에 보여 주는 작은 그림의 긴 변
    static let thumbnailSide = 640
    /// 한 말에 붙이는 수
    static let maxCount = MessageExtras.uploadLimit
    /// 읽어 볼 원본의 크기. 이보다 크면 읽지 않는다
    static let sourceLimit = 150 * 1024 * 1024

    enum Failure: Error, Equatable, Sendable {
        case unsupported, tooLarge, unreadable

        var notice: String {
            switch self {
            case .unsupported: "사진과 PDF만 붙일 수 있어요."
            case .tooLarge: "파일이 너무 커요. 사진은 7MB, PDF는 10MB까지 붙일 수 있어요."
            case .unreadable: "파일을 읽지 못했어요."
            }
        }
    }

    struct Prepared: Equatable, Sendable {
        let kind: ChatUpload.Kind
        /// 맥에 올릴 바이트 (사진은 다시 만든 JPEG, PDF는 그대로)
        let data: Data
        /// 대화에 보여 줄 작은 그림 (JPEG. PDF에는 없다)
        let thumbnail: Data?
    }

    static func isPDF(_ data: Data) -> Bool { data.starts(with: Array("%PDF-".utf8)) }

    /// 파일 앱에서 고른 파일을 읽는다. 너무 큰 것은 읽지 않는다 (읽는 동안만 그 파일에 닿는다)
    static func read(file url: URL) -> Result<Data, Failure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > sourceLimit { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return .failure(.unreadable) }
        return .success(data)
    }

    static func prepare(_ data: Data) -> Result<Prepared, Failure> {
        guard !data.isEmpty else { return .failure(.unreadable) }
        if isPDF(data) {
            guard data.count <= pdfLimit else { return .failure(.tooLarge) }
            return .success(Prepared(kind: .pdf, data: data, thumbnail: nil))
        }
        guard data.count <= sourceLimit else { return .failure(.tooLarge) }
        // 사진이 아닌 것(영상, 문서)은 받지 않는다
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), type.conforms(to: .image),
              CGImageSourceGetCount(source) > 0 else { return .failure(.unsupported) }
        // 돌려 찍은 사진은 바로 세우고, 긴 변을 줄인다 (작은 사진을 키우지는 않는다)
        guard let scaled = scaled(source, longSide: longSide), let flat = flattened(scaled) else { return .failure(.unreadable) }
        for quality in [0.85, 0.7, 0.5] {
            guard let jpeg = jpeg(flat, quality: quality) else { return .failure(.unreadable) }
            guard jpeg.count <= imageLimit else { continue }
            let small = resized(flat, longSide: thumbnailSide).flatMap { self.jpeg($0, quality: 0.8) }
            return .success(Prepared(kind: .image, data: jpeg, thumbnail: small))
        }
        return .failure(.tooLarge)
    }

    private static func scaled(_ source: CGImageSource, longSide: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 흰 바탕에 그려 투명한 곳을 없앤다. 새로 그린 그림이라 원본에 든 정보(위치, 기기, 찍은 때)는 따라오지 않는다
    private static func flattened(_ image: CGImage) -> CGImage? { draw(image, width: image.width, height: image.height) }

    private static func resized(_ image: CGImage, longSide: Int) -> CGImage? {
        let long = max(image.width, image.height)
        guard long > longSide else { return image }
        let scale = Double(longSide) / Double(long)
        return draw(image, width: max(1, Int(Double(image.width) * scale)), height: max(1, Int(Double(image.height) * scale)))
    }

    private static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// 붙인 사진·PDF를 들고 있는 곳. **메모리에만 있다**: 파일로도, 대화 기록으로도 남기지 않는다.
/// 올릴 바이트는 답을 받으면 버리고, 대화에 보여 주는 작은 그림만 대화를 보는 동안 둔다
@MainActor
@Observable
final class UploadStore {
    private struct Item {
        var data: Data?
        var thumbnail: UIImage?
        var remoteID: String?
        var uploadedAt: Date?
        var isUploading = false
    }

    private var items: [UUID: Item] = [:]
    private var order: [UUID] = []
    /// 입력창에 붙여 둔 것 (아직 보내지 않았다)
    private(set) var draft: [ChatUpload] = []
    /// 손질하는 중인 수 (입력창에 돌아가는 표시를 둔다)
    private(set) var preparing = 0
    /// 붙이지 못한 까닭 한 줄 (입력창에 보여 준다)
    var notice: String?

    /// 들고 있는 그림의 수. 넘으면 오래된 것부터 버린다 (그 말풍선에는 빈 칸이 보인다)
    static let limit = 40
    /// 맥은 쓰이지 않은 것을 30분 뒤에 지운다. 그 전에 다시 올리게 여유를 둔 시간
    static let remoteLife: TimeInterval = 25 * 60

    /// 더 붙일 수 있는 수
    var room: Int { max(0, UploadPrep.maxCount - draft.count - preparing) }
    var heldCount: Int { items.count }

    // MARK: 입력창

    /// 고른 사진·파일을 손질해 입력창에 붙인다. `name`: PDF일 때만 남는 파일 이름
    func attach(_ data: Data, name: String? = nil) async {
        guard room > 0 else {
            notice = "한 번에 \(UploadPrep.maxCount)개까지 붙일 수 있어요."
            return
        }
        preparing += 1
        // 큰 사진을 줄이는 일은 화면을 멈추지 않게 따로 한다
        let result = await Task.detached(priority: .userInitiated) { UploadPrep.prepare(data) }.value
        preparing -= 1
        switch result {
        case .success(let prepared):
            let upload = ChatUpload(kind: prepared.kind, name: prepared.kind == .pdf ? Self.shownName(name) : nil)
            items[upload.id] = Item(data: prepared.data, thumbnail: prepared.thumbnail.flatMap { UIImage(data: $0) })
            order.append(upload.id)
            draft.append(upload)
            notice = nil
            trim()
        case .failure(let failure):
            notice = failure.notice
        }
    }

    /// 붙이지 못했다고 알린다 (읽기 전에 크기로 걸러 낸 파일 등)
    func fail(_ failure: UploadPrep.Failure) { notice = failure.notice }

    /// 입력창에서 뗀다
    func detach(_ id: ChatUpload.ID) {
        draft.removeAll { $0.id == id }
        forget(id)
        notice = nil
    }

    /// 보낼 때: 입력창에 붙여 둔 것을 가져가고 비운다 (그림과 바이트는 그대로 들고 있다)
    func takeDraft() -> [ChatUpload] {
        let taken = draft
        draft = []
        notice = nil
        return taken
    }

    /// 파일 이름: 경로는 떼고 80자까지
    nonisolated static func shownName(_ name: String?) -> String? {
        guard let last = name?.split(separator: "/").last else { return nil }
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    // MARK: 대화

    func thumbnail(for id: ChatUpload.ID) -> UIImage? { items[id]?.thumbnail }
    func isUploading(_ id: ChatUpload.ID) -> Bool { items[id]?.isUploading == true }
    func bytes(for id: ChatUpload.ID) -> Data? { items[id]?.data }

    /// 맥에 올리고 받은 번호. 바이트를 아직 들고 있는데 올린 지 오래됐으면 nil이다 (맥이 지웠을 수 있으니 다시 올린다)
    func remoteID(for id: ChatUpload.ID, now: Date = .now) -> String? {
        guard let item = items[id], let remote = item.remoteID else { return nil }
        if item.data != nil, let at = item.uploadedAt, now.timeIntervalSince(at) > Self.remoteLife { return nil }
        return remote
    }

    func setRemote(_ remote: String, for id: ChatUpload.ID, at date: Date = .now) {
        items[id]?.remoteID = remote
        items[id]?.uploadedAt = date
    }

    func setUploading(_ id: ChatUpload.ID, _ uploading: Bool) { items[id]?.isUploading = uploading }

    /// 답을 받았다: 올릴 바이트는 버린다 (작은 그림과 번호는 둔다)
    func release(_ ids: [ChatUpload.ID]) {
        for id in ids { items[id]?.data = nil }
    }

    /// 다른 대화로 옮기거나 새 대화를 열 때: 보낸 것은 모두 버린다. 입력창에 붙여 둔 것은 남는다
    func clear() {
        let kept = Set(draft.map(\.id))
        items = items.filter { kept.contains($0.key) }
        order.removeAll { !kept.contains($0) }
    }

    private func forget(_ id: ChatUpload.ID) {
        items[id] = nil
        order.removeAll { $0 == id }
    }

    private func trim() {
        let kept = Set(draft.map(\.id))
        while items.count > Self.limit, let oldest = order.first(where: { !kept.contains($0) }) { forget(oldest) }
    }
}
