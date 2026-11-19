import Foundation
import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import MeetingSummary

// 사진·PDF 붙여 묻기 (맥의 `uploads`, D85). 그림과 문서는 모두 이 파일이 그린 가상의 것이다

private enum UploadFixture {
    static let pdf = Data("%PDF-1.4\n가상의 안내문\n%%EOF".utf8)

    /// 색을 칠한 PNG. `clear`면 가운데만 칠하고 나머지는 투명하다
    static func png(width: Int, height: Int, clear: Bool = false) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(clear ? CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2)
                : CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// 위치와 찍은 기기가 적힌 JPEG (좌표와 기기 이름은 지어낸 것)
    static func jpegWithPlace() throws -> Data {
        let image = try #require(UIImage(data: png(width: 300, height: 200))?.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 34.5, kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "가상 카메라 1"] as [CFString: Any],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:15 10:00:00"] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func properties(of data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    static func size(of data: Data) throws -> (width: Int, height: Int) {
        let image = try #require(UIImage(data: data)?.cgImage)
        return (image.width, image.height)
    }

    static func cloud(by: Bool = false, replies: [String] = []) -> MockDialogCloud {
        var cloud = MockDialogCloud(marksWriter: by)
        cloud.takesUploads = true
        cloud.uploadReplies = replies
        return cloud
    }
}

// MARK: - 보내기 전 손질

@Suite("붙이기: 보내기 전 손질")
struct UploadPrepTests {
    @Test func pdfGoesAsIs() throws {
        let prepared = try UploadPrep.prepare(UploadFixture.pdf).get()
        #expect(prepared.kind == .pdf)
        #expect(prepared.data == UploadFixture.pdf)
        #expect(prepared.thumbnail == nil)
    }

    @Test func pdfOverTheLimitIsRefusedBeforeSending() {
        // 맥은 큰 것을 받으면 연결을 끊는다: 앱이 먼저 거른다
        let big = UploadFixture.pdf + Data(count: UploadPrep.pdfLimit)
        #expect(UploadPrep.prepare(big) == .failure(.tooLarge))
        #expect(UploadPrep.Failure.tooLarge.notice.contains("10MB"))
    }

