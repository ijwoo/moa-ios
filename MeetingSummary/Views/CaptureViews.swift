import SwiftUI
import UIKit

/// 보고에 붙은 화면 캡처들 (D56, 모양은 D84). 대화 안에서만 쓴다.
///
/// 맥이 작업하면서 본 실제 화면이다. 그림은 `CaptureStore`가 메모리에만 들고 있다.
/// 작은 그림으로 포개어 바로 보여 주고, 누르면 크게 본다 (D84. 전에는 로그인한 화면의 캡처를 가려 두었다).
/// 복사·공유·저장은 붙이지 않는다.
struct ReportCaptures: View {
    let taskID: String
    let attachments: [AgentAttachment]
    /// 같은 결과에 "○○ 열기" 줄로 보이는 사이트: 설명에서 그 주소를 되풀이하지 않는다 (D83)
    var linkedSites: Set<String> = []
    @Environment(CaptureStore.self) private var store: CaptureStore?

    var body: some View {
        // 그림을 받아 줄 곳이 없으면(미리 보기 등) 아무것도 그리지 않는다
        if let store, !attachments.isEmpty {
            let pictures = attachments.filter { !$0.isVideo }
            VStack(alignment: .leading, spacing: 10) {
                // 작업실이 만든 영상 (D112): 누를 때만 받아 재생한다
                ForEach(attachments.filter(\.isVideo)) { video in
                    ReportVideoCard(taskID: taskID, attachment: video, store: store)
                }
                if !pictures.isEmpty {
                    CaptureGroup(taskID: taskID, attachments: pictures, linkedSites: linkedSites, store: store)
                }
            }
        }
    }
}

/// 캡처 한 장의 지금 상태
private enum CaptureContent: Equatable {
    case waiting
    /// 작은 그림 (크게 볼 때는 원래 그림을 다시 꺼낸다)
    case image(UIImage)
    case gone
    case failed
}

/// 한 보고의 캡처 묶음: 포개 놓은 작은 그림들 + 그 아래 한 줄 설명.
/// 접어 둔 것·지워진 것·받지 못한 것은 그림 자리 없이 한 줄로 알린다
private struct CaptureGroup: View {
    let taskID: String
    let attachments: [AgentAttachment]
    let linkedSites: Set<String>
    let store: CaptureStore

    /// 다시 받아야 하는 때: 접었다 펴거나, 앱이 뒤로 갔다 오거나, 다시 시도를 누를 때
    private struct LoadKey: Equatable {
        var shown: [Bool]
        var wasSeen: Bool
        var isOnScreen: Bool
        var generation: Int
        var attempt: Int
    }

    /// 크게 보기를 연 캡처
    private struct Viewing: Identifiable {
        let id: String
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contents: [String: CaptureContent] = [:]
    @State private var attempt = 0
    @State private var viewing: Viewing?
    /// 이 자리가 화면에 한 번이라도 보였는지. 대화는 말을 한꺼번에 놓으므로(D69), 놓였다고 받지 않고 보였을 때 받는다
    @State private var wasSeen = false

    private func content(_ attachment: AgentAttachment) -> CaptureContent {
        contents[attachment.id] ?? .waiting
    }

    private var loadKey: LoadKey {
        LoadKey(
            shown: attachments.map { store.isShown(taskID, $0) }, wasSeen: wasSeen,
            isOnScreen: scenePhase != .background, generation: store.generation, attempt: attempt
        )
    }

    /// 그림으로 포개어 보여 주는 것: 접어 두지 않았고, 받는 중이거나 받은 것
    private func isPiled(_ attachment: AgentAttachment) -> Bool {
        guard store.isShown(taskID, attachment) else { return false }
        switch content(attachment) {
        case .waiting, .image: return true
        case .gone, .failed: return false
        }
    }

    private func label(_ attachment: AgentAttachment) -> String {
        let label = attachment.label(besides: linkedSites)
        return label.isEmpty ? "화면 캡처" : label
    }

