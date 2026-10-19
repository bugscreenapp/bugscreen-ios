import AVKit
import Combine
import SwiftUI

struct NativeVideoPreview: View {
    let isActive: Bool
    @StateObject private var playback: VideoPreviewPlayback

    init(url: URL, isActive: Bool) {
        self.isActive = isActive
        _playback = StateObject(wrappedValue: VideoPreviewPlayback(url: url))
    }

    var body: some View {
        let playback = playback
        return Group {
            if playback.failed {
                Text(SDKStrings.videoUnavailable).foregroundColor(.white)
            } else {
                VStack(spacing: 12) {
                    NativeVideoPlayer(player: playback.player)
                    playbackControls(playback: playback)
                }
            }
        }
        .onChange(of: isActive) { if !$0 { playback.player.pause() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in playback.player.pause() }
        .onDisappear { playback.player.pause() }
    }

    private func playbackControls(playback: VideoPreviewPlayback) -> some View {
        HStack(spacing: 12) {
            Button(action: playback.togglePlayback) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? SDKStrings.videoPause : SDKStrings.videoPlay)

            Slider(value: Binding(get: { playback.position }, set: { playback.position = $0 }), in: 0 ... max(
                playback.duration,
                0.01
            )) { editing in
                playback.isSeeking = editing
                if !editing { playback.seek() }
            }
            .accessibilityLabel(SDKStrings.videoSeek)
            .accessibilityValue(SDKStrings.videoDuration(Int(playback.position)))

            Text("\(timestamp(playback.position)) / \(timestamp(playback.duration))")
                .font(.system(size: 12).monospacedDigit())
        }
        .foregroundColor(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .disabled(playback.duration <= 0 || !isActive)
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

@MainActor
final class VideoPreviewPlayback: ObservableObject {
    let player: AVPlayer
    @Published private(set) var failed = false
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var position: Double = 0
    var isSeeking = false
    private var subscriptions = Set<AnyCancellable>()
    private var timeObserver: Any?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
            self?.failed = status == .failed
        }.store(in: &subscriptions)
        item.publisher(for: \.duration).receive(on: DispatchQueue.main).sink { [weak self] duration in
            self?.duration = duration.seconds.isFinite ? max(0, duration.seconds) : 0
        }.store(in: &subscriptions)
        player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink { [weak self] status in
            self?.isPlaying = status != .paused
        }.store(in: &subscriptions)
        timeObserver = player
            .addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self, !isSeeking, time.seconds.isFinite else { return }
                    position = min(max(0, time.seconds), duration)
                }
            }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            if position >= duration { player.seek(to: .zero) }
            player.play()
        }
    }

    func seek() {
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context _: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        // A persistent SwiftUI toolbar owns playback; AVKit's inline controls start hidden.
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context _: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator _: Void) {
        controller.player?.pause()
        controller.player = nil
    }
}