    @Test func photoBecomesAJPEGNoLongerThanTwoThousand() throws {
        let prepared = try UploadPrep.prepare(UploadFixture.png(width: 3000, height: 1500)).get()
        #expect(prepared.kind == .image)
        #expect(prepared.data.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(prepared.data.count <= UploadPrep.imageLimit)
        let size = try UploadFixture.size(of: prepared.data)
        #expect(size.width == 2000 && size.height == 1000)
        // 화면에 보일 작은 그림도 같이 만든다
        let small = try UploadFixture.size(of: try #require(prepared.thumbnail))
        #expect(max(small.width, small.height) == UploadPrep.thumbnailSide)
    }

    @Test func smallPhotoIsNotEnlarged() throws {
        let prepared = try UploadPrep.prepare(UploadFixture.png(width: 300, height: 200)).get()
        let size = try UploadFixture.size(of: prepared.data)
        #expect(size.width == 300 && size.height == 200)
        let small = try UploadFixture.size(of: try #require(prepared.thumbnail))
        #expect(small.width == 300 && small.height == 200)
    }

    @Test func transparentPartsBecomeWhite() throws {
        // 맥이 받는 JPEG에는 투명이 없다: 검게 나오지 않게 흰 바탕에 그린다
        let prepared = try UploadPrep.prepare(UploadFixture.png(width: 200, height: 200, clear: true)).get()
        let image = try #require(UIImage(data: prepared.data)?.cgImage)
        #expect(image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // 왼쪽 위 구석 (투명하던 곳)
        context.draw(image, in: CGRect(x: 0, y: -199, width: 200, height: 200))
        #expect(pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240)
    }

    @Test func placeAndCameraAreNotSent() throws {
        let source = try UploadFixture.jpegWithPlace()
        // 원래 파일에는 위치와 기기가 적혀 있다
        let before = try UploadFixture.properties(of: source)
        #expect(before[kCGImagePropertyGPSDictionary] != nil)
        #expect((before[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] != nil)

        let prepared = try UploadPrep.prepare(source).get()
        let after = try UploadFixture.properties(of: prepared.data)
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        #expect((after[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil)
        #expect((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
        // 바이트 어디에도 그 글이 없다
        #expect(prepared.data.range(of: Data("가상 카메라 1".utf8)) == nil)
        #expect(prepared.data.range(of: Data("2026:11:15".utf8)) == nil)
        let small = try #require(prepared.thumbnail)
        #expect(try UploadFixture.properties(of: small)[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func otherFilesAreRefused() {
        #expect(UploadPrep.prepare(Data("회의록 초안입니다".utf8)) == .failure(.unsupported))
        #expect(UploadPrep.prepare(Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0])) == .failure(.unsupported))
        #expect(UploadPrep.prepare(Data()) == .failure(.unreadable))
        #expect(UploadPrep.Failure.unsupported.notice == "사진과 PDF만 붙일 수 있어요.")
    }

    @Test func fileIsReadOnlyWhenNotTooLarge() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("가상 안내문.pdf")
        try UploadFixture.pdf.write(to: file)
        #expect(try UploadPrep.read(file: file).get() == UploadFixture.pdf)
        #expect(UploadPrep.read(file: folder.appendingPathComponent("없는 파일.pdf")) == .failure(.unreadable))
    }

    @Test func captionSaysWhatWasAttached() {
        let photo = ChatUpload(kind: .image), pdf = ChatUpload(kind: .pdf, name: "안내.pdf")
        #expect(SentUploads.caption([photo]) == "사진 1장")
        #expect(SentUploads.caption([photo, ChatUpload(kind: .image)]) == "사진 2장")
        #expect(SentUploads.caption([pdf]) == "PDF 1개")
        #expect(SentUploads.caption([photo, pdf]) == "사진 1장 · PDF 1개")
    }

    @Test func singleTileKeepsTheShape() {
        // 세로로 긴 영수증: 높이에 맞춘다. 가로로 긴 것: 너비에 맞춘다. 아주 길쭉해도 80보다 작아지지 않는다
        #expect(UploadTiles.singleSize(for: CGSize(width: 900, height: 1300)) == CGSize(width: 180, height: 260))
        #expect(UploadTiles.singleSize(for: CGSize(width: 1400, height: 1000)) == CGSize(width: 220, height: 157))
        #expect(UploadTiles.singleSize(for: CGSize(width: 2000, height: 100)) == CGSize(width: 220, height: 80))
        #expect(UploadTiles.singleSize(for: .zero) == CGSize(width: 112, height: 112))
    }
}

// MARK: - 들고 있기

@MainActor
@Suite("붙이기: 들고 있기")
struct UploadStoreTests {
    @Test func attachesUpToFour() async {
        let store = UploadStore()
        for _ in 0..<5 { await store.attach(UploadFixture.png(width: 40, height: 40)) }
        #expect(store.draft.count == 4)
        #expect(store.room == 0)
        #expect(store.notice == "한 번에 4개까지 붙일 수 있어요.")
        #expect(store.draft.allSatisfy { $0.kind == .image && $0.name == nil })
        #expect(store.draft.allSatisfy { store.thumbnail(for: $0.id) != nil && store.bytes(for: $0.id) != nil })
    }

    @Test func onlyPDFKeepsItsName() async throws {
        let store = UploadStore()
        // 사진의 파일 이름은 두지 않는다 (찍은 때나 곳이 들어 있을 수 있다)
        await store.attach(UploadFixture.png(width: 40, height: 40), name: "IMG_가상_0001.png")
        await store.attach(UploadFixture.pdf, name: "/var/가상/폴더/가을 워크숍 안내.pdf")
        #expect(store.draft.map(\.name) == [nil, "가을 워크숍 안내.pdf"])
        #expect(store.draft.map(\.kind) == [.image, .pdf])
    }

    @Test func refusedFileLeavesANotice() async {
        let store = UploadStore()
        await store.attach(Data("그냥 글".utf8), name: "메모.txt")
        #expect(store.draft.isEmpty)
        #expect(store.notice == "사진과 PDF만 붙일 수 있어요.")
        #expect(store.heldCount == 0)
        // 다음 것이 붙으면 그 말은 사라진다
        await store.attach(UploadFixture.pdf, name: "안내.pdf")
        #expect(store.notice == nil)
    }

