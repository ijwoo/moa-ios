import Foundation
import Photos

/// "사진에 저장" (D113): 맥이 만든 영상·그림을 사진 보관함에 넣는다.
/// 넣기 전용 권한(`.addOnly`)만 묻는다 — 보관함을 읽지 않는다. 화면 캡처(맥의 브라우저 화면)는 넣지 않는다
enum PhotoSaver {
    enum Outcome: Equatable {
        case saved
        /// 사진 보관함에 넣는 것을 허락하지 않았다 (설정에서 바꿀 수 있다)
        case denied
        case failed

        /// 저장한 뒤 화면에 잠깐 보일 한마디
        var message: String {
            switch self {
            case .saved: "사진 보관함에 저장했어요."
            case .denied: "사진 보관함에 저장하려면 설정 > 모아 > 사진에서 '사진 추가만'을 허용해 주세요."
            case .failed: "저장하지 못했어요. 다시 시도해 주세요."
            }
        }
    }

    static func saveVideo(at url: URL) async -> Outcome {
        guard await allowed() else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return .saved
        } catch {
            return .failed
        }
    }

    static func saveImage(_ data: Data) async -> Outcome {
        guard await allowed() else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return .saved
        } catch {
            return .failed
        }
    }

    private static func allowed() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }
}