    var body: some View {
        let piled = attachments.filter(isPiled)
        let lined = attachments.filter { !isPiled($0) }
        VStack(alignment: .leading, spacing: 8) {
            if !piled.isEmpty {
                CapturePile(
                    items: piled.enumerated().map { index, attachment in
                        CapturePile.Item(
                            attachment: attachment, content: content(attachment),
                            spoken: piled.count == 1 ? "화면 캡처, \(label(attachment))" : "화면 캡처 \(piled.count)장 중 \(index + 1)번째, \(label(attachment))"
                        )
                    },
                    onOpen: { viewing = Viewing(id: $0) }
                )
                Label(piled.count == 1 ? label(piled[0]) : "화면 캡처 \(piled.count)장", systemImage: "camera.viewfinder")
                    .font(.footnote)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .lineLimit(2)
                    .padding(.leading, 4)
                    .accessibilityHidden(true)
            }
            ForEach(lined) { attachment in
                switch content(attachment) {
                case .gone:
                    // 맥이 지운 캡처는 자리도 그리지 않는다 (D119: 답 사이의 조각을 줄인다. 맥은 캡처를 하루까지만 보관한다)
                    EmptyView()
                case .failed:
                    notice("캡처를 받지 못했어요", detail: nil, icon: "exclamationmark.triangle") {
                        Button("다시 시도") { attempt += 1 }
                            .font(.footnote.weight(.semibold))
                            .frame(minHeight: DS.minTouch)
                    }
                case .waiting, .image:
                    folded(attachment)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: contents)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: loadKey.shown)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            if visible { wasSeen = true }
        }
        .task(id: loadKey) { await refresh() }
        .fullScreenCover(item: $viewing) { viewing in
            CaptureViewer(
                taskID: taskID,
                // 크게 볼 수 있는 것: 지금 작은 그림으로 보이는 것
                attachments: attachments.filter { if case .image = content($0) { store.isShown(taskID, $0) } else { false } },
                label: label, store: store, current: viewing.id
            ) { attachment in
                self.viewing = nil
                store.hide(taskID, attachment)
            }
        }
    }