    @Test func detachForgetsEverything() async throws {
        let store = UploadStore()
        await store.attach(UploadFixture.png(width: 40, height: 40))
        let id = try #require(store.draft.first?.id)
        store.detach(id)
        #expect(store.draft.isEmpty && store.heldCount == 0)
        #expect(store.thumbnail(for: id) == nil && store.bytes(for: id) == nil)
    }

    @Test func sentOnesKeepThePictureButNotTheBytes() async throws {
        let store = UploadStore()
        await store.attach(UploadFixture.png(width: 40, height: 40))
        let sent = store.takeDraft()
        #expect(store.draft.isEmpty && store.room == 4)
        let id = try #require(sent.first?.id)
        store.setRemote("u_mockfile0001", for: id)
        store.release([id])
        #expect(store.bytes(for: id) == nil)
        #expect(store.thumbnail(for: id) != nil)
        #expect(store.remoteID(for: id) == "u_mockfile0001")
    }

    @Test func oldRemoteNumberIsNotReusedWhileBytesAreHeld() async throws {
        let store = UploadStore()
        await store.attach(UploadFixture.pdf, name: "안내.pdf")
        let id = try #require(store.takeDraft().first?.id)
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        store.setRemote("u_mockfile0001", for: id, at: then)
        #expect(store.remoteID(for: id, now: then.addingTimeInterval(24 * 60)) == "u_mockfile0001")
        // 맥은 30분 쓰이지 않으면 지운다: 그 전에(25분) 다시 올린다
        #expect(store.remoteID(for: id, now: then.addingTimeInterval(26 * 60)) == nil)
    }

