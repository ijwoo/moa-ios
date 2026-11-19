import AVKit
import SwiftUI
import UIKit

/// 작업실이 만든 영상 (D112): 대화의 결과 아래에 한 장. 누르면 그때 맥에서 받아(수~수십 MB) 전체 화면으로 재생한다.
/// 받은 파일은 앱의 임시 폴더에만 두고 앱이 뒤로 가면 지운다 (`CaptureStore`). 공유 화면으로 파일 앱 등에 넘기거나,
/// "사진에 저장"으로 사진 보관함에 넣는다 (D113)
struct ReportVideoCard: View {
    let taskID: String
    let attachment: AgentAttachment
    let store: CaptureStore

    private enum Phase: Equatable { case idle, loading, gone, failed }

    @State private var phase: Phase = .idle
    @State private var playing: PlayingVideo?

    struct PlayingVideo: Identifiable {
        let url: URL
        var id: URL { url }
    }

    /// 세로 영상이면 좁게, 가로 영상이면 넓게
    private var width: CGFloat { attachment.aspect < 1 ? 150 : 260 }

    var body: some View {
        Button(action: open) {
            ZStack {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    Group {
                        switch phase {
                        case .loading:
                            ProgressView().tint(.white).controlSize(.large)
                        case .gone:
                            Image(systemName: "clock.badge.xmark")
                        case .failed:
                            Image(systemName: "arrow.clockwise.circle.fill")
                        case .idle:
                            Image(systemName: "play.circle.fill")
                        }
                    }
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.92))
                    Text(statusLine)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
            }
            .frame(width: width, height: width / max(attachment.aspect, 0.3))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(phase == .loading || phase == .gone)
        .accessibilityLabel("만든 영상\(attachment.caption.map { ", \($0)" } ?? "")")
        .accessibilityHint("눌러서 재생해요")
        .fullScreenCover(item: $playing) { video in
            VideoPlayerScreen(url: video.url, caption: attachment.caption)
        }
    }

    private var statusLine: String {
        switch phase {
        case .loading: return "영상을 받는 중…"
        case .gone: return "맥에서 지워진 영상이에요"
        case .failed: return "받지 못했어요. 눌러서 다시"
        case .idle:
            let line = [attachment.caption, Self.size(attachment.bytes)].compactMap { $0 }.joined(separator: " · ")
            return line.isEmpty ? "영상" : line
        }
    }

    static func size(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func open() {
        guard phase != .loading else { return }
        phase = .loading
        Task {
            switch await store.video(taskID, attachment) {
            case .file(let url):
                phase = .idle
                playing = PlayingVideo(url: url)
            case .gone: phase = .gone
            case .failed: phase = .failed
            }
        }
    }
}

/// 전체 화면 재생: 위에 닫기·사진에 저장·공유
struct VideoPlayerScreen: View {
    let url: URL
    let caption: String?
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var sharing = false
    @State private var saving = false
    @State private var saved: PhotoSaver.Outcome?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
            }
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("닫기")
                Spacer()
                if let caption {
                    Text(caption).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer()
                Button(action: save) {
                    Group {
                        if saving {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: saved == .saved ? "checkmark" : "square.and.arrow.down")
                        }
                    }
                    .font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .disabled(saving || saved == .saved)
                .accessibilityLabel(saved == .saved ? "사진에 저장함" : "사진에 저장")
                Button { sharing = true } label: {
                    Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("공유")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 12)
        }
        .overlay(alignment: .bottom) {
            if let saved {
                SaveNote(text: saved.message)
                    .padding(.bottom, 90)
                    .transition(.opacity)
            }
        }
        .onAppear {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $sharing) {
            VideoShareSheet(url: url)
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            let outcome = await PhotoSaver.saveVideo(at: url)
            saving = false
            if outcome == .saved { Haptic.success() } else { Haptic.error() }
            withAnimation { saved = outcome }
            // 저장하지 못했으면 한마디를 잠시 보이고 다시 누를 수 있게 한다
            if outcome != .saved {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { if saved == outcome { saved = nil } }
            }
        }
    }
}

/// 저장한 뒤의 한마디 (전체 화면 위)
struct SaveNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 24)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// 공유 화면 (사진 보관함 권한 문구가 있어 "비디오 저장" 칸도 쓸 수 있다, D113)
private struct VideoShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