    /// 접어 둔 캡처: 한 줄. 누르면 다시 그림으로 보여 준다 (무엇의 캡처인지 · 접어 두었다 · 보기)
    private func folded(_ attachment: AgentAttachment) -> some View {
        let label = label(attachment)
        return Button {
            store.reveal(taskID, attachment)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Chat.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(DS.Chat.textPrimary)
                        .lineLimit(2)
                    Text("가려 둔 화면 캡처예요")
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("보기")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.Chat.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(DS.Chat.elevated, in: RoundedRectangle(cornerRadius: DS.Chat.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.Chat.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("가려 둔 화면 캡처, \(label)")
        .accessibilityHint("눌러서 다시 봅니다")
        .accessibilityAddTraits(.isButton)
    }

    /// 그림 대신 한 줄: 지워졌다 · 받지 못했다
    private func notice(_ title: String, detail: String?, icon: String, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Chat.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DS.Chat.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(DS.Chat.elevated, in: RoundedRectangle(cornerRadius: DS.Chat.cardRadius, style: .continuous))
    }

    private func refresh() async {
        let isOnScreen = scenePhase != .background
        // 앱이 뒤로 가면 크게 보던 것도 닫는다
        if !isOnScreen { viewing = nil }
        for attachment in attachments {
            let id = attachment.id
            // 맥이 지웠을 시각이 지났으면 묻지 않고 알려 준다
            if attachment.isExpired() {
                if viewing?.id == id { viewing = nil }
                contents[id] = .gone
                continue
            }
            guard store.isShown(taskID, attachment), isOnScreen else {
                // 접어 두었거나 앱이 뒤로 갔다: 들고 있던 그림을 버린다
                if content(attachment) != .gone { contents[id] = .waiting }
                continue
            }
            if case .image = content(attachment) { continue }
            // 아직 화면에 보인 적이 없으면 받지 않는다
            guard wasSeen else { continue }
            if content(attachment) == .failed { contents[id] = .waiting }
            let loaded = await store.load(taskID, attachment)
            guard !Task.isCancelled else { return }
            switch loaded {
            case .image(let data):
                contents[id] = await Self.thumbnail(data).map(CaptureContent.image) ?? .failed
            case .gone:
                contents[id] = .gone
            case .failed:
                contents[id] = .failed
            }
        }
    }

    /// 포개 놓을 작은 그림. 원래 그림을 그대로 들고 있지 않는다 (여러 장이 대화에 놓여도 메모리를 적게 쓴다).
    /// 아주 긴 화면은 위쪽만 남긴다 (전체는 눌러서 본다)
    private static func thumbnail(_ data: Data) async -> UIImage? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        var source = image
        let visible = CGRect(x: 0, y: 0, width: image.size.width, height: min(image.size.height, (image.size.width / CapturePile.minAspect).rounded()))
        if visible.height < image.size.height, let cropped = image.cgImage?.cropping(to: visible) {
            source = UIImage(cgImage: cropped)
        }
        let width = min(source.size.width, CapturePile.pixelWidth)
        let size = CGSize(width: width, height: (source.size.height * width / source.size.width).rounded())
        return await source.byPreparingThumbnail(ofSize: size) ?? source
    }
}

/// 포개 놓은 작은 그림들: 한 장씩 조금 기울여 아래로 비껴 쌓는다 (D84)
private struct CapturePile: View {
    struct Item: Identifiable {
        let attachment: AgentAttachment
        let content: CaptureContent
        /// VoiceOver가 읽는 말
        let spoken: String
        var id: String { attachment.id }
    }

    let items: [Item]
    let onOpen: (String) -> Void

    /// 작은 그림의 가로÷세로 한도. 가로로 긴 화면 꼴로 맞춘다
    static let minAspect: CGFloat = 1.2
    static let maxAspect: CGFloat = 1.7
    /// 들고 있는 작은 그림의 폭 (픽셀. 가장 큰 자리의 3배)
    static let pixelWidth: CGFloat = 540
    /// 한 장씩 비껴 놓는 거리
    private static let step = CGSize(width: 30, height: 54)
    private static let tilts: [Double] = [-3, 2.5, -1.5, 3]

    private var width: CGFloat { items.count == 1 ? 180 : 150 }

    private func size(_ attachment: AgentAttachment) -> CGSize {
        let aspect = min(max(attachment.aspect, Self.minAspect), Self.maxAspect)
        return CGSize(width: width, height: (width / aspect).rounded())
    }

    private var bounds: CGSize {
        var bounds = CGSize.zero
        for (index, item) in items.enumerated() {
            let size = size(item.attachment)
            bounds.width = max(bounds.width, CGFloat(index) * Self.step.width + size.width)
            bounds.height = max(bounds.height, CGFloat(index) * Self.step.height + size.height)
        }
        return bounds
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                CaptureThumb(content: item.content, size: size(item.attachment), spoken: item.spoken) {
                    onOpen(item.id)
                }
                // 여러 장일 때만 비스듬히 겹쳐 놓는다. 한 장은 반듯하게 (D107)
                .rotationEffect(.degrees(items.count > 1 ? Self.tilts[index % Self.tilts.count] : 0))
                .offset(x: CGFloat(index) * Self.step.width, y: CGFloat(index) * Self.step.height)
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        // 기울어진 모서리와 그림자가 놓일 자리
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }
}

/// 작은 그림 한 장. 누르면 크게 본다
private struct CaptureThumb: View {
    let content: CaptureContent
    let size: CGSize
    let spoken: String
    let action: () -> Void

    private var isLoaded: Bool {
        if case .image = content { true } else { false }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            ZStack {
                DS.Chat.elevated
                if case .image(let image) = content {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .transition(.opacity)
                } else {
                    ProgressView()
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(DS.Chat.hairline, lineWidth: 1) }
            .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!isLoaded)
        .accessibilityLabel(isLoaded ? spoken : "캡처를 받는 중")
        .accessibilityHint(isLoaded ? "크게 봅니다" : "")
    }
}

/// 캡처 크게 보기: 옆으로 넘겨 다음 장을 보고, 두 손가락으로 키우고, 두 번 눌러 키웠다 줄인다
private struct CaptureViewer: View {
    let taskID: String
    let attachments: [AgentAttachment]
    let label: (AgentAttachment) -> String
    let store: CaptureStore
    @State var current: String
    /// "가리기": 닫으면서 그 캡처를 접어 둔다
    let onHide: (AgentAttachment) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    /// 사진에 저장한 결과 (그림 번호별)
    @State private var saved: [String: PhotoSaver.Outcome] = [:]

    private var shown: AgentAttachment? {
        attachments.first { $0.id == current } ?? attachments.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(attachments) { attachment in
                    CapturePage(taskID: taskID, attachment: attachment, label: label(attachment), store: store)
                        .tag(attachment.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: DS.minTouch, height: DS.minTouch)
                }
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("닫기")
                Spacer()
                // 맥이 만든 그림만 사진에 저장할 수 있다 (D113). 맥의 브라우저 화면 캡처는 넣지 않는다
                if let shown, shown.kind == .image {
                    Button {
                        save(shown)
                    } label: {
                        Group {
                            if saving {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: saved[shown.id] == .saved ? "checkmark" : "square.and.arrow.down")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .frame(width: DS.minTouch, height: DS.minTouch)
                    }
                    .glassEffect(.regular.interactive(), in: Circle())
                    .disabled(saving || saved[shown.id] == .saved)
                    .accessibilityLabel(saved[shown.id] == .saved ? "사진에 저장함" : "사진에 저장")
                }
                if let shown {
                    Button {
                        onHide(shown)
                    } label: {
                        Label("가리기", systemImage: "eye.slash")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(height: DS.minTouch)
                    }
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .accessibilityHint("이 캡처를 대화에서 접어 둡니다")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 4) {
                if attachments.count > 1, let shown, let index = attachments.firstIndex(of: shown) {
                    Text("\(index + 1) / \(attachments.count)")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .accessibilityLabel("\(attachments.count)장 중 \(index + 1)번째")
                }
                if let shown {
                    Text(label(shown))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .overlay(alignment: .bottom) {
            if let shown, let outcome = saved[shown.id] {
                SaveNote(text: outcome.message)
                    .padding(.bottom, 80)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save(_ attachment: AgentAttachment) {
        guard !saving else { return }
        saving = true
        Task {
            let outcome: PhotoSaver.Outcome
            if case .image(let data) = await store.load(taskID, attachment) {
                outcome = await PhotoSaver.saveImage(data)
            } else {
                outcome = .failed
            }
            saving = false
            if outcome == .saved { Haptic.success() } else { Haptic.error() }
            withAnimation { saved[attachment.id] = outcome }
            if outcome != .saved {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { if saved[attachment.id] == outcome { saved[attachment.id] = nil } }
            }
        }
    }
}

/// 크게 보기의 한 장: 원래 그림을 `CaptureStore`에서 꺼낸다 (들고 있지 않으면 다시 받는다)
private struct CapturePage: View {
    let taskID: String
    let attachment: AgentAttachment
    let label: String
    let store: CaptureStore
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image)
                    .accessibilityLabel("화면 캡처, \(label)")
            } else if failed {
                Text("캡처를 받지 못했어요")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("캡처를 받는 중")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard image == nil else { return }
            if case .image(let data) = await store.load(taskID, attachment), let loaded = UIImage(data: data) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// 키웠다 줄일 수 있는 그림 (UIScrollView)
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear

        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.imageView = view

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                // 누른 곳을 가운데로 3배
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