    @Test func clearKeepsOnlyWhatIsStillInTheComposer() async throws {
        let store = UploadStore()
        await store.attach(UploadFixture.png(width: 40, height: 40))
        let sent = try #require(store.takeDraft().first?.id)
        await store.attach(UploadFixture.pdf, name: "안내.pdf")
        let waiting = try #require(store.draft.first?.id)
        store.clear()
        #expect(store.thumbnail(for: sent) == nil)
        #expect(store.bytes(for: waiting) != nil)
        #expect(store.draft.count == 1)
    }
}

// MARK: - 요청

/// 이 파일만 쓰는 가짜 서버 (받은 본문을 바이트 그대로 적어 둔다)
final class UploadStubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        let cachePolicy: URLRequest.CachePolicy
    }

    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var respond: @Sendable (String) -> (Int, String) = { _ in (200, "{}") }
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let path = request.url?.path() ?? ""
        let (status, text) = Self.lock.withLock {
            Self.seen.append(Seen(
                method: request.httpMethod ?? "", path: path, headers: request.allHTTPHeaderFields ?? [:], body: body,
                cachePolicy: request.cachePolicy
            ))
            return Self.respond(path)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("붙이기: 요청", .serialized)
struct UploadRequestTests {
    private static let created = #"{"upload":{"id":"u_Ab3dEf9hIjKl","kind":"pdf","mime":"application/pdf","bytes":33,"name":"안내.pdf","expires_in_s":1800}}"#

    private func client(uploads: Bool = true, upload: (Int, String) = (201, UploadRequestTests.created)) -> AgentHTTPClient {
        let features = uploads ? #"["messages","task_questions","dialog_cloud","uploads"]"# : #"["messages","task_questions","dialog_cloud"]"#
        UploadStubProtocol.lock.withLock {
            UploadStubProtocol.seen = []
            UploadStubProtocol.respond = { path in
                path.hasSuffix("/health") ? (200, #"{"status":"ok","features":\#(features)}"#) : upload
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadStubProtocol.self]
        return AgentHTTPClient(baseURL: URL(string: "http://mac.test:8765")!, token: "t", session: URLSession(configuration: configuration))
    }

    private var seen: [UploadStubProtocol.Seen] {
        UploadStubProtocol.lock.withLock { UploadStubProtocol.seen }.filter { !$0.path.hasSuffix("/health") }
    }

    @Test func fileGoesAsTheBodyItself() async throws {
        let client = client()
        #expect(await client.isReachable())
        #expect(await client.supports(AgentFeature.uploads))
        let id = try await client.upload(UploadFixture.pdf, name: "가을 워크숍 안내.pdf")
        #expect(id == "u_Ab3dEf9hIjKl")

        let request = try #require(seen.first)
        #expect(seen.count == 1)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/uploads")
        #expect(request.headers["X-App-Token"] == "t")
        #expect(request.headers["Content-Type"] == "application/octet-stream")
        // 본문은 JSON이 아니라 파일 그대로다. 기기 캐시에도 남기지 않는다
        #expect(request.body == UploadFixture.pdf)
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        // 이름은 ASCII만 남게 퍼센트 인코딩한다 (머리글에 한글을 그대로 넣지 않는다)
        let name = try #require(request.headers["X-Filename"])
        let ascii = name.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(ascii)
        #expect(name.removingPercentEncoding == "가을 워크숍 안내.pdf")
    }

    @Test func photoGoesWithoutAName() async throws {
        let client = client()
        #expect(await client.isReachable())
        _ = try await client.upload(Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]), name: nil)
        #expect(seen.first?.headers["X-Filename"] == nil)
        #expect(seen.first?.body == Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]))
    }

    @Test func fileNameIsTrimmedToTheLastPart() {
        #expect(AgentHTTPClient.uploadFilename("/private/var/folders/report-1.pdf") == "report-1.pdf")
        #expect(AgentHTTPClient.uploadFilename("a b.pdf") == "a%20b.pdf")
        #expect(AgentHTTPClient.uploadFilename("  ") == nil)
        #expect(AgentHTTPClient.uploadFilename(nil) == nil)
        let long = String(repeating: "가", count: 300) + ".pdf"
        #expect(AgentHTTPClient.uploadFilename(long)?.removingPercentEncoding?.count == 100)
    }

    @Test func macThatDoesNotTakeUploadsIsNeverAsked() async {
        let client = client(uploads: false)
        #expect(await client.isReachable())
        await #expect(throws: AgentError.uploadUnsupported) { try await client.upload(UploadFixture.pdf, name: "안내.pdf") }
        #expect(seen.isEmpty)
    }

    @Test func refusalsAreToldApart() async {
        var client = client(upload: (415, #"{"error":{"code":"unsupported_media_type","message":"받지 않는 파일"}}"#))
        #expect(await client.isReachable())
        await #expect(throws: AgentError.uploadUnsupported) { try await client.upload(UploadFixture.pdf, name: nil) }
        client = self.client(upload: (413, #"{"error":{"code":"payload_too_large","message":"너무 큼"}}"#))
        #expect(await client.isReachable())
        await #expect(throws: AgentError.uploadTooLarge) { try await client.upload(UploadFixture.pdf, name: nil) }
        #expect(AgentError.uploadTooLarge.errorDescription?.contains("7MB") == true)
    }

    @Test func strangeNumberIsNotUsed() async {
        let client = client(upload: (201, #"{"upload":{"id":"../../etc/passwd"}}"#))
        #expect(await client.isReachable())
        await #expect(throws: AgentError.invalidResponse) { try await client.upload(UploadFixture.pdf, name: nil) }
    }

    @Test func numberShape() {
        #expect(AgentHTTPClient.isUploadID("u_Ab3dEf9hIjKl"))
        #expect(AgentHTTPClient.isUploadID("u_mockfile0001"))
        #expect(AgentHTTPClient.isUploadID("u_a-b_c-d_e"))
        #expect(!AgentHTTPClient.isUploadID("u_short"))
        #expect(!AgentHTTPClient.isUploadID("t_Ab3dEf9hIjKl"))
        #expect(!AgentHTTPClient.isUploadID("u_Ab3dEf9h/../x"))
        #expect(!AgentHTTPClient.isUploadID("u_가나다라마바사아자"))
        #expect(!AgentHTTPClient.isUploadID("u_" + String(repeating: "a", count: 41)))
    }

    private func sent(_ uploads: [String], features: Set<String>) throws -> [String]? {
        try body(uploads, features: features)["uploads"] as? [String]
    }

    private func body(_ uploads: [String], features: Set<String>, text: String = "이거 봐 줘") throws -> [String: Any] {
        var extras = MessageExtras.none
        extras.uploads = uploads
        let body = AgentHTTPClient.MessageBody(
            text: text, conversationID: nil, context: nil, messageID: "m1", replyTaskID: nil, tone: "polite", features: features,
            extras: extras
        )
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    @Test func messageCarriesTheNumbers() throws {
        let known: Set<String> = [AgentFeature.uploads]
        let two = try sent(["u_mockfile0001", "u_mockfile0002"], features: known)
        #expect(two == ["u_mockfile0001", "u_mockfile0002"])
        // 넷까지, 모양이 맞는 것만
        let many = (1...6).map { "u_mockfile000\($0)" }
        let capped = try sent(many, features: known)
        #expect(capped == Array(many.prefix(4)))
        let shaped = try sent(["u_mockfile0001", "../x", ""], features: known)
        #expect(shaped == ["u_mockfile0001"])
        // 붙인 것만 보낼 때는 글이 비어도 된다
        let textless = try body(["u_mockfile0001"], features: known, text: "")
        #expect(textless["text"] as? String == "")
        #expect(textless["context"] == nil)
    }

    @Test func messageWithoutUploadsLooksLikeBefore() throws {
        let none = try body([], features: [AgentFeature.uploads])
        #expect(none["uploads"] == nil)
        // 붙이기를 모르는 맥에는 넣지 않는다
        let unknown = try body(["u_mockfile0001"], features: [])
        #expect(unknown["uploads"] == nil)
    }
}

// MARK: - 대화에서

@MainActor
@Suite("붙이기: 대화에서")
struct UploadChatTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func session(_ agent: MockAgentClient, cloud: FakeAskProvider = FakeAskProvider([])) async -> AskSession {
        let session = AskSession(provider: cloud, agent: agent, pollInterval: .zero)
        session.attach(context)
        await session.checkAgent()
        return session
    }

    /// 입력창에 붙이고 가져온다 (화면의 "+"와 보내기가 하는 일)
    private func attached(_ session: AskSession, photos: Int = 1, pdf: Bool = false) async -> [ChatUpload] {
        for _ in 0..<photos { await session.uploads.attach(UploadFixture.png(width: 60, height: 40)) }
        if pdf { await session.uploads.attach(UploadFixture.pdf, name: "가을 워크숍 안내.pdf") }
        return session.uploads.takeDraft()
    }

    @Test func plusIsOnlyThereForAMacThatTakesUploads() async {
        #expect(await session(MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud())).canAttach)
        // Claude 판단이지만 붙이기를 모르는 맥, 로컬 판단인 맥
        #expect(await !session(MockAgentClient(v2: true, dialogCloud: MockDialogCloud())).canAttach)
        #expect(await !session(MockAgentClient(v2: true)).canAttach)
        #expect(!AskSession(provider: FakeAskProvider([]), agent: nil).canAttach)
    }

    @Test func uploadsFirstThenTheMessageWithTheNumbers() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud(replies: ["네, 합계 23,500원이 맞아요."]))
        let session = await session(agent)
        let items = await attached(session, photos: 2, pdf: true)
        await session.send("이 영수증 합계가 얼마야?", meetings: [], uploads: items)

        let calls = await agent.uploadCalls
        #expect(calls.map(\.kind) == ["image", "image", "pdf"])
        // 사진의 이름은 가지 않고, PDF의 이름만 간다
        #expect(calls.map(\.name) == [nil, nil, "가을 워크숍 안내.pdf"])
        let messages = await agent.uploadMessages
        #expect(messages.count == 1)
        #expect(messages.first?.text == "이 영수증 합계가 얼마야?")
        #expect(messages.first?.ids == ["u_mockfile0001", "u_mockfile0002", "u_mockfile0003"])

        let mine = try #require(session.messages.first { $0.role == .user })
        #expect(mine.text == "이 영수증 합계가 얼마야?")
        #expect(mine.uploads?.items == items)
        #expect(mine.uploads?.textless == false)
        #expect(session.messages.last?.text == "네, 합계 23,500원이 맞아요.")
        // 답을 받았으니 올릴 바이트는 버리고, 화면에 보일 작은 그림만 둔다
        #expect(items.allSatisfy { session.uploads.bytes(for: $0.id) == nil })
        #expect(items.filter { $0.kind == .image }.allSatisfy { session.uploads.thumbnail(for: $0.id) != nil })
    }

    @Test func attachmentAloneGoesWithEmptyText() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud())
        let session = await session(agent)
        let meeting = Meeting(title: "주간 회의")
        context.insert(meeting)
        meeting.appendUtterance(Utterance(start: 3, end: 8, text: "출시일은 12월 3일로 확정했습니다."))
        let items = await attached(session, photos: 1, pdf: true)
        await session.send("", meetings: [meeting], uploads: items)

        // 대화에는 무엇을 붙였는지 한 줄로 남고, 맥에는 빈 글이 간다. 회의 자료도 붙이지 않는다
        let mine = try #require(session.messages.first { $0.role == .user })
        #expect(mine.text == "사진 1장 · PDF 1개")
        #expect(mine.uploads?.textless == true)
        let received = try #require(await agent.received.last)
        #expect(received.text == "")
        #expect(received.context == nil)
        #expect(await agent.uploadMessages.first?.ids.count == 2)
        #expect(session.messages.last?.text == "붙여 주신 사진 1장과 PDF 1개을 봤어요.")
    }

    @Test func nothingIsSentWithoutTextOrAttachment() async {
        let agent = MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud())
        let session = await session(agent)
        await session.send("   ", meetings: [], uploads: [])
        #expect(session.messages.isEmpty)
        #expect(await agent.received.isEmpty)
    }

    @Test func recordKeepsOnlyTheKindAndThePDFName() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud())
        let session = await session(agent)
        let items = await attached(session, photos: 1, pdf: true)
        await session.send("이거 정리해 줘", meetings: [], uploads: items)

        let records = try context.fetch(FetchDescriptor<ChatRecord>())
        let record = try #require(records.first { $0.uploadsData != nil })
        let stored = try #require(record.uploadsData)
        // 적어 둔 것은 종류와 PDF 이름, 글이 없었는지뿐이다 (그림이나 파일의 내용은 없다)
        #expect(stored.count < 400)
        let saved = try JSONDecoder().decode(SentUploads.self, from: stored)
        #expect(saved.items.map(\.kind) == [.image, .pdf])
        #expect(saved.items.map(\.name) == [nil, "가을 워크숍 안내.pdf"])
        #expect(stored.range(of: Data([0xFF, 0xD8, 0xFF])) == nil)
        #expect(stored.range(of: Data("%PDF".utf8)) == nil)

        // 앱을 다시 켜면: 무엇을 붙였는지는 보이고, 그림은 없다 (빈 칸으로 보인다)
        let reopened = AskSession(provider: FakeAskProvider([]), agent: nil)
        reopened.attach(context)
        let mine = try #require(reopened.messages.first { $0.role == .user })
        #expect(mine.uploads?.items == items)
        #expect(items.allSatisfy { reopened.uploads.thumbnail(for: $0.id) == nil })
    }

    @Test func unreachableMacMeansAnErrorNotTheCloud() async throws {
        let cloud = FakeAskProvider([.success(.init(answer: "기록에 없습니다.", found: false, citations: []))])
        let agent = MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud())
        let session = await session(agent, cloud: cloud)
        let items = await attached(session)
        await agent.setReachable(false)
        await session.send("이거 뭐야?", meetings: [], uploads: items)

        // 붙인 것은 앱의 중계 서버(회의 질문의 길)로 가지 않는다
        #expect(cloud.requests.isEmpty)
        let error = try #require(session.messages.last)
        #expect(error.role == .error)
        #expect(error.text == "맥에 연결되지 않아 붙인 것을 보내지 못했어요.")
        #expect(error.retryQuestion == "이거 뭐야?")
        #expect(await agent.uploadCalls.isEmpty)
        // 다시 보낼 수 있게 바이트는 그대로 들고 있다
        #expect(session.uploads.bytes(for: items[0].id) != nil)

        // 맥이 돌아온 뒤 "다시 시도": 같은 말에 붙인 것이 함께 간다 (내 말이 하나 더 생기지 않는다)
        await agent.setReachable(true)
        await session.send("이거 뭐야?", meetings: [])
        #expect(session.messages.filter { $0.role == .user }.count == 1)
        #expect(await agent.uploadCalls.count == 1)
        #expect(await agent.uploadMessages.first?.ids == ["u_mockfile0001"])
        #expect(session.messages.last?.role == .assistant)
    }

    @Test func failedUploadCanBeRetriedWithoutUploadingTwice() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud())
        let session = await session(agent)
        let items = await attached(session, photos: 2)
        // 첫 장은 올라가고 둘째 장에서 끊긴다
        await agent.failUpload(after: 1, with: .unreachable)
        await session.send("둘이 뭐가 달라?", meetings: [], uploads: items)
        let error = try #require(session.messages.last)
        #expect(error.role == .error)
        #expect(error.text == "붙인 것을 맥에 보내지 못했어요. 연결을 확인하고 다시 시도해 주세요.")
        #expect(error.retryQuestion == "둘이 뭐가 달라?")
        #expect(await agent.uploadMessages.isEmpty)
        #expect(await agent.uploadCalls.count == 1)

        await session.send("둘이 뭐가 달라?", meetings: [])
        // 이미 올라간 첫 장은 다시 올리지 않는다
        #expect(await agent.uploadCalls.count == 2)
        #expect(await agent.uploadMessages.first?.ids == ["u_mockfile0001", "u_mockfile0002"])
        #expect(!session.messages.contains { $0.role == .error })
    }

    @Test func refusedFileIsNotOfferedForRetry() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud())
        let session = await session(agent)
        let items = await attached(session)
        await agent.failNextUpload(.uploadTooLarge)
        await session.send("이거 봐 줘", meetings: [], uploads: items)
        let error = try #require(session.messages.last)
        #expect(error.role == .error)
        #expect(error.text.contains("7MB"))
        #expect(error.retryQuestion == nil)
    }

    @Test func macThatForgotTheFileSaysSo() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud(by: true))
        let session = await session(agent)
        let items = await attached(session)
        await session.send("이거 봐 줘", meetings: [], uploads: items)
        #expect(session.messages.last?.role == .assistant)

        // 답을 받은 뒤라 바이트는 없다. 같은 것을 또 보내려 해도 올릴 것이 없다: 다시 붙이라고 알린다
        await agent.dropUploads()
        let forgotten = session.messages.count
        await session.send("다시 봐 줘", meetings: [], uploads: items)
        #expect(session.messages.count == forgotten + 2)
        // 번호는 남아 있어 그대로 가고, 맥이 "받지 못했다"고 답한다 (맥의 말 그대로 보여 준다)
        #expect(session.messages.last?.text == "붙이신 것을 받지 못했어요(시간이 지나 지워졌을 수 있어요). 다시 붙여 주세요.")
        #expect(session.messages.last?.writer == .mac)
    }

    @Test func plusIsOffWhileTheMacIsAway() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud())
        let session = await session(agent)
        #expect(session.canAttachNow)
        await agent.setReachable(false)
        await session.checkAgent()
        #expect(!session.canAttachNow)
        await agent.setReachable(true)
        await session.checkAgent()
        #expect(session.canAttachNow)
    }

    @Test func plusIsOffWhileATaskWaitsForMyAnswer() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud())
        let session = await session(agent)
        let items = await attached(session)
        // 작업 담당이 묻고 멈췄다: 지금 쓰는 글은 그 질문의 답이라, 붙인 것이 갈 자리가 없다
        await session.send("할 일로 팀 공유 메일 초안 써줘", meetings: [])
        try #require(session.openQuestionTask != nil || session.hasPendingApproval)
        #expect(!session.canAttachNow)
        #expect(await agent.uploadCalls.isEmpty)
        // 붙여 둔 것은 그대로 들고 있다 (답한 뒤에 보낼 수 있게)
        #expect(session.uploads.bytes(for: items[0].id) != nil)
    }

    @Test func macWithoutTheFeatureNeverGetsTheFile() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: MockDialogCloud())
        let session = await session(agent)
        let items = await attached(session)
        await session.send("이거 봐 줘", meetings: [], uploads: items)
        #expect(await agent.uploadCalls.isEmpty)
        #expect(await agent.received.isEmpty)
        #expect(session.messages.last?.text == "지금 연결된 맥은 사진과 파일을 받지 못해요.")
    }

    @Test func newChatDropsWhatWasSent() async throws {
        let agent = MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud())
        let session = await session(agent)
        let items = await attached(session)
        await session.send("이거 봐 줘", meetings: [], uploads: items)
        #expect(session.uploads.thumbnail(for: items[0].id) != nil)
        session.reset()
        #expect(session.uploads.thumbnail(for: items[0].id) == nil)
        #expect(session.uploads.heldCount == 0)
    }
}

