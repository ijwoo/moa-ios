import AVFoundation
import SwiftUI
import UIKit

// 사진·PDF 붙여 묻기의 화면 (D85): 입력창 위의 붙인 것 줄, 내 말 위의 붙인 것.
// 그림은 `UploadStore`의 메모리에만 있다. 앱을 다시 켜면 내 말에는 빈 칸만 보인다.

extension View {
    /// 대화가 잠깐 들고 있는 그림들을 아래 화면에 건넨다. 모두 메모리에만 있고 기록에는 남지 않는다:
    /// 보고에 붙은 화면 캡처, 찾은 페이지 카드의 대표 그림, 내 말에 붙여 보낸 사진 (D85)
    func chatImages(of session: AskSession) -> some View {
        environment(session.captures)
            .environment(session.thumbnails)
            .environment(session.uploads)
    }
}

/// 입력창 위: 보내기 전에 붙여 둔 것들. 하나씩 뗄 수 있다
struct AttachTray: View {
    let store: UploadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.draft.isEmpty || store.preparing > 0 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(store.draft.enumerated()), id: \.element.id) { index, item in
                            DraftTile(item: item, number: index + 1, image: store.thumbnail(for: item.id)) {
                                withAnimation(.snappy(duration: 0.2)) { store.detach(item.id) }
                            }
                        }
                        ForEach(0..<store.preparing, id: \.self) { _ in
                            ProgressView()
                                .frame(width: DraftTile.side, height: DraftTile.side)
                                .background(DS.Chat.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .accessibilityLabel("붙이는 중")
                        }
                    }
                    // ✕가 칸 밖으로 조금 나와 있다
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
                .scrollIndicators(.hidden)
            }
            if let notice = store.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(DS.Chat.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !store.draft.isEmpty {
                // 어디로 가는지 보내기 전에 알린다 (자세한 것은 설정의 데이터 처리 방식에 있다)
                Text("붙인 것은 내 맥을 거쳐 Claude가 봐요")
                    .font(.caption)
                    .foregroundStyle(DS.Chat.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DraftTile: View {
    static let side: CGFloat = 64
    let item: ChatUpload
    let number: Int
    let image: UIImage?
    let onRemove: () -> Void

    var body: some View {
        Group {
            if item.kind == .pdf {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(DS.Chat.danger)
                    Text(item.name ?? "PDF")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(DS.Chat.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .frame(width: 150, height: Self.side, alignment: .leading)
                .background(DS.Chat.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                UploadImage(image: image)
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.kind == .pdf ? "붙인 PDF \(item.name ?? "")" : "붙인 사진 \(number)")
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.72), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                    // 보이는 것은 작게, 누르는 자리는 넉넉하게
                    .frame(width: 36, height: 36, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(item.kind == .pdf ? "PDF 떼기" : "사진 \(number) 떼기")
        }
    }
}

/// 그림 한 칸. 들고 있는 그림이 없으면 (앱을 다시 켰거나 오래된 말) 빈 칸을 보여 준다
private struct UploadImage: View {
    let image: UIImage?

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                DS.Chat.elevated
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(DS.Chat.textSecondary)
            }
        }
    }
}

/// 내 말 위: 그 말에 붙여 보낸 사진과 PDF
struct UploadTiles: View {
    let uploads: SentUploads

    /// 한 장일 때의 크기: 생긴 비율 그대로, 220×260 안에 들게. 아주 길쭉한 것도 한 변이 80보다 작아지지 않는다 (그때는 잘라 보여 준다)
    nonisolated static func singleSize(for image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return CGSize(width: 112, height: 112) }
        let scale = min(220 / image.width, 260 / image.height)
        return CGSize(width: max(80, (image.width * scale).rounded()), height: max(80, (image.height * scale).rounded()))
    }
    @Environment(UploadStore.self) private var store: UploadStore?

    private var images: [ChatUpload] { uploads.items.filter { $0.kind == .image } }
    private var pdfs: [ChatUpload] { uploads.items.filter { $0.kind == .pdf } }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if images.count == 1, let only = images.first {
                tile(only, single: true)
            } else if !images.isEmpty {
                // 둘씩 놓는다 (셋이면 마지막 줄은 하나)
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(Array(stride(from: 0, to: images.count, by: 2)), id: \.self) { start in
                        HStack(spacing: 4) {
                            ForEach(images[start..<min(start + 2, images.count)]) { tile($0, single: false) }
                        }
                    }
                }
            }
            ForEach(pdfs) { item in
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(DS.Chat.danger)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name ?? "PDF")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(DS.Chat.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("PDF")
                            .font(.caption)
                            .foregroundStyle(DS.Chat.textSecondary)
                    }
                    if store?.isUploading(item.id) == true { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(DS.Chat.bubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("붙인 PDF \(item.name ?? "")" + (store?.isUploading(item.id) == true ? ", 보내는 중" : ""))
            }
        }
    }

    @ViewBuilder
    private func tile(_ item: ChatUpload, single: Bool) -> some View {
        let image = store?.thumbnail(for: item.id)
        let uploading = store?.isUploading(item.id) == true
        Group {
            if single, let image {
                // 한 장은 생긴 대로 보여 준다 (너무 길거나 넓지 않게)
                let size = Self.singleSize(for: image.size)
                UploadImage(image: image)
                    .frame(width: size.width, height: size.height)
            } else {
                UploadImage(image: image)
                    .frame(width: 112, height: 112)
            }
        }
        .overlay {
            if uploading {
                ZStack {
                    Color.black.opacity(0.35)
                    ProgressView().tint(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Chat.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(uploading ? "붙인 사진, 보내는 중" : "붙인 사진")
    }
}

// MARK: - 카메라로 찍어 붙이기 (D87)

/// 카메라를 열어도 되는지. 권한은 "카메라"를 처음 누를 때에만 묻는다
enum CameraGate {
    enum Step: Equatable {
        /// 바로 연다
        case open
        /// 먼저 권한을 묻는다
        case ask
        /// 꺼 두었다. 열지 않고 설정에서 켜라고 알린다
        case blocked
    }

    static let blockedNotice = "카메라가 꺼져 있어요. 설정 → 모아에서 카메라를 허용해 주세요."

    nonisolated static func step(for status: AVAuthorizationStatus) -> Step {
        switch status {
        case .authorized: .open
        case .notDetermined: .ask
        default: .blocked
        }
    }

    /// 지금 카메라를 열어도 되는지. 아직 묻지 않았으면 여기서 묻는다
    static func mayOpen() async -> Bool {
        switch step(for: AVCaptureDevice.authorizationStatus(for: .video)) {
        case .open: true
        case .ask: await AVCaptureDevice.requestAccess(for: .video)
        case .blocked: false
        }
    }

    /// 카메라가 있는 기기인지 (시뮬레이터에는 없다. 없으면 메뉴에 "카메라"가 나오지 않는다)
    @MainActor static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    /// 찍은 사진을 붙일 바이트로 바꾼다. 여기서는 그대로 담기만 하고, 줄이고 정보를 빼는 일은 `UploadPrep`이 한다
    nonisolated static func data(from photo: UIImage) -> Data? { photo.jpegData(compressionQuality: 0.92) }
}

/// 시스템 카메라 화면. 사진 한 장을 찍어 돌려준다 (취소하면 nil). 찍은 사진은 사진 보관함에 저장하지 않는다
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(
            _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