// MARK: - 데이터 처리 방식

@Suite("붙이기: 데이터 처리 방식의 설명")
struct UploadFactsTests {
    @Test func setupRemembersWhetherTheMacTakesUploads() throws {
        let setup = DialogSetup(place: .cloud, sendsContext: true, takesUploads: true)
        #expect(setup.stored.hasSuffix(" uploads"))
        #expect(DialogSetup(stored: setup.stored) == setup)
        #expect(DialogSetup(stored: "v2 cloud context")?.takesUploads == false)
        // 로컬 판단인 맥은 붙인 것을 받지 않는다 (Claude가 보는 것이라)
        #expect(!DialogSetup(place: .local, takesUploads: true).takesUploads)
    }

    @Test func setupIsReadFromTheMac() async {
        #expect(await DialogSetup(agent: MockAgentClient(v2: true, dialogCloud: UploadFixture.cloud())).takesUploads)
        #expect(await !DialogSetup(agent: MockAgentClient(v2: true, dialogCloud: MockDialogCloud())).takesUploads)
    }

    @Test func factIsShownOnlyWhenTheMacTakesUploads() throws {
        let with = MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true, takesUploads: true)).rows
        let without = MacAgentFacts(setup: DialogSetup(place: .cloud, sendsContext: true)).rows
        let fact = try #require(with.first { $0.text.contains("붙인 사진과 PDF") })
        #expect(!without.contains { $0.text.contains("붙인 사진과 PDF") })
        #expect(with.count == without.count + 1)
        // 어디를 거쳐 누가 보는지, 얼마나 남는지를 말한다
        let note = try #require(fact.note)
        for word in ["Claude", "30분", "위치", "PDF"] { #expect(note.contains(word), "\(word)") }
    }
}

// MARK: - 카메라로 찍어 붙이기 (D87)

@Suite("붙이기: 카메라")
struct CameraTests {
    @Test func opensOnlyWhenAllowed() {
        #expect(CameraGate.step(for: .authorized) == .open)
        // 아직 묻지 않았으면 누를 때 묻는다
        #expect(CameraGate.step(for: .notDetermined) == .ask)
        // 꺼 두었거나 막혀 있으면 열지 않고 알린다
        #expect(CameraGate.step(for: .denied) == .blocked)
        #expect(CameraGate.step(for: .restricted) == .blocked)
        #expect(CameraGate.blockedNotice.contains("설정 → 모아"))
    }

    /// 세워 찍은 사진은 가로로 저장되고 "돌려서 보라"는 표시만 붙는다: 보낼 때는 바로 세운 그림이어야 한다
    @Test func aPortraitShotIsSentUpright() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let shot = UIImage(cgImage: try #require(wide.cgImage), scale: 1, orientation: .right)
        let data = try #require(CameraGate.data(from: shot))
        let prepared = try UploadPrep.prepare(data).get()
        #expect(prepared.kind == .image)
        let size = try UploadFixture.size(of: prepared.data)
        #expect(size.width == 200)
        #expect(size.height == 400)
        // 다시 만든 그림에는 돌리라는 표시도, 기기 정보도 없다
        let properties = try UploadFixture.properties(of: prepared.data)
        let orientation = properties[kCGImagePropertyOrientation] as? Int
        #expect(orientation == nil || orientation == 1)
        let model = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel]
        #expect(model == nil)
    }
}
